//! `hlz` — Hyperliquid CLI.

const std = @import("std");

const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const output_mod = @import("output.zig");
const commands = @import("commands.zig");
const trade_mod = @import("trade");
const runtime = @import("hlz").runtime;

const Style = output_mod.Style;
const VERSION = "0.7.0";

// Exit codes (documented in --help, stable contract)
const EXIT_OK: u8 = 0;
const EXIT_ERROR: u8 = 1;
const EXIT_USAGE: u8 = 2;
const EXIT_AUTH: u8 = 3;
const EXIT_NETWORK: u8 = 4;

pub fn main(init: std.process.Init) !void {
    runtime.installIo(init.io);
    runtime.installEnvironMap(init.environ_map);
    const allocator = init.gpa;

    const result = args_mod.parse(allocator, init.minimal.args) catch |e| {
        var w = output_mod.Writer.init(init.io, .pretty);
        switch (e) {
            error.MissingArgument => try w.err("missing required argument. Run `hlz help` for usage."),
            error.UnknownCommand => try w.err("unknown command. Run `hlz help` for usage."),
            error.InvalidFlag => try w.err("invalid flag value. Run `hlz help` for usage."),
        }
        std.process.exit(EXIT_USAGE);
    };

    const flags = result.flags;

    // Apply HL_OUTPUT env var override
    var effective_output = flags.output;
    var effective_explicit = flags.output_explicit;

    var config = config_mod.load(allocator, flags);
    defer config.deinit();

    if (config.output_override) |ov| {
        effective_output = ov;
        effective_explicit = true;
    }

    var w = output_mod.Writer.initAuto(init.io, effective_output, effective_explicit);
    w.quiet = flags.quiet;

    const cmd = result.command orelse {
        try printHelp(&w, .{});
        return;
    };

    const cmd_name: []const u8 = switch (cmd) {
        .approve_agent => "approve-agent",
        .rate_limit => "rate-limit",
        .approve_builder => "approve-builder",
        else => @tagName(cmd),
    };
    if (w.format == .json) {
        w.cmd = cmd_name;
        w.start_ns = std.Io.Clock.awake.now(init.io).toNanoseconds();
    }

    switch (cmd) {
        .help => |a| {
            if (a.invalid_topic) |bad| {
                try w.failFmt("unknown command '{s}'. Run `hlz help` for usage.", .{bad});
                std.process.exit(EXIT_USAGE);
            }
            try printHelp(&w, a);
        },
        .version => try printVersion(&w),
        .config => try commands.showConfig(&w, config),
        .keys => |a| commands.keys(allocator, &w, a) catch |e| return exit(&w, "keys", e),
        .approve_agent => |a| commands.approveAgent(allocator, &w, config, a) catch |e| return exit(&w, "approve-agent", e),
        .mids => |a| commands.mids(allocator, &w, config, a) catch |e| return exit(&w, "mids", e),
        .positions => |a| commands.positions(allocator, &w, config, a) catch |e| return exit(&w, "positions", e),
        .orders => |a| commands.orders(allocator, &w, config, a) catch |e| return exit(&w, "orders", e),
        .fills => |a| commands.fills(allocator, &w, config, a) catch |e| return exit(&w, "fills", e),
        .balance => |a| commands.balance(allocator, &w, config, a) catch |e| return exit(&w, "balance", e),
        .perps => |a| commands.perps(allocator, &w, config, a) catch |e| return exit(&w, "perps", e),
        .spot => |a| commands.spotMarkets(allocator, &w, config, a) catch |e| return exit(&w, "spot", e),
        .outcomes => |a| commands.outcomes(allocator, &w, config, a) catch |e| return exit(&w, "outcomes", e),
        .dexes => commands.dexes(allocator, &w, config) catch |e| return exit(&w, "dexes", e),
        .buy => |a| commands.placeOrder(allocator, &w, config, a, true) catch |e| return exit(&w, "buy", e),
        .sell => |a| commands.placeOrder(allocator, &w, config, a, false) catch |e| return exit(&w, "sell", e),
        .cancel => |a| commands.cancelOrder(allocator, &w, config, a) catch |e| return exit(&w, "cancel", e),
        .modify => |a| commands.modifyOrder(allocator, &w, config, a) catch |e| return exit(&w, "modify", e),
        .send => |a| commands.sendAsset(allocator, &w, config, a) catch |e| return exit(&w, "send", e),
        .stream => |a| commands.stream(allocator, &w, config, a) catch |e| return exit(&w, "stream", e),
        .status => |a| commands.orderStatus(allocator, &w, config, a) catch |e| return exit(&w, "status", e),
        .funding => |a| commands.funding(allocator, &w, config, a) catch |e| return exit(&w, "funding", e),
        .book => |a| commands.book(allocator, &w, config, a) catch |e| return exit(&w, "book", e),
        .markets => commands.markets(allocator, config) catch |e| return exit(&w, "markets", e),
        .leverage => |a| commands.setLeverage(allocator, &w, config, a) catch |e| return exit(&w, "leverage", e),
        .price => |a| commands.price(allocator, &w, config, a) catch |e| return exit(&w, "price", e),
        .portfolio => |a| commands.portfolio(allocator, &w, config, a) catch |e| return exit(&w, "portfolio", e),
        .referral => |a| commands.referralCmd(allocator, &w, config, a) catch |e| return exit(&w, "referral", e),
        .twap => |a| commands.twap(allocator, &w, config, a) catch |e| return exit(&w, "twap", e),
        .batch => |a| commands.batchCmd(allocator, &w, config, a) catch |e| return exit(&w, "batch", e),
        .withdraw => |a| commands.withdrawCmd(allocator, &w, config, a) catch |e| return exit(&w, "withdraw", e),
        .transfer => |a| commands.transferCmd(allocator, &w, config, a) catch |e| return exit(&w, "transfer", e),
        .fees => |a| commands.feesCmd(allocator, &w, config, a) catch |e| return exit(&w, "fees", e),
        .rate_limit => |a| commands.rateLimitCmd(allocator, &w, config, a) catch |e| return exit(&w, "rate-limit", e),
        .stake => |a| commands.stakeCmd(allocator, &w, config, a) catch |e| return exit(&w, "stake", e),
        .vault => |a| commands.vaultCmd(allocator, &w, config, a) catch |e| return exit(&w, "vault", e),
        .ledger => |a| commands.ledgerCmd(allocator, &w, config, a) catch |e| return exit(&w, "ledger", e),
        .approve_builder => |a| commands.approveBuilderCmd(allocator, &w, config, a) catch |e| return exit(&w, "approve-builder", e),
        .subaccount => |a| commands.subaccountCmd(allocator, &w, config, a) catch |e| return exit(&w, "subaccount", e),
        .account => |a| commands.accountCmd(allocator, &w, config, a) catch |e| return exit(&w, "account", e),
        .deploy => |a| commands.deployCmd(allocator, &w, config, a) catch |e| return exit(&w, "deploy", e),
        .trade => |a| trade_mod.run(allocator, .{
            .chain = config.chain,
            .key_hex = config.key_hex,
            .address = config.getAddress(),
        }, a.coin) catch |e| return exit(&w, "trade", e),
    }
}

