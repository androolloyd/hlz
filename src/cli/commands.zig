const std = @import("std");
const posix = std.posix;
const hlz = @import("hlz");
const runtime = hlz.runtime;
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const output_mod = @import("output.zig");
const keystore = @import("keystore.zig");
const client_mod = hlz.hypercore.client;
const response = hlz.hypercore.response;
const types = hlz.hypercore.types;
const signing = hlz.hypercore.signing;
const json_mod = hlz.hypercore.json;
const ws_types = hlz.hypercore.ws;
const WsConnection = ws_types.Connection;
const Decimal = hlz.math.decimal.Decimal;

const Client = client_mod.Client;
const Signer = hlz.crypto.signer.Signer;
const Column = output_mod.Column;
const Style = output_mod.Style;
const Writer = output_mod.Writer;
const Config = config_mod.Config;

pub const CmdError = client_mod.ClientError || config_mod.ConfigError || error{
    Overflow,
    MissingAddress,
    MissingKey,
    AddressMismatch,
    AssetNotFound,
    CommandFailed,
    InvalidFlag,
    BrokenPipe,
};

var stream_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var stream_socket_fd: std.atomic.Value(std.posix.fd_t) = std.atomic.Value(std.posix.fd_t).init(-1);

fn makeClient(allocator: std.mem.Allocator, config: Config) Client {
    return switch (config.chain) {
        .mainnet => Client.mainnet(allocator),
        .testnet => Client.testnet(allocator),
    };
}

fn stdoutWriteAll(io: std.Io, data: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, data) catch {};
}

fn stderrWriteAll(io: std.Io, data: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, data) catch {};
}

fn stderrWriteAllSimple(data: []const u8) void {
    stderrWriteAll(runtime.io(), data);
}

fn stdinReadAll(buf: []u8) usize {
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.posix.read(std.posix.STDIN_FILENO, buf[len..]) catch break;
        if (n == 0) break;
        len += n;
    }
    return len;
}

const ListW = @import("List");
const App = @import("App");
const BufMod = @import("Buffer");

const ListViewOpts = struct {
    title: []const u8 = "",
    help: []const u8 = "j/k:nav  /:search  s:sort  q:quit",
    on_render_cell: ?ListW.RenderCellFn = null,
    on_select: ?*const fn (allocator: std.mem.Allocator, config: Config, items: []const ListW.Item, idx: usize) void = null,
    allocator: std.mem.Allocator = undefined,
    config: Config = undefined,
};

fn runListView(
    columns: []const ListW.Column,
    items: []const ListW.Item,
    count: usize,
    opts: ListViewOpts,
) !void {
    var list = ListW.init(columns, items, count);
    list.title = opts.title;
    list.help = opts.help;
    list.on_render_cell = opts.on_render_cell;

    var app = App.init(opts.allocator, runtime.io()) catch {
        stderrWriteAllSimple("error: requires an interactive terminal\n");
        return error.CommandFailed;
    };
    defer app.deinit();
    app.setTickMs(100);

    while (app.running) {
        app.beginFrame();
        list.render(&app.buf, app.fullRect());
        app.endFrame();
        app.tick();

        if (app.pollKey()) |key| {
            switch (list.handleKey(key)) {
                .quit => app.running = false,
                .select => {
                    if (opts.on_select) |cb| {
                        if (list.selectedIndex()) |idx| {
                            app.deinit();
                            cb(opts.allocator, opts.config, items, idx);
                            app = App.init(opts.allocator, runtime.io()) catch {
                                stderrWriteAllSimple("error: failed to restore terminal\n");
                                return error.CommandFailed;
                            };
                            app.setTickMs(100);
                        }
                    }
                },
                else => {},
            }
        }
    }
}

fn fail(w: *Writer, msg: []const u8) CmdError!void {
    try w.fail(msg);
    return error.CommandFailed;
}

fn failFmt(w: *Writer, comptime fmt: []const u8, a: anytype) CmdError!void {
    try w.failFmt(fmt, a);
    return error.CommandFailed;
}

const WriteAuth = struct {
    signer: Signer,
    address_buf: [42]u8,

    fn address(self: *const WriteAuth) []const u8 {
        return self.address_buf[0..];
    }
};

fn getWriteAuth(w: *Writer, config: Config) CmdError!WriteAuth {
    const signer = config.getSigner() catch |e| return e;
    var auth = WriteAuth{
        .signer = signer,
        .address_buf = undefined,
    };
    const signer_addr = signer.addressHex(&auth.address_buf);
    if (config.address) |addr| {
        if (!std.ascii.eqlIgnoreCase(addr, signer_addr)) {
            try w.failFmt("--address {s} does not match signer address {s} for write commands", .{ addr, signer_addr });
            return error.AddressMismatch;
        }
    }
    return auth;
}

pub fn keys(allocator: std.mem.Allocator, w: *Writer, a: args_mod.KeysArgs) !void {
    const password = a.password orelse runtime.getenv("HL_PASSWORD") orelse {
        // For ls, no password needed
        if (a.action == .ls) return keysLs(allocator, w);
        if (a.action == .rm) return keysRm(w, a.name orelse {
            try w.err("usage: hlz keys rm <name>");
            return error.MissingArgument;
        });
        if (a.action == .default) return keysDefault(w, a.name orelse {
            try w.err("usage: hlz keys default <name>");
            return error.MissingArgument;
        });
        try w.err("password required: --password <PASS> or HL_PASSWORD env");
        return error.MissingKey;
    };

    switch (a.action) {
        .ls => return keysLs(allocator, w),
        .new => {
            const name = a.name orelse {
                try w.err("usage: hlz keys new <name> --password <PASS>");
                return error.MissingArgument;
            };
            // Generate random 32-byte private key
            var priv: [32]u8 = undefined;
            runtime.fillRandomSecure(&priv) catch |e| {
                return failFmt(w, "keygen: {s}", .{@errorName(e)});
            };
            const json = keystore.encrypt(allocator, priv, password) catch |e| {
                return failFmt(w, "encrypt: {s}", .{@errorName(e)});
            };
            defer allocator.free(json);
            keystore.save(name, json) catch |e| {
                return failFmt(w, "save: {s}", .{@errorName(e)});
            };
            const signer = Signer.init(priv) catch {
                return fail(w, "invalid private key");
            };
            var addr_buf: [42]u8 = undefined;
            _ = signer.addressHex(&addr_buf);
            // Zero out key
            @memset(&priv, 0);
            if (w.format == .json) {
                try w.jsonFmt("{{\"status\":\"created\",\"name\":\"{s}\",\"address\":\"{s}\"}}", .{ name, addr_buf });
            } else {
                try w.success(name);
                try w.print("  address: {s}\n  path:    ~/.hl/keys/{s}.json\n", .{ addr_buf, name });
                try w.nl();
                try w.styled(Style.muted, "  To use as API wallet, approve on your main account:\n");
                try w.print("    hlz approve-agent {s}\n", .{addr_buf});
                try w.styled(Style.muted, "  Or approve via web UI:\n");
                try w.print("    https://app.hyperliquid.xyz/API\n", .{});
            }
        },
        .import_ => {
            const name = a.name orelse {
                try w.err("usage: hlz keys import <name> --private-key <HEX> --password <PASS>");
                return error.MissingArgument;
            };
            const hex = a.key_hex orelse runtime.getenv("HL_KEY") orelse {
                try w.err("provide key: --private-key <HEX> or HL_KEY env");
                return error.MissingKey;
            };
            const signer = Signer.fromHex(hex) catch {
                try w.err("invalid private key hex");
                return error.MissingKey;
            };
            var priv: [32]u8 = signer.private_key;
            const json = keystore.encrypt(allocator, priv, password) catch |e| {
                return failFmt(w, "encrypt: {s}", .{@errorName(e)});
            };
            defer allocator.free(json);
            keystore.save(name, json) catch |e| {
                return failFmt(w, "save: {s}", .{@errorName(e)});
            };
            @memset(&priv, 0);
            var addr_buf: [42]u8 = undefined;
            _ = signer.addressHex(&addr_buf);
            if (w.format == .json) {
                try w.jsonFmt("{{\"status\":\"imported\",\"name\":\"{s}\",\"address\":\"{s}\"}}", .{ name, addr_buf });
            } else {
                try w.success(name);
                try w.print("  address: {s}\n  path: ~/.hl/keys/{s}.json\n", .{ addr_buf, name });
            }
        },
        .export_ => {
            const name = a.name orelse {
                try w.err("usage: hlz keys export <name> --password <PASS>");
                return error.MissingArgument;
            };
            const data = keystore.load(allocator, name) catch {
                return failFmt(w, "key \"{s}\" not found", .{name});
            };
            defer allocator.free(data);
            var priv = keystore.decrypt(allocator, data, password) catch |e| {
                if (e == error.BadPassword) {
                    try w.fail("wrong password");
                } else {
                    try w.failFmt("decrypt: {s}", .{@errorName(e)});
                }
                return error.CommandFailed;
            };
            // Print hex (stderr for safety, stdout only if piped/json)
            var hex_buf: [66]u8 = undefined;
            hex_buf[0] = '0';
            hex_buf[1] = 'x';
            const hc = "0123456789abcdef";
            for (priv, 0..) |b, i| {
                hex_buf[2 + i * 2] = hc[b >> 4];
                hex_buf[2 + i * 2 + 1] = hc[b & 0xf];
            }
            @memset(&priv, 0);
            if (w.format == .json) {
                try w.jsonFmt("{{\"name\":\"{s}\",\"key\":\"{s}\"}}", .{ name, hex_buf });
            } else {
                try w.print("{s}\n", .{hex_buf});
            }
            @memset(&hex_buf, 0);
        },
        .rm => {
            const name = a.name orelse {
                try w.err("usage: hlz keys rm <name>");
                return error.MissingArgument;
            };
            return keysRm(w, name);
        },
        .default => {
            const name = a.name orelse {
                try w.err("usage: hlz keys default <name>");
                return error.MissingArgument;
            };
            return keysDefault(w, name);
        },
    }
}

fn keysLs(allocator: std.mem.Allocator, w: *Writer) !void {
    const entries = keystore.list(allocator) catch {
        return fail(w, "failed to list keys");
    };
    defer allocator.free(entries);

    if (entries.len == 0) {
        if (w.format == .json) {
            try w.jsonRaw("[]");
        } else {
            try w.styled(Style.muted, "  no keys. Run: hlz keys new <name> --password <PASS>\n");
        }
        return;
    }

    if (w.format == .json) {
        var jbuf: [4096]u8 = undefined;
        var jlen: usize = 0;
        jbuf[0] = '[';
        jlen = 1;
        for (entries, 0..) |e, i| {
            if (i > 0) {
                jbuf[jlen] = ',';
                jlen += 1;
            }
            jlen += (std.fmt.bufPrint(jbuf[jlen..], "{{\"name\":\"{s}\",\"address\":\"{s}\",\"default\":{s}}}", .{
                e.getName(), e.address, if (e.is_default) "true" else "false",
            }) catch break).len;
        }
        jbuf[jlen] = ']';
        jlen += 1;
        try w.jsonRaw(jbuf[0..jlen]);
        return;
    }

    try w.heading("KEYS");
    for (entries) |e| {
        const default_mark: []const u8 = if (e.is_default) " *" else "";
        try w.print("  ", .{});
        try w.styled(Style.bold_cyan, e.getName());
        try w.styled(Style.muted, "  ");
        try w.styled(Style.white, &e.address);
        try w.styled(Style.yellow, default_mark);
        try w.nl();
    }
    try w.footer();
}

fn keysRm(w: *Writer, name: []const u8) !void {
    keystore.remove(name) catch {
        return failFmt(w, "key \"{s}\" not found", .{name});
    };
    if (w.format == .json) {
        try w.jsonFmt("{{\"status\":\"removed\",\"name\":\"{s}\"}}", .{name});
    } else {
        try w.success("removed");
        try w.print("  {s}\n", .{name});
    }
}

fn keysDefault(w: *Writer, name: []const u8) !void {
    // Verify key exists
    const home = runtime.getenv("HOME") orelse "";
    var pbuf: [576]u8 = undefined;
    const kpath = std.fmt.bufPrint(&pbuf, "{s}/.hl/keys/{s}.json", .{ home, name }) catch {
        return failFmt(w, "key \"{s}\" not found", .{name});
    };
    {
        std.Io.Dir.cwd().access(runtime.io(), kpath, .{}) catch {
            return failFmt(w, "key \"{s}\" not found", .{name});
        };
    }
    keystore.setDefault(name) catch {
        return fail(w, "failed to set default");
    };
    if (w.format == .json) {
        try w.jsonFmt("{{\"status\":\"default\",\"name\":\"{s}\"}}", .{name});
    } else {
        try w.success("default set");
        try w.print("  {s}\n", .{name});
    }
}

pub fn approveAgent(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.ApproveAgentArgs) !void {
    const agent_addr = a.agent_address orelse {
        try w.err("usage: hlz approve-agent <ADDRESS> [--name <NAME>]");
        try w.nl();
        try w.styled(Style.muted, "  Or approve via web UI:\n");
        const url: []const u8 = if (config.chain == .mainnet) "https://app.hyperliquid.xyz/API" else "https://app.hyperliquid-testnet.xyz/API";
        try w.print("  {s}\n", .{url});
        return error.MissingArgument;
    };
    const auth = try getWriteAuth(w, config);
    var client = switch (config.chain) {
        .mainnet => Client.mainnet(allocator),
        .testnet => Client.testnet(allocator),
    };
    defer client.deinit();
    const nonce = runtime.nonceMs();
    const addr = Client.parseAddress(agent_addr) catch {
        try w.err("invalid agent address");
        return;
    };
    var result = client.approveAgent(auth.signer, addr, a.agent_name, nonce) catch |e| {
        return failFmt(w, "approve failed: {s}", .{@errorName(e)});
    };
    defer result.deinit();
    if (result.isOk() catch false) {
        if (w.format == .json) {
            try w.jsonFmt("{{\"status\":\"approved\",\"agent\":\"{s}\"}}", .{agent_addr});
        } else {
            try w.success("Agent approved");
            try w.print("  {s}\n", .{agent_addr});
        }
    } else {
        const val = result.json() catch {
            return fail(w, "Agent approval rejected");
        };
        const resp = json_mod.getString(val, "response") orelse "rejected";
        return failFmt(w, "Approval failed: {s}", .{resp});
    }
}

pub fn showConfig(w: *Writer, config: Config) !void {
    if (w.format == .json) {
        try w.jsonFmt("{{\"chain\":\"{s}\",\"address\":{s},\"key_set\":{s}}}", .{
            if (config.chain == .mainnet) "mainnet" else "testnet",
            if (config.address) |a| a else "null",
            if (config.key_hex != null) "true" else "false",
        });
        return;
    }
    try w.heading("CONFIG");
    try w.print("│ Chain:    {s}\n", .{if (config.chain == .mainnet) "mainnet" else "testnet"});
    try w.print("│ Address:  {s}\n", .{config.address orelse "(not set)"});
    try w.print("│ Key:      {s}\n", .{if (config.key_hex != null) "✓ loaded" else "✗ not set"});
    try w.footer();
}

pub fn mids(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.MidsArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    var result = try client.allMids(a.dex);
    defer result.deinit();

    const val = try result.json();
    if (val != .object) {
        return fail(w, "unexpected response from allMids");
    }

    // Resolve @index → human-readable spot pair names via universe + tokens
    var spot_names: [512][48]u8 = undefined;
    var spot_count: usize = 0;
    if (hasAtKeys(val)) {
        var spot_result = client.getSpotMeta() catch null;
        defer if (spot_result) |*sr| sr.deinit();
        if (spot_result) |sr| {
            const tokens = sr.value.tokens;
            for (sr.value.universe, 0..) |pair, i| {
                if (i >= 512) break;
                // Use pair.name if canonical, else build from token names
                const name_src = if (pair.name.len > 0 and pair.name[0] != '@')
                    pair.name
                else blk: {
                    const base_t = response.findSpotToken(tokens, pair.tokens[0]) orelse break :blk pair.name;
                    const quote_t = response.findSpotToken(tokens, pair.tokens[1]) orelse break :blk pair.name;
                    const base = base_t.name;
                    const quote = quote_t.name;
                    const total_len = base.len + 1 + quote.len;
                    if (total_len >= 47) break :blk pair.name;
                    @memcpy(spot_names[i][0..base.len], base);
                    spot_names[i][base.len] = '/';
                    @memcpy(spot_names[i][base.len + 1 .. base.len + 1 + quote.len], quote);
                    spot_names[i][total_len] = 0;
                    break :blk spot_names[i][0..total_len];
                };
                if (name_src.ptr != &spot_names[i]) {
                    const len = @min(name_src.len, 47);
                    @memcpy(spot_names[i][0..len], name_src[0..len]);
                    spot_names[i][len] = 0;
                }
                spot_count = i + 1;
            }
        }
    }

    const MidEntry = struct { coin: []const u8, mid: []const u8, resolved: ?[]const u8 };
    var entries = try allocator.alloc(MidEntry, val.object.count());
    defer allocator.free(entries);
    var total: usize = 0;

    var iter = val.object.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const resolved: ?[]const u8 = if (key.len > 1 and key[0] == '@') blk: {
            const idx = std.fmt.parseInt(usize, key[1..], 10) catch break :blk null;
            if (idx < spot_count) {
                const name_buf = &spot_names[idx];
                const len = std.mem.indexOfScalar(u8, name_buf, 0) orelse name_buf.len;
                break :blk name_buf[0..len];
            }
            break :blk null;
        } else null;
        entries[total] = .{
            .coin = key,
            .mid = switch (entry.value_ptr.*) {
                .string => |s| s,
                else => "?",
            },
            .resolved = resolved,
        };
        total += 1;
    }

    if (w.format == .json) {
        // coin names are alphanumeric from HL API, no JSON escaping needed
        const buf_size = total * 48 + 16;
        var jbuf = try allocator.alloc(u8, buf_size);
        defer allocator.free(jbuf);
        var jlen: usize = 0;
        jbuf[0] = '{';
        jlen = 1;
        var first = true;
        for (entries[0..total]) |e| {
            const display = e.resolved orelse e.coin;
            if (a.coin) |f| {
                if (!containsInsensitive(display, f)) continue;
            }
            if (!first) {
                jbuf[jlen] = ',';
                jlen += 1;
            }
            jlen += (std.fmt.bufPrint(jbuf[jlen..], "\"{s}\":\"{s}\"", .{ display, e.mid }) catch return error.Overflow).len;
            first = false;
        }
        jbuf[jlen] = '}';
        jlen += 1;
        try w.jsonRaw(jbuf[0..jlen]);
        return;
    }

    if (w.is_tty and !a.all and a.page == 1 and a.coin == null) {
        return midsTui(allocator, config, entries[0..total]);
    }

    try w.heading("MID PRICES");
    const hdr = [_]Column{
        .{ .text = "COIN", .width = 14 },
        .{ .text = "MID", .width = 16, .align_right = true },
    };
    try w.tableHeader(&hdr);

    var filtered: usize = 0;
    for (entries[0..total]) |e| {
        const display = e.resolved orelse e.coin;
        if (a.coin) |f| {
            if (!containsInsensitive(display, f)) continue;
        }
        entries[filtered] = e;
        filtered += 1;
    }

    const per_page: usize = 20;
    const start = if (a.all or a.coin != null) @as(usize, 0) else (a.page -| 1) * per_page;
    const limit = if (a.all or a.coin != null) filtered else per_page;
    const end = @min(start + limit, filtered);

    for (entries[start..end]) |e| {
        const display = e.resolved orelse e.coin;
        const cols = [_]Column{
            .{ .text = display, .width = 14, .color = Style.cyan },
            .{ .text = e.mid, .width = 16, .align_right = true, .color = Style.white },
        };
        try w.tableRow(&cols);
    }
    const pages = (filtered + per_page - 1) / per_page;
    if (!a.all and a.coin == null and end < filtered) try w.paginatePage(end - start, filtered, a.page, pages);
    try w.footer();
}

fn midsTui(allocator: std.mem.Allocator, config: Config, entries: anytype) !void {
    _ = config;
    const n = @min(entries.len, ListW.MAX_ITEMS);

    var items: [ListW.MAX_ITEMS]ListW.Item = undefined;
    const cyan = BufMod.Style{ .fg = .cyan, .bold = true };
    const white = BufMod.Style{ .fg = .bright_white };

    for (0..n) |i| {
        const display = entries[i].resolved orelse entries[i].coin;
        items[i] = .{
            .cells = cellsInit(&.{ display, entries[i].mid }),
            .styles = stylesInit(&.{ cyan, white }),
            .sort_key = std.fmt.parseFloat(f64, entries[i].mid) catch 0,
        };
    }

    const columns = [_]ListW.Column{
        .{ .label = "COIN", .width = 14 },
        .{ .label = "MID", .width = 16, .right_align = true },
    };

    try runListView(&columns, &items, n, .{
        .title = "MID PRICES",
        .allocator = allocator,
    });
}

fn cellsInit(vals: []const []const u8) [ListW.MAX_COLS][]const u8 {
    var c: [ListW.MAX_COLS][]const u8 = .{""} ** ListW.MAX_COLS;
    for (vals, 0..) |v, i| c[i] = v;
    return c;
}

fn stylesInit(vals: []const BufMod.Style) [ListW.MAX_COLS]BufMod.Style {
    var s: [ListW.MAX_COLS]BufMod.Style = .{BufMod.Style{}} ** ListW.MAX_COLS;
    for (vals, 0..) |v, i| s[i] = v;
    return s;
}

pub fn positions(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.UserQuery) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;

    if (w.format == .json and !a.all_dexes) {
        var raw = try client.clearinghouseState(addr, a.dex);
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getClearinghouseState(addr, a.dex);
    defer typed.deinit();
    const state = typed.value;

    try w.heading("POSITIONS");
    const hdr = [_]Column{
        .{ .text = "COIN", .width = 6 },
        .{ .text = "SIDE", .width = 9 },
        .{ .text = "SIZE", .width = 10, .align_right = true },
        .{ .text = "ENTRY", .width = 10, .align_right = true },
        .{ .text = "VALUE", .width = 10, .align_right = true },
        .{ .text = "PNL", .width = 10, .align_right = true },
        .{ .text = "ROE", .width = 8 },
    };
    try w.tableHeader(&hdr);

    for (state.assetPositions) |ap| {
        const pos = ap.position;
        var szi_buf: [32]u8 = undefined;
        var entry_buf: [32]u8 = undefined;
        var pnl_buf: [32]u8 = undefined;

        const szi = pos.szi;
        const szi_str = szi.normalize().toString(&szi_buf) catch continue;
        if (szi.mantissa == 0) continue;

        const is_short = szi.isNegative();
        var side_buf: [16]u8 = undefined;
        const side_str: []const u8 = if (is_short)
            std.fmt.bufPrint(&side_buf, "\xe2\x96\xbc SHORT", .{}) catch "SHORT"
        else
            std.fmt.bufPrint(&side_buf, "\xe2\x96\xb2 LONG", .{}) catch "LONG";
        const side_color: []const u8 = if (is_short) Style.red else Style.green;
        const entry_str = decStr(pos.entryPx, &entry_buf);
        var val_buf: [32]u8 = undefined;
        const val_str = decStr(pos.positionValue, &val_buf);
        const pnl_str = decStr(pos.unrealizedPnl, &pnl_buf);

        var roe_buf: [16]u8 = undefined;
        const roe_f = blk: {
            const pnl_f = if (pos.unrealizedPnl) |p| decToF64(p) else break :blk @as(f64, 0);
            const margin_f = if (pos.marginUsed) |m| decToF64(m) else break :blk @as(f64, 0);
            if (margin_f == 0) break :blk @as(f64, 0);
            break :blk pnl_f / margin_f * 100.0;
        };
        const roe_str = std.fmt.bufPrint(&roe_buf, "{d:.1}%", .{roe_f}) catch "-";

        var abs_buf: [32]u8 = undefined;
        const abs_str = if (szi.isNegative()) blk: {
            const abs = szi.negate();
            break :blk abs.normalize().toString(&abs_buf) catch szi_str;
        } else szi_str;

        // Format ROE as badge string (will be rendered inline)
        const roe_color: []const u8 = if (roe_f < 0) Style.bold_red else Style.bold_green;

        const cols = [_]Column{
            .{ .text = pos.coin, .width = 6, .color = Style.bold_cyan },
            .{ .text = side_str, .width = 9, .color = side_color },
            .{ .text = abs_str, .width = 10, .align_right = true },
            .{ .text = entry_str, .width = 10, .align_right = true, .color = Style.muted },
            .{ .text = val_str, .width = 10, .align_right = true },
            .{ .text = pnl_str, .width = 10, .align_right = true, .color = Writer.pnlColor(pos.unrealizedPnl) },
            .{ .text = roe_str, .width = 8, .align_right = true, .color = roe_color },
        };
        try w.tableRow(&cols);
    }
    try w.footer();

    // HIP-3 DEX positions
    if (a.all_dexes) {
        var dex_typed = client.getPerpDexs() catch null;
        if (dex_typed) |*dt| {
            defer dt.deinit();
            for (dt.value) |dex| {
                var dex_state = client.getClearinghouseState(addr, dex.name) catch continue;
                defer dex_state.deinit();
                var has_dex_pos = false;
                for (dex_state.value.assetPositions) |ap| {
                    const p = ap.position;
                    const szi_f = decToF64(p.szi);
                    if (szi_f == 0) continue;
                    if (!has_dex_pos) {
                        try w.print("\n", .{});
                        try w.styled(Style.bold, "DEX: ");
                        try w.styled(Style.cyan, dex.name);
                        try w.print("\n", .{});
                        has_dex_pos = true;
                    }
                    var szi_buf: [32]u8 = undefined;
                    var entry_buf: [32]u8 = undefined;
                    var pnl_buf: [32]u8 = undefined;
                    const side_s: []const u8 = if (szi_f > 0) "LONG" else "SHORT";
                    try w.print("  {s: <8} {s: <6} {s: >12} entry {s: >10} pnl {s}\n", .{
                        p.coin,
                        side_s,
                        decFmt(p.szi, &szi_buf),
                        if (p.entryPx) |ep| decFmt(ep, &entry_buf) else "-",
                        if (p.unrealizedPnl) |up| decFmt(up, &pnl_buf) else "-",
                    });
                }
            }
        }
    }
}

