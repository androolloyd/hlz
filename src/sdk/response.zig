//! Response types for Hyperliquid API.
//!
//! Types use camelCase field names matching JSON keys exactly, enabling
//! automatic deserialization via `std.json.parseFromSlice` / `parseFromValue`.
//! Custom types (Decimal) implement `jsonParseFromValue` hooks.
//!
//! Usage:
//!   const parsed = try std.json.parseFromSlice(
//!       ClearinghouseState, allocator, body,
//!       .{ .ignore_unknown_fields = true },
//!   );
//!   defer parsed.deinit();
//!   const equity = parsed.value.marginSummary.accountValue;

const std = @import("std");
const json = @import("json.zig");
const runtime = @import("../lib/runtime.zig");
const Decimal = @import("../lib/math/decimal.zig").Decimal;

pub const ParseOpts = std.json.ParseOptions{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

// ── Exchange Response ─────────────────────────────────────────

pub const ResponseStatus = enum {
    ok,
    err,
    unknown,
};

pub const OrderResponseStatus = union(enum) {
    success: void,
    waitingForTrigger: void,
    waitingForFill: void,
    resting: struct { oid: u64, cloid: ?[]const u8 = null },
    filled: struct { totalSz: ?Decimal = null, avgPx: ?Decimal = null, oid: u64 = 0 },
    @"error": []const u8,
    unknown: void,
};

/// Parse the exchange response status.
pub fn parseResponseStatus(obj: std.json.Value) ResponseStatus {
    const status = json.getString(obj, "status") orelse return .unknown;
    if (std.mem.eql(u8, status, "ok")) return .ok;
    if (std.mem.eql(u8, status, "err")) return .err;
    return .unknown;
}

/// Parse order response statuses from a place/cancel/modify response.
pub fn parseOrderStatuses(allocator: std.mem.Allocator, obj: std.json.Value) ![]OrderResponseStatus {
    const resp = json.getObject(obj, "response") orelse return &[_]OrderResponseStatus{};
    const data = json.getObject(resp, "data") orelse return &[_]OrderResponseStatus{};
    const statuses_arr = json.getArray(data, "statuses") orelse return &[_]OrderResponseStatus{};

    var result = try allocator.alloc(OrderResponseStatus, statuses_arr.len);
    for (statuses_arr, 0..) |item, i| {
        result[i] = parseOneOrderStatus(item);
    }
    return result;
}

fn parseOneOrderStatus(item: std.json.Value) OrderResponseStatus {
    if (item == .string) {
        if (std.mem.eql(u8, item.string, "success")) return .{ .success = {} };
        if (std.mem.eql(u8, item.string, "waitingForTrigger")) return .{ .waitingForTrigger = {} };
        if (std.mem.eql(u8, item.string, "waitingForFill")) return .{ .waitingForFill = {} };
        return .{ .@"error" = item.string };
    }
    if (item != .object) return .{ .unknown = {} };

    if (json.getObject(item, "resting")) |r| {
        return .{ .resting = .{
            .oid = json.getInt(u64, r, "oid") orelse 0,
            .cloid = json.getString(r, "cloid"),
        } };
    }
    if (json.getObject(item, "filled")) |f| {
        return .{ .filled = .{
            .totalSz = json.getDecimal(f, "totalSz"),
            .avgPx = json.getDecimal(f, "avgPx"),
            .oid = json.getInt(u64, f, "oid") orelse 0,
        } };
    }
    if (json.getString(item, "error")) |e| {
        return .{ .@"error" = e };
    }
    return .{ .unknown = {} };
}

// ── Info Response Types ───────────────────────────────────────
// Field names match JSON keys (camelCase) for automatic std.json parsing.

pub const MarginSummary = struct {
    accountValue: Decimal = Decimal.ZERO,
    totalNtlPos: Decimal = Decimal.ZERO,
    totalRawUsd: Decimal = Decimal.ZERO,
    totalMarginUsed: Decimal = Decimal.ZERO,

    pub fn availableMargin(self: MarginSummary) Decimal {
        return self.accountValue.subtract(self.totalMarginUsed);
    }
};

pub const Leverage = struct {
    type: []const u8 = "",
    value: u32 = 1,
    rawVal: ?[]const u8 = null,
};

pub const PositionData = struct {
    coin: []const u8 = "",
    szi: Decimal = Decimal.ZERO,
    entryPx: ?Decimal = null,
    positionValue: ?Decimal = null,
    unrealizedPnl: ?Decimal = null,
    returnOnEquity: ?Decimal = null,
    liquidationPx: ?Decimal = null,
    marginUsed: ?Decimal = null,
    maxLeverage: ?u32 = null,
    leverage: ?Leverage = null,
    cumFunding: ?struct {
        allTime: Decimal = Decimal.ZERO,
        sinceOpen: Decimal = Decimal.ZERO,
        sinceChange: Decimal = Decimal.ZERO,
    } = null,
};

pub const AssetPosition = struct {
    type: []const u8 = "oneWay",
    position: PositionData = .{},
};

pub const ClearinghouseState = struct {
    marginSummary: MarginSummary = .{},
    crossMarginSummary: MarginSummary = .{},
    crossMaintenanceMarginUsed: Decimal = Decimal.ZERO,
    withdrawable: Decimal = Decimal.ZERO,
    assetPositions: []AssetPosition = &.{},
    time: u64 = 0,
};

pub const UserBalance = struct {
    coin: []const u8 = "",
    token: u32 = 0,
    hold: Decimal = Decimal.ZERO,
    total: Decimal = Decimal.ZERO,
    entryNtl: ?Decimal = null,
};

pub const SpotClearinghouseState = struct {
    balances: []UserBalance = &.{},
};

pub const Fill = struct {
    coin: []const u8 = "",
    px: Decimal = Decimal.ZERO,
    sz: Decimal = Decimal.ZERO,
    side: []const u8 = "",
    time: u64 = 0,
    startPosition: ?Decimal = null,
    dir: []const u8 = "",
    closedPnl: ?Decimal = null,
    hash: []const u8 = "",
    oid: u64 = 0,
    crossed: bool = false,
    fee: Decimal = Decimal.ZERO,
    tid: u64 = 0,
    feeToken: []const u8 = "",
    cloid: ?[]const u8 = null,
    twapId: ?u64 = null,
};

pub const BasicOrder = struct {
    coin: []const u8 = "",
    side: []const u8 = "",
    limitPx: Decimal = Decimal.ZERO,
    sz: Decimal = Decimal.ZERO,
    oid: u64 = 0,
    timestamp: u64 = 0,
    origSz: ?Decimal = null,
    reduceOnly: bool = false,
    orderType: []const u8 = "",
    tif: ?[]const u8 = null,
    cloid: ?[]const u8 = null,
    triggerCondition: ?[]const u8 = null,
    isTrigger: bool = false,
    triggerPx: ?Decimal = null,
    children: ?[]const std.json.Value = null,
    isPositionTpsl: bool = false,
};

pub const HistoricalOrder = struct {
    order: BasicOrder = .{},
    status: []const u8 = "",
    statusTimestamp: u64 = 0,
};

pub const Candle = struct {
    t: u64 = 0, // openTime
    T: u64 = 0, // closeTime
    s: []const u8 = "", // coin
    i: []const u8 = "", // interval
    o: Decimal = Decimal.ZERO, // open
    h: Decimal = Decimal.ZERO, // high
    l: Decimal = Decimal.ZERO, // low
    c: Decimal = Decimal.ZERO, // close
    v: Decimal = Decimal.ZERO, // volume
    n: u64 = 0, // numTrades
};

pub const Trade = struct {
    coin: []const u8 = "",
    side: []const u8 = "",
    px: Decimal = Decimal.ZERO,
    sz: Decimal = Decimal.ZERO,
    time: u64 = 0,
    hash: []const u8 = "",
    tid: u64 = 0,
};

pub const BookLevel = struct {
    px: Decimal = Decimal.ZERO,
    sz: Decimal = Decimal.ZERO,
    n: u64 = 0,
};

pub const L2Book = struct {
    coin: []const u8 = "",
    time: u64 = 0,
    levels: [2][]BookLevel = .{ &.{}, &.{} },
};

pub const Bbo = struct {
    coin: []const u8 = "",
    bidPx: ?Decimal = null,
    bidSz: ?Decimal = null,
    askPx: ?Decimal = null,
    askSz: ?Decimal = null,
    time: u64 = 0,
};

pub const FundingRate = struct {
    coin: []const u8 = "",
    fundingRate: Decimal = Decimal.ZERO,
    premium: ?Decimal = null,
    time: u64 = 0,
};

pub const UserFundingDelta = struct {
    type: []const u8 = "funding",
    coin: []const u8 = "",
    usdc: Decimal = Decimal.ZERO,
    szi: Decimal = Decimal.ZERO,
    fundingRate: Decimal = Decimal.ZERO,
    nSamples: ?u64 = null,
};

pub const UserFunding = struct {
    time: u64 = 0,
    hash: []const u8 = "",
    delta: UserFundingDelta = .{},
};

pub const UserLeverage = struct {
    type: []const u8 = "",
    value: u32 = 1,
    rawVal: ?[]const u8 = null,
};

pub const ActiveAssetData = struct {
    user: []const u8 = "",
    coin: []const u8 = "",
    leverage: ?UserLeverage = null,
    markPx: ?Decimal = null,
    maxTradeSzs: ?[2]Decimal = null,
    availableToTrade: ?[2]Decimal = null,
};

pub const AssetContext = struct {
    funding: Decimal = Decimal.ZERO,
    openInterest: Decimal = Decimal.ZERO,
    prevDayPx: ?Decimal = null,
    dayNtlVlm: ?Decimal = null,
    premium: ?Decimal = null,
    oraclePx: ?Decimal = null,
    markPx: ?Decimal = null,
    midPx: ?Decimal = null,
    impactPxs: ?[]Decimal = null,
};

pub const PerpMeta = struct {
    name: []const u8 = "",
    szDecimals: u32 = 0,
    maxLeverage: u32 = 1,
    onlyIsolated: bool = false,
    isDelisted: bool = false,
    isAlignedQuoteToken: bool = false,
};

pub const PerpUniverse = struct {
    universe: []PerpMeta = &.{},
};

/// Parsed result of metaAndAssetCtxs — zips universe names with asset contexts.
pub const MetaAndAssetCtx = struct {
    meta: PerpMeta,
    ctx: AssetContext,
};

pub const Referral = struct {
    referredBy: ?[]const u8 = null,
    cumVlm: ?Decimal = null,
    unclaimedRewards: ?Decimal = null,
    claimedRewards: ?Decimal = null,
    referrerState: ?struct {
        data: ?struct {
            referralCode: ?[]const u8 = null,
        } = null,
    } = null,
};

pub const SpotToken = struct {
    name: []const u8 = "",
    index: u32 = 0,
    tokenId: []const u8 = "",
    szDecimals: u32 = 0,
    weiDecimals: u32 = 0,
    isCanonical: ?bool = null,
    evmContract: ?std.json.Value = null,
    fullName: ?[]const u8 = null,
};

pub const SpotMeta = struct {
    tokens: []SpotToken = &.{},
    universe: []SpotPair = &.{},
};

/// Match by `.index` — `tokens` is sparse (delistings leave gaps), so position-based lookup misses.
pub fn findSpotToken(tokens: []const SpotToken, idx: u32) ?*const SpotToken {
    for (tokens) |*t| {
        if (t.index == idx) return t;
    }
    return null;
}

pub const SpotPair = struct {
    name: []const u8 = "",
    tokens: [2]u32 = .{ 0, 0 },
    index: u32 = 0,
    isCanonical: ?bool = null,
};

pub const SpotAssetCtx = struct {
    coin: []const u8 = "",
    markPx: ?[]const u8 = null,
    midPx: ?[]const u8 = null,
    prevDayPx: ?[]const u8 = null,
    dayNtlVlm: ?[]const u8 = null,
    circulatingSupply: ?[]const u8 = null,
    totalSupply: ?[]const u8 = null,
};

// ── Outcomes ──────────────────────────────────────────────────

pub const OutcomeSideSpec = struct {
    name: []const u8 = "",
};

pub const OutcomeInfo = struct {
    outcome: u32 = 0,
    name: []const u8 = "",
    description: []const u8 = "",
    sideSpecs: []OutcomeSideSpec = &.{},
};

pub const OutcomeQuestion = struct {
    question: u32 = 0,
    name: []const u8 = "",
    description: []const u8 = "",
    fallbackOutcome: ?u32 = null,
    namedOutcomes: []u32 = &.{},
    settledNamedOutcomes: []u32 = &.{},
};

pub const OutcomeMeta = struct {
    outcomes: []OutcomeInfo = &.{},
    questions: []OutcomeQuestion = &.{},
};

/// Decoded form of `class:...|underlying:...|expiry:...|targetPrice:...|period:...`.
/// Slices alias the source description — keep it alive for as long as the event.
pub const RecurringEvent = struct {
    class: []const u8,
    underlying: []const u8,
    expiry: []const u8,
    target_price: Decimal,
    period: []const u8,
};

pub fn parseRecurringEvent(description: []const u8) ?RecurringEvent {
    var class: ?[]const u8 = null;
    var underlying: ?[]const u8 = null;
    var expiry: ?[]const u8 = null;
    var target_price_str: ?[]const u8 = null;
    var period: ?[]const u8 = null;

    var parts = std.mem.splitScalar(u8, description, '|');
    while (parts.next()) |part| {
        const colon = std.mem.indexOfScalar(u8, part, ':') orelse return null;
        const key = part[0..colon];
        const value = part[colon + 1 ..];
        if (std.mem.eql(u8, key, "class")) {
            class = value;
        } else if (std.mem.eql(u8, key, "underlying")) {
            underlying = value;
        } else if (std.mem.eql(u8, key, "expiry")) {
            expiry = value;
        } else if (std.mem.eql(u8, key, "targetPrice")) {
            target_price_str = value;
        } else if (std.mem.eql(u8, key, "period")) {
            period = value;
        }
    }

    const target_price = Decimal.fromString(target_price_str orelse return null) catch return null;
    return .{
        .class = class orelse return null,
        .underlying = underlying orelse return null,
        .expiry = expiry orelse return null,
        .target_price = target_price,
        .period = period orelse return null,
    };
}

pub const TokenDetails = struct {
    name: []const u8 = "",
    szDecimals: u32 = 0,
    weiDecimals: u32 = 0,
    midPx: ?[]const u8 = null,
    markPx: ?[]const u8 = null,
    prevDayPx: ?[]const u8 = null,
    maxSupply: ?[]const u8 = null,
    totalSupply: ?[]const u8 = null,
    circulatingSupply: ?[]const u8 = null,
    deployer: ?[]const u8 = null,
    deployTime: ?[]const u8 = null,
    deployGas: ?[]const u8 = null,
    seededUsdc: ?[]const u8 = null,
    fullName: ?[]const u8 = null,
    futureEmissions: ?[]const u8 = null,
};

pub const Dex = struct {
    name: []const u8 = "",
    index: u32 = 0,
};

/// perpDeployAuctionStatus / spotPairDeployAuctionStatus payload.
/// currentGas is null between auction windows; endGas is null while an
/// auction is in progress and the floor hasn't been reached yet.
pub const DeployAuctionStatus = struct {
    startTimeSeconds: u64 = 0,
    durationSeconds: u64 = 0,
    startGas: []const u8 = "",
    currentGas: ?[]const u8 = null,
    endGas: ?[]const u8 = null,
};

pub const DexInfo = struct {
    name: []const u8 = "",
    fullName: ?[]const u8 = null,
    deployer: ?[]const u8 = null,
    deployerFeeScale: ?[]const u8 = null,
    assetToStreamingOiCap: ?[]const std.json.Value = null,
};

pub const ApiAgent = struct {
    name: []const u8 = "",
    address: []const u8 = "",
    validUntil: ?u64 = null,
};

pub const UserRole = struct {
    role: []const u8 = "",
    data: ?std.json.Value = null,

    pub fn isUser(self: UserRole) bool {
        return std.mem.eql(u8, self.role, "user");
    }
    pub fn isAgent(self: UserRole) bool {
        return std.mem.eql(u8, self.role, "agent");
    }
    pub fn isVault(self: UserRole) bool {
        return std.mem.eql(u8, self.role, "vault");
    }
    pub fn isMissing(self: UserRole) bool {
        return std.mem.eql(u8, self.role, "missing");
    }
};

pub const MultiSigConfig = struct {
    authorizedUsers: ?[]const std.json.Value = null,
    threshold: u32 = 0,
};

pub const UserVaultEquity = struct {
    vaultAddress: []const u8 = "",
    equity: ?Decimal = null,
    lockedUntilTimestamp: ?u64 = null,
};

pub const SubAccount = struct {
    name: []const u8 = "",
    subAccountUser: []const u8 = "",
    master: []const u8 = "",
    clearinghouseState: ?ClearinghouseState = null,
};

pub const VaultDetails = struct {
    name: []const u8 = "",
    vaultAddress: []const u8 = "",
    leader: []const u8 = "",
    description: []const u8 = "",
    apr: ?Decimal = null,
};

pub const WsBasicOrder = struct {
    coin: []const u8 = "",
    side: []const u8 = "",
    limitPx: Decimal = Decimal.ZERO,
    sz: Decimal = Decimal.ZERO,
    oid: u64 = 0,
    timestamp: u64 = 0,
    origSz: ?Decimal = null,
};

pub const OrderUpdate = struct {
    order: BasicOrder = .{},
    status: []const u8 = "",
    statusTimestamp: u64 = 0,
};

pub const UserLiquidation = struct {
    lid: u64 = 0,
    liquidator: []const u8 = "",
    liquidated_user: []const u8 = "",
    liquidated_ntl_pos: ?Decimal = null,
    liquidated_account_value: ?Decimal = null,
};

pub const NonUserCancel = struct {
    coin: []const u8 = "",
    oid: u64 = 0,
};

pub const Liquidation = struct {
    lid: u64 = 0,
    liquidator: []const u8 = "",
    liquidated_user: []const u8 = "",
    liquidated_ntl_pos: ?Decimal = null,
    liquidated_account_value: ?Decimal = null,
};

// ── User Fees / Rate Limit ────────────────────────────────────

pub const UserFees = struct {
    activeReferralDiscount: ?Decimal = null,
    dailyUserVlm: ?[]DailyUserVlm = null,
    feeSchedule: ?FeeSchedule = null,
    userCrossRate: ?Decimal = null,
    userAddRate: ?Decimal = null,
    readiness: ?[]const u8 = null,
};

pub const DailyUserVlm = struct {
    date: []const u8 = "",
    userCross: ?Decimal = null,
    userAdd: ?Decimal = null,
    exchange: ?Decimal = null,
};

pub const FeeSchedule = struct {
    cross: ?[]FeeTier = null,
    add: ?[]FeeTier = null,
};

pub const FeeTier = struct {
    minVlm: ?Decimal = null,
    rate: ?Decimal = null,
};

pub const UserRateLimit = struct {
    cumVlm: ?Decimal = null,
    nRequestsUsed: ?u64 = null,
    nRequestsCap: ?u64 = null,
};

// ── Staking Types ─────────────────────────────────────────────

pub const DelegatorSummary = struct {
    delegated: ?Decimal = null,
    undelegating: ?Decimal = null,
    totalRewards: ?Decimal = null,
    pendingRewards: ?Decimal = null,
    nValidators: ?u32 = null,
};

pub const Delegation = struct {
    validator: []const u8 = "",
    amount: ?Decimal = null,
    lockedUntil: ?u64 = null,
};

pub const DelegatorReward = struct {
    validator: []const u8 = "",
    amount: ?Decimal = null,
    source: ?[]const u8 = null,
};

pub const DelegatorHistoryEntry = struct {
    time: u64 = 0,
    delta: ?std.json.Value = null,
    hash: ?[]const u8 = null,
};

// ── Borrow/Lend Types ─────────────────────────────────────────

pub const BorrowLendPosition = struct {
    coin: []const u8 = "",
    amount: ?Decimal = null,
    entryRate: ?Decimal = null,
    type: []const u8 = "",
};

pub const BorrowLendUserState = struct {
    positions: ?[]BorrowLendPosition = null,
};

// ── Nonce Handler ─────────────────────────────────────────────

pub const NonceHandler = struct {
    nonce: std.atomic.Value(u64),

    pub fn init() NonceHandler {
        const now = runtime.nonceMs();
        return .{ .nonce = std.atomic.Value(u64).init(now) };
    }

    pub fn next(self: *NonceHandler) u64 {
        const now = runtime.nonceMs();
        var current = self.nonce.load(.acquire);
        while (true) {
            const new_val = @max(current + 1, now);
            if (self.nonce.cmpxchgWeak(current, new_val, .release, .acquire)) |old| {
                current = old;
            } else {
                return new_val;
            }
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────

test "ClearinghouseState auto-parse" {
    const body =
        \\{"marginSummary":{"accountValue":"10000","totalNtlPos":"5000","totalRawUsd":"10000","totalMarginUsed":"500"},"crossMarginSummary":{"accountValue":"10000","totalNtlPos":"5000","totalRawUsd":"10000","totalMarginUsed":"500"},"withdrawable":"9500","crossMaintenanceMarginUsed":"250","assetPositions":[],"time":1690000000000}
    ;
    const parsed = try std.json.parseFromSlice(ClearinghouseState, std.testing.allocator, body, ParseOpts);
    defer parsed.deinit();
    const s = parsed.value;
    try std.testing.expectEqual(@as(u64, 1690000000000), s.time);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("10000", try s.marginSummary.accountValue.toString(&buf));
    try std.testing.expectEqualStrings("500", try s.marginSummary.totalMarginUsed.toString(&buf));
    try std.testing.expectEqualStrings("9500", try s.withdrawable.toString(&buf));
}

test "Fill auto-parse" {
    const body =
        \\{"coin":"BTC","px":"50000.5","sz":"0.1","side":"B","time":1690000000000,"startPosition":"0","dir":"Open Long","closedPnl":"0","hash":"0xabc","oid":12345,"crossed":true,"fee":"0.5","tid":99,"feeToken":"USDC"}
    ;
    const parsed = try std.json.parseFromSlice(Fill, std.testing.allocator, body, ParseOpts);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("BTC", parsed.value.coin);
    try std.testing.expectEqual(@as(u64, 12345), parsed.value.oid);
    try std.testing.expectEqual(true, parsed.value.crossed);
}

test "parseRecurringEvent: full description" {
    const desc = "class:priceBinary|underlying:BTC|expiry:20260317-0300|targetPrice:74212|period:1d";
    const ev = parseRecurringEvent(desc) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("priceBinary", ev.class);
    try std.testing.expectEqualStrings("BTC", ev.underlying);
    try std.testing.expectEqualStrings("20260317-0300", ev.expiry);
    try std.testing.expectEqualStrings("1d", ev.period);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("74212", try ev.target_price.toString(&buf));
}

test "parseRecurringEvent: free-text returns null" {
    try std.testing.expect(parseRecurringEvent("What will Hypurr eat?") == null);
}

test "parseRecurringEvent: missing key returns null" {
    const desc = "class:priceBinary|underlying:BTC|expiry:20260317-0300|targetPrice:74212";
    try std.testing.expect(parseRecurringEvent(desc) == null);
}

test "parseOneOrderStatus waitingForTrigger and waitingForFill" {
    const trigger = std.json.Value{ .string = "waitingForTrigger" };
    try std.testing.expect(parseOneOrderStatus(trigger) == .waitingForTrigger);
    const fill = std.json.Value{ .string = "waitingForFill" };
    try std.testing.expect(parseOneOrderStatus(fill) == .waitingForFill);
}

test "BasicOrder auto-parse" {
    const body =
        \\{"coin":"ETH","side":"A","limitPx":"9000.0","sz":"0.01","oid":331815070150,"timestamp":1772184984390,"triggerCondition":"N/A","isTrigger":false,"triggerPx":"0.0","children":[],"isPositionTpsl":false,"reduceOnly":false,"orderType":"Limit","origSz":"0.01","tif":"Gtc","cloid":"0x0000019c9e74d69c0000000000000000"}
    ;
    const parsed = try std.json.parseFromSlice(BasicOrder, std.testing.allocator, body, ParseOpts);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ETH", parsed.value.coin);
    try std.testing.expectEqualStrings("A", parsed.value.side);
    try std.testing.expectEqual(@as(u64, 331815070150), parsed.value.oid);
}

test "HistoricalOrder auto-parse" {
    const body =
        \\{"order":{"coin":"ETH","side":"A","limitPx":"9000.0","sz":"0.01","oid":331815070150,"timestamp":1772184984390,"triggerCondition":"N/A","isTrigger":false,"triggerPx":"0.0","children":[],"isPositionTpsl":false,"reduceOnly":false,"orderType":"Limit","origSz":"0.01","tif":"Gtc","cloid":"0x0000019c9e74d69c0000000000000000"},"status":"perpMarginRejected","statusTimestamp":1772184984390}
    ;
    const parsed = try std.json.parseFromSlice(HistoricalOrder, std.testing.allocator, body, ParseOpts);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ETH", parsed.value.order.coin);
    try std.testing.expectEqualStrings("perpMarginRejected", parsed.value.status);
    try std.testing.expectEqual(@as(u64, 1772184984390), parsed.value.statusTimestamp);
}

test "UserFunding auto-parse" {
    const body =
        \\{"time":1772186400074,"hash":"0x0000","delta":{"type":"funding","coin":"BTC","usdc":"-0.004885","szi":"0.0058","fundingRate":"0.0000125","nSamples":null}}
    ;
    const parsed = try std.json.parseFromSlice(UserFunding, std.testing.allocator, body, ParseOpts);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 1772186400074), parsed.value.time);
    try std.testing.expectEqualStrings("BTC", parsed.value.delta.coin);
}

test "SpotToken auto-parse" {
    const body =
        \\{"name":"PURR","index":1,"szDecimals":0,"weiDecimals":18}
    ;
    const parsed = try std.json.parseFromSlice(SpotToken, std.testing.allocator, body, ParseOpts);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("PURR", parsed.value.name);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.index);
}

test "OutcomeMeta auto-parse" {
    const body =
        \\{"outcomes":[{"outcome":1273,"name":"Recurring","description":"class:priceBinary|underlying:BTC|expiry:20260317-0300|targetPrice:74212|period:1d","sideSpecs":[{"name":"Yes"},{"name":"No"}]}],"questions":[{"question":1,"name":"What will Hypurr eat?","description":"Food journal.","fallbackOutcome":13,"namedOutcomes":[10,11,12],"settledNamedOutcomes":[]}]}
    ;
    const parsed = try std.json.parseFromSlice(OutcomeMeta, std.testing.allocator, body, ParseOpts);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.outcomes.len);
    try std.testing.expectEqual(@as(u32, 1273), parsed.value.outcomes[0].outcome);
    try std.testing.expectEqualStrings("Recurring", parsed.value.outcomes[0].name);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.outcomes[0].sideSpecs.len);
    try std.testing.expectEqualStrings("Yes", parsed.value.outcomes[0].sideSpecs[0].name);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.questions.len);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.questions[0].question);
    try std.testing.expectEqual(@as(usize, 3), parsed.value.questions[0].namedOutcomes.len);
}

test "parseResponseStatus" {
    const ok_json =
        \\{"status":"ok","response":{"type":"default"}}
    ;
    var parsed = try json.parse(std.testing.allocator, ok_json);
    defer parsed.deinit();
    try std.testing.expectEqual(ResponseStatus.ok, parseResponseStatus(parsed.value));
}

test "NonceHandler: monotonic" {
    var handler = NonceHandler.init();
    const n1 = handler.next();
    const n2 = handler.next();
    const n3 = handler.next();
    try std.testing.expect(n2 > n1);
    try std.testing.expect(n3 > n2);
}