fn exit(w: *output_mod.Writer, cmd: []const u8, e: anyerror) void {
    if (e == error.BrokenPipe) std.process.exit(EXIT_OK);

    const code: u8 = switch (e) {
        error.MissingKey, error.MissingAddress, error.AddressMismatch => EXIT_AUTH,
        error.MissingArgument, error.InvalidFlag => EXIT_USAGE,
        error.ConnectionRefused, error.ConnectionResetByPeer, error.NetworkUnreachable => EXIT_NETWORK,
        else => EXIT_ERROR,
    };

    if (w.format == .json) {
        var buf: [2048]u8 = undefined;
        const name = @errorName(e);
        const retryable = switch (e) {
            error.ConnectionRefused, error.ConnectionResetByPeer, error.NetworkUnreachable => true,
            else => false,
        };
        const hint = switch (e) {
            error.MissingKey => "set HL_KEY env var or pass --key",
            error.MissingAddress => "set HL_ADDRESS env var or pass --address",
            error.AddressMismatch => "use a signer/key that matches --address, or omit --address for write commands",
            error.MissingArgument => "run `hlz help` for usage",
            error.AssetNotFound => "check coin name: BTC (perp), PURR/USDC (spot), xyz:BTC (dex)",
            error.CommandFailed => "",
            error.InvalidFlag => "check flag values",
            else => "",
        };
        var msg_buf: [1536]u8 = undefined;
        const msg = jsonEscape(w.exitMessage() orelse "", &msg_buf);
        const ms = w.elapsedMs();
        const s = std.fmt.bufPrint(&buf,
            \\{{"v":1,"status":"error","cmd":"{s}","error":"{s}","message":"{s}","retryable":{s},"hint":"{s}","timing_ms":{d}}}
        , .{ cmd, name, msg, if (retryable) "true" else "false", hint, ms }) catch return;
        w.rawJson(s) catch {};
    } else if (e != error.CommandFailed and e != error.AddressMismatch) {
        w.errFmt("{s}: {s}", .{ cmd, @errorName(e) }) catch {};
    }

    std.process.exit(code);
}

fn jsonEscape(input: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    for (input) |c| {
        switch (c) {
            0x08 => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = 'b';
                i += 2;
            },
            0x09 => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = 't';
                i += 2;
            },
            '"' => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = 'n';
                i += 2;
            },
            0x0c => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = 'f';
                i += 2;
            },
            '\r' => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = 'r';
                i += 2;
            },
            else => {
                if (c < 0x20) {
                    if (i + 6 > buf.len) break;
                    _ = std.fmt.bufPrint(buf[i .. i + 6], "\\u00{x:0>2}", .{c}) catch break;
                    i += 6;
                } else {
                    if (i >= buf.len) break;
                    buf[i] = c;
                    i += 1;
                }
            },
        }
    }
    return buf[0..i];
}