pub fn orders(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.UserQuery) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;

    if (w.format == .json) {
        var raw = try client.openOrders(addr, a.dex);
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getOpenOrders(addr, a.dex);
    defer typed.deinit();
    const open_orders = typed.value;

    try w.heading("OPEN ORDERS");
    const hdr = [_]Column{
        .{ .text = "COIN", .width = 8 },
        .{ .text = "SIDE", .width = 6 },
        .{ .text = "SIZE", .width = 12, .align_right = true },
        .{ .text = "PRICE", .width = 12, .align_right = true },
        .{ .text = "OID", .width = 12, .align_right = true },
    };
    try w.tableHeader(&hdr);

    for (open_orders) |ord| {
        var sz_buf: [32]u8 = undefined;
        var px_buf: [32]u8 = undefined;
        var oid_buf: [20]u8 = undefined;

        const side_color: []const u8 = if (std.mem.eql(u8, ord.side, "B")) Style.green else Style.red;
        const side_str: []const u8 = if (std.mem.eql(u8, ord.side, "B")) "BUY" else "SELL";

        const cols = [_]Column{
            .{ .text = ord.coin, .width = 8, .color = Style.cyan },
            .{ .text = side_str, .width = 6, .color = side_color },
            .{ .text = decFmt(ord.sz, &sz_buf), .width = 12, .align_right = true },
            .{ .text = decFmt(ord.limitPx, &px_buf), .width = 12, .align_right = true },
            .{ .text = std.fmt.bufPrint(&oid_buf, "{d}", .{ord.oid}) catch "?", .width = 12, .align_right = true, .color = Style.dim },
        };
        try w.tableRow(&cols);
    }
    try w.footer();
}

pub fn fills(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.FillsArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;

    // If time range specified, use userFillsByTime
    if (a.start_time != null) {
        const start = parseTimestampMs(a.start_time.?) orelse return error.Overflow;
        const end = if (a.end_time) |et| parseTimestampMs(et) else null;

        if (w.format == .json) {
            var raw = try client.userFillsByTime(addr, start, end);
            defer raw.deinit();
            try w.jsonRaw(raw.body);
            return;
        }

        var typed = try client.getUserFillsByTime(addr, start, end);
        defer typed.deinit();

        return renderFills(w, typed.value);
    }

    if (w.format == .json) {
        var raw = try client.userFills(addr);
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getUserFills(addr);
    defer typed.deinit();

    return renderFills(w, typed.value);
}

fn renderFills(w: *Writer, fill_slice: []const response.Fill) !void {
    try w.heading("RECENT FILLS");
    const hdr = [_]Column{
        .{ .text = "COIN", .width = 8 },
        .{ .text = "SIDE", .width = 6 },
        .{ .text = "SIZE", .width = 12, .align_right = true },
        .{ .text = "PRICE", .width = 12, .align_right = true },
        .{ .text = "FEE", .width = 10, .align_right = true },
        .{ .text = "PNL", .width = 12, .align_right = true },
    };
    try w.tableHeader(&hdr);

    const limit = @min(fill_slice.len, 20);
    for (fill_slice[0..limit]) |fill| {
        var sz_buf: [32]u8 = undefined;
        var px_buf: [32]u8 = undefined;
        var fee_buf: [32]u8 = undefined;
        var pnl_buf: [32]u8 = undefined;

        const side_color: []const u8 = if (std.mem.eql(u8, fill.side, "B")) Style.green else Style.red;
        const side_str: []const u8 = if (std.mem.eql(u8, fill.side, "B")) "BUY" else "SELL";

        const cols = [_]Column{
            .{ .text = fill.coin, .width = 8, .color = Style.cyan },
            .{ .text = side_str, .width = 6, .color = side_color },
            .{ .text = decFmt(fill.sz, &sz_buf), .width = 12, .align_right = true },
            .{ .text = decFmt(fill.px, &px_buf), .width = 12, .align_right = true },
            .{ .text = decFmt(fill.fee, &fee_buf), .width = 10, .align_right = true, .color = Style.dim },
            .{ .text = decStr(fill.closedPnl, &pnl_buf), .width = 12, .align_right = true, .color = Writer.pnlColor(fill.closedPnl) },
        };
        try w.tableRow(&cols);
    }
    try w.footer();
}

pub fn balance(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.UserQuery) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;

    if (w.format == .json) {
        var spot_raw = try client.spotBalances(addr);
        defer spot_raw.deinit();
        var perp_raw = try client.clearinghouseState(addr, a.dex);
        defer perp_raw.deinit();
        var combo_buf: [16384]u8 = undefined;
        const combo = std.fmt.bufPrint(&combo_buf, "{{\"spot\":{s},\"perp\":{s}}}", .{ spot_raw.body, perp_raw.body }) catch return error.Overflow;
        try w.jsonRaw(combo);
        return;
    }

    var perp_typed = try client.getClearinghouseState(addr, a.dex);
    defer perp_typed.deinit();
    const state = perp_typed.value;
    const m = state.marginSummary;

    // Hero-style account header
    try w.nl();
    try w.styled(Style.muted, "  ACCOUNT\n\n");

    {
        var av_buf: [32]u8 = undefined;
        try w.print("  ", .{});
        try w.styled(Style.bold_white, "$");
        try w.styled(Style.bold_white, decFmt(m.accountValue, &av_buf));
        try w.nl();
        try w.nl();

        try w.style(Style.subtle);
        try w.print("  ", .{});
        var si: usize = 0;
        while (si < 52) : (si += 1) try w.print("\xe2\x94\x80", .{});
        try w.style(Style.reset);
        try w.nl();

        var mu_buf: [32]u8 = undefined;
        var wd_buf: [32]u8 = undefined;

        try w.style(Style.muted);
        try w.print("  margin ", .{});
        try w.style(Style.reset);
        try w.styled(Style.white, decFmt(m.totalMarginUsed, &mu_buf));
        try w.style(Style.muted);
        try w.print("  free ", .{});
        try w.style(Style.reset);
        try w.styled(Style.white, decFmt(state.withdrawable, &wd_buf));

        const av_f = decToF64(m.accountValue);
        const mu_f = decToF64(m.totalMarginUsed);
        const health_pct: f64 = if (mu_f > 0 and av_f > 0)
            @max(0, @min(100, 100.0 - (mu_f / av_f * 100.0)))
        else
            100.0;
        const health_color: []const u8 = if (health_pct > 50) Style.bold_green else if (health_pct > 25) Style.bold_yellow else Style.bold_red;
        try w.style(Style.muted);
        try w.print("  health ", .{});
        try w.style(Style.reset);
        try w.bar(health_pct, 100.0, 8, health_color);
        var pct_buf: [8]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, " {d:.0}%", .{health_pct}) catch "?";
        try w.styled(health_color, pct_str);
        try w.nl();
    }
    try w.nl();

    var spot_typed = client.getSpotBalances(addr) catch |e| {
        try w.nl();
        return e;
    };
    defer spot_typed.deinit();
    const balances = spot_typed.value.balances;

    {
        var nz: usize = 0;
        for (balances) |b| {
            if (decToF64(b.total) != 0) nz += 1;
        }
        if (nz > 0) {
            try w.heading("SPOT");
            const hdr = [_]Column{
                .{ .text = "TOKEN", .width = 10 },
                .{ .text = "BALANCE", .width = 18, .align_right = true },
                .{ .text = "HOLD", .width = 14, .align_right = true },
            };
            try w.tableHeader(&hdr);

            for (balances) |b| {
                var total_buf: [32]u8 = undefined;
                var hold_buf: [32]u8 = undefined;
                const total_f = decToF64(b.total);
                if (total_f == 0) continue;
                const hold_f = decToF64(b.hold);
                const hold_str: []const u8 = if (hold_f != 0) decFmt(b.hold, &hold_buf) else "";
                const cols = [_]Column{
                    .{ .text = b.coin, .width = 10, .color = Style.cyan },
                    .{ .text = decFmt(b.total, &total_buf), .width = 18, .align_right = true },
                    .{ .text = hold_str, .width = 14, .align_right = true, .color = Style.muted },
                };
                try w.tableRow(&cols);
            }
        }
    }

    // HIP-3 DEX balances (--all-dexes)
    if (a.all_dexes) {
        var dex_typed = client.getPerpDexs() catch null;
        if (dex_typed) |*dt| {
            defer dt.deinit();
            for (dt.value) |dex| {
                var dex_state = client.getClearinghouseState(addr, dex.name) catch continue;
                defer dex_state.deinit();
                const dm = dex_state.value.marginSummary;
                const av_f = decToF64(dm.accountValue);
                if (av_f == 0) continue;
                var title_buf: [32]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "DEX \xc2\xb7 {s}", .{dex.name}) catch "DEX";
                try w.heading(title);
                var dav_buf: [32]u8 = undefined;
                var dmu_buf: [32]u8 = undefined;
                try w.kv("Account Value", decFmt(dm.accountValue, &dav_buf));
                try w.kv("Margin Used", decFmt(dm.totalMarginUsed, &dmu_buf));
            }
        }
    }

    try w.footer();
}

