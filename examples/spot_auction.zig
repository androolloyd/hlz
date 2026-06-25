//! Bid on the HIP-1 spot deploy (ticker) auction.
//!
//! Registering a token via `registerToken2` is step 1 of a spot deploy: it
//! takes part in the shared Dutch gas auction and, if the live price is at or
//! below your `maxGas` cap, claims the ticker and charges the auction price in
//! HYPE. The gas decays linearly over 31h from the start price down to a
//! 500 HYPE floor (HIP-1). `maxGas` is denominated in HYPE wei (8 decimals),
//! so 500 HYPE == 50_000_000_000.
//!
//! This is only the auction bid. Turning the token into a tradable spot market
//! needs the later steps (userGenesis → genesis → registerSpot →
//! registerHyperliquidity), which this example does not perform.
//!
//! SAFETY: defaults to testnet. Set HL_MAINNET=1 for mainnet. The bid is only
//! actually sent when HL_CONFIRM=1; otherwise this just prints the live auction
//! price and what it would submit.
//!
//! Usage:
//!   HL_KEY=<hex> zig build example-spot_auction              # preview only (testnet)
//!   HL_KEY=<hex> HL_CONFIRM=1 zig build example-spot_auction  # actually bid

const std = @import("std");
const hlz = @import("hlz");

const Signer = hlz.crypto.signer.Signer;
const types = hlz.hypercore.types;
const Client = hlz.hypercore.client.Client;
const eip712 = hlz.crypto.eip712;

// ── Deployment parameters ────────────────────────────────────────
const TOKEN_NAME = "XD";
const FULL_NAME = "XD";
const SZ_DECIMALS: u32 = 2;
const WEI_DECIMALS: u32 = 8;

// Max price to pay for the auction, in HYPE. The bid only fills when the live
// auction price is <= this. 500 HYPE is the auction floor.
const MAX_GAS_HYPE: u64 = 900;
const HYPE_WEI_PER_UNIT: u64 = 100_000_000; // native token wei decimals = 8
const MAX_GAS_WEI: u64 = MAX_GAS_HYPE * HYPE_WEI_PER_UNIT;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

fn getenv(name: [:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name.ptr) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const key_hex = getenv("HL_KEY") orelse getenv("TRADING_KEY") orelse
        fatal("Set HL_KEY (or TRADING_KEY) to your private key (hex, with or without 0x)", .{});

    const key = if (std.mem.startsWith(u8, key_hex, "0x")) key_hex[2..] else key_hex;
    const signer = Signer.fromHex(key) catch fatal("Invalid private key", .{});

    const is_mainnet = getenv("HL_MAINNET") != null;
    const confirmed = getenv("HL_CONFIRM") != null;
    var client = if (is_mainnet) Client.mainnet(allocator) else Client.testnet(allocator);
    defer client.deinit();

    const addr = eip712.addressToHex(signer.address);
    std.debug.print("Account: {s}  chain: {s}\n\n", .{
        &addr,
        if (is_mainnet) "mainnet" else "testnet",
    });

    // ── Live auction price ───────────────────────────────────────
    const user: []const u8 = &addr;
    var state = try client.spotDeployState(user);
    defer state.deinit();

    const root = try state.json();
    var current_gas: ?[]const u8 = null;
    if (root.object.get("gasAuction")) |ga| {
        const start = if (ga.object.get("startGas")) |v| (if (v == .string) v.string else "?") else "?";
        const cur = if (ga.object.get("currentGas")) |v| (if (v == .string) v.string else "null") else "null";
        const end = if (ga.object.get("endGas")) |v| (if (v == .string) v.string else "null") else "null";
        if (ga.object.get("currentGas")) |v| {
            if (v == .string) current_gas = v.string;
        }
        std.debug.print("Gas auction:  start={s} HYPE  current={s} HYPE  end={s} HYPE\n", .{ start, cur, end });
    } else {
        std.debug.print("Gas auction:  (no active auction in state response)\n", .{});
    }

    std.debug.print(
        "\nBid:  name={s}  szDecimals={d}  weiDecimals={d}  maxGas={d} HYPE ({d} wei)\n",
        .{ TOKEN_NAME, SZ_DECIMALS, WEI_DECIMALS, MAX_GAS_HYPE, MAX_GAS_WEI },
    );

    if (current_gas) |cg| {
        const cur_f = std.fmt.parseFloat(f64, cg) catch 0;
        if (cur_f > @as(f64, @floatFromInt(MAX_GAS_HYPE))) {
            std.debug.print(
                "Note: live price {s} HYPE is above the {d} HYPE cap — this bid only fills once the auction decays to the cap.\n",
                .{ cg, MAX_GAS_HYPE },
            );
        }
    }

    if (!confirmed) {
        std.debug.print("\nPreview only. Re-run with HL_CONFIRM=1 to submit the bid.\n", .{});
        return;
    }

    // ── Submit the bid ───────────────────────────────────────────
    const rt = types.SpotDeployRegisterToken{
        .name = TOKEN_NAME,
        .sz_decimals = SZ_DECIMALS,
        .wei_decimals = WEI_DECIMALS,
        .max_gas = MAX_GAS_WEI,
        .full_name = FULL_NAME,
    };

    const nonce: u64 = hlz.runtime.nonceMs();
    std.debug.print("\nSubmitting registerToken2...\n", .{});
    var result = try client.spotDeployRegisterToken(signer, rt, nonce);
    defer result.deinit();

    std.debug.print("Response: {s}\n", .{result.body});
    // On success, response.data holds the new token index (needed for genesis).
}