fn printVersion(w: *output_mod.Writer) !void {
    if (w.format == .json) {
        try w.jsonRaw("{\"version\":\"" ++ VERSION ++ "\"}");
    } else {
        try w.print("hlz {s}\n", .{VERSION});
    }
}

fn printHelp(w: *output_mod.Writer, help: args_mod.HelpArgs) !void {
    if (help.topic) |topic| {
        try printCommandHelp(w, topic);
        return;
    }
    try printGlobalHelp(w);
}

fn printGlobalHelp(w: *output_mod.Writer) !void {
    try w.styled(Style.bold_cyan,
        \\
        \\  ╦ ╦╦  
        \\  ╠═╣║  
        \\  ╩ ╩╩═╝
        \\
    );
    try w.print("  Hyperliquid CLI v{s}\n\n", .{VERSION});
    try w.styled(Style.bold_white, "USAGE\n");
    try w.print("  hlz <command> [args] [flags]\n", .{});
    try w.print("  hlz help <command>\n\n", .{});

    try w.styled(Style.bold_white, "MARKET DATA\n");
    try w.print(
        \\  price <COIN>             Mid price + bid/ask spread
        \\  mids [COIN]              All mid prices (--all, --page N)
        \\  funding [--top N] [--dex] Funding rates with heat bars
        \\  book <COIN> [--live]     L2 order book
        \\  perps [--dex xyz]        Perpetual markets
        \\  spot [--all]             Spot markets
        \\  outcomes [--all]         Outcome (prediction) markets
        \\  dexes                    HIP-3 DEXes
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "ACCOUNT\n");
    try w.print(
        \\  portfolio [ADDR]         Positions + spot balances
        \\  positions [ADDR]         Open positions
        \\  orders [ADDR]            Open orders
        \\  fills [ADDR] [--from T]  Recent fills (optionally by time)
        \\  balance [ADDR]           Account balance + health
        \\  status <OID>             Order status by OID
        \\  referral [set <CODE>]    Referral status or set code
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "TRADING\n");
    try w.print(
        \\  buy <COIN> <SZ> [@PX]    Limit or market buy
        \\  sell <COIN> <SZ> [@PX]   Limit or market sell
        \\  cancel <COIN> [OID]      Cancel order(s)
        \\  cancel --all             Cancel all open orders
        \\  modify <COIN> <OID> <SZ> <PX>
        \\  leverage <COIN> [N]      Query or set leverage
        \\  twap <COIN> buy|sell <SZ> --duration 1h --slices 10
        \\  batch "buy BTC 0.1 @98000" "sell ETH 1.0" [--stdin]
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "TRADING FLAGS\n");
    try w.print(
        \\  --reduce-only            Reduce-only order
        \\  --tp <PX>                Take-profit (bracket)
        \\  --sl <PX>                Stop-loss (bracket)
        \\  --trigger-above <PX>     Trigger order (take-profit)
        \\  --trigger-below <PX>     Trigger order (stop-loss)
        \\  --slippage <PX>          Max slippage for market orders
        \\  --tif <gtc|ioc|alo>      Time-in-force
        \\  --dry-run, -n            Preview order without sending
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "TRANSFERS & ACCOUNT\n");
    try w.print(
        \\  send <AMT> [TOKEN] <DEST>      Send to address
        \\  send <AMT> USDC --to spot      Perp → spot transfer
        \\  withdraw <AMT> [DEST]          Bridge withdrawal
        \\  transfer <AMT> --to-spot       Move USDC from perp to spot
        \\  transfer <AMT> --to-perp       Move USDC from spot to perp
        \\  fees [ADDR]                    Fee rates
        \\  rate-limit [ADDR]              Rate limit status
        \\  ledger [ADDR] [--from T]       Non-funding ledger updates
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "STREAMING\n");
    try w.print(
        \\  stream trades|bbo|book|candles|mids|fills|orders <COIN|ADDR>
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "STAKING & VAULTS\n");
    try w.print(
        \\  stake status             Delegation summary
        \\  stake delegate <VALIDATOR> <WEI>    Delegate to validator
        \\  stake undelegate <VALIDATOR> <WEI>  Undelegate
        \\  stake rewards            Staking rewards
        \\  stake history            Delegation history
        \\  vault <ADDR>             Vault details
        \\  vault deposit <ADDR> <AMT>   Deposit to vault
        \\  vault withdraw <ADDR> <AMT>  Withdraw from vault
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "SUB-ACCOUNTS\n");
    try w.print(
        \\  subaccount ls            List sub-accounts
        \\  subaccount create <NAME> Create sub-account
        \\  subaccount transfer <ADDR> <AMT>  USDC transfer
        \\  subaccount transfer <ADDR> <AMT> --token <T>  Spot transfer
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "ACCOUNT MODE\n");
    try w.print(
        \\  account                  Show account abstraction mode help
        \\  account standard         Separate spot/perp wallets (builders, MMs)
        \\  account unified          Single balance, shared collateral (default)
        \\  account portfolio        Portfolio margin (pre-alpha)
        \\  approve-agent <ADDR>     Approve API wallet for your account
        \\  approve-builder <ADDR> <RATE>  Approve builder fee
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "KEYS\n");
    try w.print(
        \\  keys ls                  List stored keys
        \\  keys new <NAME>          Generate new key (encrypted)
        \\  keys import <NAME>       Import existing key (--private-key)
        \\  keys export <NAME>       Export key (decrypted hex)
        \\  keys default <NAME>      Set default key
        \\  keys rm <NAME>           Remove key
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "TUI\n");
    try w.print(
        \\  trade [COIN]             Trading terminal (candlestick, orderbook)
        \\  markets                  Interactive market browser
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "GLOBAL FLAGS\n");
    try w.print(
        \\  --output json|pretty|csv Output format (auto-json when piped)
        \\  --json                   Shorthand for --output json
        \\  --quiet, -q              Minimal output (just result value)
        \\  --chain mainnet|testnet  Target chain
        \\  --key <HEX>             Private key (prefer keystore)
        \\  --key-name <NAME>       Use named keystore key
        \\  --address <ADDR>        User address
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "ENVIRONMENT\n");
    try w.print(
        \\  HL_KEY                   Trading private key (raw hex)
        \\  HL_PASSWORD              Keystore password (for --key-name)
        \\  HL_ADDRESS               Default wallet address
        \\  HL_CHAIN                 Default chain (mainnet|testnet)
        \\  HL_OUTPUT                Default output format (json|pretty|csv)
        \\  NO_COLOR                 Disable colored output
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "EXIT CODES\n");
    try w.print(
        \\  0   Success
        \\  1   Error (check JSON error envelope on stdout with --json)
        \\  2   Usage error (bad arguments, unknown command)
        \\  3   Auth error (missing key or address)
        \\  4   Network error (connection failed, retryable)
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "EXAMPLES\n");
    try w.print(
        \\  hlz price BTC                           Current BTC price
        \\  hlz positions --json                     Positions as JSON
        \\  hlz buy BTC 0.1 @95000 --dry-run         Preview order
        \\  hlz buy ETH 1.0 @3400 --tp 3600 --sl 3200  Bracket order
        \\  hlz cancel ETH                           Cancel all ETH orders
        \\  hlz stream trades BTC                    Real-time BTC trades
        \\  hlz mids --json | jq .data.BTC           Pipe mid price
        \\  HL_OUTPUT=json hlz positions              Agent-friendly default
        \\  echo '["buy BTC 0.1 @95000"]' | hlz batch --stdin  Pipe orders
        \\
        \\
    , .{});

    try w.styled(Style.muted, "  Asset syntax: BTC (perp) · PURR/USDC (spot) · xyz:BTC (HIP-3 DEX)\n");
    try w.styled(Style.muted, "  Aliases: long=buy short=sell pos=positions bal=balance ord=orders\n\n");
}