pub fn perps(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.MarketArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    if (w.format == .json) {
        var raw = try client.perps(a.dex);
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getPerps(a.dex);
    defer typed.deinit();
    const universe = typed.value.universe;

    if (w.is_tty and !a.all and a.page == 1 and a.filter == null) {
        return perpsTui(allocator, config, universe);
    }

    try w.heading("PERP MARKETS");
    const hdr = [_]Column{
        .{ .text = "NAME", .width = 12 },
        .{ .text = "MAX LEV", .width = 8, .align_right = true },
        .{ .text = "SZ DEC", .width = 7, .align_right = true },
    };
    try w.tableHeader(&hdr);

    var total: usize = 0;
    var shown: usize = 0;
    var skipped: usize = 0;
    const per_page: usize = 20;
    const start = if (a.all) @as(usize, 0) else (a.page -| 1) * per_page;
    const limit = if (a.all) universe.len else per_page;

    for (universe) |pm| {
        if (a.filter) |f| {
            if (!containsInsensitive(pm.name, f)) continue;
        }
        total += 1;
    }

    for (universe) |pm| {
        if (shown >= limit) break;
        const m = pm;
        if (a.filter) |f| {
            if (!containsInsensitive(m.name, f)) continue;
        }
        if (skipped < start) {
            skipped += 1;
            continue;
        }
        var lev_buf: [16]u8 = undefined;
        var dec_buf: [8]u8 = undefined;
        const cols = [_]Column{
            .{ .text = m.name, .width = 12, .color = Style.cyan },
            .{ .text = std.fmt.bufPrint(&lev_buf, "{d}x", .{m.maxLeverage}) catch "?", .width = 8, .align_right = true, .color = Style.yellow },
            .{ .text = std.fmt.bufPrint(&dec_buf, "{d}", .{m.szDecimals}) catch "?", .width = 7, .align_right = true },
        };
        try w.tableRow(&cols);
        shown += 1;
    }
    const pages = (total + per_page - 1) / per_page;
    if (!a.all and start + shown < total) try w.paginatePage(shown, total, a.page, pages);
    try w.footer();
}

fn perpsTui(allocator: std.mem.Allocator, config: Config, universe: []const response.PerpMeta) !void {
    const n = @min(universe.len, ListW.MAX_ITEMS);

    const CellBuf = struct { lev: [16]u8 = undefined, lev_len: usize = 0, dec: [8]u8 = undefined, dec_len: usize = 0 };
    var cell_bufs: [ListW.MAX_ITEMS]CellBuf = undefined;
    var items: [ListW.MAX_ITEMS]ListW.Item = undefined;

    const cyan = BufMod.Style{ .fg = .cyan, .bold = true };
    const yellow = BufMod.Style{ .fg = .yellow };

    for (0..n) |i| {
        const m = universe[i];
        const lev_s = std.fmt.bufPrint(&cell_bufs[i].lev, "{d}x", .{m.maxLeverage}) catch "?";
        cell_bufs[i].lev_len = lev_s.len;
        const dec_s = std.fmt.bufPrint(&cell_bufs[i].dec, "{d}", .{m.szDecimals}) catch "?";
        cell_bufs[i].dec_len = dec_s.len;

        items[i] = .{
            .cells = cellsInit(&.{ m.name, cell_bufs[i].lev[0..cell_bufs[i].lev_len], cell_bufs[i].dec[0..cell_bufs[i].dec_len] }),
            .styles = stylesInit(&.{ cyan, yellow }),
            .sort_key = @as(f64, @floatFromInt(m.maxLeverage)),
        };
    }

    const columns = [_]ListW.Column{
        .{ .label = "NAME", .width = 12 },
        .{ .label = "MAX LEV", .width = 10, .right_align = true },
        .{ .label = "SZ DEC", .width = 8, .right_align = true },
    };

    try runListView(&columns, &items, n, .{
        .title = "PERP MARKETS",
        .help = "j/k:nav  /:search  s:sort  Enter:book  q:quit",
        .allocator = allocator,
        .config = config,
        .on_select = &perpsOnSelect,
    });
}

fn perpsOnSelect(allocator: std.mem.Allocator, config: Config, items: []const ListW.Item, idx: usize) void {
    const coin = items[idx].cells[0];
    const ba = args_mod.BookArgs{ .coin = coin, .depth = 15, .live = true };
    bookLive(allocator, config, ba) catch {};
}

pub fn dexes(allocator: std.mem.Allocator, w: *Writer, config: Config) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    if (w.format == .json) {
        var raw = try client.perpDexs();
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getDexInfos();
    defer typed.deinit();

    try w.heading("HIP-3 DEXES");
    const hdr = [_]Column{
        .{ .text = "NAME", .width = 10 },
        .{ .text = "FULL NAME", .width = 16 },
        .{ .text = "MARKETS", .width = 8, .align_right = true },
        .{ .text = "DEPLOYER", .width = 14 },
    };
    try w.tableHeader(&hdr);

    for (typed.value) |d| {
        const name = d.name;
        const full_name = d.fullName orelse name;
        const deployer_full = d.deployer orelse "-";
        const markets_count: usize = if (d.assetToStreamingOiCap) |oi| oi.len else 0;
        var cnt_buf: [8]u8 = undefined;
        const cnt_str = std.fmt.bufPrint(&cnt_buf, "{d}", .{markets_count}) catch "?";
        // Truncate deployer to 0x1234...5678
        var dep_buf: [14]u8 = undefined;
        const dep_str = if (deployer_full.len >= 42) blk: {
            @memcpy(dep_buf[0..6], deployer_full[0..6]);
            @memcpy(dep_buf[6..9], "...");
            @memcpy(dep_buf[9..13], deployer_full[38..42]);
            dep_buf[13] = 0;
            break :blk dep_buf[0..13];
        } else deployer_full;

        const cols = [_]Column{
            .{ .text = name, .width = 10, .color = Style.bold_cyan },
            .{ .text = full_name, .width = 16 },
            .{ .text = cnt_str, .width = 8, .align_right = true, .color = Style.yellow },
            .{ .text = dep_str, .width = 14, .color = Style.muted },
        };
        try w.tableRow(&cols);
    }
    try w.footer();
}

pub fn spotMarkets(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.MarketArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    if (w.format == .json) {
        var raw = try client.spot();
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getSpotMeta();
    defer typed.deinit();
    const tokens = typed.value.tokens;

    if (w.is_tty and !a.all and a.page == 1 and a.filter == null) {
        return spotTui(allocator, tokens);
    }

    try w.heading("SPOT TOKENS");
    const hdr = [_]Column{
        .{ .text = "NAME", .width = 12 },
        .{ .text = "INDEX", .width = 6, .align_right = true },
        .{ .text = "SZ DEC", .width = 7, .align_right = true },
        .{ .text = "WEI DEC", .width = 8, .align_right = true },
    };
    try w.tableHeader(&hdr);

    const per_page: usize = 20;
    const start = if (a.all) @as(usize, 0) else (a.page -| 1) * per_page;
    const limit = if (a.all) tokens.len else per_page;

    var total: usize = 0;
    for (tokens) |t| {
        if (a.filter) |f| {
            if (!containsInsensitive(t.name, f)) continue;
        }
        total += 1;
    }

    var shown: usize = 0;
    var skipped: usize = 0;
    for (tokens) |t| {
        if (shown >= limit) break;
        if (a.filter) |f| {
            if (!containsInsensitive(t.name, f)) continue;
        }
        if (skipped < start) {
            skipped += 1;
            continue;
        }
        var idx_buf: [8]u8 = undefined;
        var sz_buf: [8]u8 = undefined;
        var wei_buf: [8]u8 = undefined;
        const cols = [_]Column{
            .{ .text = t.name, .width = 12, .color = Style.cyan },
            .{ .text = std.fmt.bufPrint(&idx_buf, "{d}", .{t.index}) catch "?", .width = 6, .align_right = true },
            .{ .text = std.fmt.bufPrint(&sz_buf, "{d}", .{t.szDecimals}) catch "?", .width = 7, .align_right = true },
            .{ .text = std.fmt.bufPrint(&wei_buf, "{d}", .{t.weiDecimals}) catch "?", .width = 8, .align_right = true },
        };
        try w.tableRow(&cols);
        shown += 1;
    }
    const pages = (total + per_page - 1) / per_page;
    if (!a.all and start + shown < total) try w.paginatePage(shown, total, a.page, pages);
    try w.footer();
}

pub fn outcomes(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.MarketArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    if (w.format == .json) {
        var raw = try client.outcomeMeta();
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getOutcomeMeta();
    defer typed.deinit();
    const ocs = typed.value.outcomes;

    if (w.is_tty and !a.all and a.page == 1 and a.filter == null) {
        return outcomesTui(allocator, ocs);
    }

    try w.heading("OUTCOME MARKETS");
    const hdr = [_]Column{
        .{ .text = "ID", .width = 6, .align_right = true },
        .{ .text = "NAME", .width = 24 },
        .{ .text = "SIDES", .width = 20 },
        .{ .text = "DESCRIPTION", .width = 50 },
    };
    try w.tableHeader(&hdr);

    const per_page: usize = 20;
    const start = if (a.all) @as(usize, 0) else (a.page -| 1) * per_page;
    const limit = if (a.all) ocs.len else per_page;

    var total: usize = 0;
    for (ocs) |o| {
        if (a.filter) |f| {
            if (!containsInsensitive(o.name, f) and !containsInsensitive(o.description, f)) continue;
        }
        total += 1;
    }

    var shown: usize = 0;
    var skipped: usize = 0;
    for (ocs) |o| {
        if (shown >= limit) break;
        if (a.filter) |f| {
            if (!containsInsensitive(o.name, f) and !containsInsensitive(o.description, f)) continue;
        }
        if (skipped < start) {
            skipped += 1;
            continue;
        }
        var id_buf: [8]u8 = undefined;
        var sides_buf: [64]u8 = undefined;
        const sides_len = formatOutcomeSides(o.sideSpecs, &sides_buf);

        const cols = [_]Column{
            .{ .text = std.fmt.bufPrint(&id_buf, "{d}", .{o.outcome}) catch "?", .width = 6, .align_right = true },
            .{ .text = o.name, .width = 24, .color = Style.cyan },
            .{ .text = sides_buf[0..sides_len], .width = 20 },
            .{ .text = o.description, .width = 50 },
        };
        try w.tableRow(&cols);
        shown += 1;
    }
    const pages = (total + per_page - 1) / per_page;
    if (!a.all and start + shown < total) try w.paginatePage(shown, total, a.page, pages);
    try w.footer();
}

/// Format outcome side specs as "Side0 / Side1" into a fixed buffer.
fn formatOutcomeSides(specs: []const response.OutcomeSideSpec, buf: *[64]u8) usize {
    var len: usize = 0;
    for (specs, 0..) |s, i| {
        if (i > 0 and len + 3 < buf.len) {
            @memcpy(buf[len .. len + 3], " / ");
            len += 3;
        }
        const remaining = buf.len - len;
        const copy_len = @min(s.name.len, remaining);
        @memcpy(buf[len .. len + copy_len], s.name[0..copy_len]);
        len += copy_len;
    }
    return len;
}

fn outcomesTui(allocator: std.mem.Allocator, ocs: []const response.OutcomeInfo) !void {
    const n = @min(ocs.len, ListW.MAX_ITEMS);

    const CellBuf = struct {
        id: [8]u8 = undefined,
        id_len: usize = 0,
        sides: [64]u8 = undefined,
        sides_len: usize = 0,
    };
    var cell_bufs: [ListW.MAX_ITEMS]CellBuf = undefined;
    var items: [ListW.MAX_ITEMS]ListW.Item = undefined;

    const cyan = BufMod.Style{ .fg = .cyan, .bold = true };

    for (0..n) |i| {
        const o = ocs[i];
        const id_s = std.fmt.bufPrint(&cell_bufs[i].id, "{d}", .{o.outcome}) catch "?";
        cell_bufs[i].id_len = id_s.len;

        cell_bufs[i].sides_len = formatOutcomeSides(o.sideSpecs, &cell_bufs[i].sides);

        items[i] = .{
            .cells = cellsInit(&.{
                cell_bufs[i].id[0..cell_bufs[i].id_len],
                o.name,
                cell_bufs[i].sides[0..cell_bufs[i].sides_len],
                o.description,
            }),
            .styles = stylesInit(&.{ .{}, cyan }),
            .sort_key = @as(f64, @floatFromInt(o.outcome)),
        };
    }

    const columns = [_]ListW.Column{
        .{ .label = "ID", .width = 8, .right_align = true },
        .{ .label = "NAME", .width = 24 },
        .{ .label = "SIDES", .width = 20 },
        .{ .label = "DESCRIPTION", .width = 50 },
    };

    try runListView(&columns, &items, n, .{
        .title = "OUTCOME MARKETS",
        .help = "j/k:nav  /:search  s:sort  q:quit",
        .allocator = allocator,
    });
}

fn spotTui(allocator: std.mem.Allocator, tokens_arr: []const response.SpotToken) !void {
    const n = @min(tokens_arr.len, ListW.MAX_ITEMS);

    const CellBuf = struct { idx: [8]u8 = undefined, idx_len: usize = 0, sz: [8]u8 = undefined, sz_len: usize = 0, wei: [8]u8 = undefined, wei_len: usize = 0 };
    var cell_bufs: [ListW.MAX_ITEMS]CellBuf = undefined;
    var items: [ListW.MAX_ITEMS]ListW.Item = undefined;
    var count: usize = 0;

    const cyan = BufMod.Style{ .fg = .cyan, .bold = true };

    for (0..n) |i| {
        const t = tokens_arr[i];
        const idx_s = std.fmt.bufPrint(&cell_bufs[count].idx, "{d}", .{t.index}) catch "?";
        cell_bufs[count].idx_len = idx_s.len;
        const sz_s = std.fmt.bufPrint(&cell_bufs[count].sz, "{d}", .{t.szDecimals}) catch "?";
        cell_bufs[count].sz_len = sz_s.len;
        const wei_s = std.fmt.bufPrint(&cell_bufs[count].wei, "{d}", .{t.weiDecimals}) catch "?";
        cell_bufs[count].wei_len = wei_s.len;

        items[count] = .{
            .cells = cellsInit(&.{ t.name, cell_bufs[count].idx[0..cell_bufs[count].idx_len], cell_bufs[count].sz[0..cell_bufs[count].sz_len], cell_bufs[count].wei[0..cell_bufs[count].wei_len] }),
            .styles = stylesInit(&.{cyan}),
            .sort_key = @as(f64, @floatFromInt(t.index)),
        };
        count += 1;
    }

    const columns = [_]ListW.Column{
        .{ .label = "NAME", .width = 12 },
        .{ .label = "INDEX", .width = 8, .right_align = true },
        .{ .label = "SZ DEC", .width = 8, .right_align = true },
        .{ .label = "WEI DEC", .width = 8, .right_align = true },
    };

    try runListView(&columns, &items, count, .{
        .title = "SPOT TOKENS",
        .allocator = allocator,
    });
}

pub fn placeOrder(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.OrderArgs, is_buy: bool) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const auth = try getWriteAuth(w, config);

    const resolved = try resolveAsset(&client, a.coin);
    const asset = resolved.index;

    const sz_raw = Decimal.fromString(a.size) catch return error.Overflow;

    // Truncate size to valid lot size (floor, never rounds up — user never spends more than intended)
    const sz = if (resolved.sz_decimals >= 0) blk: {
        const sd: u8 = @intCast(resolved.sz_decimals);
        const truncated = sz_raw.truncDp(sd);
        if (truncated.isZero()) {
            return failFmt(w, "size {s} too small — {s} requires {d} decimal places", .{
                a.size, a.coin, sd,
            });
        }
        break :blk truncated;
    } else sz_raw;

    // Trigger order: --trigger-above or --trigger-below
    const is_trigger = a.trigger_px != null;
    const is_market = a.price == null and !is_trigger;

    const order_type: types.OrderTypePlacement = if (is_trigger) blk: {
        const tpx = Decimal.fromString(a.trigger_px.?) catch return error.Overflow;
        break :blk .{ .trigger = .{
            .is_market = a.price == null,
            .trigger_px = tpx,
            .tpsl = if (a.trigger_is_tp) .tp else .sl,
        } };
    } else if (!is_market) blk: {
        const tif: types.TimeInForce = if (std.mem.eql(u8, a.tif, "ioc"))
            .Ioc
        else if (std.mem.eql(u8, a.tif, "alo"))
            .Alo
        else
            .Gtc;
        break :blk .{ .limit = .{ .tif = tif } };
    } else .{ .limit = .{ .tif = .FrontendMarket } };

    // For spot orders, derive @index from resolved asset for book lookup
    // For outcome orders, use #<encoding> format
    var book_idx_buf: [16]u8 = undefined;
    var book_coin_upper: [16]u8 = undefined;
    const book_coin = if (isOutcomeAsset(asset))
        (std.fmt.bufPrint(&book_idx_buf, "#{d}", .{asset - 100_000_000}) catch a.coin)
    else if (asset > 10000 and isSpotAsset(asset))
        (std.fmt.bufPrint(&book_idx_buf, "@{d}", .{asset - 10000}) catch a.coin)
    else if (asset == 10000 and isSpotAsset(asset))
        upperCoin(a.coin, &book_coin_upper) // PURR/USDC (index 0) uses pair name
    else
        a.coin;

    const tick_mod = hlz.hypercore.tick;
    const limit_px_raw = if (a.price) |px_str|
        Decimal.fromString(px_str) catch return error.Overflow
    else if (a.slippage) |sl_str|
        Decimal.fromString(sl_str) catch return error.Overflow
    else blk: {
        var book_typed = client.getL2Book(book_coin) catch
            break :blk if (is_buy) Decimal.fromString("999999") catch unreachable else Decimal.fromString("0.01") catch unreachable;
        defer book_typed.deinit();
        const bl = book_typed.value.levels;
        if (is_buy) {
            if (bl[1].len > 0) {
                const ask_px = decToF64(bl[1][0].px);
                const slippage_px = ask_px * 1.005;
                var sl_buf: [32]u8 = undefined;
                break :blk Decimal.fromString(slippageFmt(&sl_buf, slippage_px)) catch Decimal.fromString("999999") catch unreachable;
            }
            break :blk Decimal.fromString("999999") catch unreachable;
        } else {
            if (bl[0].len > 0) {
                const bid_px = decToF64(bl[0][0].px);
                const slippage_px = bid_px * 0.995;
                var sl_buf: [32]u8 = undefined;
                break :blk Decimal.fromString(slippageFmt(&sl_buf, slippage_px)) catch Decimal.fromString("0.01") catch unreachable;
            }
            break :blk Decimal.fromString("0.01") catch unreachable;
        }
    };

    // Round to valid tick size
    const limit_px = if (resolved.sz_decimals >= 0) blk: {
        const pt = if (isSpotAsset(asset) or isOutcomeAsset(asset))
            tick_mod.PriceTick.forSpot(resolved.sz_decimals)
        else
            tick_mod.PriceTick.forPerp(resolved.sz_decimals);
        break :blk pt.round(limit_px_raw) orelse limit_px_raw;
    } else limit_px_raw;

    // Preflight: min notional check (spot: 10 quote units, perp: 10 USD)
    if (!a.reduce_only) {
        const sz_f = decToF64(sz);
        const px_f = decToF64(limit_px);
        const notional = sz_f * px_f;
        if (notional > 0 and notional < 10.0) {
            var lot_mult: f64 = 1.0;
            const sd: u8 = if (resolved.sz_decimals >= 0) @intCast(resolved.sz_decimals) else 4;
            for (0..sd) |_| lot_mult *= 10.0;
            const min_sz = @ceil(10.0 / px_f * lot_mult) / lot_mult;
            var min_buf: [32]u8 = undefined;
            const min_str = Decimal.fromString(smartFmt(&min_buf, min_sz)) catch Decimal.ZERO;
            var min_str_buf: [32]u8 = undefined;
            const min_display = min_str.truncDp(sd).toString(&min_str_buf) catch "?";
            return failFmt(w, "order value ${d:.2} below $10 minimum — need at least {s} {s}", .{
                notional, min_display, a.coin,
            });
        }
    }

    const now: u64 = runtime.nonceMs();
    var cloid = types.ZERO_CLOID;
    cloid[0] = @intCast((now >> 56) & 0xff);
    cloid[1] = @intCast((now >> 48) & 0xff);
    cloid[2] = @intCast((now >> 40) & 0xff);
    cloid[3] = @intCast((now >> 32) & 0xff);
    cloid[4] = @intCast((now >> 24) & 0xff);
    cloid[5] = @intCast((now >> 16) & 0xff);
    cloid[6] = @intCast((now >> 8) & 0xff);
    cloid[7] = @intCast(now & 0xff);

    const order = types.OrderRequest{
        .asset = asset,
        .is_buy = is_buy,
        .limit_px = limit_px,
        .sz = sz,
        .reduce_only = a.reduce_only,
        .order_type = order_type,
        .cloid = cloid,
    };

    // Bracket: attach TP and/or SL orders
    var bracket_orders: [3]types.OrderRequest = undefined;
    var bracket_count: usize = 1;
    bracket_orders[0] = order;

    if (a.tp) |tp_str| {
        const tp_px = Decimal.fromString(tp_str) catch return error.Overflow;
        bracket_orders[bracket_count] = .{
            .asset = asset,
            .is_buy = !is_buy, // TP closes the position (opposite side)
            .limit_px = tp_px,
            .sz = sz,
            .reduce_only = true,
            .order_type = .{ .trigger = .{ .is_market = true, .trigger_px = tp_px, .tpsl = .tp } },
            .cloid = types.ZERO_CLOID,
        };
        bracket_count += 1;
    }
    if (a.sl) |sl_str| {
        const sl_px = Decimal.fromString(sl_str) catch return error.Overflow;
        bracket_orders[bracket_count] = .{
            .asset = asset,
            .is_buy = !is_buy, // SL closes the position (opposite side)
            .limit_px = sl_px,
            .sz = sz,
            .reduce_only = true,
            .order_type = .{ .trigger = .{ .is_market = true, .trigger_px = sl_px, .tpsl = .sl } },
            .cloid = types.ZERO_CLOID,
        };
        bracket_count += 1;
    }

    const grouping: types.OrderGrouping = if (bracket_count > 1) .normalTpsl else .na;
    const builder = parseBuilderArgs(a.builder, a.builder_fee) catch |e| switch (e) {
        error.MissingArgument => return failFmt(w, "--builder requires --builder-fee", .{}),
        error.InvalidFlag => return failFmt(w, "invalid --builder or --builder-fee value", .{}),
    };
    const batch = types.BatchOrder{
        .orders = bracket_orders[0..bracket_count],
        .grouping = grouping,
        .builder = builder,
    };

    // --dry-run: preview without sending
    if (a.dry_run) {
        if (w.format == .json) {
            var db: [512]u8 = undefined;
            var lp_buf: [32]u8 = undefined;
            var sz_dbuf: [32]u8 = undefined;
            const lp_s = limit_px.normalize().toString(&lp_buf) catch "?";
            const sz_s = sz.normalize().toString(&sz_dbuf) catch "?";
            const dr = std.fmt.bufPrint(&db,
                \\{{"status":"dry_run","side":"{s}","coin":"{s}","size":"{s}","price":"{s}","reduce_only":{s},"bracket":{d}}}
            , .{
                if (is_buy) "buy" else "sell",
                a.coin,
                sz_s,
                lp_s,
                if (a.reduce_only) "true" else "false",
                bracket_count - 1,
            }) catch "{}";
            try w.jsonRaw(dr);
        } else {
            try w.styled(Style.bold_yellow, "⊘ dry-run");
            try w.print(" {s} {s}", .{ if (is_buy) "buy" else "sell", a.coin });
            var sz_dbuf: [32]u8 = undefined;
            var lp_buf: [32]u8 = undefined;
            try w.print(" {s} @ {s}", .{ sz.normalize().toString(&sz_dbuf) catch "?", limit_px.normalize().toString(&lp_buf) catch "?" });
            if (a.reduce_only) try w.print(" reduce-only", .{});
            if (bracket_count > 1) try w.print(" +{d} bracket", .{bracket_count - 1});
            try w.nl();
        }
        return;
    }

    var nonce_handler = response.NonceHandler.init();
    const nonce = nonce_handler.next();

    var result = try client.place(auth.signer, batch, nonce, null, null);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const statuses = try response.parseOrderStatuses(allocator, val);
    defer allocator.free(statuses);

    var failed = false;
    if (statuses.len > 0) {
        switch (statuses[0]) {
            .resting => |r| {
                try w.styled(Style.bold_green, "\xe2\x9c\x93 resting");
                var oid_buf: [20]u8 = undefined;
                try w.print(" oid={s}\n", .{std.fmt.bufPrint(&oid_buf, "{d}", .{r.oid}) catch "?"});
            },
            .filled => |f| {
                try w.styled(Style.bold_green, "\xe2\x9c\x93 filled");
                var avg_buf: [32]u8 = undefined;
                try w.print(" avg={s}\n", .{decStr(f.avgPx, &avg_buf)});
            },
            .success => try w.success("accepted"),
            .waitingForTrigger => try w.success("waiting for trigger"),
            .waitingForFill => try w.success("waiting to fill"),
            .@"error" => |msg| {
                try w.failFmt("rejected: {s}", .{msg});
                failed = true;
            },
            .unknown => {
                try w.fail("unknown response");
                failed = true;
            },
        }
    } else {
        const status = response.parseResponseStatus(val);
        switch (status) {
            .ok => try w.success("submitted"),
            .err => {
                const err_msg = json_mod.getString(val, "response") orelse "unknown error";
                try w.failFmt("rejected: {s}", .{err_msg});
                failed = true;
            },
            .unknown => {
                try w.fail("unexpected response");
                try w.print("{s}\n", .{result.body});
                failed = true;
            },
        }
    }
    if (failed) return error.CommandFailed;
}

pub fn cancelOrder(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.CancelArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const auth = try getWriteAuth(w, config);
    var nonce_handler = response.NonceHandler.init();

    if (a.all) {
        var orders_typed = try client.getOpenOrders(auth.address(), null);
        defer orders_typed.deinit();

        var cancels: [64]types.Cancel = undefined;
        const CoinAsset = struct { coin: []const u8, asset: usize };
        var asset_cache: [64]CoinAsset = undefined;
        var asset_cache_len: usize = 0;
        var total_cancelled: usize = 0;
        var batch_count: usize = 0;
        var batch_len: usize = 0;

        for (orders_typed.value) |order| {
            const asset = blk: {
                for (asset_cache[0..asset_cache_len]) |entry| {
                    if (std.ascii.eqlIgnoreCase(entry.coin, order.coin)) break :blk entry.asset;
                }
                const resolved = (try resolveAsset(&client, order.coin)).index;
                if (asset_cache_len < asset_cache.len) {
                    asset_cache[asset_cache_len] = .{ .coin = order.coin, .asset = resolved };
                    asset_cache_len += 1;
                }
                break :blk resolved;
            };
            cancels[batch_len] = .{ .asset = asset, .oid = order.oid };
            batch_len += 1;

            if (batch_len == cancels.len) {
                var result = try client.cancel(auth.signer, .{ .cancels = cancels[0..batch_len] }, nonce_handler.next(), null, null);
                defer result.deinit();
                if (!try result.isOk()) {
                    if (w.format == .json) {
                        try w.jsonFmt("{{\"status\":\"error\",\"cancelled\":{d},\"batches\":{d},\"response\":{s}}}", .{ total_cancelled, batch_count, result.body });
                        return;
                    }
                    try w.fail("cancel-all failed");
                    try w.print("{s}\n", .{result.body});
                    return error.CommandFailed;
                }
                total_cancelled += batch_len;
                batch_count += 1;
                batch_len = 0;
            }
        }

        if (batch_len > 0) {
            var result = try client.cancel(auth.signer, .{ .cancels = cancels[0..batch_len] }, nonce_handler.next(), null, null);
            defer result.deinit();
            if (!try result.isOk()) {
                if (w.format == .json) {
                    try w.jsonFmt("{{\"status\":\"error\",\"cancelled\":{d},\"batches\":{d},\"response\":{s}}}", .{ total_cancelled, batch_count, result.body });
                    return;
                }
                try w.fail("cancel-all failed");
                try w.print("{s}\n", .{result.body});
                return error.CommandFailed;
            }
            total_cancelled += batch_len;
            batch_count += 1;
        }

        if (w.format == .json) {
            try w.jsonFmt("{{\"status\":\"ok\",\"cancelled\":{d},\"batches\":{d}}}", .{ total_cancelled, batch_count });
            return;
        }

        if (total_cancelled == 0) {
            try w.print("no open orders\n", .{});
            return;
        }
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{d} orders cancelled", .{total_cancelled}) catch "orders cancelled";
        try w.success(msg);
        return;
    }

    const nonce = nonce_handler.next();

    // cancel ETH (no OID, no CLOID) → cancel all orders for this coin
    if (a.oid == null and a.cloid == null) {
        const coin = a.coin orelse return error.MissingArgument;
        const asset = (try resolveAsset(&client, coin)).index;
        var orders_typed = try client.getOpenOrders(auth.address(), null);
        defer orders_typed.deinit();

        // Collect OIDs matching this coin
        var cancels: [64]types.Cancel = undefined;
        var cancel_count: usize = 0;
        for (orders_typed.value) |order| {
            if (!std.ascii.eqlIgnoreCase(order.coin, coin)) continue;
            const oid = order.oid;
            if (cancel_count >= 64) break;
            cancels[cancel_count] = .{ .asset = asset, .oid = oid };
            cancel_count += 1;
        }

        if (cancel_count == 0) {
            if (w.format == .json) {
                try w.jsonFmt("{{\"status\":\"ok\",\"cancelled\":0}}", .{});
            } else {
                try w.print("no open orders for {s}\n", .{coin});
            }
            return;
        }

        const batch = types.BatchCancel{ .cancels = cancels[0..cancel_count] };
        var result = try client.cancel(auth.signer, batch, nonce, null, null);
        defer result.deinit();

        if (w.format == .json) {
            try w.jsonRaw(result.body);
            return;
        }
        const ok = try result.isOk();
        if (ok) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{d} {s} orders cancelled", .{ cancel_count, coin }) catch "orders cancelled";
            try w.success(msg);
        } else {
            try w.fail("cancel failed");
            try w.print("{s}\n", .{result.body});
            return error.CommandFailed;
        }
        return;
    }

    if (a.cloid) |cloid_hex| {
        const coin = a.coin orelse return error.MissingArgument;
        const asset = (try resolveAsset(&client, coin)).index;
        var cloid: types.Cloid = types.ZERO_CLOID;
        const hex_str = if (cloid_hex.len >= 2 and cloid_hex[0] == '0' and cloid_hex[1] == 'x') cloid_hex[2..] else cloid_hex;
        if (hex_str.len != 32) return error.InvalidArgument;
        for (0..16) |bi| {
            cloid[bi] = std.fmt.parseInt(u8, hex_str[bi * 2 ..][0..2], 16) catch return error.InvalidArgument;
        }

        const cancel_cloid = types.CancelByCloid{ .asset = @intCast(asset), .cloid = cloid };
        const batch_cloid = types.BatchCancelCloid{
            .cancels = &[_]types.CancelByCloid{cancel_cloid},
        };

        var result = try client.cancelByCloid(auth.signer, batch_cloid, nonce, null, null);
        defer result.deinit();

        if (w.format == .json) {
            try w.jsonRaw(result.body);
            return;
        }

        const ok = try result.isOk();
        if (ok) {
            try w.success("Order cancelled (by CLOID)");
        } else {
            try w.fail("cancel by CLOID failed");
            try w.print("{s}\n", .{result.body});
            return error.CommandFailed;
        }
        return;
    }

    const oid_str = a.oid orelse return error.MissingArgument;
    const oid = std.fmt.parseInt(u64, oid_str, 10) catch return error.Overflow;
    const asset = if (a.coin) |coin|
        (try resolveAsset(&client, coin)).index
    else blk: {
        var orders_typed = try client.getOpenOrders(auth.address(), null);
        defer orders_typed.deinit();
        for (orders_typed.value) |order| {
            if (order.oid == oid) break :blk (try resolveAsset(&client, order.coin)).index;
        }
        return failFmt(w, "order {d} not found in open orders", .{oid});
    };

    const cancel = types.Cancel{ .asset = asset, .oid = oid };
    const batch = types.BatchCancel{
        .cancels = &[_]types.Cancel{cancel},
    };

    var result = try client.cancel(auth.signer, batch, nonce, null, null);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const statuses = try response.parseOrderStatuses(allocator, val);
    defer allocator.free(statuses);

    if (statuses.len > 0) {
        switch (statuses[0]) {
            .success => try w.success("Order cancelled"),
            .@"error" => |msg| {
                return failFmt(w, "cancel failed: {s}", .{msg});
            },
            else => {
                const ok = try result.isOk();
                if (ok) {
                    try w.success("Cancel submitted");
                } else {
                    return fail(w, "cancel failed");
                }
            },
        }
    } else {
        const ok = try result.isOk();
        if (ok) {
            try w.success("Cancel submitted");
        } else {
            try w.fail("cancel failed");
            try w.print("{s}\n", .{result.body});
            return error.CommandFailed;
        }
    }
}

pub fn sendAsset(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.SendArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const auth = try getWriteAuth(w, config);
    const now: u64 = runtime.nonceMs();

    const is_usdc = std.ascii.eqlIgnoreCase(a.token, "USDC");
    const is_simple = is_usdc and std.mem.eql(u8, a.from, "perp") and std.mem.eql(u8, a.to, "perp") and a.subaccount == null;

    const dest_str = a.destination orelse auth.address();
    const dest = Client.parseAddress(dest_str) catch {
        try w.err("invalid destination address");
        return;
    };

    if (is_simple) {
        var result = try client.sendUsdc(auth.signer, dest, a.amount, now);
        defer result.deinit();

        if (w.format == .json) {
            try w.jsonRaw(result.body);
            return;
        }

        const ok = try result.isOk();
        if (ok) {
            try w.success("Sent ");
            try w.print("{s} USDC \xe2\x86\x92 {s}\n", .{ a.amount, dest_str });
        } else {
            try w.fail("send failed");
            try w.print("{s}\n", .{result.body});
            return error.CommandFailed;
        }
    } else {
        const source_dex = if (std.mem.eql(u8, a.from, "perp")) "" else if (std.mem.eql(u8, a.from, "spot")) "spot" else a.from;
        const dest_dex = if (std.mem.eql(u8, a.to, "perp")) "" else if (std.mem.eql(u8, a.to, "spot")) "spot" else a.to;
        const sub = a.subaccount orelse "";

        var result = if (a.agent) blk: {
            const dest_signer = auth.address();
            if (!std.ascii.eqlIgnoreCase(dest_str, dest_signer)) {
                return failFmt(w, "--agent requires destination to equal signer ({s})", .{dest_signer});
            }
            const asa = types.AgentSendAsset{
                .destination = dest,
                .source_dex = source_dex,
                .destination_dex = dest_dex,
                .token = a.token,
                .amount = a.amount,
                .from_sub_account = sub,
                .nonce = now,
            };
            break :blk try client.agentSendAsset(auth.signer, asa);
        } else try client.sendAsset(auth.signer, dest, source_dex, dest_dex, a.token, a.amount, sub, now);
        defer result.deinit();

        if (w.format == .json) {
            try w.jsonRaw(result.body);
            return;
        }

        const ok = try result.isOk();
        if (ok) {
            try w.success("Sent ");
            const from_label = if (source_dex.len == 0) "perp" else source_dex;
            const to_label = if (dest_dex.len == 0) "perp" else dest_dex;
            try w.print("{s} {s} ({s} \xe2\x86\x92 {s}) \xe2\x86\x92 {s}{s}\n", .{
                a.amount,                        a.token, from_label, to_label, dest_str,
                if (a.agent) " (agent)" else "",
            });
        } else {
            try w.fail("send failed");
            try w.print("{s}\n", .{result.body});
            return error.CommandFailed;
        }
    }
}

pub fn modifyOrder(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.ModifyArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const auth = try getWriteAuth(w, config);
    var nonce_handler = response.NonceHandler.init();
    const nonce = nonce_handler.next();

    const asset = (try resolveAsset(&client, a.coin)).index;
    const oid = std.fmt.parseInt(u64, a.oid, 10) catch return error.Overflow;
    const sz = Decimal.fromString(a.size) catch return error.Overflow;
    const px = Decimal.fromString(a.price) catch return error.Overflow;

    const now: u64 = runtime.nonceMs();
    var cloid = types.ZERO_CLOID;
    cloid[0] = @intCast((now >> 56) & 0xff);
    cloid[1] = @intCast((now >> 48) & 0xff);
    cloid[2] = @intCast((now >> 40) & 0xff);
    cloid[3] = @intCast((now >> 32) & 0xff);
    cloid[4] = @intCast((now >> 24) & 0xff);
    cloid[5] = @intCast((now >> 16) & 0xff);
    cloid[6] = @intCast((now >> 8) & 0xff);
    cloid[7] = @intCast(now & 0xff);

    const modify_req = types.Modify{
        .oid = .{ .oid = oid },
        .order = .{
            .asset = asset,
            .is_buy = true,
            .limit_px = px,
            .sz = sz,
            .reduce_only = false,
            .order_type = .{ .limit = .{ .tif = .Gtc } },
            .cloid = cloid,
        },
    };
    const batch = types.BatchModify{
        .modifies = &[_]types.Modify{modify_req},
    };

    var result = try client.modify(auth.signer, batch, nonce, null, null);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const statuses = try response.parseOrderStatuses(allocator, val);
    defer allocator.free(statuses);

    var failed = false;
    if (statuses.len > 0) {
        switch (statuses[0]) {
            .resting => |r| {
                try w.styled(Style.bold_green, "\xe2\x9c\x93 Order modified");
                var oid_buf: [20]u8 = undefined;
                try w.print(" (oid: {s})\n", .{std.fmt.bufPrint(&oid_buf, "{d}", .{r.oid}) catch "?"});
            },
            .success => try w.success("Order modified"),
            .@"error" => |msg| {
                try w.failFmt("modify rejected: {s}", .{msg});
                failed = true;
            },
            else => {
                const ok = try result.isOk();
                if (ok) {
                    try w.success("Modify submitted");
                } else {
                    try w.fail("modify failed");
                    failed = true;
                }
            },
        }
    } else {
        const status = response.parseResponseStatus(val);
        switch (status) {
            .ok => try w.success("Modify submitted"),
            .err => {
                const err_msg = json_mod.getString(val, "response") orelse "unknown error";
                try w.failFmt("rejected: {s}", .{err_msg});
                failed = true;
            },
            .unknown => {
                try w.fail("unexpected response");
                try w.print("{s}\n", .{result.body});
                failed = true;
            },
        }
    }
    if (failed) return error.CommandFailed;
}

pub fn orderStatus(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.StatusArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = config.getAddress() orelse return error.MissingAddress;
    const oid = std.fmt.parseInt(u64, a.oid, 10) catch return error.Overflow;

    var result = try client.orderStatus(addr, oid);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    try w.heading("ORDER STATUS");
    try w.print("│ {s}\n", .{result.body});
    try w.footer();
}

pub fn funding(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.FundingArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    var mac = try client.getMetaAndAssetCtxs(a.dex);
    defer mac.deinit();

    var sorted = try parseFundingData(allocator, mac.entries);
    defer allocator.free(sorted.entries.ptr[0..sorted.alloc_len]);

    if (a.filter) |f| {
        var fc: usize = 0;
        for (sorted.entries) |e| {
            if (containsInsensitive(e.name, f)) {
                sorted.entries[fc] = e;
                fc += 1;
            }
        }
        sorted.entries = sorted.entries[0..fc];
    }

    const per_page: usize = a.top;
    const total_count = sorted.entries.len;
    const pages = (total_count + per_page - 1) / per_page;
    const page = @min(a.page, pages);
    const start: usize = if (a.all) 0 else (page -| 1) * per_page;
    const end: usize = if (a.all) total_count else @min(start + per_page, total_count);
    const show_slice = sorted.entries[start..end];

    if (w.format == .json) {
        // coin names are alphanumeric from HL API, no JSON escaping needed
        const buf_size = show_slice.len * 128 + 16;
        var jbuf = try allocator.alloc(u8, buf_size);
        defer allocator.free(jbuf);
        var jlen: usize = 0;
        jbuf[0] = '[';
        jlen = 1;
        for (show_slice, 0..) |e, i| {
            if (i > 0) {
                jbuf[jlen] = ',';
                jlen += 1;
            }
            var mark_buf: [32]u8 = undefined;
            jlen += (std.fmt.bufPrint(
                jbuf[jlen..],
                "{{\"coin\":\"{s}\",\"funding\":{d:.8},\"annualized\":{d:.2},\"mark\":\"{s}\"}}",
                .{ e.name, e.funding, e.funding * 8760.0 * 100.0, decFmt(e.mark, &mark_buf) },
            ) catch return error.Overflow).len;
        }
        jbuf[jlen] = ']';
        jlen += 1;
        try w.jsonRaw(jbuf[0..jlen]);
        return;
    }

    if (w.is_tty and !a.all and a.page == 1 and a.filter == null) {
        return fundingTui(allocator, sorted.entries[0..sorted.count]);
    }

    try w.heading("FUNDING RATES (hourly)");

    const stdout = std.Io.File.stdout();
    const io = w.io;
    const is_tty = w.is_tty;

    {
        var buf: [512]u8 = undefined;
        var p: usize = 0;
        if (is_tty) p = emit(&buf, p, Style.muted);
        p = rpad(&buf, p, "COIN", 8);
        p = lpad(&buf, p, "RATE", 14);
        p = lpad(&buf, p, "ANN%", 10);
        p = emit(&buf, p, "  ");
        p = rpad(&buf, p, "HEAT", 20);
        p = lpad(&buf, p, "MARK", 12);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "\r\n");
        stdout.writeStreamingAll(io, buf[0..p]) catch {};
    }

    var max_rate: f64 = 0;
    for (show_slice) |e| max_rate = @max(max_rate, @abs(e.funding));
    if (max_rate == 0) max_rate = 1;

    for (show_slice) |e| {
        var rate_buf: [20]u8 = undefined;
        var ann_buf: [16]u8 = undefined;
        const rate_pct = e.funding * 100.0;
        const ann_pct = e.funding * 8760.0 * 100.0;
        const rate_str = std.fmt.bufPrint(&rate_buf, "{d:.6}%", .{rate_pct}) catch "?";
        const ann_str = std.fmt.bufPrint(&ann_buf, "{d:.1}%", .{ann_pct}) catch "?";
        const is_neg = e.funding < 0;
        const rate_color: []const u8 = if (is_neg) Style.red else if (e.funding > 0) Style.green else Style.dim;
        const bg_color: []const u8 = if (is_neg) Style.bg_red else Style.bg_green;
        const bar_width: usize = 20;
        const fill_f = @sqrt(@abs(e.funding) / max_rate);
        const fill: usize = @max(1, @as(usize, @intFromFloat(fill_f * @as(f64, @floatFromInt(bar_width)))));

        var buf: [512]u8 = undefined;
        var p: usize = 0;
        if (is_tty) p = emit(&buf, p, Style.bold_cyan);
        p = rpad(&buf, p, e.name, 8);
        if (is_tty) p = emit(&buf, p, Style.reset);
        if (is_tty) p = emit(&buf, p, rate_color);
        p = lpad(&buf, p, rate_str, 14);
        p = lpad(&buf, p, ann_str, 10);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "  ");
        if (is_tty) p = emit(&buf, p, bg_color);
        p = spaces(&buf, p, fill);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = spaces(&buf, p, bar_width - fill);
        if (is_tty) p = emit(&buf, p, Style.dim);
        var mark_buf2: [32]u8 = undefined;
        p = lpad(&buf, p, decFmt(e.mark, &mark_buf2), 12);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "\r\n");
        stdout.writeStreamingAll(io, buf[0..p]) catch {};
    }
    if (!a.all and end < total_count) try w.paginatePage(end - start, total_count, page, pages);
    try w.footer();
}

var funding_max_rate: f64 = 1;
var funding_entries_ptr: [*]const FundingEntry = undefined;
var funding_entries_len: usize = 0;

fn fundingTui(allocator: std.mem.Allocator, entries: []const FundingEntry) !void {
    const n = @min(entries.len, ListW.MAX_ITEMS);

    var max_rate: f64 = 0;
    for (entries[0..n]) |e| max_rate = @max(max_rate, @abs(e.funding));
    if (max_rate == 0) max_rate = 1;
    funding_max_rate = max_rate;
    funding_entries_ptr = entries.ptr;
    funding_entries_len = entries.len;

    const CellBuf = struct {
        rate: [20]u8 = undefined,
        rate_len: usize = 0,
        ann: [16]u8 = undefined,
        ann_len: usize = 0,
        mark: [32]u8 = undefined,
        mark_len: usize = 0,
    };
    var cell_bufs: [ListW.MAX_ITEMS]CellBuf = undefined;
    var items: [ListW.MAX_ITEMS]ListW.Item = undefined;

    for (0..n) |i| {
        const e = entries[i];
        const rate_pct = e.funding * 100.0;
        const ann_pct = e.funding * 8760.0 * 100.0;

        const rate_s = std.fmt.bufPrint(&cell_bufs[i].rate, "{d:.6}%", .{rate_pct}) catch "?";
        cell_bufs[i].rate_len = rate_s.len;
        const ann_s = std.fmt.bufPrint(&cell_bufs[i].ann, "{d:.1}%", .{ann_pct}) catch "?";
        cell_bufs[i].ann_len = ann_s.len;

        const mark_s = e.mark.normalize().toString(&cell_bufs[i].mark) catch "0";
        cell_bufs[i].mark_len = mark_s.len;

        const color: BufMod.Style = if (e.funding < 0) .{ .fg = .red } else if (e.funding > 0) .{ .fg = .green } else .{ .fg = .grey };

        items[i] = .{
            .cells = cellsInit(&.{ e.name, cell_bufs[i].rate[0..cell_bufs[i].rate_len], cell_bufs[i].ann[0..cell_bufs[i].ann_len], "", cell_bufs[i].mark[0..cell_bufs[i].mark_len] }),
            .styles = stylesInit(&.{ .{ .fg = .cyan, .bold = true }, color, color, .{}, .{ .fg = .grey, .dim = true } }),
            .sort_key = @abs(e.funding),
        };
    }

    const columns = [_]ListW.Column{
        .{ .label = "COIN", .width = 10 },
        .{ .label = "RATE", .width = 14, .right_align = true },
        .{ .label = "ANN%", .width = 10, .right_align = true },
        .{ .label = "HEAT", .width = 16 },
        .{ .label = "MARK", .width = 12, .right_align = true },
    };

    try runListView(&columns, &items, n, .{
        .title = "FUNDING RATES (hourly)",
        .on_render_cell = &fundingRenderCell,
        .allocator = allocator,
    });
}

fn fundingRenderCell(buf: *BufMod, x: u16, y: u16, width: u16, item: *const ListW.Item, col: usize, selected: bool) bool {
    if (col != 3) return false;
    if (width < 2) return true;

    const abs_rate = item.sort_key;
    const is_neg = std.mem.startsWith(u8, item.cells[1], "-"); // rate cell starts with '-'

    const fill_f = @sqrt(abs_rate / funding_max_rate);
    const fill: u16 = @max(1, @as(u16, @intFromFloat(fill_f * @as(f64, @floatFromInt(width)))));

    const bg_color: BufMod.Color = if (is_neg) .red else .green;
    const bar_style: BufMod.Style = if (selected)
        .{ .fg = .bright_white, .bg = .blue, .bold = true }
    else
        .{ .bg = bg_color };

    var bx: u16 = 0;
    while (bx < fill and x + bx < x + width) : (bx += 1) {
        const cell = buf.get(x + bx, y);
        cell.setChar(' ');
        cell.style = bar_style;
    }
    return true;
}

const FundingEntry = struct {
    name: []const u8,
    funding: f64,
    oi: Decimal,
    mark: Decimal,
};

const FundingData = struct {
    entries: []FundingEntry,
    count: usize,
    alloc_len: usize,
};

fn parseFundingData(allocator: std.mem.Allocator, mac_entries: []const response.MetaAndAssetCtx) !FundingData {
    var entries = try allocator.alloc(FundingEntry, mac_entries.len);
    var count: usize = 0;

    for (mac_entries) |e| {
        entries[count] = .{
            .name = e.meta.name,
            .funding = decToF64(e.ctx.funding),
            .oi = e.ctx.openInterest,
            .mark = if (e.ctx.markPx) |mp| mp else Decimal.ZERO,
        };
        count += 1;
    }

    std.mem.sort(FundingEntry, entries[0..count], {}, struct {
        fn lessThan(_: void, lhs: FundingEntry, rhs: FundingEntry) bool {
            return @abs(lhs.funding) > @abs(rhs.funding);
        }
    }.lessThan);

    return .{ .entries = entries[0..count], .count = count, .alloc_len = mac_entries.len };
}

pub fn book(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.BookArgs) !void {
    if (a.live) {
        return bookLive(allocator, config, a);
    }
    return bookStatic(allocator, w, config, a);
}

// Resolve spot pair name to @index for API calls.
// Returns null if pair not found in spotMeta.
fn resolveSpotIndex(allocator: std.mem.Allocator, config: Config, pair: []const u8, buf: *[16]u8) ?[]const u8 {
    const slash = std.mem.indexOf(u8, pair, "/") orelse return null;
    const base = pair[0..slash];
    const quote = pair[slash + 1 ..];
    var client = makeClient(allocator, config);
    defer client.deinit();
    var sm = client.getSpotMeta() catch return null;
    defer sm.deinit();
    for (sm.value.universe) |u| {
        const base_t = response.findSpotToken(sm.value.tokens, u.tokens[0]) orelse continue;
        const quote_t = response.findSpotToken(sm.value.tokens, u.tokens[1]) orelse continue;
        if (std.ascii.eqlIgnoreCase(base_t.name, base) and
            std.ascii.eqlIgnoreCase(quote_t.name, quote))
        {
            return std.fmt.bufPrint(buf, "@{d}", .{u.index}) catch return null;
        }
    }
    return null;
}

// Resolve spot coin for API calls. Index 0 (PURR/USDC) only
// accepts the pair name directly; all others need @index.
fn resolveSpotCoin(allocator: std.mem.Allocator, config: Config, pair: []const u8, buf: *[16]u8) []const u8 {
    const idx = resolveSpotIndex(allocator, config, pair, buf) orelse return pair;
    if (std.mem.eql(u8, idx, "@0")) return pair;
    return idx;
}

fn bookStatic(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.BookArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    var coin_upper: [16]u8 = undefined;
    var display_upper: [16]u8 = undefined;
    var spot_idx_buf: [16]u8 = undefined;
    const is_spot = std.mem.indexOf(u8, a.coin, "/") != null;
    const display_coin = upperCoin(a.coin, &display_upper);
    const coin = if (is_spot)
        resolveSpotCoin(allocator, config, display_coin, &spot_idx_buf)
    else
        upperCoin(a.coin, &coin_upper);

    if (w.format == .json) {
        var raw = try client.l2Book(coin);
        defer raw.deinit();
        if (raw.body.len < 10 or std.mem.startsWith(u8, raw.body, "null")) {
            return fail(w, "no book data for this coin");
        }
        if (is_spot) {
            if (std.mem.indexOf(u8, raw.body, coin)) |idx| {
                const new_len = raw.body.len - coin.len + display_coin.len;
                if (new_len <= 8192) {
                    var buf: [8192]u8 = undefined;
                    const prefix = raw.body[0..idx];
                    const suffix = raw.body[idx + coin.len ..];
                    const len = (std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ prefix, display_coin, suffix }) catch {
                        try w.jsonRaw(raw.body);
                        return;
                    }).len;
                    try w.jsonRaw(buf[0..len]);
                    return;
                }
            }
        }
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = client.getL2Book(coin) catch {
        return fail(w, "no book data for this coin");
    };
    defer typed.deinit();
    const book_data = typed.value;

    const bids_raw = book_data.levels[0];
    const asks_raw = book_data.levels[1];
    const depth = @min(a.depth, @min(bids_raw.len, asks_raw.len));

    const Level = struct { px: Decimal, sz: f64, cum: f64 };
    var bids = try allocator.alloc(Level, depth);
    defer allocator.free(bids);
    var asks = try allocator.alloc(Level, depth);
    defer allocator.free(asks);

    var bid_cum: f64 = 0;
    var ask_cum: f64 = 0;
    for (0..depth) |i| {
        const bid_sz = decToF64(bids_raw[i].sz);
        bid_cum += bid_sz;
        bids[i] = .{ .px = bids_raw[i].px, .sz = bid_sz, .cum = bid_cum };

        const ask_sz = decToF64(asks_raw[i].sz);
        ask_cum += ask_sz;
        asks[i] = .{ .px = asks_raw[i].px, .sz = ask_sz, .cum = ask_cum };
    }
    const max_cum = @max(bid_cum, ask_cum);

    var title_buf: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s} ORDER BOOK", .{coin}) catch "ORDER BOOK";
    try w.heading(title);

    const stdout = std.Io.File.stdout();
    const io = w.io;
    const is_tty = w.is_tty;

    const px_w: usize = 10;
    const sz_w: usize = 10;
    const cum_w: usize = 10;
    const bar_w: usize = 20;

    {
        var buf: [512]u8 = undefined;
        var p: usize = 0;
        if (is_tty) p = emit(&buf, p, Style.muted);
        p = rpad(&buf, p, "PRICE", px_w);
        p = lpad(&buf, p, "SIZE", sz_w);
        p = lpad(&buf, p, "TOTAL", cum_w);
        p = emit(&buf, p, "  ");
        p = rpad(&buf, p, "DEPTH", bar_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "\r\n");
        stdout.writeStreamingAll(io, buf[0..p]) catch {};
    }

    var ri: usize = depth;
    while (ri > 0) {
        ri -= 1;
        const ak = asks[ri];
        const fill = barFillSqrt(ak.cum, max_cum, bar_w);
        var cum_buf: [16]u8 = undefined;
        const cum_str = floatFmt(&cum_buf, ak.cum);

        var buf: [512]u8 = undefined;
        var p: usize = 0;
        var ak_px_buf: [32]u8 = undefined;
        var ak_sz_buf: [32]u8 = undefined;
        if (is_tty) p = emit(&buf, p, Style.red);
        p = rpad(&buf, p, decFmt(ak.px, &ak_px_buf), px_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = lpad(&buf, p, floatFmt(&ak_sz_buf, ak.sz), sz_w);
        if (is_tty) p = emit(&buf, p, Style.dim);
        p = lpad(&buf, p, cum_str, cum_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "  ");
        if (is_tty) p = emit(&buf, p, Style.bg_red);
        p = spaces(&buf, p, fill);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "\r\n");
        stdout.writeStreamingAll(io, buf[0..p]) catch {};
    }

    if (depth > 0) {
        const bid_f = decToF64(bids[0].px);
        const ask_f = decToF64(asks[0].px);
        const spread = ask_f - bid_f;
        const spread_pct = if (bid_f > 0) spread / bid_f * 100 else 0;
        var sbuf: [64]u8 = undefined;
        var sp_buf: [24]u8 = undefined;
        const sp_str = smartFmt(&sp_buf, spread);
        const ss = std.fmt.bufPrint(&sbuf, "spread: {s} ({d:.4}%)", .{ sp_str, spread_pct }) catch "";

        const total_w = px_w + sz_w + cum_w + 2 + bar_w;
        const left_pad = if (total_w > ss.len) (total_w - ss.len) / 2 else 0;

        var buf: [256]u8 = undefined;
        var p: usize = 0;
        if (is_tty) p = emit(&buf, p, Style.dim);
        p = spaces(&buf, p, left_pad);
        @memcpy(buf[p..][0..ss.len], ss);
        p += ss.len;
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "\r\n");
        stdout.writeStreamingAll(io, buf[0..p]) catch {};
    }

    for (0..depth) |i| {
        const b = bids[i];
        const fill = barFillSqrt(b.cum, max_cum, bar_w);
        var cum_buf: [16]u8 = undefined;
        const cum_str = floatFmt(&cum_buf, b.cum);

        var buf: [512]u8 = undefined;
        var p: usize = 0;
        var b_px_buf: [32]u8 = undefined;
        var b_sz_buf: [32]u8 = undefined;
        if (is_tty) p = emit(&buf, p, Style.green);
        p = rpad(&buf, p, decFmt(b.px, &b_px_buf), px_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = lpad(&buf, p, floatFmt(&b_sz_buf, b.sz), sz_w);
        if (is_tty) p = emit(&buf, p, Style.dim);
        p = lpad(&buf, p, cum_str, cum_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "  ");
        if (is_tty) p = emit(&buf, p, Style.bg_green);
        p = spaces(&buf, p, fill);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "\r\n");
        stdout.writeStreamingAll(io, buf[0..p]) catch {};
    }

    try w.footer();
}

/// sqrt-scaled bar fill for cumulative depth.
fn barFillSqrt(value: f64, max_value: f64, width: usize) usize {
    if (value <= 0 or max_value <= 0) return 0;
    const ratio = @min(@sqrt(value / max_value), 1.0);
    const raw: usize = @intFromFloat(ratio * @as(f64, @floatFromInt(width)));
    return @max(raw, 1);
}

fn floatFmt(buf: []u8, value: f64) []const u8 {
    return smartFmt(buf, value);
}

/// Adaptive decimal formatting: shows enough precision to be meaningful.
///   >= 1000    → 2 decimals  (67340.50)
///   >= 1       → 4 decimals  (85.8905)
///   >= 0.01    → 6 decimals  (0.003142)
///   < 0.01     → 8 decimals  (0.00003192)
fn emitSpotRow(w: *Writer, token: []const u8, bal_str: []const u8, val: f64, max_val: f64) !void {
    if (w.is_tty) {
        try w.print("  {s}{s}", .{ Style.rail_dim, Style.reset });
    } else {
        try w.print("  ", .{});
    }
    try w.print(" ", .{});
    try w.styled(Style.cyan, token);
    var i: usize = output_mod.displayWidth(token);
    while (i < 9) : (i += 1) try w.print(" ", .{});
    i = bal_str.len;
    while (i < 18) : (i += 1) try w.print(" ", .{});
    try w.styled(Style.bold_white, bal_str);
    try w.print(" ", .{});
    const ratio = if (max_val > 0) @sqrt(val / max_val) else 0.0;
    const fill = @max(if (val > 0) @as(usize, 1) else 0, @as(usize, @intFromFloat(ratio * 20.0)));
    try w.style(Style.bg_green);
    i = 0;
    while (i < fill) : (i += 1) try w.print(" ", .{});
    try w.style(Style.reset);
    try w.nl();
}

fn smartFmt(buf: []u8, value: f64) []const u8 {
    const abs = @abs(value);
    if (abs >= 1000) return std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch "?";
    if (abs >= 1) return std.fmt.bufPrint(buf, "{d:.4}", .{value}) catch "?";
    if (abs >= 0.01) return std.fmt.bufPrint(buf, "{d:.6}", .{value}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.8}", .{value}) catch "?";
}

/// Format a slippage price preserving the precision of the original.
fn slippageFmt(buf: []u8, value: f64) []const u8 {
    const abs = @abs(value);
    if (abs >= 100) return std.fmt.bufPrint(buf, "{d:.1}", .{value}) catch "?";
    if (abs >= 1) return std.fmt.bufPrint(buf, "{d:.4}", .{value}) catch "?";
    if (abs >= 0.001) return std.fmt.bufPrint(buf, "{d:.6}", .{value}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.10}", .{value}) catch "?";
}

fn emit(buf: []u8, pos: usize, s: []const u8) usize {
    @memcpy(buf[pos..][0..s.len], s);
    return pos + s.len;
}

fn spaces(buf: []u8, pos: usize, n: usize) usize {
    @memset(buf[pos..][0..n], ' ');
    return pos + n;
}

fn rpad(buf: []u8, pos: usize, text: []const u8, width: usize) usize {
    var p = pos;
    const tlen = @min(text.len, width);
    @memcpy(buf[p..][0..tlen], text[0..tlen]);
    p += tlen;
    if (width > tlen) {
        @memset(buf[p..][0 .. width - tlen], ' ');
        p += width - tlen;
    }
    return p;
}

fn lpad(buf: []u8, pos: usize, text: []const u8, width: usize) usize {
    var p = pos;
    if (width > text.len) {
        const pad = width - text.len;
        @memset(buf[p..][0..pad], ' ');
        p += pad;
    }
    @memcpy(buf[p..][0..text.len], text);
    p += text.len;
    return p;
}

fn bookLive(allocator: std.mem.Allocator, config: Config, a: args_mod.BookArgs) !void {
    var coin_upper: [16]u8 = undefined;
    var spot_idx_buf: [16]u8 = undefined;
    const coin = if (std.mem.indexOf(u8, a.coin, "/") != null)
        resolveSpotCoin(allocator, config, upperCoin(a.coin, &coin_upper), &spot_idx_buf)
    else
        upperCoin(a.coin, &coin_upper);

    var client = makeClient(allocator, config);
    defer client.deinit();

    var app = App.init(allocator, runtime.io()) catch return error.Overflow;
    defer app.deinit();
    app.setTickMs(150);

    var depth: usize = a.depth;

    const cyan = BufMod.Style{ .fg = .cyan, .bold = true };
    const white = BufMod.Style{ .fg = .bright_white };
    const dim = BufMod.Style{ .fg = .grey, .dim = true };
    const bold_green = BufMod.Style{ .fg = .green, .bold = true };
    const bold_red = BufMod.Style{ .fg = .red, .bold = true };

    while (app.running) {
        app.beginFrame();
        const buf = &app.buf;

        const w = app.width();
        const h = app.height();

        if (w < 50 or h < 10) {
            buf.putStr(1, 1, "too small", dim);
            app.endFrame();
            app.tick();
            if (app.pollKey()) |key| switch (key) {
                .char => |c| if (c == 'q') {
                    app.running = false;
                },
                .esc => {
                    app.running = false;
                },
                else => {},
            };
            continue;
        }

        var result = client.l2Book(coin) catch {
            buf.putStr(2, 4, "Fetching...", dim);
            app.endFrame();
            app.tick();
            continue;
        };
        defer result.deinit();

        var typed = std.json.parseFromSlice(response.L2Book, allocator, result.body, response.ParseOpts) catch continue;
        defer typed.deinit();
        const book_data = typed.value;

        const bids_bl = book_data.levels[0];
        const asks_bl = book_data.levels[1];
        const eff_depth = @min(depth, @min(bids_bl.len, asks_bl.len));

        const CumLevel = struct { px: Decimal, sz: f64, cum: f64 };
        var bid_levels: [64]CumLevel = undefined;
        var ask_levels: [64]CumLevel = undefined;
        var bid_cum: f64 = 0;
        var ask_cum: f64 = 0;

        for (0..eff_depth) |i| {
            const bid_sz = decToF64(bids_bl[i].sz);
            bid_cum += bid_sz;
            bid_levels[i] = .{ .px = bids_bl[i].px, .sz = bid_sz, .cum = bid_cum };

            const ask_sz = decToF64(asks_bl[i].sz);
            ask_cum += ask_sz;
            ask_levels[i] = .{ .px = asks_bl[i].px, .sz = ask_sz, .cum = ask_cum };
        }
        const max_cum = @max(bid_cum, ask_cum);

        var title_buf: [48]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s} ORDER BOOK", .{coin}) catch "BOOK";
        buf.drawBox(.{ .x = 0, .y = 0, .w = w, .h = h }, title, cyan);

        const col_p: u16 = 2;
        const col_s: u16 = 14;
        const col_c: u16 = 26;
        const col_b: u16 = 38;
        const bar_w: u16 = if (w > 60) @min(w -| 42, 30) else 0;

        buf.putStr(col_p, 1, "PRICE", dim);
        buf.putStr(col_s, 1, "SIZE", dim);
        buf.putStr(col_c, 1, "TOTAL", dim);
        if (bar_w > 0) buf.putStr(col_b, 1, "DEPTH", dim);

        const data_rows = h -| 4; // -2 border, -1 header, -1 sparkline
        const half_h = (data_rows -| 1) / 2;
        const show_depth = @min(eff_depth, half_h);

        var ri: usize = show_depth;
        var y: u16 = 2;
        while (ri > 0) : (y += 1) {
            ri -= 1;
            if (y >= h -| 2) break;
            const lv = ask_levels[ri];
            var apx_buf: [32]u8 = undefined;
            var asz_buf: [32]u8 = undefined;
            buf.putStr(col_p, y, decFmt(lv.px, &apx_buf), bold_red);
            buf.putStrRight(col_s, y, 10, floatFmt(&asz_buf, lv.sz), white);
            var cb: [16]u8 = undefined;
            buf.putStrRight(col_c, y, 10, floatFmt(&cb, lv.cum), dim);
            if (bar_w > 0 and max_cum > 0) {
                const fw: u16 = @max(1, @as(u16, @intFromFloat(@sqrt(lv.cum / max_cum) * @as(f64, @floatFromInt(bar_w)))));
                buf.putBgBar(col_b, y, fw, .{ .bg = .red });
            }
        }

        if (show_depth > 0 and y < h -| 2) {
            const bp = decToF64(bid_levels[0].px);
            const ap = decToF64(ask_levels[0].px);
            const sp = ap - bp;
            const pct = if (bp > 0) sp / bp * 100 else 0;
            var sb: [48]u8 = undefined;
            var spf: [24]u8 = undefined;
            const sp_s = smartFmt(&spf, sp);
            const ss = std.fmt.bufPrint(&sb, "\xe2\x94\x80\xe2\x94\x80 {s} ({d:.3}%) \xe2\x94\x80\xe2\x94\x80", .{ sp_s, pct }) catch "";
            buf.putStr((w -| @as(u16, @intCast(ss.len))) / 2, y, ss, .{ .fg = .yellow, .bold = true });
            y += 1;
        }

        for (0..show_depth) |i| {
            if (y >= h -| 2) break;
            const lv = bid_levels[i];
            var bpx_buf: [32]u8 = undefined;
            var bsz_buf: [32]u8 = undefined;
            buf.putStr(col_p, y, decFmt(lv.px, &bpx_buf), bold_green);
            buf.putStrRight(col_s, y, 10, floatFmt(&bsz_buf, lv.sz), white);
            var cb: [16]u8 = undefined;
            buf.putStrRight(col_c, y, 10, floatFmt(&cb, lv.cum), dim);
            if (bar_w > 0 and max_cum > 0) {
                const fw: u16 = @max(1, @as(u16, @intFromFloat(@sqrt(lv.cum / max_cum) * @as(f64, @floatFromInt(bar_w)))));
                buf.putBgBar(col_b, y, fw, .{ .bg = .green });
            }
            y += 1;
        }

        if (h > 8 and show_depth >= 2) {
            const spark_y = h -| 2;
            const spark_w: usize = @min(w -| 4, 60);
            const half_sp = spark_w / 2;
            var sv: [60]f64 = .{0} ** 60;
            for (0..@min(half_sp, show_depth)) |i| {
                sv[i] = ask_levels[@min(show_depth - 1, half_sp - 1 - i)].cum;
                if (i < show_depth) sv[half_sp + i] = bid_levels[i].cum;
            }
            buf.putSparkline(2, spark_y, sv[0..half_sp], .{ .fg = .red });
            buf.putSparkline(2 + @as(u16, @intCast(half_sp)), spark_y, sv[half_sp .. half_sp * 2], .{ .fg = .green });
        }

        buf.putStr(2, h -| 1, "q=quit +/-=depth 1-5=preset", dim);
        var db: [16]u8 = undefined;
        buf.putStr(30, h -| 1, std.fmt.bufPrint(&db, "depth={d}", .{show_depth}) catch "?", white);

        app.endFrame();
        app.tick();

        if (app.pollKey()) |key| {
            switch (key) {
                .char => |c| switch (c) {
                    'q' => app.running = false,
                    '+', '=' => depth = @min(depth + 5, 50),
                    '-', '_' => depth = if (depth > 5) depth - 5 else 5,
                    '1' => depth = 5,
                    '2' => depth = 10,
                    '3' => depth = 15,
                    '4' => depth = 20,
                    '5' => depth = 30,
                    else => {},
                },
                .esc => app.running = false,
                else => {},
            }
        }
    }
}