fn printHelpSection(w: *output_mod.Writer, title: []const u8, body: []const u8) !void {
    try w.styled(Style.bold_white, title);
    try w.print("{s}", .{body});
}

fn printCommandDoc(
    w: *output_mod.Writer,
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
    aliases: ?[]const u8,
    details: ?[]const u8,
    examples: ?[]const u8,
) !void {
    try w.styled(Style.bold_white, "COMMAND\n");
    try w.print("  {s}\n", .{name});
    try w.print("  {s}\n\n", .{summary});
    try printHelpSection(w, "USAGE\n", usage);
    if (aliases) |body| try printHelpSection(w, "ALIASES\n", body);
    if (details) |body| try printHelpSection(w, "DETAILS\n", body);
    if (examples) |body| try printHelpSection(w, "EXAMPLES\n", body);
    try w.styled(Style.muted, "  Global flags: --json --quiet --chain --key --key-name --address\n");
}

fn printCommandHelp(w: *output_mod.Writer, topic: args_mod.HelpTopic) !void {
    switch (topic) {
        .keys => try printCommandDoc(w, "keys", "Manage encrypted local keystore entries.",
            \\  hlz keys ls
            \\  hlz keys new <NAME>
            \\  hlz keys import <NAME> --private-key <HEX>
            \\  hlz keys export <NAME>
            \\  hlz keys default <NAME>
            \\  hlz keys rm <NAME>
            \\
        , "  key\n\n",
            \\  `keys new` and `keys import` store encrypted keys locally.
            \\  `keys export` and `keys rm` operate on an existing named key.
            \\  Use HL_PASSWORD or --password when the keystore command requires decryption.
            \\
        ,
            \\  hlz keys ls
            \\  hlz keys import market-maker --private-key 0xabc...
            \\
        ),
        .mids => try printCommandDoc(w, "mids", "Show all mid prices or a single asset.",
            \\  hlz mids [COIN] [--dex <DEX>] [--all] [--page <N>]
            \\
        , "  mid\n\n",
            \\  With no COIN, hlz prints a paginated market-wide view.
            \\  Use --dex for HIP-3 markets and --all to disable pagination.
            \\
        ,
            \\  hlz mids
            \\  hlz mids BTC
            \\
        ),
        .positions => try printCommandDoc(w, "positions", "Show open perp positions for an address.",
            \\  hlz positions [ADDR] [--dex <DEX>] [--all-dexes]
            \\
        , "  pos\n\n",
            \\  If ADDR is omitted, hlz uses --address or HL_ADDRESS when available.
            \\  This is a read command and does not require a signing key.
            \\
        ,
            \\  hlz positions 0xabc...
            \\  hlz pos --json
            \\
        ),
        .orders => try printCommandDoc(w, "orders", "Show open orders for an address.",
            \\  hlz orders [ADDR] [--dex <DEX>] [--all-dexes]
            \\
        , "  ord\n\n",
            \\  If ADDR is omitted, hlz uses --address or HL_ADDRESS when available.
            \\  This is a read command and does not require a signing key.
            \\
        ,
            \\  hlz orders 0xabc...
            \\  hlz ord --json
            \\
        ),
        .fills => try printCommandDoc(w, "fills", "Show recent fills for an address.",
            \\  hlz fills [ADDR] [--from <TIME>] [--to <TIME>]
            \\
        , null,
            \\  Time filters are forwarded as strings; use the format expected by your workflow.
            \\  If ADDR is omitted, hlz uses --address or HL_ADDRESS when available.
            \\
        ,
            \\  hlz fills
            \\  hlz fills 0xabc... --from 1710000000000
            \\
        ),
        .balance => try printCommandDoc(w, "balance", "Show account balance, equity, and health.",
            \\  hlz balance [ADDR] [--dex <DEX>] [--all-dexes]
            \\
        , "  bal\n\n",
            \\  If ADDR is omitted, hlz uses --address or HL_ADDRESS when available.
            \\  This is a read command and does not require a signing key.
            \\
        ,
            \\  hlz balance
            \\  hlz bal 0xabc...
            \\
        ),
        .perps => try printCommandDoc(w, "perps", "List perpetual markets.",
            \\  hlz perps [FILTER] [--dex <DEX>] [--all] [--page <N>] [--filter <TEXT>]
            \\
        , null,
            \\  A bare FILTER positional is treated the same as --filter.
            \\  Use --all to disable pagination.
            \\
        ,
            \\  hlz perps
            \\  hlz perps BTC
            \\
        ),
        .spot => try printCommandDoc(w, "spot", "List spot markets.",
            \\  hlz spot [FILTER] [--all] [--page <N>] [--filter <TEXT>]
            \\
        , null,
            \\  A bare FILTER positional is treated the same as --filter.
            \\  Use --all to disable pagination.
            \\
        ,
            \\  hlz spot
            \\  hlz spot PURR
            \\
        ),
        .outcomes => try printCommandDoc(w, "outcomes", "List outcome (prediction) markets.",
            \\  hlz outcomes [FILTER] [--all] [--page <N>] [--filter <TEXT>]
            \\
        , null,
            \\  A bare FILTER positional is treated the same as --filter.
            \\  Use --all to disable pagination.
            \\  Outcome asset IDs: 100_000_000 + (10 * outcome_id + side).
            \\  Outcome coins use #<encoding> format (e.g. #12730).
            \\
        ,
            \\  hlz outcomes
            \\  hlz outcomes BTC
            \\  hlz outcomes Recurring
            \\
        ),
        .dexes => try printCommandDoc(w, "dexes", "List available HIP-3 DEX venues.",
            \\  hlz dexes
            \\
        , "  dex\n\n", null,
            \\  hlz dexes
            \\
        ),
        .buy => try printCommandDoc(w, "buy", "Place a buy order.",
            \\  hlz buy <COIN> <SZ> [@PX]
            \\  hlz buy <COIN> <SZ> --slippage <PCT>
            \\
        , "  long\n\n",
            \\  Limit orders use @PX or a bare trailing price. Omit price for market-style execution.
            \\  Flags: --reduce-only --tif <gtc|ioc|alo> --tp <PX> --sl <PX>
            \\  Also supports --trigger-above, --trigger-below, and --dry-run.
            \\  Route via builder: --builder <ADDR> --builder-fee <PCT|TENTHS_BPS>.
            \\  Requires a signing key via --key-name/HL_PASSWORD, --key, or HL_KEY.
            \\
        ,
            \\  hlz buy BTC 0.1 @95000
            \\  hlz long ETH 1 --slippage 0.5 --dry-run
            \\  hlz buy BTC 0.1 @95000 --builder 0xabc... --builder-fee 0.001%
            \\
        ),
        .sell => try printCommandDoc(w, "sell", "Place a sell order.",
            \\  hlz sell <COIN> <SZ> [@PX]
            \\  hlz sell <COIN> <SZ> --slippage <PCT>
            \\
        , "  short\n\n",
            \\  Limit orders use @PX or a bare trailing price. Omit price for market-style execution.
            \\  Flags: --reduce-only --tif <gtc|ioc|alo> --tp <PX> --sl <PX>
            \\  Also supports --trigger-above, --trigger-below, and --dry-run.
            \\  Route via builder: --builder <ADDR> --builder-fee <PCT|TENTHS_BPS>.
            \\  Requires a signing key via --key-name/HL_PASSWORD, --key, or HL_KEY.
            \\
        ,
            \\  hlz sell BTC 0.1 @98000
            \\  hlz short ETH 1 --slippage 0.5 --dry-run
            \\
        ),
        .cancel => try printCommandDoc(w, "cancel", "Cancel one order, a market, or all orders.",
            \\  hlz cancel <COIN> [OID]
            \\  hlz cancel <COIN> --cloid <CLOID>
            \\  hlz cancel --all
            \\
        , null,
            \\  A numeric positional after COIN is treated as an order id.
            \\  Requires a signing key via --key-name/HL_PASSWORD, --key, or HL_KEY.
            \\
        ,
            \\  hlz cancel ETH
            \\  hlz cancel BTC 123456789
            \\
        ),
        .modify => try printCommandDoc(w, "modify", "Modify an existing order in place.",
            \\  hlz modify <COIN> <OID> <SZ> <PX>
            \\
        , "  mod\n\n",
            \\  Price can be passed as `@3400` or `3400`.
            \\  Requires a signing key via --key-name/HL_PASSWORD, --key, or HL_KEY.
            \\
        ,
            \\  hlz modify ETH 123456789 1.5 @3400
            \\
        ),
        .send => try printCommandDoc(w, "send", "Send a token to another address or move assets internally.",
            \\  hlz send <AMT> [TOKEN] <DEST>
            \\  hlz send <AMT> [TOKEN] --from <perp|spot> --to <DEST|perp|spot>
            \\  hlz send <AMT> [TOKEN] --subaccount <ADDR> --to <DEST>
            \\
        , null,
            \\  TOKEN defaults to USDC. If DEST is omitted, hlz performs a self-transfer.
            \\  Use --from and --to for perp/spot moves or DEX destinations.
            \\  --agent uses agentSendAsset (API wallet signing); destination must equal the signer.
            \\  Requires a signing key via --key-name/HL_PASSWORD, --key, or HL_KEY.
            \\
        ,
            \\  hlz send 100 USDC 0xabc...
            \\  hlz send 100 USDC --to spot
            \\  hlz send 100 USDC --from perp --to spot --agent
            \\
        ),
        .stream => try printCommandDoc(w, "stream", "Subscribe to a live WebSocket feed.",
            \\  hlz stream [trades|bbo|book|candles|mids|fills|orders] <COIN|ADDR> [--interval <INT>] [--filter <TEXT>]
            \\
        , "  sub\n\n",
            \\  If the first positional is not a stream kind, hlz treats it as the coin and defaults to trades.
            \\  Address targets apply to fills and orders streams.
            \\
        ,
            \\  hlz stream trades BTC
            \\  hlz sub candles ETH --interval 5m
            \\
        ),
        .status => try printCommandDoc(w, "status", "Fetch order status by order id.",
            \\  hlz status <OID>
            \\
        , null,
            \\  This is a read command and does not require a signing key.
            \\
        ,
            \\  hlz status 123456789
            \\
        ),
        .funding => try printCommandDoc(w, "funding", "Show funding rates with optional pagination and filtering.",
            \\  hlz funding [FILTER] [--top <N>] [--all] [--page <N>] [--filter <TEXT>] [--dex <NAME>]
            \\
        , "  fund\n\n",
            \\  A bare FILTER positional is treated the same as --filter.
            \\  Use --all to disable pagination.
            \\  Use --dex to show HIP-3 builder perp markets for a specific dex.
            \\
        ,
            \\  hlz funding
            \\  hlz fund BTC
            \\  hlz funding --dex hyperliquidity
            \\
        ),
        .book => try printCommandDoc(w, "book", "Show the L2 order book for one market.",
            \\  hlz book <COIN> [--depth <N>] [--live]
            \\
        , "  ob\n\n",
            \\  --live keeps the book open and refreshes in place.
            \\  Depth defaults to 15.
            \\
        ,
            \\  hlz book BTC
            \\  hlz ob ETH --depth 25 --live
            \\
        ),
        .markets => try printCommandDoc(w, "markets", "Open the interactive market browser.",
            \\  hlz markets
            \\
        , "  m\n\n",
            \\  This launches the TUI market browser.
            \\
        ,
            \\  hlz markets
            \\
        ),
        .trade => try printCommandDoc(w, "trade", "Open the trading terminal TUI.",
            \\  hlz trade [COIN]
            \\
        , "  t\n\n",
            \\  COIN defaults to BTC.
            \\  Trading actions inside the terminal still require a signing key.
            \\
        ,
            \\  hlz trade
            \\  hlz t ETH
            \\
        ),
        .leverage => try printCommandDoc(w, "leverage", "Query or set leverage for a perp market.",
            \\  hlz leverage <COIN> [N] [--cross|--isolated]
            \\
        , "  lev\n\n",
            \\  Omit N to query the current leverage.
            \\  Passing N changes leverage and requires a signing key.
            \\
        ,
            \\  hlz leverage BTC
            \\  hlz lev ETH 5 --isolated
            \\
        ),
        .price => try printCommandDoc(w, "price", "Show mid price plus bid/ask spread.",
            \\  hlz price <COIN> [--dex <DEX>] [--quote <TOKEN>] [--all]
            \\
        , null,
            \\  Use --dex for HIP-3 venues and --quote when a market supports multiple quote tokens.
            \\
        ,
            \\  hlz price BTC
            \\  hlz price xyz:BTC --dex xyz
            \\
        ),
        .portfolio => try printCommandDoc(w, "portfolio", "Show positions plus spot balances for an address.",
            \\  hlz portfolio [ADDR] [--dex <DEX>] [--all-dexes]
            \\
        , "  folio\n\n",
            \\  If ADDR is omitted, hlz uses --address or HL_ADDRESS when available.
            \\  This is a read command and does not require a signing key.
            \\
        ,
            \\  hlz portfolio
            \\  hlz folio 0xabc...
            \\
        ),
        .referral => try printCommandDoc(w, "referral", "Show referral status or set a referral code.",
            \\  hlz referral
            \\  hlz referral status
            \\  hlz referral set <CODE>
            \\  hlz referral <CODE>
            \\
        , null,
            \\  Setting a referral code is a write action and requires a signing key.
            \\  Querying status is read-only.
            \\
        ,
            \\  hlz referral
            \\  hlz referral set MYCODE
            \\
        ),
        .twap => try printCommandDoc(w, "twap", "Slice an order over time.",
            \\  hlz twap <COIN> <buy|sell> <SZ> [--duration <SPAN>] [--slices <N>] [--slippage <PCT>]
            \\
        , null,
            \\  Duration defaults to 1h, slices default to 10, slippage defaults to 1.0 percent.
            \\  Requires a signing key via --key-name/HL_PASSWORD, --key, or HL_KEY.
            \\
        ,
            \\  hlz twap BTC buy 1 --duration 30m --slices 6
            \\
        ),
        .batch => try printCommandDoc(w, "batch", "Submit multiple order instructions at once.",
            \\  hlz batch "buy BTC 0.1 @98000" "sell ETH 1.0"
            \\  echo '["buy BTC 0.1 @98000"]' | hlz batch --stdin
            \\
        , null,
            \\  Batch accepts up to 16 orders from argv or stdin.
            \\  Route via builder: --builder <ADDR> --builder-fee <PCT|TENTHS_BPS>.
            \\  Requires a signing key via --key-name/HL_PASSWORD, --key, or HL_KEY.
            \\
        ,
            \\  hlz batch "buy BTC 0.1 @98000" "sell ETH 1.0"
            \\
        ),
        .approve_agent => try printCommandDoc(w, "approve-agent", "Approve an API wallet for your account.",
            \\  hlz approve-agent <ADDR> [--name <LABEL>]
            \\
        , "  approve\n\n",
            \\  This is a write action and requires a signing key for the main account.
            \\
        ,
            \\  hlz approve-agent 0xabc... --name bot-1
            \\
        ),
        .withdraw => try printCommandDoc(w, "withdraw", "Bridge-withdraw funds to an address.",
            \\  hlz withdraw <AMT> [DEST]
            \\
        , null,
            \\  If DEST is omitted, the destination defaults to self.
            \\  This is a write action and requires a signing key.
            \\
        ,
            \\  hlz withdraw 100
            \\  hlz withdraw 100 0xabc...
            \\
        ),
        .transfer => try printCommandDoc(w, "transfer", "Move USDC between perp and spot wallets.",
            \\  hlz transfer <AMT> --to-spot
            \\  hlz transfer <AMT> --to-perp
            \\
        , null,
            \\  One direction flag is required to prevent accidental transfers.
            \\  This is a write action and requires a signing key.
            \\
        ,
            \\  hlz transfer 250 --to-spot
            \\  hlz transfer 250 --to-perp
            \\
        ),
        .fees => try printCommandDoc(w, "fees", "Show fee tiers and fee rates for an address.",
            \\  hlz fees [ADDR]
            \\
        , "  fee\n\n",
            \\  If ADDR is omitted, hlz uses --address or HL_ADDRESS when available.
            \\  This is a read command and does not require a signing key.
            \\
        ,
            \\  hlz fees
            \\  hlz fee 0xabc...
            \\
        ),
        .rate_limit => try printCommandDoc(w, "rate-limit", "Show account rate-limit status.",
            \\  hlz rate-limit [ADDR]
            \\
        , "  ratelimit\n\n",
            \\  If ADDR is omitted, hlz uses --address or HL_ADDRESS when available.
            \\  This is a read command and does not require a signing key.
            \\
        ,
            \\  hlz rate-limit
            \\
        ),
        .stake => try printCommandDoc(w, "stake", "Inspect or manage staking delegation.",
            \\  hlz stake status
            \\  hlz stake rewards
            \\  hlz stake history
            \\  hlz stake delegate <VALIDATOR> <WEI>
            \\  hlz stake undelegate <VALIDATOR> <WEI>
            \\
        , "  staking\n\n",
            \\  Delegate and undelegate are write actions and require a signing key.
            \\  Status, rewards, and history are read-only.
            \\
        ,
            \\  hlz stake status
            \\  hlz staking delegate 0xvalidator 1000000000000000000
            \\
        ),
        .vault => try printCommandDoc(w, "vault", "Inspect a vault or move funds in and out.",
            \\  hlz vault <ADDR>
            \\  hlz vault info <ADDR>
            \\  hlz vault deposit <ADDR> <AMT>
            \\  hlz vault withdraw <ADDR> <AMT>
            \\
        , null,
            \\  `vault` and `vault info` are read-only.
            \\  Deposit and withdraw are write actions and require a signing key.
            \\
        ,
            \\  hlz vault 0xvault...
            \\  hlz vault deposit 0xvault... 100
            \\
        ),
        .ledger => try printCommandDoc(w, "ledger", "Show non-funding ledger updates.",
            \\  hlz ledger [ADDR] [--from <TIME>] [--to <TIME>]
            \\
        , null,
            \\  If ADDR is omitted, hlz uses --address or HL_ADDRESS when available.
            \\  This is a read command and does not require a signing key.
            \\
        ,
            \\  hlz ledger
            \\  hlz ledger 0xabc... --from 1710000000000
            \\
        ),
        .approve_builder => try printCommandDoc(w, "approve-builder", "Approve a builder fee rate.",
            \\  hlz approve-builder <ADDR> <RATE>
            \\
        , null,
            \\  This is a write action and requires a signing key.
            \\  RATE is the max fee rate you are approving.
            \\
        ,
            \\  hlz approve-builder 0xbuilder... "0.001%"
            \\
        ),
        .subaccount => try printCommandDoc(w, "subaccount", "Manage sub-accounts and sub-account transfers.",
            \\  hlz subaccount ls
            \\  hlz subaccount create <NAME>
            \\  hlz subaccount transfer <ADDR> <AMT> [--withdraw]
            \\  hlz subaccount transfer <ADDR> <AMT> --token <TOKEN> [--withdraw]
            \\
        , null,
            \\  `ls` is read-only. `create` and transfer actions require a signing key.
            \\  `--withdraw` flips transfer direction from deposit to withdraw.
            \\  Adding --token turns a USDC transfer into a spot token transfer.
            \\
        ,
            \\  hlz subaccount ls
            \\  hlz subaccount create market-maker-1
            \\
        ),
        .account => try printCommandDoc(w, "account", "Query or set account abstraction mode.",
            \\  hlz account
            \\  hlz account standard
            \\  hlz account unified
            \\  hlz account portfolio
            \\
        , null,
            \\  With no mode, hlz shows help or queries the current mode when an address is available.
            \\  Setting a mode is a write action and requires a signing key.
            \\
        ,
            \\  hlz account
            \\  hlz account unified
            \\
        ),
        .config => try printCommandDoc(w, "config", "Show the resolved runtime configuration.",
            \\  hlz config
            \\
        , null,
            \\  Prints the effective chain, output mode, address, and key source information.
            \\
        ,
            \\  hlz config
            \\
        ),
        .help => try printCommandDoc(w, "help", "Show global help or help for one command.",
            \\  hlz help
            \\  hlz help <COMMAND>
            \\
        , null,
            \\  Every top-level command also supports `--help` and `-h`.
            \\
        ,
            \\  hlz help transfer
            \\  hlz buy --help
            \\
        ),
        .version => try printCommandDoc(w, "version", "Print the hlz version.",
            \\  hlz version
            \\
        , null, null,
            \\  hlz version
            \\
        ),
        .deploy => try printCommandDoc(w, "deploy", "HIP-1 spot token deployment (5-step flow + admin).",
            \\  hlz deploy status [--pair]
            \\  hlz deploy spot <register|user-genesis|genesis|register-pair|hyperliquidity|...>
            \\
        , null,
            \\  Run `hlz deploy` with no arguments to see the full subcommand tree.
            \\  The 5-step flow is:  register -> user-genesis -> genesis -> register-pair -> hyperliquidity.
            \\
        ,
            \\  hlz deploy status
            \\  hlz deploy status --pair
            \\
        ),
    }
}