fn upperCoin(coin: []const u8, buf: *[16]u8) []const u8 {
    const len = @min(coin.len, 16);
    for (0..len) |i| buf[i] = std.ascii.toUpper(coin[i]);
    return buf[0..len];
}

fn isSpotAsset(asset: anytype) bool {
    const a: u64 = @intCast(asset);
    return a >= 10000 and a < 100000;
}

fn isOutcomeAsset(asset: anytype) bool {
    const a: u64 = @intCast(asset);
    return a >= 100_000_000;
}

/// Accept "0.001%" or "0.001" as percent, bare integer as raw tenths-of-bps.
/// One tenth of a basis point = 0.0001%.
fn parseBuilderFee(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    const has_pct = s[s.len - 1] == '%';
    const body = if (has_pct) s[0 .. s.len - 1] else s;
    if (!has_pct and std.mem.indexOfScalar(u8, body, '.') == null) {
        return std.fmt.parseInt(u32, body, 10) catch null;
    }
    const pct = std.fmt.parseFloat(f64, body) catch return null;
    if (pct < 0) return null;
    const tenths_bps = pct * 10_000.0;
    if (tenths_bps > @as(f64, std.math.maxInt(u32))) return null;
    return @intFromFloat(@round(tenths_bps));
}

fn parseBuilderArgs(addr_opt: ?[]const u8, fee_opt: ?[]const u8) !?types.BuilderInfo {
    const addr_str = addr_opt orelse return null;
    const fee_str = fee_opt orelse return error.MissingArgument;
    const addr = Client.parseAddress(addr_str) catch return error.InvalidFlag;
    const fee = parseBuilderFee(fee_str) orelse return error.InvalidFlag;
    return .{ .address = addr, .fee_tenths_bps = fee };
}

const ResolvedAsset = struct {
    index: usize,
    sz_decimals: i32, // -1 = unknown (raw index input)
};

/// Resolve asset name to index and sz_decimals.
fn resolveAsset(client: *Client, coin: []const u8) !ResolvedAsset {
    if (std.fmt.parseInt(usize, coin, 10) catch null) |idx|
        return .{ .index = idx, .sz_decimals = -1 };

    // Outcome coins: #<encoding> where encoding = 10 * outcome_id + side
    // Asset ID = 100_000_000 + encoding
    if (coin.len > 1 and coin[0] == '#') {
        if (std.fmt.parseInt(u32, coin[1..], 10) catch null) |encoding| {
            return .{
                .index = 100_000_000 + @as(usize, encoding),
                .sz_decimals = 0, // outcome shares are whole units
            };
        }
        return error.AssetNotFound;
    }

    if (std.mem.indexOf(u8, coin, "/")) |slash| {
        const base = coin[0..slash];
        const quote = coin[slash + 1 ..];
        var typed = try client.getSpotMeta();
        defer typed.deinit();
        const tokens = typed.value.tokens;
        for (typed.value.universe) |pair| {
            const base_t = response.findSpotToken(tokens, pair.tokens[0]) orelse continue;
            const quote_t = response.findSpotToken(tokens, pair.tokens[1]) orelse continue;
            if (std.ascii.eqlIgnoreCase(base_t.name, base) and
                std.ascii.eqlIgnoreCase(quote_t.name, quote))
            {
                return .{
                    .index = @intCast(10000 + pair.index),
                    .sz_decimals = @intCast(base_t.szDecimals),
                };
            }
        }
        return error.AssetNotFound;
    }

    if (std.mem.indexOf(u8, coin, ":")) |colon| {
        const dex_name = coin[0..colon];
        const symbol = coin[colon + 1 ..];
        var perp_dexes = try client.getPerpDexs();
        defer perp_dexes.deinit();
        var dex_index: ?u32 = null;
        for (perp_dexes.value) |dex| {
            if (std.ascii.eqlIgnoreCase(dex.name, dex_name)) {
                dex_index = dex.index;
                break;
            }
        }
        if (dex_index == null) return error.AssetNotFound;
        var typed = try client.getPerps(dex_name);
        defer typed.deinit();
        for (typed.value.universe, 0..) |pm, i| {
            if (std.ascii.eqlIgnoreCase(pm.name, symbol))
                return .{
                    .index = if (dex_index.? == 0) i else @as(usize, 100000 + dex_index.? * 10000 + @as(u32, @intCast(i))),
                    .sz_decimals = @intCast(pm.szDecimals),
                };
            if (std.mem.indexOf(u8, pm.name, ":")) |nc| {
                if (std.ascii.eqlIgnoreCase(pm.name[nc + 1 ..], symbol))
                    return .{
                        .index = if (dex_index.? == 0) i else @as(usize, 100000 + dex_index.? * 10000 + @as(u32, @intCast(i))),
                        .sz_decimals = @intCast(pm.szDecimals),
                    };
            }
        }
        return error.AssetNotFound;
    }

    var typed = try client.getPerps(null);
    defer typed.deinit();

    for (typed.value.universe, 0..) |pm, i| {
        if (std.ascii.eqlIgnoreCase(pm.name, coin))
            return .{ .index = i, .sz_decimals = @intCast(pm.szDecimals) };
    }

    return error.AssetNotFound;
}

pub fn stream(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.StreamArgs) !void {
    // Resolve spot pair names to @index for WS subscriptions
    var spot_idx_buf: [16]u8 = undefined;
    var coin_upper_buf: [16]u8 = undefined;
    const resolved_coin: ?[]const u8 = if (a.coin) |c| blk: {
        if (std.mem.indexOf(u8, c, "/") != null) {
            break :blk resolveSpotCoin(allocator, config, upperCoin(c, &coin_upper_buf), &spot_idx_buf);
        }
        break :blk c;
    } else null;

    const sub: ws_types.Subscription = switch (a.kind) {
        .trades => .{ .trades = .{ .coin = resolved_coin orelse return error.MissingArgument } },
        .bbo => .{ .bbo = .{ .coin = resolved_coin orelse return error.MissingArgument } },
        .book => .{ .l2Book = .{ .coin = resolved_coin orelse return error.MissingArgument } },
        .candles => .{ .candle = .{ .coin = resolved_coin orelse return error.MissingArgument, .interval = a.interval } },
        .mids => .{ .allMids = .{ .dex = null } },
        .fills => .{ .userFills = .{ .user = a.address orelse config.getAddress() orelse return error.MissingAddress } },
        .orders => .{ .orderUpdates = .{ .user = a.address orelse config.getAddress() orelse return error.MissingAddress } },
    };

    const is_json = w.format == .json or !w.is_tty;
    const io = w.io;

    if (!is_json) {
        stderrWriteAll(io, "Connecting...\r\n");
    }

    var conn = WsConnection.connect(std.heap.page_allocator, config.chain) catch |e| {
        return failFmt(w, "WebSocket connection failed: {s}", .{@errorName(e)});
    };
    defer conn.close();

    conn.subscribe(sub) catch {
        return fail(w, "Failed to subscribe");
    };

    if (!is_json) {
        stderrWriteAll(io, "Subscribed \xe2\x9c\x93  (Ctrl+C to quit)\r\n");
    }

    stream_shutdown.store(false, .release);
    stream_socket_fd.store(conn.socket_fd, .release);
    const S = struct {
        fn handler(_: posix.SIG) callconv(.c) void {
            stream_shutdown.store(true, .release);
            const fd = stream_socket_fd.load(.acquire);
            if (fd != -1) {
                _ = std.c.shutdown(fd, 2); // SHUT_RDWR = 2
            }
        }
    };
    const act = posix.Sigaction{
        .handler = .{ .handler = S.handler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);

    while (!stream_shutdown.load(.acquire)) {
        const event = conn.next() catch |e| {
            if (!is_json) {
                if (e == error.EndOfStream) {
                    stderrWriteAll(io, "Server closed connection (bad subscription?)\r\n");
                } else {
                    var err_buf: [256]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "Connection error: {s}\r\n", .{@errorName(e)}) catch "Connection error\r\n";
                    stderrWriteAll(io, err_msg);
                }
            }
            return;
        };

        switch (event) {
            .timeout => continue,
            .closed => {
                if (!is_json) {
                    stderrWriteAll(io, "Connection closed\r\n");
                }
                return;
            },
            .message => |msg| {
                if (msg.channel == .subscriptionResponse) continue;

                if (is_json) {
                    stdoutWriteAll(io, msg.raw_json);
                    stdoutWriteAll(io, "\n");
                    continue;
                }

                streamPretty(io, a.kind, msg.raw_json);
            },
        }
    }

    if (!is_json) {
        stderrWriteAll(io, "\r\n");
    }
}

fn streamPretty(io: std.Io, kind: args_mod.StreamKind, text: []const u8) void {
    const channel = ws_types.parseChannel(text);
    const data_slice = ws_types.extractData(text);

    switch (channel) {
        .subscriptionResponse => return,
        .pong => return,
        else => {},
    }

    _ = data_slice;

    switch (kind) {
        .trades => streamTradesPretty(io, text),
        .bbo => streamBboPretty(io, text),
        .candles => streamCandlePretty(io, text),
        else => {
            stdoutWriteAll(io, text);
            stdoutWriteAll(io, "\r\n");
        },
    }
}

fn streamTradesPretty(io: std.Io, text: []const u8) void {
    const data_start = std.mem.indexOf(u8, text, "\"data\"") orelse return;
    const arr_start = std.mem.indexOfPos(u8, text, data_start, "[") orelse return;
    var pos = arr_start;
    while (std.mem.indexOfPos(u8, text, pos, "{")) |obj_start| {
        const obj_end = std.mem.indexOfPos(u8, text, obj_start, "}") orelse break;
        const obj = text[obj_start .. obj_end + 1];

        const coin = jsonFieldStr(obj, "coin") orelse "?";
        const side = jsonFieldStr(obj, "side") orelse "?";
        const px = jsonFieldStr(obj, "px") orelse "?";
        const sz = jsonFieldStr(obj, "sz") orelse "?";

        const is_buy = side.len > 0 and side[0] == 'B';
        const side_color: []const u8 = if (is_buy) Style.bold_green else Style.bold_red;
        const side_label: []const u8 = if (is_buy) "BUY " else "SELL";

        const px_f = std.fmt.parseFloat(f64, px) catch 0;
        const sz_f = std.fmt.parseFloat(f64, sz) catch 0;
        const notional = px_f * sz_f;
        const whale = notional > 100_000;

        var buf: [256]u8 = undefined;
        var p: usize = 0;
        p = emit(&buf, p, side_color);
        p = emit(&buf, p, side_label);
        p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, " ");
        p = emit(&buf, p, Style.bold);
        p = rpad(&buf, p, coin, 6);
        p = emit(&buf, p, Style.reset);
        p = lpad(&buf, p, sz, 12);
        p = emit(&buf, p, " @ ");
        p = emit(&buf, p, Style.cyan);
        p = lpad(&buf, p, px, 12);
        p = emit(&buf, p, Style.reset);
        if (whale) {
            p = emit(&buf, p, " \xe2\x9a\xa1"); // ⚡
            var not_buf: [16]u8 = undefined;
            const not_str = std.fmt.bufPrint(&not_buf, " ${d:.0}", .{notional}) catch "?";
            p = emit(&buf, p, Style.bold_yellow);
            p = emit(&buf, p, not_str);
            p = emit(&buf, p, Style.reset);
        }
        p = emit(&buf, p, "\r\n");
        stdoutWriteAll(io, buf[0..p]);

        pos = obj_end + 1;
    }
}

fn streamBboPretty(io: std.Io, text: []const u8) void {
    const coin = jsonFieldStr(text, "coin") orelse "?";

    const bbo_marker = std.mem.indexOf(u8, text, "\"bbo\":[") orelse return;
    const arr_start = bbo_marker + 7; // past "bbo":[

    const bid_start = std.mem.indexOfPos(u8, text, arr_start, "{") orelse return;
    const bid_end = std.mem.indexOfPos(u8, text, bid_start, "}") orelse return;
    const bid_obj = text[bid_start .. bid_end + 1];
    const bid_px = jsonFieldStr(bid_obj, "px") orelse "-";
    const bid_sz = jsonFieldStr(bid_obj, "sz") orelse "-";

    const ask_start = std.mem.indexOfPos(u8, text, bid_end + 1, "{") orelse return;
    const ask_end = std.mem.indexOfPos(u8, text, ask_start, "}") orelse return;
    const ask_obj = text[ask_start .. ask_end + 1];
    const ask_px = jsonFieldStr(ask_obj, "px") orelse "-";
    const ask_sz = jsonFieldStr(ask_obj, "sz") orelse "-";

    var buf: [256]u8 = undefined;
    var p: usize = 0;
    p = emit(&buf, p, Style.bold);
    p = rpad(&buf, p, coin, 6);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, Style.green);
    p = emit(&buf, p, " bid ");
    p = lpad(&buf, p, bid_sz, 12);
    p = emit(&buf, p, " @ ");
    p = lpad(&buf, p, bid_px, 10);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, Style.dim);
    p = emit(&buf, p, " | ");
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, Style.red);
    p = emit(&buf, p, "ask ");
    p = lpad(&buf, p, ask_sz, 12);
    p = emit(&buf, p, " @ ");
    p = lpad(&buf, p, ask_px, 10);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, "\r\n");
    stdoutWriteAll(io, buf[0..p]);
}

fn streamCandlePretty(io: std.Io, text: []const u8) void {
    const data_start = std.mem.indexOf(u8, text, "\"data\"") orelse return;
    const obj_start = std.mem.indexOfPos(u8, text, data_start, "{") orelse return;
    const obj_end = std.mem.lastIndexOf(u8, text, "}") orelse return;
    const obj = text[obj_start .. obj_end + 1];

    const coin = jsonFieldStr(obj, "s") orelse jsonFieldStr(obj, "coin") orelse "?";
    const open = jsonFieldStr(obj, "o") orelse "?";
    const high = jsonFieldStr(obj, "h") orelse "?";
    const low = jsonFieldStr(obj, "l") orelse "?";
    const close_px = jsonFieldStr(obj, "c") orelse "?";
    const vol = jsonFieldStr(obj, "v") orelse "?";

    var buf: [256]u8 = undefined;
    var p: usize = 0;
    p = emit(&buf, p, Style.bold);
    p = rpad(&buf, p, coin, 6);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, " O:");
    p = emit(&buf, p, open);
    p = emit(&buf, p, " H:");
    p = emit(&buf, p, Style.green);
    p = emit(&buf, p, high);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, " L:");
    p = emit(&buf, p, Style.red);
    p = emit(&buf, p, low);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, " C:");
    p = emit(&buf, p, Style.bold);
    p = emit(&buf, p, close_px);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, Style.dim);
    p = emit(&buf, p, " V:");
    p = emit(&buf, p, vol);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, "\r\n");
    stdoutWriteAll(io, buf[0..p]);
}

/// Quick JSON string field extractor (no allocations, returns slice into input).
fn jsonFieldStr(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, json, search) orelse return null;
    const val_start = start + search.len;
    const val_end = std.mem.indexOfPos(u8, json, val_start, "\"") orelse return null;
    return json[val_start..val_end];
}

fn decToF64(d: Decimal) f64 {
    const m: f64 = @floatFromInt(d.mantissa);
    const s: f64 = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(d.scale)));
    return m / s;
}

fn decStr(d: ?Decimal, buf: []u8) []const u8 {
    if (d) |val| return val.normalize().toString(buf) catch "-";
    return "-";
}

fn decFmt(d: Decimal, buf: []u8) []const u8 {
    return d.normalize().toString(buf) catch "-";
}

fn hasAtKeys(val: std.json.Value) bool {
    var it = val.object.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.*.len > 1 and entry.key_ptr.*[0] == '@') return true;
    }
    return false;
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

pub fn markets(allocator: std.mem.Allocator, config: Config) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    var perps_typed = try client.getPerps(null);
    defer perps_typed.deinit();
    const universe = perps_typed.value.universe;

    // allMids returns {coin: "price"} dict — use raw JSON (dynamic keys)
    var mids_result = try client.allMids(null);
    defer mids_result.deinit();
    const mids_val = try mids_result.json();

    const MarketRow = struct {
        name_buf: [16]u8 = undefined,
        name_len: usize = 0,
        price_buf: [16]u8 = undefined,
        price_len: usize = 0,
        lev_buf: [8]u8 = undefined,
        lev_len: usize = 0,
        price_f: f64 = 0,
        delisted: bool = false,
    };

    const MAX = ListW.MAX_ITEMS;
    var rows: [MAX]MarketRow = undefined;
    var items: [MAX]ListW.Item = undefined;
    var count: usize = 0;

    for (universe) |pm| {
        if (count >= MAX) break;
        const name = pm.name;
        if (pm.isDelisted) continue; // skip delisted

        const mid_str = if (mids_val == .object) (mids_val.object.get(name) orelse null) else null;
        const price_str = if (mid_str) |ms| switch (ms) {
            .string => |s| s,
            else => "—",
        } else "—";
        const price_f = std.fmt.parseFloat(f64, price_str) catch 0;

        var row = &rows[count];
        row.delisted = false;
        row.price_f = price_f;

        row.name_len = @min(name.len, 16);
        @memcpy(row.name_buf[0..row.name_len], name[0..row.name_len]);

        const p = smartFmt(&row.price_buf, price_f);
        row.price_len = p.len;

        const l = std.fmt.bufPrint(&row.lev_buf, "{d}x", .{pm.maxLeverage}) catch "?";
        row.lev_len = l.len;

        const white = BufMod.Style{ .fg = .bright_white };
        const dim = BufMod.Style{ .fg = .grey };
        const cyan = BufMod.Style{ .fg = .cyan };

        items[count] = .{
            .cells = blk: {
                var c: [ListW.MAX_COLS][]const u8 = .{""} ** ListW.MAX_COLS;
                c[0] = row.name_buf[0..row.name_len];
                c[1] = row.price_buf[0..row.price_len];
                c[2] = row.lev_buf[0..row.lev_len];
                break :blk c;
            },
            .styles = blk: {
                var s: [ListW.MAX_COLS]BufMod.Style = .{BufMod.Style{}} ** ListW.MAX_COLS;
                s[0] = cyan;
                s[1] = white;
                s[2] = dim;
                break :blk s;
            },
            .sort_key = price_f,
        };
        count += 1;
    }

    const items_slice = items[0..count];
    std.mem.sort(ListW.Item, items_slice, {}, struct {
        fn cmp(_: void, a: ListW.Item, b: ListW.Item) bool {
            return a.sort_key > b.sort_key;
        }
    }.cmp);

    const columns = [_]ListW.Column{
        .{ .label = "COIN", .width = 12 },
        .{ .label = "PRICE", .width = 14, .right_align = true },
        .{ .label = "LEV", .width = 6, .right_align = true },
    };

    try runListView(&columns, items_slice, count, .{
        .title = "PERP MARKETS",
        .help = "j/k:nav  /:search  s:sort  Enter:book  q:quit",
        .allocator = allocator,
        .config = config,
        .on_select = &marketsOnSelect,
    });
}

fn marketsOnSelect(allocator: std.mem.Allocator, config: Config, items: []const ListW.Item, idx: usize) void {
    const coin = items[idx].cells[0];
    const ba = args_mod.BookArgs{ .coin = coin, .depth = 15, .live = true };
    bookLive(allocator, config, ba) catch {};
}

// ── Price ─────────────────────────────────────────────────────

pub fn price(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.PriceArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    // --- Parse coin input ---
    // "xyz:BTC" → dex=xyz, base=BTC
    // "HYPE/USDC" → base=HYPE, quote_filter=USDC (explicit spot)
    // "BTC" → base=BTC (resolve perp first, then spot)
    var base: []const u8 = a.coin;
    var dex: ?[]const u8 = a.dex;
    var quote_filter: ?[]const u8 = a.quote;
    var explicit_spot = false;

    if (std.mem.indexOf(u8, a.coin, ":")) |colon| {
        dex = a.coin[0..colon];
        base = a.coin[colon + 1 ..];
    } else if (std.mem.indexOf(u8, a.coin, "/")) |slash| {
        base = a.coin[0..slash];
        quote_filter = a.coin[slash + 1 ..];
        explicit_spot = true;
    }

    // --- Collect price sources ---
    const MAX_RESULTS = 16;
    var results: [MAX_RESULTS]PriceResult = undefined;
    var n_results: usize = 0;

    // 1. Perp on specified/default dex (skip if explicit spot or --quote)
    var perp_coin_buf: [64]u8 = undefined;
    var perp_mid_buf: [32]u8 = undefined;
    var perp_mids: ?client_mod.Client.InfoResult = null;
    defer if (perp_mids) |*m| m.deinit();
    if (!explicit_spot and quote_filter == null) {
        const perp_coin = if (dex) |d|
            (std.fmt.bufPrint(&perp_coin_buf, "{s}:{s}", .{ d, base }) catch base)
        else
            base;
        perp_mids = client.allMids(dex) catch null;
        if (perp_mids) |*m| {
            const val = m.json() catch null;
            if (val) |v| {
                if (json_mod.getString(v, perp_coin)) |mid_s| {
                    if (n_results < MAX_RESULTS) {
                        const len = @min(mid_s.len, 31);
                        @memcpy(perp_mid_buf[0..len], mid_s[0..len]);
                        results[n_results] = .{
                            .market = perp_coin,
                            .kind = "perp",
                            .venue = dex orelse "hl",
                            .mid = perp_mid_buf[0..len],
                        };
                        n_results += 1;
                    }
                }
            }
        }
    }

    // 2. Spot pairs — find all pairs with this base token
    const MAX_PAIRS = 8;
    var pair_names: [MAX_PAIRS][48]u8 = undefined;
    var pair_quotes: [MAX_PAIRS][16]u8 = undefined;
    var n_pairs: usize = 0;
    var spot_price_buf: [32]u8 = undefined;
    var spot_price_len: usize = 0;
    var token_details: ?std.json.Parsed(response.TokenDetails) = null;
    defer if (token_details) |*t| t.deinit();

    const want_spot = a.all or explicit_spot or quote_filter != null or n_results == 0;
    if (want_spot) {
        var token_id_buf: [36]u8 = undefined;
        var token_id_len: usize = 0;
        {
            var spot_meta = client.getSpotMeta() catch null;
            defer if (spot_meta) |*sm| sm.deinit();
            if (spot_meta) |sm| {
                for (sm.value.tokens) |tok| {
                    if (std.ascii.eqlIgnoreCase(tok.name, base) and tok.tokenId.len > 0 and tok.tokenId.len <= 36) {
                        @memcpy(token_id_buf[0..tok.tokenId.len], tok.tokenId);
                        token_id_len = tok.tokenId.len;
                        break;
                    }
                }
                for (sm.value.universe) |pair| {
                    const base_t = response.findSpotToken(sm.value.tokens, pair.tokens[0]) orelse continue;
                    const quote_t = response.findSpotToken(sm.value.tokens, pair.tokens[1]) orelse continue;
                    const pair_base = base_t.name;
                    const pair_quote = quote_t.name;
                    if (!std.ascii.eqlIgnoreCase(pair_base, base)) continue;
                    if (quote_filter) |qf| {
                        if (!std.ascii.eqlIgnoreCase(pair_quote, qf)) continue;
                    }
                    if (n_pairs >= MAX_PAIRS) break;
                    const total = pair_base.len + 1 + pair_quote.len;
                    if (total >= 48) continue;
                    @memcpy(pair_names[n_pairs][0..pair_base.len], pair_base);
                    pair_names[n_pairs][pair_base.len] = '/';
                    @memcpy(pair_names[n_pairs][pair_base.len + 1 .. total], pair_quote);
                    pair_names[n_pairs][total] = 0;
                    const ql = @min(pair_quote.len, 15);
                    @memcpy(pair_quotes[n_pairs][0..ql], pair_quote[0..ql]);
                    pair_quotes[n_pairs][ql] = 0;
                    n_pairs += 1;
                }
            }
        }
        if (token_id_len > 0 and n_pairs > 0) {
            token_details = client.getTokenDetails(token_id_buf[0..token_id_len]) catch null;
            const price_str = if (token_details) |t| (t.value.markPx orelse t.value.midPx) else null;
            if (price_str) |ps| {
                const len = @min(ps.len, 31);
                @memcpy(spot_price_buf[0..len], ps[0..len]);
                spot_price_len = len;
            }
            if (spot_price_len > 0) {
                for (0..n_pairs) |pi| {
                    if (n_results >= MAX_RESULTS) break;
                    results[n_results] = .{
                        .market = std.mem.sliceTo(&pair_names[pi], 0),
                        .kind = "spot",
                        .venue = std.mem.sliceTo(&pair_quotes[pi], 0),
                        .mid = spot_price_buf[0..spot_price_len],
                    };
                    n_results += 1;
                }
            }
        }
    }

    if (n_results == 0) {
        return fail(w, "no market data for this coin");
    }

    // --- JSON output ---
    if (w.format == .json) {
        if (a.all and n_results > 1) {
            var jbuf: [2048]u8 = undefined;
            var jlen: usize = 0;
            jbuf[0] = '[';
            jlen = 1;
            for (results[0..n_results], 0..) |r, i| {
                if (i > 0) {
                    jbuf[jlen] = ',';
                    jlen += 1;
                }
                jlen += (std.fmt.bufPrint(
                    jbuf[jlen..],
                    "{{\"market\":\"{s}\",\"type\":\"{s}\",\"venue\":\"{s}\",\"price\":{s}}}",
                    .{ r.market, r.kind, r.venue, r.mid },
                ) catch return error.Overflow).len;
            }
            jbuf[jlen] = ']';
            jlen += 1;
            try w.jsonRaw(jbuf[0..jlen]);
        } else {
            const r = results[0];
            var jbuf: [256]u8 = undefined;
            const jlen = (std.fmt.bufPrint(
                &jbuf,
                "{{\"coin\":\"{s}\",\"mid\":{s}}}",
                .{ r.market, r.mid },
            ) catch return error.Overflow).len;
            try w.jsonRaw(jbuf[0..jlen]);
        }
        return;
    }

    // --- Quiet output ---
    if (w.quiet) {
        try w.print("{s}\n", .{results[0].mid});
        return;
    }

    // --- TTY output ---
    try w.nl();
    for (results[0..n_results]) |r| {
        try w.style(Style.muted);
        try w.print("  {s: <18}", .{r.market});
        try w.style(Style.reset);
        try w.styled(Style.bold_white, r.mid);
        try w.style(Style.muted);
        try w.print("  {s}", .{r.kind});
        try w.style(Style.reset);
        try w.nl();
    }
    if (!a.all and n_results == 1 and !explicit_spot and quote_filter == null) {
        try w.style(Style.dim);
        try w.print("  (use --all to see spot pairs and other venues)\n", .{});
        try w.style(Style.reset);
    }
    try w.nl();
}

const PriceResult = struct {
    market: []const u8,
    kind: []const u8,
    venue: []const u8,
    mid: []const u8,
};

// ── Leverage ──────────────────────────────────────────────────

pub fn setLeverage(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.LeverageArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const asset = (try resolveAsset(&client, a.coin)).index;

    // If no leverage value, just show current leverage info
    if (a.leverage == null) {
        const addr = config.getAddress() orelse return error.MissingAddress;
        if (w.format == .json) {
            var result = try client.activeAssetData(addr, a.coin);
            defer result.deinit();
            try w.jsonRaw(result.body);
            return;
        }

        var typed = try client.getActiveAssetData(addr, a.coin);
        defer typed.deinit();
        const aad = typed.value;

        try w.styled(output_mod.Style.bold, a.coin);
        try w.print(" leverage\n", .{});

        {
            if (aad.leverage) |lev| {
                try w.print("  current   {d}x", .{lev.value});
                try w.print(" {s}", .{lev.type});
                try w.print("\n", .{});
                if (lev.rawVal) |r|
                    try w.print("  raw USD   {s}\n", .{r});
            }
            if (aad.markPx) |px| {
                var px_buf: [32]u8 = undefined;
                try w.print("  mark      {s}\n", .{decFmt(px, &px_buf)});
            }
            if (aad.maxTradeSzs) |mts| {
                var lb: [32]u8 = undefined;
                var sb: [32]u8 = undefined;
                try w.print("  max sz    {s} / {s}\n", .{ decFmt(mts[0], &lb), decFmt(mts[1], &sb) });
            }
            if (aad.availableToTrade) |avail| {
                var alb: [32]u8 = undefined;
                var asb: [32]u8 = undefined;
                try w.print("  avail     {s} / {s}\n", .{ decFmt(avail[0], &alb), decFmt(avail[1], &asb) });
            }
        }
        return;
    }

    // Set leverage
    const auth = try getWriteAuth(w, config);
    const lev = std.fmt.parseInt(u32, a.leverage.?, 10) catch return error.InvalidFlag;
    const nonce: u64 = runtime.nonceMs();

    const ul = types.UpdateLeverage{
        .asset = asset,
        .is_cross = a.cross,
        .leverage = lev,
    };
    var result = try client.updateLeverage(auth.signer, ul, nonce, null, null);
    defer result.deinit();

    if (try result.isOk()) {
        if (w.format == .json) {
            try w.jsonFmt("{{\"coin\":\"{s}\",\"leverage\":{d},\"mode\":\"{s}\"}}", .{
                a.coin, lev, if (a.cross) "cross" else "isolated",
            });
        } else {
            try w.print("{s} leverage set to {d}x ({s})\n", .{
                a.coin, lev, if (a.cross) "cross" else "isolated",
            });
        }
    } else {
        return failFmt(w, "failed: {s}", .{result.body});
    }
}

// ── Portfolio ─────────────────────────────────────────────────

pub fn portfolio(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.UserQuery) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;

    if (w.format == .json) {
        var perp_result = try client.clearinghouseState(addr, a.dex);
        defer perp_result.deinit();
        var spot_result = try client.spotClearinghouseState(addr);
        defer spot_result.deinit();
        var combo_buf: [16384]u8 = undefined;
        const combo = std.fmt.bufPrint(&combo_buf, "{{\"perp\":{s},\"spot\":{s}}}", .{ perp_result.body, spot_result.body }) catch return;
        try w.jsonRaw(combo);
        return;
    }

    var perp_typed = try client.getClearinghouseState(addr, a.dex);
    defer perp_typed.deinit();
    const state = perp_typed.value;
    const ms = state.marginSummary;

    {
        try w.nl();
        try w.styled(Style.muted, "  PORTFOLIO\n\n");
        var av_buf: [32]u8 = undefined;
        try w.print("  ", .{});
        try w.styled(Style.bold_white, "$");
        try w.styled(Style.bold_white, decFmt(ms.accountValue, &av_buf));
        try w.nl();
        try w.nl();

        try w.style(Style.subtle);
        try w.print("  ", .{});
        var i: usize = 0;
        while (i < 52) : (i += 1) try w.print("\xe2\x94\x80", .{});
        try w.style(Style.reset);
        try w.nl();
        var mu_buf: [32]u8 = undefined;
        var wd_buf: [32]u8 = undefined;
        try w.style(Style.muted);
        try w.print("  margin ", .{});
        try w.style(Style.reset);
        try w.styled(Style.white, decFmt(ms.totalMarginUsed, &mu_buf));
        try w.style(Style.muted);
        try w.print("  free ", .{});
        try w.style(Style.reset);
        try w.styled(Style.white, decFmt(state.withdrawable, &wd_buf));

        const av_f2 = decToF64(ms.accountValue);
        const mu_f2 = decToF64(ms.totalMarginUsed);
        const health = if (mu_f2 > 0 and av_f2 > 0) @max(0.0, @min(100.0, 100.0 - (mu_f2 / av_f2 * 100.0))) else 100.0;
        const hc: []const u8 = if (health > 50) Style.bold_green else if (health > 25) Style.bold_yellow else Style.bold_red;
        try w.style(Style.muted);
        try w.print("  health ", .{});
        try w.style(Style.reset);
        try w.bar(health, 100.0, 8, hc);
        var hbuf: [8]u8 = undefined;
        const hstr = std.fmt.bufPrint(&hbuf, " {d:.0}%", .{health}) catch "?";
        try w.styled(hc, hstr);
        try w.nl();
        try w.nl();
    }

    try printPositions(w, state.assetPositions, null);

    // HIP-3 DEX positions (--all-dexes)
    if (a.all_dexes) {
        var dex_typed = client.getPerpDexs() catch null;
        if (dex_typed) |*dt| {
            defer dt.deinit();
            for (dt.value) |dex| {
                var dex_state = client.getClearinghouseState(addr, dex.name) catch continue;
                defer dex_state.deinit();
                try printPositions(w, dex_state.value.assetPositions, dex.name);
            }
        }
    }

    // Spot balances with proportion bars
    var spot_typed = client.getSpotBalances(addr) catch null;
    defer if (spot_typed) |*st| st.deinit();
    if (spot_typed) |st| {
        var max_bal: f64 = 0;
        var nz_count: usize = 0;
        for (st.value.balances) |b| {
            const tf = decToF64(b.total);
            if (tf == 0) continue;
            max_bal = @max(max_bal, tf);
            nz_count += 1;
        }
        if (nz_count > 0) {
            try w.heading("SPOT");
            const hdr = [_]Column{
                .{ .text = "TOKEN", .width = 8 },
                .{ .text = "BALANCE", .width = 16, .align_right = true },
                .{ .text = "", .width = 20 },
            };
            try w.tableHeader(&hdr);
            try w.panelSep();

            for (st.value.balances) |b| {
                const total_f = decToF64(b.total);
                if (total_f == 0) continue;
                var fmt_buf: [32]u8 = undefined;
                const formatted = smartFmt(&fmt_buf, total_f);
                try emitSpotRow(w, b.coin, formatted, total_f, max_bal);
            }
            try w.footer();
        }
    }
}

fn printPositions(w: *Writer, asset_positions: []const response.AssetPosition, dex_name: ?[]const u8) !void {
    {
        var title_buf: [64]u8 = undefined;
        const title = if (dex_name) |dn|
            std.fmt.bufPrint(&title_buf, "POSITIONS \xc2\xb7 {s}", .{dn}) catch "POSITIONS"
        else
            "POSITIONS";
        try w.heading(title);

        const hdr = [_]Column{
            .{ .text = "COIN", .width = 8 },
            .{ .text = "SIDE", .width = 6 },
            .{ .text = "SIZE", .width = 12, .align_right = true },
            .{ .text = "ENTRY", .width = 10, .align_right = true },
            .{ .text = "PNL", .width = 14, .align_right = true },
        };
        try w.tableHeader(&hdr);

        var has_any = false;
        for (asset_positions) |ap| {
            const p = ap.position;
            const szi_f = decToF64(p.szi);
            if (szi_f == 0) continue;
            has_any = true;
            var szi_buf: [32]u8 = undefined;
            var entry_buf: [32]u8 = undefined;
            var pnl_buf: [32]u8 = undefined;
            const side_s: []const u8 = if (szi_f > 0) "LONG" else "SHORT";
            const side_c: []const u8 = if (szi_f > 0) Style.green else Style.red;
            var abs_buf: [32]u8 = undefined;
            const abs_s = std.fmt.bufPrint(&abs_buf, "{d}", .{@abs(szi_f)}) catch decFmt(p.szi, &szi_buf);
            const entry_s = if (p.entryPx) |ep| decFmt(ep, &entry_buf) else "-";
            const pnl_s = if (p.unrealizedPnl) |up| decFmt(up, &pnl_buf) else "-";
            const pnl_f = if (p.unrealizedPnl) |up| decToF64(up) else 0;
            const pnl_c: []const u8 = if (pnl_f > 0) Style.bold_green else if (pnl_f < 0) Style.bold_red else Style.muted;

            const cols = [_]Column{
                .{ .text = p.coin, .width = 8, .color = Style.bold_cyan },
                .{ .text = side_s, .width = 6, .color = side_c },
                .{ .text = abs_s, .width = 12, .align_right = true },
                .{ .text = entry_s, .width = 10, .align_right = true, .color = Style.muted },
                .{ .text = pnl_s, .width = 14, .align_right = true, .color = pnl_c },
            };
            try w.tableRow(&cols);
        }
        if (!has_any) {
            try w.style(Style.muted);
            try w.print("  (none)\n", .{});
            try w.style(Style.reset);
        }
        try w.nl();
    }
}

// ── Referral ──────────────────────────────────────────────────

pub fn referralCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.ReferralArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    switch (a.action) {
        .status => {
            const addr = config.getAddress() orelse return error.MissingAddress;
            if (w.format == .json) {
                var result = try client.referral(addr);
                defer result.deinit();
                try w.jsonRaw(result.body);
                return;
            }

            var typed = try client.getReferral(addr);
            defer typed.deinit();
            const ref = typed.value;
            if (ref.referredBy) |r|
                try w.print("referred by   {s}\n", .{r})
            else
                try w.print("referred by   (none)\n", .{});
            if (ref.cumVlm) |v| {
                var b: [32]u8 = undefined;
                try w.print("referral vol  ${s}\n", .{decFmt(v, &b)});
            }
            if (ref.unclaimedRewards) |v| {
                var b: [32]u8 = undefined;
                try w.print("unclaimed     ${s}\n", .{decFmt(v, &b)});
            }
            if (ref.claimedRewards) |v| {
                var b: [32]u8 = undefined;
                try w.print("claimed       ${s}\n", .{decFmt(v, &b)});
            }
        },
        .set => {
            const code = a.code orelse {
                try w.err("usage: hlz referral set <CODE>");
                return error.MissingArgument;
            };
            const auth = try getWriteAuth(w, config);
            const nonce: u64 = runtime.nonceMs();
            var result = try client.setReferrer(auth.signer, .{ .code = code }, nonce, null, null);
            defer result.deinit();

            if (try result.isOk()) {
                if (w.format == .json) {
                    try w.jsonFmt("{{\"status\":\"ok\",\"code\":\"{s}\"}}", .{code});
                } else {
                    try w.print("referral code set: {s}\n", .{code});
                }
            } else {
                return failFmt(w, "failed: {s}", .{result.body});
            }
        },
    }
}

// ── TWAP ──────────────────────────────────────────────────

pub fn twap(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.TwapArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const auth = try getWriteAuth(w, config);
    const resolved = try resolveAsset(&client, a.coin);
    const asset = resolved.index;
    const total_sz = std.fmt.parseFloat(f64, a.size) catch return error.Overflow;
    const is_buy = std.mem.eql(u8, a.side, "buy") or std.mem.eql(u8, a.side, "long");
    const duration_ms = parseDuration(a.duration) orelse return error.InvalidFlag;
    const slices = @max(a.slices, 1);
    const slice_sz = total_sz / @as(f64, @floatFromInt(slices));
    const interval_ms: u64 = duration_ms / @as(u64, @intCast(slices));

    if (w.format != .json) {
        try w.print("TWAP: {s} {s} {s} over {s} in {d} slices\n", .{
            a.side, a.size, a.coin, a.duration, slices,
        });
        try w.print("  slice size: ", .{});
        var sb: [24]u8 = undefined;
        try w.print("{s}  interval: {d}s\n\n", .{ smartFmt(&sb, slice_sz), interval_ms / 1000 });
    }

    // Resolve spot @index / outcome #encoding for book lookup
    var twap_book_buf: [16]u8 = undefined;
    var twap_coin_upper: [16]u8 = undefined;
    const twap_book_coin = if (isOutcomeAsset(asset))
        (std.fmt.bufPrint(&twap_book_buf, "#{d}", .{asset - 100_000_000}) catch a.coin)
    else if (asset > 10000 and isSpotAsset(asset))
        (std.fmt.bufPrint(&twap_book_buf, "@{d}", .{asset - 10000}) catch a.coin)
    else if (asset == 10000 and isSpotAsset(asset))
        upperCoin(a.coin, &twap_coin_upper)
    else
        a.coin;

    var filled: f64 = 0;
    var total_cost: f64 = 0;

    for (0..slices) |i| {
        var book_result = client.l2Book(twap_book_coin) catch {
            if (w.format == .json) {
                try w.jsonFmt("{{\"event\":\"error\",\"slice\":{d},\"error\":\"book_fetch_failed\"}}", .{i + 1});
            } else {
                try w.errFmt("slice {d}: failed to fetch book", .{i + 1});
            }
            continue;
        };
        defer book_result.deinit();
        var book_typed = std.json.parseFromSlice(response.L2Book, allocator, book_result.body, response.ParseOpts) catch continue;
        defer book_typed.deinit();

        // Get best price + apply slippage
        const slippage_mult: f64 = if (is_buy) 1.0 + a.slippage_pct / 100.0 else 1.0 - a.slippage_pct / 100.0;
        const best_px = getBestPrice(book_typed.value.levels, is_buy) orelse continue;
        const slip_px = best_px * slippage_mult;

        var px_buf: [32]u8 = undefined;
        const px_str = slippageFmt(&px_buf, slip_px);
        const limit_px_raw = Decimal.fromString(px_str) catch continue;
        const limit_px = if (resolved.sz_decimals >= 0) blk: {
            const pt = if (isSpotAsset(asset) or isOutcomeAsset(asset))
                hlz.hypercore.tick.PriceTick.forSpot(resolved.sz_decimals)
            else
                hlz.hypercore.tick.PriceTick.forPerp(resolved.sz_decimals);
            break :blk pt.round(limit_px_raw) orelse limit_px_raw;
        } else limit_px_raw;

        var sz_buf: [32]u8 = undefined;
        const sz_str = smartFmt(&sz_buf, slice_sz);
        const sz_dec = Decimal.fromString(sz_str) catch continue;

        const order = types.OrderRequest{
            .asset = asset,
            .is_buy = is_buy,
            .limit_px = limit_px,
            .sz = sz_dec,
            .reduce_only = false,
            .order_type = .{ .limit = .{ .tif = .FrontendMarket } },
            .cloid = makeCloid(),
        };
        const batch_order = types.BatchOrder{
            .orders = &[_]types.OrderRequest{order},
            .grouping = .na,
        };

        var nonce_handler = response.NonceHandler.init();
        const nonce = nonce_handler.next();

        var result = client.place(auth.signer, batch_order, nonce, null, null) catch |e| {
            if (w.format == .json) {
                try w.jsonFmt("{{\"event\":\"error\",\"slice\":{d},\"error\":\"{s}\"}}", .{ i + 1, @errorName(e) });
            } else {
                try w.errFmt("slice {d}: {s}", .{ i + 1, @errorName(e) });
            }
            continue;
        };
        defer result.deinit();

        const val = result.json() catch continue;
        const statuses = response.parseOrderStatuses(allocator, val) catch continue;
        defer allocator.free(statuses);

        var slice_px: f64 = 0;
        var slice_filled: f64 = 0;
        if (statuses.len > 0) {
            switch (statuses[0]) {
                .filled => |f| {
                    slice_filled = slice_sz;
                    slice_px = std.fmt.parseFloat(f64, decStr(f.avgPx, &px_buf)) catch best_px;
                },
                .resting => {
                    slice_filled = slice_sz;
                    slice_px = best_px;
                },
                else => {},
            }
        }

        filled += slice_filled;
        total_cost += slice_filled * slice_px;

        if (w.format == .json) {
            var avg_buf: [24]u8 = undefined;
            try w.jsonFmt("{{\"event\":\"slice\",\"n\":{d},\"filled\":\"{s}\",\"price\":\"{s}\",\"total_filled\":\"{s}\"}}", .{
                i + 1, smartFmt(&sz_buf, slice_filled), smartFmt(&px_buf, slice_px), smartFmt(&avg_buf, filled),
            });
        } else {
            try w.print("  [{d}/{d}] filled {s} @ {s}  (total: {s})\n", .{
                i + 1,                     slices, smartFmt(&sz_buf, slice_filled), smartFmt(&px_buf, slice_px),
                smartFmt(&px_buf, filled),
            });
        }

        // Sleep between slices (except after last)
        if (i + 1 < slices) {
            try runtime.sleepNs(interval_ms * std.time.ns_per_ms);
        }
    }

    // Summary
    const avg_px = if (filled > 0) total_cost / filled else 0;
    if (w.format == .json) {
        var fb: [24]u8 = undefined;
        var ab: [24]u8 = undefined;
        try w.jsonFmt("{{\"event\":\"done\",\"total_filled\":\"{s}\",\"avg_price\":\"{s}\",\"slices\":{d}}}", .{
            smartFmt(&fb, filled), smartFmt(&ab, avg_px), slices,
        });
    } else {
        var fb: [24]u8 = undefined;
        var ab: [24]u8 = undefined;
        try w.print("\ndone: filled {s} @ avg {s}\n", .{ smartFmt(&fb, filled), smartFmt(&ab, avg_px) });
    }
}

fn getBestPrice(book_levels: [2][]response.BookLevel, is_buy: bool) ?f64 {
    const side_idx: usize = if (is_buy) 1 else 0; // asks for buy, bids for sell
    const side = book_levels[side_idx];
    if (side.len == 0) return null;
    return decToF64(side[0].px);
}

fn parseDuration(s: []const u8) ?u64 {
    if (s.len < 2) return null;
    const unit = s[s.len - 1];
    const num_str = s[0 .. s.len - 1];
    const num = std.fmt.parseInt(u64, num_str, 10) catch return null;
    return switch (unit) {
        's' => num * 1000,
        'm' => num * 60 * 1000,
        'h' => num * 3600 * 1000,
        'd' => num * 86400 * 1000,
        else => null,
    };
}

fn makeCloid() types.Cloid {
    const now: u64 = runtime.nonceMs();
    var cloid = types.ZERO_CLOID;
    cloid[0] = @intCast((now >> 56) & 0xff);
    cloid[1] = @intCast((now >> 48) & 0xff);
    cloid[2] = @intCast((now >> 40) & 0xff);
    cloid[3] = @intCast((now >> 32) & 0xff);
    cloid[4] = @intCast((now >> 24) & 0xff);
    cloid[5] = @intCast((now >> 16) & 0xff);
    cloid[6] = @intCast((now >> 8) & 0xff);
    cloid[7] = @intCast(now & 0xff);
    return cloid;
}

// ── Batch ─────────────────────────────────────────────────

pub fn batchCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.BatchArgs) !void {
    // --stdin: read order strings from stdin (one per line or JSON array)
    var stdin_storage: [4096]u8 = undefined;
    var stdin_len: usize = 0;
    var effective = a;

    if (a.stdin) {
        stdin_len = stdinReadAll(&stdin_storage);
        if (stdin_len > 0) {
            const input = std.mem.trim(u8, stdin_storage[0..stdin_len], " \t\r\n");
            if (input.len > 0 and input[0] == '[') {
                // JSON array — parse, then copy strings into stdin_storage tail
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
                    return fail(w, "invalid JSON on stdin");
                };
                // Copy strings into rest of stdin_storage so they outlive parsed
                var pos: usize = stdin_len;
                if (parsed.value == .array) {
                    for (parsed.value.array.items) |item| {
                        if (item == .string and effective.count < 16) {
                            const s = item.string;
                            if (pos + s.len <= stdin_storage.len) {
                                @memcpy(stdin_storage[pos..][0..s.len], s);
                                effective.orders[effective.count] = stdin_storage[pos..][0..s.len];
                                effective.count += 1;
                                pos += s.len;
                            }
                        }
                    }
                }
                parsed.deinit();
            } else {
                // Plain text: one order per line (slices into stdin_storage, stable)
                var it = std.mem.splitScalar(u8, input, '\n');
                while (it.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (trimmed.len > 0 and effective.count < 16) {
                        effective.orders[effective.count] = trimmed;
                        effective.count += 1;
                    }
                }
            }
        }
    }

    if (effective.count == 0) {
        return fail(w, "no orders. Usage: hlz batch \"buy BTC 0.1 @98000\" or echo orders | hlz batch --stdin");
    }
    const ba = effective;

    var client = makeClient(allocator, config);
    defer client.deinit();
    const auth = try getWriteAuth(w, config);

    // Parse each order string into OrderRequest
    var batch_items: [16]types.OrderRequest = undefined;
    var order_count: usize = 0;

    for (0..ba.count) |i| {
        const order_str = ba.orders[i] orelse continue;
        // Tokenize the order string (space-separated)
        var tokens: [8][]const u8 = undefined;
        var token_count: usize = 0;
        var it = std.mem.splitScalar(u8, order_str, ' ');
        while (it.next()) |tok| {
            if (tok.len > 0 and token_count < 8) {
                tokens[token_count] = tok;
                token_count += 1;
            }
        }
        if (token_count < 3) {
            try w.errFmt("order {d}: need at least 'side coin size' (got {d} tokens)", .{ i + 1, token_count });
            continue;
        }

        const side_str = tokens[0];
        const coin = tokens[1];
        const size_str = tokens[2];
        const is_buy = std.mem.eql(u8, side_str, "buy") or std.mem.eql(u8, side_str, "long");

        const resolved_asset = resolveAsset(&client, coin) catch {
            try w.errFmt("order {d}: unknown asset {s}", .{ i + 1, coin });
            continue;
        };
        const asset_idx = resolved_asset.index;

        const sz = Decimal.fromString(size_str) catch {
            try w.errFmt("order {d}: invalid size {s}", .{ i + 1, size_str });
            continue;
        };

        // Check for price (@PX or 4th positional)
        var limit_px: Decimal = undefined;
        var order_type: types.OrderTypePlacement = .{ .limit = .{ .tif = .FrontendMarket } };
        var found_price = false;

        for (tokens[3..token_count]) |tok| {
            if (tok.len > 0 and tok[0] == '@') {
                limit_px = Decimal.fromString(tok[1..]) catch continue;
                order_type = .{ .limit = .{ .tif = .Gtc } };
                found_price = true;
                break;
            }
        }

        if (!found_price) {
            // Market order — resolve spot @index / outcome #encoding for book lookup
            var batch_book_buf: [16]u8 = undefined;
            var batch_coin_upper: [16]u8 = undefined;
            const batch_book_coin = if (isOutcomeAsset(asset_idx))
                (std.fmt.bufPrint(&batch_book_buf, "#{d}", .{asset_idx - 100_000_000}) catch coin)
            else if (asset_idx > 10000 and isSpotAsset(asset_idx))
                (std.fmt.bufPrint(&batch_book_buf, "@{d}", .{asset_idx - 10000}) catch coin)
            else if (asset_idx == 10000 and isSpotAsset(asset_idx))
                upperCoin(coin, &batch_coin_upper)
            else
                coin;
            var book_typed = client.getL2Book(batch_book_coin) catch continue;
            defer book_typed.deinit();
            const best = getBestPrice(book_typed.value.levels, is_buy) orelse continue;
            const slip = if (is_buy) best * 1.01 else best * 0.99;
            var sb: [32]u8 = undefined;
            limit_px = Decimal.fromString(slippageFmt(&sb, slip)) catch continue;
        }

        // Round to valid tick size
        if (resolved_asset.sz_decimals >= 0) {
            const pt = if (isSpotAsset(asset_idx) or isOutcomeAsset(asset_idx))
                hlz.hypercore.tick.PriceTick.forSpot(resolved_asset.sz_decimals)
            else
                hlz.hypercore.tick.PriceTick.forPerp(resolved_asset.sz_decimals);
            limit_px = pt.round(limit_px) orelse limit_px;
        }

        batch_items[order_count] = .{
            .asset = asset_idx,
            .is_buy = is_buy,
            .limit_px = limit_px,
            .sz = sz,
            .reduce_only = false,
            .order_type = order_type,
            .cloid = makeCloid(),
        };
        order_count += 1;
    }

    if (order_count == 0) {
        return fail(w, "no valid orders to submit");
    }

    const builder = parseBuilderArgs(ba.builder, ba.builder_fee) catch |e| switch (e) {
        error.MissingArgument => return failFmt(w, "--builder requires --builder-fee", .{}),
        error.InvalidFlag => return failFmt(w, "invalid --builder or --builder-fee value", .{}),
    };
    const batch_order = types.BatchOrder{
        .orders = batch_items[0..order_count],
        .grouping = .na,
        .builder = builder,
    };

    var nonce_handler = response.NonceHandler.init();
    const nonce = nonce_handler.next();

    var result = try client.place(auth.signer, batch_order, nonce, null, null);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const statuses = try response.parseOrderStatuses(allocator, val);
    defer allocator.free(statuses);

    for (statuses, 0..) |s, idx| {
        switch (s) {
            .resting => |r| {
                var ob: [20]u8 = undefined;
                try w.print("  [{d}] resting (oid: {s})\n", .{ idx + 1, std.fmt.bufPrint(&ob, "{d}", .{r.oid}) catch "?" });
            },
            .filled => |f| {
                var ab: [32]u8 = undefined;
                try w.print("  [{d}] filled @ {s}\n", .{ idx + 1, decStr(f.avgPx, &ab) });
            },
            .success => try w.print("  [{d}] accepted\n", .{idx + 1}),
            .waitingForTrigger => try w.print("  [{d}] waiting for trigger\n", .{idx + 1}),
            .waitingForFill => try w.print("  [{d}] waiting to fill\n", .{idx + 1}),
            .@"error" => |msg| try w.print("  [{d}] error: {s}\n", .{ idx + 1, msg }),
            .unknown => try w.print("  [{d}] unknown\n", .{idx + 1}),
        }
    }

    if (statuses.len == 0) {
        const status = response.parseResponseStatus(val);
        switch (status) {
            .ok => try w.success("Batch submitted"),
            .err => {
                const err_msg = json_mod.getString(val, "response") orelse "unknown error";
                return failFmt(w, "rejected: {s}", .{err_msg});
            },
            .unknown => return fail(w, "unknown response"),
        }
    }
}

// ── Account & Transfer Commands ───────────────────────────────

/// Parse a timestamp from user input (seconds or milliseconds).
fn parseTimestampMs(s: []const u8) ?u64 {
    const v = std.fmt.parseInt(u64, s, 10) catch return null;
    // If value < 2^40, assume seconds and convert to ms
    if (v < 1_099_511_627_776) return v * 1000;
    return v;
}

pub fn withdrawCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.WithdrawArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const auth = try getWriteAuth(w, config);
    const now: u64 = runtime.nonceMs();
    const dest_str = a.destination orelse auth.address();
    const dest = Client.parseAddress(dest_str) catch {
        try w.err("invalid destination address");
        return;
    };

    var result = try client.withdraw(auth.signer, dest, a.amount, now);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const ok = try result.isOk();
    if (ok) {
        try w.success("Withdrawal initiated ");
        try w.print("{s} USDC \xe2\x86\x92 {s}\n", .{ a.amount, dest_str });
    } else {
        try w.fail("withdrawal failed");
        try w.print("{s}\n", .{result.body});
        return error.CommandFailed;
    }
}

pub fn transferCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.TransferArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const auth = try getWriteAuth(w, config);
    var nonce_handler = response.NonceHandler.init();
    const nonce = nonce_handler.next();

    const to_perp = a.direction == .to_perp;

    var result = try client.usdClassTransfer(auth.signer, a.amount, to_perp, nonce);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const ok = try result.isOk();
    if (ok) {
        const label = if (to_perp) "spot \xe2\x86\x92 perp" else "perp \xe2\x86\x92 spot";
        try w.success("Transferred ");
        try w.print("{s} USDC ({s})\n", .{ a.amount, label });
    } else {
        try w.fail("transfer failed");
        try w.print("{s}\n", .{result.body});
        return error.CommandFailed;
    }
}

pub fn feesCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.UserQuery) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;

    if (w.format == .json) {
        var raw = try client.userFees(addr);
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getUserFees(addr);
    defer typed.deinit();
    const fees = typed.value;

    try w.heading("FEE RATES");
    var add_buf: [32]u8 = undefined;
    var cross_buf: [32]u8 = undefined;
    try w.kv("Maker rate", decStr(fees.userAddRate, &add_buf));
    try w.kv("Taker rate", decStr(fees.userCrossRate, &cross_buf));
    if (fees.activeReferralDiscount) |d| {
        var disc_buf: [32]u8 = undefined;
        try w.kv("Referral discount", decFmt(d, &disc_buf));
    }
    try w.footer();
}

pub fn rateLimitCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.UserQuery) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;

    if (w.format == .json) {
        var raw = try client.userRateLimit(addr);
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getUserRateLimit(addr);
    defer typed.deinit();
    const rl = typed.value;

    try w.heading("RATE LIMIT");
    var vlm_buf: [32]u8 = undefined;
    try w.kv("Cumulative volume", decStr(rl.cumVlm, &vlm_buf));

    if (rl.nRequestsUsed) |used| {
        var used_buf: [20]u8 = undefined;
        const used_str = std.fmt.bufPrint(&used_buf, "{d}", .{used}) catch "-";
        try w.kv("Requests used", used_str);
    }
    if (rl.nRequestsCap) |cap| {
        var cap_buf: [20]u8 = undefined;
        const cap_str = std.fmt.bufPrint(&cap_buf, "{d}", .{cap}) catch "-";
        try w.kv("Requests cap", cap_str);
    }
    try w.footer();
}

pub fn stakeCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.StakeArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    switch (a.action) {
        .status => {
            const addr = config.getAddress() orelse return error.MissingAddress;
            if (w.format == .json) {
                var raw = try client.delegatorSummary(addr);
                defer raw.deinit();
                try w.jsonRaw(raw.body);
                return;
            }
            // Pretty output — just forward raw JSON for now (complex nested structure)
            var raw = try client.delegatorSummary(addr);
            defer raw.deinit();
            try w.heading("STAKING SUMMARY");
            try w.print("{s}\n", .{raw.body});
        },
        .delegate, .undelegate => {
            const validator = a.validator orelse return error.Overflow;
            const amount_str = a.amount orelse return error.Overflow;
            const auth = try getWriteAuth(w, config);
            var nonce_handler = response.NonceHandler.init();
            const nonce = nonce_handler.next();

            // Convert amount to wei (amount * 1e18) — for now, pass as integer directly
            const wei = std.fmt.parseInt(u64, amount_str, 10) catch return error.Overflow;
            const is_undelegate = a.action == .undelegate;

            const val_addr = Client.parseAddress(validator) catch {
                try w.err("invalid validator address");
                return;
            };
            var result = try client.tokenDelegate(auth.signer, val_addr, wei, is_undelegate, nonce);
            defer result.deinit();

            if (w.format == .json) {
                try w.jsonRaw(result.body);
                return;
            }

            const ok = try result.isOk();
            if (ok) {
                const verb: []const u8 = if (is_undelegate) "Undelegated" else "Delegated";
                try w.success(verb);
                try w.print(" {s} wei to {s}\n", .{ amount_str, validator });
            } else {
                try w.fail(if (is_undelegate) "undelegate failed" else "delegate failed");
                try w.print("{s}\n", .{result.body});
                return error.CommandFailed;
            }
        },
        .rewards => {
            const addr = config.getAddress() orelse return error.MissingAddress;
            var raw = try client.delegatorRewards(addr);
            defer raw.deinit();
            if (w.format == .json) {
                try w.jsonRaw(raw.body);
            } else {
                try w.heading("STAKING REWARDS");
                try w.print("{s}\n", .{raw.body});
            }
        },
        .history => {
            const addr = config.getAddress() orelse return error.MissingAddress;
            var raw = try client.delegatorHistory(addr);
            defer raw.deinit();
            if (w.format == .json) {
                try w.jsonRaw(raw.body);
            } else {
                try w.heading("DELEGATION HISTORY");
                try w.print("{s}\n", .{raw.body});
            }
        },
    }
}

pub fn vaultCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.VaultArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    switch (a.action) {
        .info => {
            const vault_addr = a.vault_address orelse return error.Overflow;
            if (w.format == .json) {
                var raw = try client.vaultDetails(vault_addr, config.getAddress());
                defer raw.deinit();
                try w.jsonRaw(raw.body);
            } else {
                var raw = try client.vaultDetails(vault_addr, config.getAddress());
                defer raw.deinit();
                try w.heading("VAULT DETAILS");
                try w.print("{s}\n", .{raw.body});
            }
        },
        .deposit, .withdraw => {
            const vault_addr = a.vault_address orelse return error.Overflow;
            const amount = a.amount orelse return error.Overflow;
            const auth = try getWriteAuth(w, config);
            var nonce_handler = response.NonceHandler.init();
            const nonce = nonce_handler.next();

            const usd = std.fmt.parseInt(u64, amount, 10) catch {
                try w.err("invalid amount (must be integer)");
                return;
            };
            const vt = types.VaultTransfer{
                .vault_address = vault_addr,
                .is_deposit = a.action == .deposit,
                .usd = usd,
            };

            var result = try client.vaultTransfer(auth.signer, vt, nonce, null, null);
            defer result.deinit();

            if (w.format == .json) {
                try w.jsonRaw(result.body);
                return;
            }

            const ok = try result.isOk();
            if (ok) {
                const verb: []const u8 = if (a.action == .deposit) "Deposited" else "Withdrew";
                try w.success(verb);
                try w.print(" {s} USDC {s} vault {s}\n", .{
                    amount,
                    if (a.action == .deposit) "into" else "from",
                    vault_addr,
                });
            } else {
                try w.fail("vault operation failed");
                try w.print("{s}\n", .{result.body});
                return error.CommandFailed;
            }
        },
    }
}

pub fn ledgerCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.LedgerArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;
    const start = parseTimestampMs(a.start_time orelse "0") orelse 0;
    const end = if (a.end_time) |et| parseTimestampMs(et) else null;

    var raw = try client.userNonFundingLedgerUpdates(addr, start, end);
    defer raw.deinit();

    if (w.format == .json) {
        try w.jsonRaw(raw.body);
    } else {
        try w.heading("LEDGER UPDATES");
        try w.print("{s}\n", .{raw.body});
    }
}

pub fn approveBuilderCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.ApproveBuilderArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const auth = try getWriteAuth(w, config);
    var nonce_handler = response.NonceHandler.init();
    const nonce = nonce_handler.next();

    const builder_addr = Client.parseAddress(a.builder) catch {
        try w.err("invalid builder address");
        return;
    };
    var result = try client.approveBuilderFee(auth.signer, a.max_fee_rate, builder_addr, nonce);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const ok = try result.isOk();
    if (ok) {
        try w.success("Builder fee approved");
        try w.print(" ({s} max fee for {s})\n", .{ a.max_fee_rate, a.builder });
    } else {
        try w.fail("approve-builder failed");
        try w.print("{s}\n", .{result.body});
        return error.CommandFailed;
    }
}

/// Switch account abstraction mode (standard, unified, portfolio).
///
/// Modes control how spot and perp balances interact:
/// - **standard**: Separate spot/perp wallets. Must `transfer --to-perp` to trade perps.
///   Required for builder code addresses. No daily action limit.
/// - **unified**: Single balance per asset. USDC is shared across all perps and spot.
///   Default on app.hyperliquid.xyz. 50k actions/day limit.
/// - **portfolio**: Most capital efficient. Unifies HYPE, BTC, USDH, USDC as collateral.
///   Currently in pre-alpha. 50k actions/day limit.
///
/// With no argument, shows the current mode.
/// See: https://hyperliquid.gitbook.io/hyperliquid-docs/trading/account-abstraction-modes
pub fn accountCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.AccountArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    if (a.invalid_mode) |bad| {
        try w.failFmt("unknown account mode '{s}'. Use: standard, unified, portfolio", .{bad});
        return error.CommandFailed;
    }

    const mode = a.mode orelse {
        // No mode argument — query and display the current mode.
        const addr = config.getAddress() orelse {
            // No address available — just show help.
            if (w.format == .json) {
                try w.print("{{\"v\":1,\"status\":\"ok\",\"cmd\":\"account\",\"hint\":\"Provide --address or HL_KEY to query current mode, or use 'hlz account standard|unified|portfolio' to set.\"}}\n", .{});
            } else {
                try w.styled(Style.bold_white, "Account Abstraction Mode\n\n");
                try w.print("  hlz account standard    Separate spot/perp wallets (builders, MMs)\n", .{});
                try w.print("  hlz account unified     Single balance, shared collateral (default)\n", .{});
                try w.print("  hlz account portfolio   Portfolio margin (pre-alpha)\n", .{});
            }
            return;
        };
        var result = try client.userAbstraction(addr);
        defer result.deinit();

        if (w.format == .json) {
            try w.jsonRaw(result.body);
            return;
        }

        // API returns a quoted string: "disabled", "unifiedAccount", or "portfolioMargin"
        const body = result.body;
        const display: []const u8 = if (std.mem.indexOf(u8, body, "disabled") != null)
            "standard"
        else if (std.mem.indexOf(u8, body, "unifiedAccount") != null)
            "unified account"
        else if (std.mem.indexOf(u8, body, "portfolioMargin") != null)
            "portfolio margin"
        else
            body;

        try w.styled(Style.bold_white, "Account mode: ");
        try w.print("{s}\n", .{display});
        return;
    };

    const auth = try getWriteAuth(w, config);
    var nonce_handler = response.NonceHandler.init();
    const nonce = nonce_handler.next();

    const user_addr = auth.signer.address;
    const api_value = mode.toApiString();

    var result = try client.userSetAbstraction(auth.signer, user_addr, api_value, nonce);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const ok = try result.isOk();
    if (ok) {
        try w.success("Account mode set to ");
        try w.styled(Style.bold_white, mode.displayName());
        try w.print("\n", .{});
    } else {
        try w.fail("failed to set account mode");
        try w.print("{s}\n", .{result.body});
        return error.CommandFailed;
    }
}

pub fn subaccountCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.SubAccountArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    switch (a.action) {
        .list => {
            const addr = config.getAddress() orelse return error.MissingAddress;
            if (w.format == .json) {
                var raw = try client.subaccounts(addr);
                defer raw.deinit();
                try w.jsonRaw(raw.body);
                return;
            }

            var typed = try client.getSubaccounts(addr);
            defer typed.deinit();

            try w.heading("SUB-ACCOUNTS");
            const hdr = [_]Column{
                .{ .text = "NAME", .width = 16 },
                .{ .text = "ADDRESS", .width = 44 },
            };
            try w.tableHeader(&hdr);

            for (typed.value) |sub| {
                const cols = [_]Column{
                    .{ .text = sub.name, .width = 16 },
                    .{ .text = sub.subAccountUser, .width = 44, .color = Style.dim },
                };
                try w.tableRow(&cols);
            }
            try w.footer();
        },
        .create => {
            const name = a.name orelse return error.Overflow;
            const auth = try getWriteAuth(w, config);
            var nonce_handler = response.NonceHandler.init();
            const nonce = nonce_handler.next();

            const csa = types.CreateSubAccount{ .name = name };
            var result = try client.createSubAccount(auth.signer, csa, nonce, null, null);
            defer result.deinit();

            if (w.format == .json) {
                try w.jsonRaw(result.body);
                return;
            }

            const ok = try result.isOk();
            if (ok) {
                try w.success("Sub-account created: ");
                try w.print("{s}\n", .{name});
            } else {
                try w.fail("create sub-account failed");
                try w.print("{s}\n", .{result.body});
                return error.CommandFailed;
            }
        },
        .transfer => {
            const sub_addr = a.sub_address orelse return error.Overflow;
            const amount = a.amount orelse return error.Overflow;
            const auth = try getWriteAuth(w, config);
            var nonce_handler = response.NonceHandler.init();
            const nonce = nonce_handler.next();

            const usd = std.fmt.parseInt(u64, amount, 10) catch {
                try w.err("invalid amount (must be integer)");
                return;
            };
            const sat = types.SubAccountTransfer{
                .sub_account_user = sub_addr,
                .is_deposit = a.is_deposit,
                .usd = usd,
            };
            var result = try client.subAccountTransfer(auth.signer, sat, nonce, null, null);
            defer result.deinit();

            if (w.format == .json) {
                try w.jsonRaw(result.body);
                return;
            }

            const ok = try result.isOk();
            if (ok) {
                const verb: []const u8 = if (a.is_deposit) "Deposited" else "Withdrew";
                try w.success(verb);
                try w.print(" {s} USDC {s} sub-account {s}\n", .{
                    amount,
                    if (a.is_deposit) "into" else "from",
                    sub_addr,
                });
            } else {
                try w.fail("sub-account transfer failed");
                try w.print("{s}\n", .{result.body});
                return error.CommandFailed;
            }
        },
        .spot_transfer => {
            const sub_addr = a.sub_address orelse return error.Overflow;
            const amount = a.amount orelse return error.Overflow;
            const token = a.token orelse return error.Overflow;
            const auth = try getWriteAuth(w, config);
            var nonce_handler = response.NonceHandler.init();
            const nonce = nonce_handler.next();

            const sst = types.SubAccountSpotTransfer{
                .sub_account_user = sub_addr,
                .is_deposit = a.is_deposit,
                .token = token,
                .amount = amount,
            };
            var result = try client.subAccountSpotTransfer(auth.signer, sst, nonce, null, null);
            defer result.deinit();

            if (w.format == .json) {
                try w.jsonRaw(result.body);
                return;
            }

            const ok = try result.isOk();
            if (ok) {
                const verb: []const u8 = if (a.is_deposit) "Deposited" else "Withdrew";
                try w.success(verb);
                try w.print(" {s} {s} {s} sub-account {s}\n", .{
                    amount,
                    token,
                    if (a.is_deposit) "into" else "from",
                    sub_addr,
                });
            } else {
                try w.fail("sub-account spot transfer failed");
                try w.print("{s}\n", .{result.body});
                return error.CommandFailed;
            }
        },
    }
}

pub fn deployCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.DeployArgs) !void {
    switch (a.action) {
        .help => try printDeployHelp(w),
        .status => |st| try deployStatus(allocator, w, config, st),
        .spot_register => |r| try deploySpotRegister(allocator, w, config, r),
        .spot_user_genesis => |g| try deploySpotUserGenesis(allocator, w, config, g),
        .spot_genesis => |g| try deploySpotGenesis(allocator, w, config, g),
        .spot_register_pair => |r| try deploySpotRegisterPair(allocator, w, config, r),
        .spot_hyperliquidity => |h| try deploySpotHyperliquidity(allocator, w, config, h),
        .spot_fee_share => |r| try deploySpotFeeShare(allocator, w, config, r),
        .spot_freeze => |f| try deploySpotFreeze(allocator, w, config, f),
        .spot_token_action => |t| try deploySpotTokenAction(allocator, w, config, t),
        .spot_request_evm => |r| try deploySpotRequestEvm(allocator, w, config, r),
        .spot_finalize_evm => |f| try deploySpotFinalizeEvm(allocator, w, config, f),
        .spot_enable_quote => |e| try deploySpotEnableToggle(allocator, w, config, e, false),
        .spot_enable_aligned => |e| try deploySpotEnableToggle(allocator, w, config, e, true),
    }
}

fn deploySpotRequestEvm(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.DeploySpotRequestEvmArgs) !void {
    if (a.address.len != 42 or !std.mem.startsWith(u8, a.address, "0x")) {
        return failFmt(w, "address must be lowercase 0x + 40 hex chars", .{});
    }
    if (a.extra_wei_dec < -2 or a.extra_wei_dec > 18) {
        return failFmt(w, "--extra-wei-dec out of range [-2, 18]", .{});
    }

    if (a.dry_run) {
        var wei_buf: [8]u8 = undefined;
        const wei_str = std.fmt.bufPrint(&wei_buf, "{d}", .{a.extra_wei_dec}) catch "?";
        try dryRunPrint(w, "request-evm", &[_][2][]const u8{
            .{ "token", intBuf(a.token) },
            .{ "address", a.address },
            .{ "extraWeiDec", wei_str },
        });
        return;
    }

    var client = makeClient(allocator, config);
    defer client.deinit();
    const auth = try getWriteAuth(w, config);
    var nh = response.NonceHandler.init();
    const r = hlz.hypercore.types.SpotDeployRequestEvmContract{
        .token = a.token,
        .address = a.address,
        .evm_extra_wei_decimals = a.extra_wei_dec,
    };
    var result = try client.spotDeployRequestEvmContract(auth.signer, r, nh.next());
    defer result.deinit();
    try renderDeployResult(w, "request-evm", &result, &[_][2][]const u8{
        .{ "token", intBuf(a.token) },
        .{ "address", a.address },
    });
}

fn deploySpotFinalizeEvm(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.DeploySpotFinalizeEvmArgs) !void {
    const proof_label: []const u8 = switch (a.proof) {
        .create_nonce => "create",
        .first_storage_slot => "firstStorageSlot",
        .custom_storage_slot => "customStorageSlot",
    };

    if (a.dry_run) {
        try dryRunPrint(w, "finalize-evm", &[_][2][]const u8{
            .{ "token", intBuf(a.token) },
            .{ "proof", proof_label },
        });
        return;
    }

    var client = makeClient(allocator, config);
    defer client.deinit();
    const auth = try getWriteAuth(w, config);
    var nh = response.NonceHandler.init();
    const input: hlz.hypercore.types.FinalizeEvmContractInput = switch (a.proof) {
        .create_nonce => |n| .{ .create = n },
        .first_storage_slot => .first_storage_slot,
        .custom_storage_slot => .custom_storage_slot,
    };
    var result = try client.finalizeEvmContract(auth.signer, a.token, input, nh.next());
    defer result.deinit();
    try renderDeployResult(w, "finalize-evm", &result, &[_][2][]const u8{
        .{ "token", intBuf(a.token) },
        .{ "proof", proof_label },
    });
}

fn deploySpotEnableToggle(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.DeploySpotEnableQuoteArgs, aligned: bool) !void {
    const label: []const u8 = if (aligned) "enable-aligned" else "enable-quote";
    if (a.dry_run) {
        try dryRunPrint(w, label, &[_][2][]const u8{.{ "token", intBuf(a.token) }});
        return;
    }
    var client = makeClient(allocator, config);
    defer client.deinit();
    const auth = try getWriteAuth(w, config);
    var nh = response.NonceHandler.init();
    var result = if (aligned)
        try client.spotDeployEnableAlignedQuoteToken(auth.signer, a.token, nh.next())
    else
        try client.spotDeployEnableQuoteToken(auth.signer, a.token, nh.next());
    defer result.deinit();
    try renderDeployResult(w, label, &result, &[_][2][]const u8{.{ "token", intBuf(a.token) }});
}

fn deploySpotFeeShare(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.DeploySpotFeeShareArgs) !void {
    if (a.dry_run) {
        try dryRunPrint(w, "fee-share", &[_][2][]const u8{ .{ "token", intBuf(a.token) }, .{ "share", a.share } });
        return;
    }
    var client = makeClient(allocator, config);
    defer client.deinit();
    const auth = try getWriteAuth(w, config);
    var nh = response.NonceHandler.init();
    var result = try client.spotDeploySetTradingFeeShare(auth.signer, a.token, a.share, nh.next());
    defer result.deinit();
    try renderDeployResult(w, "fee-share", &result, &[_][2][]const u8{ .{ "token", intBuf(a.token) }, .{ "share", a.share } });
}

fn deploySpotFreeze(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.DeploySpotFreezeArgs) !void {
    const label: []const u8 = if (a.unfreeze) "unfreeze" else "freeze";
    if (a.dry_run) {
        try dryRunPrint(w, label, &[_][2][]const u8{ .{ "token", intBuf(a.token) }, .{ "user", a.user } });
        return;
    }
    var client = makeClient(allocator, config);
    defer client.deinit();
    const auth = try getWriteAuth(w, config);
    var nh = response.NonceHandler.init();
    var result = try client.spotDeployFreezeUser(auth.signer, a.token, a.user, !a.unfreeze, nh.next());
    defer result.deinit();
    try renderDeployResult(w, label, &result, &[_][2][]const u8{ .{ "token", intBuf(a.token) }, .{ "user", a.user } });
}

fn deploySpotTokenAction(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.DeploySpotTokenActionArgs) !void {
    if (a.dry_run) {
        try dryRunPrint(w, "token-action", &[_][2][]const u8{ .{ "token", intBuf(a.token) }, .{ "variant", a.variant } });
        return;
    }
    var client = makeClient(allocator, config);
    defer client.deinit();
    const auth = try getWriteAuth(w, config);
    var nh = response.NonceHandler.init();
    var result = try client.spotDeployTokenAction(auth.signer, a.variant, a.token, nh.next());
    defer result.deinit();
    try renderDeployResult(w, a.variant, &result, &[_][2][]const u8{.{ "token", intBuf(a.token) }});
}

// ── Small dry-run / result helpers for the compact admin commands ──

threadlocal var deploy_int_buf: [24]u8 = undefined;
fn intBuf(v: u32) []const u8 {
    return std.fmt.bufPrint(&deploy_int_buf, "{d}", .{v}) catch "?";
}

fn dryRunPrint(w: *Writer, label: []const u8, pairs: []const [2][]const u8) !void {
    if (w.format == .json) {
        var buf: [512]u8 = undefined;
        var wj: std.Io.Writer = .fixed(&buf);
        try wj.print("{{\"status\":\"dry_run\",\"op\":\"{s}\"", .{label});
        for (pairs) |kv| try wj.print(",\"{s}\":\"{s}\"", .{ kv[0], kv[1] });
        try wj.writeAll("}");
        try w.jsonRaw(wj.buffered());
    } else {
        try w.styled(Style.bold_yellow, "\xe2\x8a\x98 dry-run");
        try w.print(" {s}", .{label});
        for (pairs) |kv| try w.print("  {s}={s}", .{ kv[0], kv[1] });
        try w.nl();
    }
}

fn renderDeployResult(w: *Writer, label: []const u8, result: anytype, pairs: []const [2][]const u8) !void {
    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }
    const ok = try result.isOk();
    if (ok) {
        try w.success(label);
        for (pairs) |kv| try w.print(" {s}={s}", .{ kv[0], kv[1] });
        try w.nl();
    } else {
        try w.failFmt("{s} failed", .{label});
        try w.print("{s}\n", .{result.body});
        return error.CommandFailed;
    }
}

fn deploySpotHyperliquidity(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.DeploySpotHyperliquidityArgs) !void {
    if (a.start_px.len == 0) return failFmt(w, "--start-px <PX> required", .{});
    if (a.order_sz.len == 0) return failFmt(w, "--order-sz <SZ> required", .{});

    if (a.dry_run) {
        if (w.format == .json) {
            try w.jsonFmt("{{\"status\":\"dry_run\",\"spot\":{d},\"startPx\":\"{s}\",\"orderSz\":\"{s}\",\"nOrders\":{d}}}", .{
                a.spot, a.start_px, a.order_sz, a.n_orders,
            });
        } else {
            try w.styled(Style.bold_yellow, "\xe2\x8a\x98 dry-run");
            try w.print(" hyperliquidity spot={d} startPx={s} orderSz={s} nOrders={d}", .{
                a.spot, a.start_px, a.order_sz, a.n_orders,
            });
            if (a.n_seeded_levels) |n| try w.print(" seededLevels={d}", .{n});
            try w.nl();
        }
        return;
    }

    var client = makeClient(allocator, config);
    defer client.deinit();
    const auth = try getWriteAuth(w, config);

    const rh = hlz.hypercore.types.SpotDeployRegisterHyperliquidity{
        .spot = a.spot,
        .start_px = a.start_px,
        .order_sz = a.order_sz,
        .n_orders = a.n_orders,
        .n_seeded_levels = a.n_seeded_levels,
    };

    var nonce_handler = response.NonceHandler.init();
    var result = try client.spotDeployRegisterHyperliquidity(auth.signer, rh, nonce_handler.next());
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }
    const ok = try result.isOk();
    if (ok) {
        try w.success("hyperliquidity submitted");
        try w.print(" spot={d} startPx={s} orderSz={s} nOrders={d}\n", .{
            a.spot, a.start_px, a.order_sz, a.n_orders,
        });
    } else {
        try w.fail("hyperliquidity failed");
        try w.print("{s}\n", .{result.body});
        return error.CommandFailed;
    }
}

fn deploySpotRegisterPair(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.DeploySpotRegisterPairArgs) !void {
    if (a.dry_run) {
        if (w.format == .json) {
            try w.jsonFmt("{{\"status\":\"dry_run\",\"baseToken\":{d},\"quoteToken\":{d}}}", .{ a.base_token, a.quote_token });
        } else {
            try w.styled(Style.bold_yellow, "\xe2\x8a\x98 dry-run");
            try w.print(" register-pair base={d} quote={d}\n", .{ a.base_token, a.quote_token });
        }
        return;
    }
    var client = makeClient(allocator, config);
    defer client.deinit();
    const auth = try getWriteAuth(w, config);
    const rs = hlz.hypercore.types.SpotDeployRegisterSpot{
        .base_token = a.base_token,
        .quote_token = a.quote_token,
    };
    var nonce_handler = response.NonceHandler.init();
    var result = try client.spotDeployRegisterSpot(auth.signer, rs, nonce_handler.next());
    defer result.deinit();
    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }
    const ok = try result.isOk();
    if (ok) {
        try w.success("register-pair submitted");
        try w.print(" base={d} quote={d}\n", .{ a.base_token, a.quote_token });
    } else {
        try w.fail("register-pair failed");
        try w.print("{s}\n", .{result.body});
        return error.CommandFailed;
    }
}

fn deploySpotGenesis(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.DeploySpotGenesisArgs) !void {
    if (a.max_supply.len == 0) return failFmt(w, "--max-supply <WEI> required (must match sum of user-genesis allocations)", .{});

    if (a.dry_run) {
        if (w.format == .json) {
            try w.jsonFmt("{{\"status\":\"dry_run\",\"token\":{d},\"maxSupply\":\"{s}\",\"noHyperliquidity\":{s}}}", .{
                a.token, a.max_supply, if (a.no_hyperliquidity) "true" else "false",
            });
        } else {
            try w.styled(Style.bold_yellow, "\xe2\x8a\x98 dry-run");
            try w.print(" genesis token={d} maxSupply={s}{s}\n", .{
                a.token,                                               a.max_supply,
                if (a.no_hyperliquidity) " no-hyperliquidity" else "",
            });
        }
        return;
    }

    var client = makeClient(allocator, config);
    defer client.deinit();
    const auth = try getWriteAuth(w, config);

    const g = hlz.hypercore.types.SpotDeployGenesis{
        .token = a.token,
        .max_supply = a.max_supply,
        .no_hyperliquidity = a.no_hyperliquidity,
    };

    var nonce_handler = response.NonceHandler.init();
    const nonce = nonce_handler.next();
    var result = try client.spotDeployGenesis(auth.signer, g, nonce);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }
    const ok = try result.isOk();
    if (ok) {
        try w.success("genesis submitted");
        try w.print(" token={d} maxSupply={s}\n", .{ a.token, a.max_supply });
    } else {
        try w.fail("genesis failed");
        try w.print("{s}\n", .{result.body});
        return error.CommandFailed;
    }
}

/// Split "addr:wei" or "tid:wei" — returns error.InvalidFlag if the colon is missing.
fn splitPair(entry: []const u8) ![2][]const u8 {
    const colon = std.mem.indexOfScalar(u8, entry, ':') orelse return error.InvalidFlag;
    return .{ entry[0..colon], entry[colon + 1 ..] };
}

fn deploySpotUserGenesis(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.DeploySpotUserGenesisArgs) !void {
    if (a.user_count == 0 and a.existing_count == 0) {
        return failFmt(w, "need at least one --alloc addr:wei or --from-token tid:wei", .{});
    }

    var user_pairs: [64][2][]const u8 = undefined;
    for (0..a.user_count) |i| {
        const raw = a.user_allocs[i] orelse return failFmt(w, "--alloc slot {d} empty", .{i});
        const parts = splitPair(raw) catch return failFmt(w, "--alloc must be addr:wei (got '{s}')", .{raw});
        user_pairs[i] = parts;
    }

    var existing_pairs: [16]hlz.hypercore.types.SpotDeployExistingTokenWei = undefined;
    for (0..a.existing_count) |i| {
        const raw = a.existing_allocs[i] orelse return failFmt(w, "--from-token slot {d} empty", .{i});
        const parts = splitPair(raw) catch return failFmt(w, "--from-token must be tid:wei (got '{s}')", .{raw});
        const tid = std.fmt.parseInt(u32, parts[0], 10) catch return failFmt(w, "--from-token tid not an integer: '{s}'", .{parts[0]});
        existing_pairs[i] = .{ .token = tid, .wei = parts[1] };
    }

    if (a.dry_run) {
        if (w.format == .json) {
            try w.jsonFmt("{{\"status\":\"dry_run\",\"token\":{d},\"userAllocs\":{d},\"existingAllocs\":{d}}}", .{ a.token, a.user_count, a.existing_count });
        } else {
            try w.styled(Style.bold_yellow, "\xe2\x8a\x98 dry-run");
            try w.print(" user-genesis token={d}  users={d}  existing={d}\n", .{ a.token, a.user_count, a.existing_count });
            for (0..a.user_count) |i| try w.print("    {s} -> {s} wei\n", .{ user_pairs[i][0], user_pairs[i][1] });
            for (0..a.existing_count) |i| try w.print("    from tid {d} -> {s} wei\n", .{ existing_pairs[i].token, existing_pairs[i].wei });
        }
        return;
    }

    var client = makeClient(allocator, config);
    defer client.deinit();
    const auth = try getWriteAuth(w, config);

    const ug = hlz.hypercore.types.SpotDeployUserGenesis{
        .token = a.token,
        .user_and_wei = user_pairs[0..a.user_count],
        .existing_token_and_wei = existing_pairs[0..a.existing_count],
    };

    var nonce_handler = response.NonceHandler.init();
    const nonce = nonce_handler.next();
    var result = try client.spotDeployUserGenesis(auth.signer, ug, nonce);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }
    const ok = try result.isOk();
    if (ok) {
        try w.success("user-genesis submitted");
        try w.print(" token={d} users={d} existing={d}\n", .{ a.token, a.user_count, a.existing_count });
    } else {
        try w.fail("user-genesis failed");
        try w.print("{s}\n", .{result.body});
        return error.CommandFailed;
    }
}

const HYPE_WEI_PER_UNIT: u64 = 100_000_000;

fn deploySpotRegister(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.DeploySpotRegisterArgs) !void {
    if (a.max_gas_hype == 0) return failFmt(w, "--max-gas <HYPE> required (500 = HIP-1 floor)", .{});
    if (a.max_gas_hype > std.math.maxInt(u64) / HYPE_WEI_PER_UNIT) return failFmt(w, "--max-gas too large", .{});
    const max_gas_wei = a.max_gas_hype * HYPE_WEI_PER_UNIT;

    var client = makeClient(allocator, config);
    defer client.deinit();

    const rt = hlz.hypercore.types.SpotDeployRegisterToken{
        .name = a.name,
        .sz_decimals = a.sz_decimals,
        .wei_decimals = a.wei_decimals,
        .max_gas = max_gas_wei,
        .full_name = a.full_name orelse a.name,
    };

    if (a.dry_run) {
        if (w.format == .json) {
            try w.jsonFmt("{{\"status\":\"dry_run\",\"name\":\"{s}\",\"maxGasHype\":{d},\"maxGasWei\":{d},\"szDecimals\":{d},\"weiDecimals\":{d}}}", .{
                a.name, a.max_gas_hype, max_gas_wei, a.sz_decimals, a.wei_decimals,
            });
        } else {
            try w.styled(Style.bold_yellow, "\xe2\x8a\x98 dry-run");
            try w.print(" register {s} maxGas={d} HYPE ({d} wei)  szDec={d} weiDec={d}\n", .{
                a.name, a.max_gas_hype, max_gas_wei, a.sz_decimals, a.wei_decimals,
            });
        }
        return;
    }

    const auth = try getWriteAuth(w, config);
    var nonce_handler = response.NonceHandler.init();
    const nonce = nonce_handler.next();

    var result = try client.spotDeployRegisterToken(auth.signer, rt, nonce);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }
    const ok = try result.isOk();
    if (ok) {
        try w.success("register submitted");
        try w.print(" name={s} maxGas={d} HYPE\n", .{ a.name, a.max_gas_hype });
    } else {
        try w.fail("register failed");
        try w.print("{s}\n", .{result.body});
        return error.CommandFailed;
    }
}

fn deployStatus(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.DeployStatusArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    if (w.format == .json) {
        var pair_raw = try client.spotPairDeployAuctionStatus();
        defer pair_raw.deinit();
        if (a.pair) {
            try w.jsonRaw(pair_raw.body);
            return;
        }
        var perp_raw = try client.perpDeployAuctionStatus();
        defer perp_raw.deinit();
        var jbuf: [2048]u8 = undefined;
        var wj: std.Io.Writer = .fixed(&jbuf);
        try wj.writeAll("{\"perp\":");
        try wj.writeAll(perp_raw.body);
        try wj.writeAll(",\"spotPair\":");
        try wj.writeAll(pair_raw.body);
        try wj.writeAll("}");
        try w.jsonRaw(wj.buffered());
        return;
    }

    var pair = try client.getSpotPairDeployAuctionStatus();
    defer pair.deinit();

    try w.heading("DEPLOY AUCTIONS");
    if (!a.pair) {
        var perp = try client.getPerpDeployAuctionStatus();
        defer perp.deinit();
        try renderAuctionRow(w, "perp", perp.value);
    }
    try renderAuctionRow(w, "spot-pair", pair.value);
}

fn renderAuctionRow(w: *Writer, label: []const u8, s: response.DeployAuctionStatus) !void {
    const start_gas = if (s.startGas.len == 0) "-" else s.startGas;
    const cur_gas: []const u8 = s.currentGas orelse "idle";
    const end_gas: []const u8 = s.endGas orelse "-";
    const now_s = @divFloor(hlz.runtime.nonceMs(), 1000);
    const elapsed = if (now_s > s.startTimeSeconds) now_s - s.startTimeSeconds else 0;
    const remaining = if (s.durationSeconds > elapsed) s.durationSeconds - elapsed else 0;
    try w.print("  {s:<10}  start={s} HYPE  current={s}  floor={s}  elapsed={d}m  remaining={d}m\n", .{
        label,
        start_gas,
        cur_gas,
        end_gas,
        elapsed / 60,
        remaining / 60,
    });
}

fn printDeployHelp(w: *Writer) !void {
    try w.styled(Style.bold_white, "hlz deploy — HIP-1 spot token deployment\n\n");
    try w.print(
        \\Read
        \\  hlz deploy status [--pair]            Show live auction gas prices
        \\
        \\Spot token flow
        \\  hlz deploy spot register <NAME>       Bid HIP-1 gas auction, mint ticker
        \\  hlz deploy spot user-genesis <TOKEN>  Allocate wei to users / existing holders
        \\  hlz deploy spot genesis <TOKEN>       Fix max supply (checksum step)
        \\  hlz deploy spot register-pair <B> <Q> Pair base against existing quote
        \\  hlz deploy spot hyperliquidity <SPOT> Seed HIP-2 book
        \\
        \\Admin
        \\  hlz deploy spot fee-share <TOKEN> <PCT>
        \\  hlz deploy spot freeze <TOKEN> <USER> [--unfreeze]
        \\  hlz deploy spot token-action <TOKEN> <VARIANT>
        \\
        \\EVM linking
        \\  hlz deploy spot request-evm <TOKEN> <ADDR> --extra-wei-dec <N>
        \\  hlz deploy spot finalize-evm <TOKEN> <--create-nonce N | --first-slot | --custom-slot>
        \\
        \\Quote-token toggles
        \\  hlz deploy spot enable-quote <TOKEN>
        \\  hlz deploy spot enable-aligned <TOKEN>
        \\
        \\Subcommands not marked above are wired up in follow-up commits.
        \\
    , .{});
}

// ---------------------------------------------------------------- watch
//
// A watchlist: the mid and 24h change for a chosen set of symbols. Mids come
// from allMids and the 24h reference from metaAndAssetCtxs' prevDayPx, so one
// pass covers every requested coin regardless of how many are listed.

const WatchRow = struct {
    coin: []const u8,
    mid: f64,
    change: ?f64,
    found: bool,
};

/// Previous-day mark for `coin`, by index into the perp universe.
fn watchPrevDayPx(mac_val: std.json.Value, coin: []const u8) ?f64 {
    if (mac_val != .array or mac_val.array.items.len < 2) return null;
    const meta = mac_val.array.items[0];
    const ctxs = mac_val.array.items[1];
    if (ctxs != .array) return null;
    const universe = json_mod.getArray(meta, "universe") orelse return null;
    for (universe, 0..) |u, i| {
        const name = json_mod.getString(u, "name") orelse continue;
        if (!std.mem.eql(u8, name, coin)) continue;
        if (i >= ctxs.array.items.len) return null;
        const s = json_mod.getString(ctxs.array.items[i], "prevDayPx") orelse return null;
        return std.fmt.parseFloat(f64, s) catch null;
    }
    return null;
}

fn watchCollect(
    allocator: std.mem.Allocator,
    config: Config,
    a: args_mod.WatchArgs,
    rows: *[args_mod.MAX_WATCH_COINS]WatchRow,
) !usize {
    var client = makeClient(allocator, config);
    defer client.deinit();

    var mids_res = try client.allMids(null);
    defer mids_res.deinit();
    const mids_val = try mids_res.json();

    // 24h change is a nicety: if this call fails we still show live prices.
    var mac_res = client.metaAndAssetCtxs() catch null;
    defer if (mac_res) |*m| m.deinit();
    const mac_val: ?std.json.Value = if (mac_res) |*m| (m.json() catch null) else null;

    var n: usize = 0;
    for (a.coins) |coin| {
        if (n >= args_mod.MAX_WATCH_COINS) break;
        const mid_s = json_mod.getString(mids_val, coin) orelse {
            rows[n] = .{ .coin = coin, .mid = 0, .change = null, .found = false };
            n += 1;
            continue;
        };
        const mid = std.fmt.parseFloat(f64, mid_s) catch 0;
        var change: ?f64 = null;
        if (mac_val) |mv| {
            if (watchPrevDayPx(mv, coin)) |pd| {
                if (pd != 0) change = (mid - pd) / pd * 100.0;
            }
        }
        rows[n] = .{ .coin = coin, .mid = mid, .change = change, .found = true };
        n += 1;
    }
    return n;
}

fn watchRender(w: *Writer, rows: []const WatchRow) !void {
    if (w.format == .json) {
        var jbuf: [8192]u8 = undefined;
        var jlen: usize = 0;
        jbuf[0] = '[';
        jlen = 1;
        for (rows, 0..) |r, i| {
            if (i > 0) {
                jbuf[jlen] = ',';
                jlen += 1;
            }
            if (r.change) |c| {
                jlen += (std.fmt.bufPrint(
                    jbuf[jlen..],
                    "{{\"coin\":\"{s}\",\"mid\":{d},\"change24h\":{d:.4}}}",
                    .{ r.coin, r.mid, c },
                ) catch return error.Overflow).len;
            } else {
                jlen += (std.fmt.bufPrint(
                    jbuf[jlen..],
                    "{{\"coin\":\"{s}\",\"mid\":{d},\"change24h\":null}}",
                    .{ r.coin, r.mid },
                ) catch return error.Overflow).len;
            }
        }
        jbuf[jlen] = ']';
        jlen += 1;
        try w.jsonRaw(jbuf[0..jlen]);
        return;
    }

    try w.nl();
    for (rows) |r| {
        if (!r.found) {
            try w.style(Style.muted);
            try w.print("  {s: <12}{s: >16}", .{ r.coin, "not listed" });
            try w.style(Style.reset);
            try w.nl();
            continue;
        }
        try w.style(Style.muted);
        try w.print("  {s: <12}", .{r.coin});
        try w.style(Style.white);
        try w.print("{d: >16.4}", .{r.mid});
        if (r.change) |c| {
            // Format sign and number together, then pad, so "+0.06%" and
            // "-0.18%" line up instead of the sign floating off on its own.
            var cbuf: [24]u8 = undefined;
            const cs = std.fmt.bufPrint(&cbuf, "{s}{d:.2}%", .{ if (c >= 0) "+" else "", c }) catch "";
            try w.style(if (c >= 0) Style.green else Style.red);
            try w.print("{s: >10}", .{cs});
        }
        try w.style(Style.reset);
        try w.nl();
    }
    try w.nl();
}

pub fn watch(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.WatchArgs) !void {
    var rows: [args_mod.MAX_WATCH_COINS]WatchRow = undefined;

    if (!a.live) {
        const n = try watchCollect(allocator, config, a, &rows);
        return watchRender(w, rows[0..n]);
    }

    while (true) {
        const n = watchCollect(allocator, config, a, &rows) catch 0;
        try w.print("\x1b[H\x1b[2J", .{});
        try watchRender(w, rows[0..n]);
        runtime.sleepNs(@as(u64, a.interval) * std.time.ns_per_s) catch {};
    }
}
