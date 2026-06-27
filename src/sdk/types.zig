//! Hyperliquid API types and MessagePack serialization.
//! Byte-identical to Rust SDK's rmp-serde output.

const std = @import("std");
const msgpack = @import("../lib/encoding/msgpack.zig");
const Decimal = @import("../lib/math/decimal.zig").Decimal;


/// B128 client order ID, serialized as "0x" + 32 hex chars.
pub const Cloid = [16]u8;

pub const ZERO_CLOID: Cloid = [_]u8{0} ** 16;

/// Format a Cloid as "0x" + 32 lowercase hex chars.
pub fn cloidToHex(cloid: Cloid) [34]u8 {
    var buf: [34]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    for (cloid, 0..) |byte, i| {
        const hex = "0123456789abcdef";
        buf[2 + i * 2] = hex[byte >> 4];
        buf[2 + i * 2 + 1] = hex[byte & 0x0f];
    }
    return buf;
}


pub const Side = enum {
    Buy,
    Sell,

    pub fn isBuy(self: Side) bool {
        return self == .Buy;
    }
};

/// Time in force — PascalCase serialization (matching Rust's #[serde(rename = "PascalCase")])
pub const TimeInForce = enum { Alo, Ioc, Gtc, FrontendMarket };
pub const TpSl = enum { tp, sl };
pub const OrderGrouping = enum { na, normalTpsl, positionTpsl };


/// Order type placement — serialized as tagged union.
pub const OrderTypePlacement = union(enum) {
    limit: struct { tif: TimeInForce },
    trigger: struct {
        is_market: bool,
        trigger_px: Decimal,
        tpsl: TpSl,
    },
};

/// A single order request.
/// Fields use single-letter serde renames: a, b, p, s, r, t, c
pub const OrderRequest = struct {
    asset: usize,
    is_buy: bool,
    limit_px: Decimal,
    sz: Decimal,
    reduce_only: bool,
    order_type: OrderTypePlacement,
    cloid: Cloid,
};

/// Serialized as `{"b": <address>, "f": <tenths_of_bps>}`. One tenth of a basis point = 0.0001%.
pub const BuilderInfo = struct {
    address: [20]u8,
    fee_tenths_bps: u32,
};

/// Batch of orders to place.
pub const BatchOrder = struct {
    orders: []const OrderRequest,
    grouping: OrderGrouping,
    builder: ?BuilderInfo = null,
};

/// Cancel a single order by exchange-assigned ID.
pub const Cancel = struct {
    asset: usize,
    oid: u64,
};

/// Cancel a single order by client ID.
pub const CancelByCloid = struct {
    asset: usize,
    cloid: Cloid,
};

pub const BatchCancel = struct {
    cancels: []const Cancel,
};

pub const BatchCancelCloid = struct {
    cancels: []const CancelByCloid,
};

pub const ScheduleCancel = struct {
    time: ?u64,
};

pub const UpdateIsolatedMargin = struct {
    asset: usize,
    is_buy: bool,
    ntli: u64,
};

pub const UpdateLeverage = struct {
    asset: usize,
    is_cross: bool,
    leverage: u32,
};

pub const SetReferrer = struct {
    code: []const u8,
};

/// Either a numeric OID or a Cloid.
pub const OidOrCloid = union(enum) {
    oid: u64,
    cloid: Cloid,
};

/// Modification of an existing order.
pub const Modify = struct {
    oid: OidOrCloid,
    order: OrderRequest,
};

pub const BatchModify = struct {
    modifies: []const Modify,
};

/// Agent-signed self-transfer. Destination must equal source — enforced by the exchange.
pub const AgentSendAsset = struct {
    destination: [20]u8,
    source_dex: []const u8,
    destination_dex: []const u8,
    token: []const u8,
    amount: []const u8,
    from_sub_account: []const u8,
    nonce: u64,
};

// These are NOT msgpack-serialized — they go through EIP-712 typed data signing.
// But they ARE JSON-serialized for the exchange endpoint.

pub const UsdSendParams = struct {
    destination: []const u8, // lowercase hex "0x..."
    amount: []const u8, // decimal string
    time: u64,
};

pub const SpotSendParams = struct {
    destination: []const u8,
    token: []const u8, // token name like "PURR" or index string
    amount: []const u8,
    time: u64,
};

pub const SendAssetParams = struct {
    destination: []const u8,
    source_dex: []const u8, // "Perp" or "Spot" or dex name
    destination_dex: []const u8,
    token: []const u8,
    amount: []const u8,
    from_sub_account: []const u8,
    nonce: u64,
};

pub const ApproveAgentParams = struct {
    agent_address: []const u8, // lowercase hex
    agent_name: ?[]const u8, // null for unnamed
    nonce: u64,
};

pub const ConvertToMultiSigParams = struct {
    authorized_users: []const []const u8, // list of address hex strings
    threshold: usize,
    nonce: u64,
};

// These functions produce byte-exact output matching rmp-serde::to_vec_named.
// The Rust SDK uses serde field renames, so we must match them exactly.

/// Pack an OrderRequest to msgpack with single-letter field names.
pub fn packOrderRequest(p: *msgpack.Packer, order: OrderRequest) msgpack.PackError!void {
    const is_zero_cloid = std.mem.eql(u8, &order.cloid, &ZERO_CLOID);
    try p.packMapHeader(if (is_zero_cloid) 6 else 7); // omit "c" when cloid is zero

    // a: asset
    try p.packStr("a");
    try p.packUint(@intCast(order.asset));

    // b: is_buy
    try p.packStr("b");
    try p.packBool(order.is_buy);

    // p: limit_px (normalized decimal string)
    try p.packStr("p");
    var px_buf: [64]u8 = undefined;
    const px_str = order.limit_px.normalize().toString(&px_buf) catch return error.BufferOverflow;
    try p.packStr(px_str);

    // s: sz (normalized decimal string)
    try p.packStr("s");
    var sz_buf: [64]u8 = undefined;
    const sz_str = order.sz.normalize().toString(&sz_buf) catch return error.BufferOverflow;
    try p.packStr(sz_str);

    // r: reduce_only
    try p.packStr("r");
    try p.packBool(order.reduce_only);

    // t: order_type (tagged union)
    try p.packStr("t");
    switch (order.order_type) {
        .limit => |lim| {
            try p.packMapHeader(1);
            try p.packStr("limit");
            try p.packMapHeader(1);
            try p.packStr("tif");
            try p.packStr(@tagName(lim.tif));
        },
        .trigger => |trig| {
            try p.packMapHeader(1);
            try p.packStr("trigger");
            try p.packMapHeader(3);
            try p.packStr("isMarket");
            try p.packBool(trig.is_market);
            try p.packStr("triggerPx");
            var tpx_buf: [64]u8 = undefined;
            const tpx_str = trig.trigger_px.normalize().toString(&tpx_buf) catch return error.BufferOverflow;
            try p.packStr(tpx_str);
            try p.packStr("tpsl");
            try p.packStr(@tagName(trig.tpsl));
        },
    }

    // c: cloid (hex string) — omit when zero to match server hashing
    if (!is_zero_cloid) {
        try p.packStr("c");
        const cloid_hex = cloidToHex(order.cloid);
        try p.packStr(&cloid_hex);
    }
}

/// Pack a BatchOrder to msgpack.
pub fn packBatchOrder(p: *msgpack.Packer, batch: BatchOrder) msgpack.PackError!void {
    const map_size: u32 = if (batch.builder != null) 3 else 2;
    try p.packMapHeader(map_size);

    // orders: array of OrderRequest
    try p.packStr("orders");
    try p.packArrayHeader(@intCast(batch.orders.len));
    for (batch.orders) |order| {
        try packOrderRequest(p, order);
    }

    // grouping: enum string
    try p.packStr("grouping");
    try p.packStr(@tagName(batch.grouping));

    if (batch.builder) |bi| {
        try p.packStr("builder");
        try packBuilderInfo(p, bi);
    }
}

fn packBuilderInfo(p: *msgpack.Packer, bi: BuilderInfo) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("b");
    var addr_buf: [42]u8 = undefined;
    const addr_str = addressToHexLower(bi.address, &addr_buf);
    try p.packStr(addr_str);
    try p.packStr("f");
    try p.packUint(@intCast(bi.fee_tenths_bps));
}

fn addressToHexLower(addr: [20]u8, buf: *[42]u8) []const u8 {
    buf[0] = '0';
    buf[1] = 'x';
    const hex = "0123456789abcdef";
    for (addr, 0..) |b, i| {
        buf[2 + i * 2] = hex[b >> 4];
        buf[2 + i * 2 + 1] = hex[b & 0x0f];
    }
    return buf[0..42];
}

/// Pack a Cancel to msgpack.
pub fn packCancel(p: *msgpack.Packer, cancel: Cancel) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("a");
    try p.packUint(@intCast(cancel.asset));
    try p.packStr("o");
    try p.packUint(cancel.oid);
}

/// Pack a BatchCancel to msgpack.
pub fn packBatchCancel(p: *msgpack.Packer, batch: BatchCancel) msgpack.PackError!void {
    try p.packMapHeader(1);
    try p.packStr("cancels");
    try p.packArrayHeader(@intCast(batch.cancels.len));
    for (batch.cancels) |cancel| {
        try packCancel(p, cancel);
    }
}

// The Rust SDK uses #[serde(tag = "type")] on the Action enum.
// This means msgpack output includes a "type" field with the variant name.

/// Action tags matching Rust's serde tag names (camelCase).
pub const ActionTag = enum {
    order,
    batchModify,
    cancel,
    cancelByCloid,
    scheduleCancel,
    usdSend,
    sendAsset,
    spotSend,
    evmUserModify,
    approveAgent,
    convertToMultiSigUser,
    updateIsolatedMargin,
    updateLeverage,
    setReferrer,
    multiSig,
    noop,
    vaultTransfer,
    createSubAccount,
    subAccountTransfer,
    subAccountSpotTransfer,
    twapOrder,
    twapCancel,
    spotDeploy,
    perpDeploy,
    CSignerAction,
    CValidatorAction,
    agentEnableDexAbstraction,
    agentSetAbstraction,
    agentSendAsset,
};

/// Pack an Action::Order to msgpack (with serde tag = "type").
/// Output: {"type": "order", "orders": [...], "grouping": "na", "builder"?: {...}}
pub fn packActionOrder(p: *msgpack.Packer, batch: BatchOrder) msgpack.PackError!void {
    const map_size: u32 = if (batch.builder != null) 4 else 3;
    try p.packMapHeader(map_size);

    // type: "order"
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.order));

    // orders: array
    try p.packStr("orders");
    try p.packArrayHeader(@intCast(batch.orders.len));
    for (batch.orders) |order| {
        try packOrderRequest(p, order);
    }

    // grouping: enum string
    try p.packStr("grouping");
    try p.packStr(@tagName(batch.grouping));

    if (batch.builder) |bi| {
        try p.packStr("builder");
        try packBuilderInfo(p, bi);
    }
}

/// Pack an Action::Cancel to msgpack (with serde tag).
pub fn packActionCancel(p: *msgpack.Packer, batch: BatchCancel) msgpack.PackError!void {
    try p.packMapHeader(2); // type + cancels

    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.cancel));

    try p.packStr("cancels");
    try p.packArrayHeader(@intCast(batch.cancels.len));
    for (batch.cancels) |cancel| {
        try packCancel(p, cancel);
    }
}

/// Pack a CancelByCloid to msgpack.
fn packCancelByCloid(p: *msgpack.Packer, cancel: CancelByCloid) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("asset");
    try p.packUint(@intCast(cancel.asset));
    try p.packStr("cloid");
    const hex = cloidToHex(cancel.cloid);
    try p.packStr(&hex);
}

/// Pack an Action::CancelByCloid to msgpack (with serde tag).
pub fn packActionCancelByCloid(p: *msgpack.Packer, batch: BatchCancelCloid) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.cancelByCloid));
    try p.packStr("cancels");
    try p.packArrayHeader(@intCast(batch.cancels.len));
    for (batch.cancels) |cancel| {
        try packCancelByCloid(p, cancel);
    }
}

/// Pack a Modify to msgpack.
fn packModify(p: *msgpack.Packer, modify: Modify) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("oid");
    switch (modify.oid) {
        .oid => |oid| try p.packUint(oid),
        .cloid => |cloid| {
            const hex = cloidToHex(cloid);
            try p.packStr(&hex);
        },
    }
    try p.packStr("order");
    try packOrderRequest(p, modify.order);
}

/// Pack an Action::BatchModify to msgpack (with serde tag).
pub fn packActionBatchModify(p: *msgpack.Packer, batch: BatchModify) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.batchModify));
    try p.packStr("modifies");
    try p.packArrayHeader(@intCast(batch.modifies.len));
    for (batch.modifies) |modify| {
        try packModify(p, modify);
    }
}

/// Pack an Action::ScheduleCancel to msgpack (with serde tag).
pub fn packActionScheduleCancel(p: *msgpack.Packer, sc: ScheduleCancel) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.scheduleCancel));
    try p.packStr("time");
    if (sc.time) |t| {
        try p.packUint(t);
    } else {
        try p.packNil();
    }
}

/// Pack an Action::UpdateIsolatedMargin to msgpack (with serde tag).
pub fn packActionUpdateIsolatedMargin(p: *msgpack.Packer, uim: UpdateIsolatedMargin) msgpack.PackError!void {
    try p.packMapHeader(4);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.updateIsolatedMargin));
    try p.packStr("asset");
    try p.packUint(@intCast(uim.asset));
    try p.packStr("isBuy");
    try p.packBool(uim.is_buy);
    try p.packStr("ntli");
    try p.packUint(uim.ntli);
}

/// Pack an Action::UpdateLeverage to msgpack (with serde tag).
pub fn packActionUpdateLeverage(p: *msgpack.Packer, ul: UpdateLeverage) msgpack.PackError!void {
    try p.packMapHeader(4);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.updateLeverage));
    try p.packStr("asset");
    try p.packUint(@intCast(ul.asset));
    try p.packStr("isCross");
    try p.packBool(ul.is_cross);
    try p.packStr("leverage");
    try p.packUint(@intCast(ul.leverage));
}

/// Pack an Action::SetReferrer to msgpack (with serde tag).
pub fn packActionSetReferrer(p: *msgpack.Packer, sr: SetReferrer) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.setReferrer));
    try p.packStr("code");
    try p.packStr(sr.code);
}

/// Pack an Action::EvmUserModify to msgpack (with serde tag).
pub fn packActionEvmUserModify(p: *msgpack.Packer, using_big_blocks: bool) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.evmUserModify));
    try p.packStr("usingBigBlocks");
    try p.packBool(using_big_blocks);
}

/// Pack an Action::Noop to msgpack (with serde tag).
pub fn packActionNoop(p: *msgpack.Packer) msgpack.PackError!void {
    try p.packMapHeader(1);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.noop));
}

/// Pack an Action::AgentSendAsset to msgpack (with serde tag).
pub fn packActionAgentSendAsset(p: *msgpack.Packer, asa: AgentSendAsset) msgpack.PackError!void {
    try p.packMapHeader(8); // type + 7 fields
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.agentSendAsset));
    try p.packStr("destination");
    var addr_buf: [42]u8 = undefined;
    const addr_str = addressToHexLower(asa.destination, &addr_buf);
    try p.packStr(addr_str);
    try p.packStr("sourceDex");
    try p.packStr(asa.source_dex);
    try p.packStr("destinationDex");
    try p.packStr(asa.destination_dex);
    try p.packStr("token");
    try p.packStr(asa.token);
    try p.packStr("amount");
    try p.packStr(asa.amount);
    try p.packStr("fromSubAccount");
    try p.packStr(asa.from_sub_account);
    try p.packStr("nonce");
    try p.packUint(asa.nonce);
}

// ── Account & Transfer Actions ────────────────────────────────

pub const VaultTransfer = struct {
    vault_address: []const u8,
    is_deposit: bool,
    usd: u64,
};

pub const CreateSubAccount = struct {
    name: []const u8,
};

pub const SubAccountTransfer = struct {
    sub_account_user: []const u8,
    is_deposit: bool,
    usd: u64,
};

pub const SubAccountSpotTransfer = struct {
    sub_account_user: []const u8,
    is_deposit: bool,
    token: []const u8,
    amount: []const u8,
};

pub const TwapOrder = struct {
    asset: usize,
    is_buy: bool,
    sz: Decimal,
    reduce_only: bool,
    duration_min: u64,
    randomize: bool,
};

pub const TwapCancel = struct {
    asset: usize,
    twap_id: u64,
};

/// Pack an Action::VaultTransfer to msgpack (with serde tag).
pub fn packActionVaultTransfer(p: *msgpack.Packer, vt: VaultTransfer) msgpack.PackError!void {
    try p.packMapHeader(4);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.vaultTransfer));
    try p.packStr("vaultAddress");
    try p.packStr(vt.vault_address);
    try p.packStr("isDeposit");
    try p.packBool(vt.is_deposit);
    try p.packStr("usd");
    try p.packUint(vt.usd);
}

/// Pack an Action::CreateSubAccount to msgpack (with serde tag).
pub fn packActionCreateSubAccount(p: *msgpack.Packer, csa: CreateSubAccount) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.createSubAccount));
    try p.packStr("name");
    try p.packStr(csa.name);
}

/// Pack an Action::SubAccountTransfer to msgpack (with serde tag).
pub fn packActionSubAccountTransfer(p: *msgpack.Packer, sat: SubAccountTransfer) msgpack.PackError!void {
    try p.packMapHeader(4);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.subAccountTransfer));
    try p.packStr("subAccountUser");
    try p.packStr(sat.sub_account_user);
    try p.packStr("isDeposit");
    try p.packBool(sat.is_deposit);
    try p.packStr("usd");
    try p.packUint(sat.usd);
}

/// Pack an Action::SubAccountSpotTransfer to msgpack (with serde tag).
pub fn packActionSubAccountSpotTransfer(p: *msgpack.Packer, sst: SubAccountSpotTransfer) msgpack.PackError!void {
    try p.packMapHeader(5);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.subAccountSpotTransfer));
    try p.packStr("subAccountUser");
    try p.packStr(sst.sub_account_user);
    try p.packStr("isDeposit");
    try p.packBool(sst.is_deposit);
    try p.packStr("token");
    try p.packStr(sst.token);
    try p.packStr("amount");
    try p.packStr(sst.amount);
}

/// Pack an Action::TwapOrder to msgpack (with serde tag).
pub fn packActionTwapOrder(p: *msgpack.Packer, tw: TwapOrder) msgpack.PackError!void {
    try p.packMapHeader(2); // {type, twap}
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.twapOrder));
    try p.packStr("twap");
    try p.packMapHeader(6); // {a, b, s, r, m, t}
    try p.packStr("a");
    try p.packUint(@intCast(tw.asset));
    try p.packStr("b");
    try p.packBool(tw.is_buy);
    try p.packStr("s");
    var sz_buf: [64]u8 = undefined;
    const sz_str = tw.sz.normalize().toString(&sz_buf) catch return error.BufferOverflow;
    try p.packStr(sz_str);
    try p.packStr("r");
    try p.packBool(tw.reduce_only);
    try p.packStr("m");
    try p.packUint(tw.duration_min);
    try p.packStr("t");
    try p.packBool(tw.randomize);
}

/// Pack an Action::TwapCancel to msgpack (with serde tag).
pub fn packActionTwapCancel(p: *msgpack.Packer, tc: TwapCancel) msgpack.PackError!void {
    try p.packMapHeader(3);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.twapCancel));
    try p.packStr("a");
    try p.packUint(@intCast(tc.asset));
    try p.packStr("t");
    try p.packUint(tc.twap_id);
}

// ── Spot Deploy Actions ───────────────────────────────────────

pub const SpotDeployRegisterToken = struct {
    name: []const u8,
    sz_decimals: u32,
    wei_decimals: u32,
    max_gas: u64,
    full_name: []const u8,
};

pub fn packActionSpotDeployRegisterToken(p: *msgpack.Packer, rt: SpotDeployRegisterToken) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("spotDeploy");
    try p.packStr("registerToken2");
    try p.packMapHeader(3);
    try p.packStr("spec");
    try p.packMapHeader(3);
    try p.packStr("name");
    try p.packStr(rt.name);
    try p.packStr("szDecimals");
    try p.packUint(@intCast(rt.sz_decimals));
    try p.packStr("weiDecimals");
    try p.packUint(@intCast(rt.wei_decimals));
    try p.packStr("maxGas");
    try p.packUint(rt.max_gas);
    try p.packStr("fullName");
    try p.packStr(rt.full_name);
}

pub const SpotDeployGenesis = struct {
    token: u32,
    max_supply: []const u8,
    no_hyperliquidity: bool,
};

pub fn packActionSpotDeployGenesis(p: *msgpack.Packer, g: SpotDeployGenesis) msgpack.PackError!void {
    const n_fields: u32 = if (g.no_hyperliquidity) 3 else 2;
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("spotDeploy");
    try p.packStr("genesis");
    try p.packMapHeader(n_fields);
    try p.packStr("token");
    try p.packUint(@intCast(g.token));
    try p.packStr("maxSupply");
    try p.packStr(g.max_supply);
    if (g.no_hyperliquidity) {
        try p.packStr("noHyperliquidity");
        try p.packBool(true);
    }
}

pub const SpotDeployExistingTokenWei = struct {
    token: u32,
    wei: []const u8,
};

pub const SpotDeployUserGenesis = struct {
    token: u32,
    user_and_wei: []const [2][]const u8, // [[addr, wei], ...]
    existing_token_and_wei: []const SpotDeployExistingTokenWei,
};

/// Pack a spotDeploy userGenesis action.
/// Caller must pass lowercase hex addresses in `user_and_wei` pairs  — exchange expects lowercase hex.
pub fn packActionSpotDeployUserGenesis(p: *msgpack.Packer, ug: SpotDeployUserGenesis) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("spotDeploy");
    try p.packStr("userGenesis");
    try p.packMapHeader(3);
    try p.packStr("token");
    try p.packUint(@intCast(ug.token));
    try p.packStr("userAndWei");
    try p.packArrayHeader(@intCast(ug.user_and_wei.len));
    for (ug.user_and_wei) |pair| {
        try p.packArrayHeader(2);
        try p.packStr(pair[0]);
        try p.packStr(pair[1]);
    }
    try p.packStr("existingTokenAndWei");
    try p.packArrayHeader(@intCast(ug.existing_token_and_wei.len));
    for (ug.existing_token_and_wei) |pair| {
        try p.packArrayHeader(2);
        try p.packUint(@intCast(pair.token));
        try p.packStr(pair.wei);
    }
}

pub const SpotDeployRegisterSpot = struct {
    base_token: u32,
    quote_token: u32,
};

pub fn packActionSpotDeployRegisterSpot(p: *msgpack.Packer, rs: SpotDeployRegisterSpot) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("spotDeploy");
    try p.packStr("registerSpot");
    try p.packMapHeader(1);
    try p.packStr("tokens");
    try p.packArrayHeader(2);
    try p.packUint(@intCast(rs.base_token));
    try p.packUint(@intCast(rs.quote_token));
}

pub const SpotDeployRegisterHyperliquidity = struct {
    spot: u32,
    start_px: []const u8,
    order_sz: []const u8,
    n_orders: u32,
    n_seeded_levels: ?u32,
};

pub fn packActionSpotDeployRegisterHyperliquidity(p: *msgpack.Packer, rh: SpotDeployRegisterHyperliquidity) msgpack.PackError!void {
    const n_fields: u32 = if (rh.n_seeded_levels != null) 5 else 4;
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("spotDeploy");
    try p.packStr("registerHyperliquidity");
    try p.packMapHeader(n_fields);
    try p.packStr("spot");
    try p.packUint(@intCast(rh.spot));
    try p.packStr("startPx");
    try p.packStr(rh.start_px);
    try p.packStr("orderSz");
    try p.packStr(rh.order_sz);
    try p.packStr("nOrders");
    try p.packUint(@intCast(rh.n_orders));
    if (rh.n_seeded_levels) |n| {
        try p.packStr("nSeededLevels");
        try p.packUint(@intCast(n));
    }
}

/// Simple token action: enableFreezePrivilege, revokeFreezePrivilege, enableQuoteToken
pub fn packActionSpotDeployTokenAction(p: *msgpack.Packer, variant: []const u8, token: u32) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("spotDeploy");
    try p.packStr(variant);
    try p.packMapHeader(1);
    try p.packStr("token");
    try p.packUint(@intCast(token));
}

/// Pack a spotDeploy freezeUser action.
/// Caller must pass lowercase hex address for `user`  — exchange expects lowercase hex.
pub fn packActionSpotDeployFreezeUser(p: *msgpack.Packer, token: u32, user: []const u8, freeze: bool) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("spotDeploy");
    try p.packStr("freezeUser");
    try p.packMapHeader(3);
    try p.packStr("token");
    try p.packUint(@intCast(token));
    try p.packStr("user");
    try p.packStr(user);
    try p.packStr("freeze");
    try p.packBool(freeze);
}

pub fn packActionSpotDeploySetTradingFeeShare(p: *msgpack.Packer, token: u32, share: []const u8) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("spotDeploy");
    try p.packStr("setDeployerTradingFeeShare");
    try p.packMapHeader(2);
    try p.packStr("token");
    try p.packUint(@intCast(token));
    try p.packStr("share");
    try p.packStr(share);
}

// ── EVM Contract Linking (HyperCore <-> HyperEVM) ─────────────

/// Links a HIP-1 spot token to a HyperEVM ERC-20 so the two can be bridged.
/// `evm_extra_wei_decimals` is the EVM weiDecimals minus the Core weiDecimals
/// (range [-2, 18]); it can be negative, so it packs as a signed int.
pub const SpotDeployRequestEvmContract = struct {
    token: u32,
    /// The ERC-20 contract address on HyperEVM. Must be lowercase hex ("0x…")
    /// — the exchange signs over these bytes, so mixed-case breaks the link.
    address: []const u8,
    evm_extra_wei_decimals: i8,
};

/// requestEvmContract is nested in spotDeploy (like registerToken2), sent by
/// the Core spot deployer.
pub fn packActionSpotDeployRequestEvmContract(p: *msgpack.Packer, r: SpotDeployRequestEvmContract) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("spotDeploy");
    try p.packStr("requestEvmContract");
    try p.packMapHeader(3);
    try p.packStr("token");
    try p.packUint(@intCast(r.token));
    try p.packStr("address");
    try p.packStr(r.address);
    try p.packStr("evmExtraWeiDecimals");
    try p.packInt(@intCast(r.evm_extra_wei_decimals));
}

/// Proof of control over the EVM contract, used to finalize a link:
/// `create` carries the nonce that deployed the contract (EOA case); the
/// storage-slot variants cover contract-deployed ERC-20s (e.g. create2).
pub const FinalizeEvmContractInput = union(enum) {
    create: u64,
    first_storage_slot,
    custom_storage_slot,
};

/// finalizeEvmContract is a TOP-LEVEL action (not nested in spotDeploy),
/// sent by the EVM contract's deployer to confirm the link.
pub fn packActionFinalizeEvmContract(p: *msgpack.Packer, token: u32, input: FinalizeEvmContractInput) msgpack.PackError!void {
    try p.packMapHeader(3);
    try p.packStr("type");
    try p.packStr("finalizeEvmContract");
    try p.packStr("token");
    try p.packUint(@intCast(token));
    try p.packStr("input");
    switch (input) {
        .create => |create_nonce| {
            try p.packMapHeader(1);
            try p.packStr("create");
            try p.packMapHeader(1);
            try p.packStr("nonce");
            try p.packUint(create_nonce);
        },
        .first_storage_slot => try p.packStr("firstStorageSlot"),
        .custom_storage_slot => try p.packStr("customStorageSlot"),
    }
}

/// The Core system (asset-bridge) address for a spot token index: first byte
/// 0x20, remaining bytes zero except the token index big-endian in the tail.
/// This is where the full supply is minted to back HyperCore <-> HyperEVM
/// transfers. Writes lowercase "0x…" into `buf` and returns the slice.
pub fn systemAddressHex(token_index: u32, buf: *[42]u8) []const u8 {
    var addr = [_]u8{0} ** 20;
    addr[0] = 0x20;
    addr[16] = @intCast((token_index >> 24) & 0xff);
    addr[17] = @intCast((token_index >> 16) & 0xff);
    addr[18] = @intCast((token_index >> 8) & 0xff);
    addr[19] = @intCast(token_index & 0xff);
    const hex = "0123456789abcdef";
    buf[0] = '0';
    buf[1] = 'x';
    for (addr, 0..) |b, i| {
        buf[2 + i * 2] = hex[b >> 4];
        buf[2 + i * 2 + 1] = hex[b & 0x0f];
    }
    return buf[0..42];
}

test "systemAddressHex derives the Core asset-bridge address" {
    var buf: [42]u8 = undefined;
    // Doc example: token index 200 -> 0x20…c8
    try std.testing.expectEqualStrings("0x20000000000000000000000000000000000000c8", systemAddressHex(200, &buf));
    // PURR (index 1)
    try std.testing.expectEqualStrings("0x2000000000000000000000000000000000000001", systemAddressHex(1, &buf));
    // XD (index 2195 = 0x893)
    try std.testing.expectEqualStrings("0x2000000000000000000000000000000000000893", systemAddressHex(2195, &buf));
}

test "requestEvmContract packs nested with signed evmExtraWeiDecimals" {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionSpotDeployRequestEvmContract(&p, .{
        .token = 2195,
        .address = "0x8cde56336e289c028c8f7cf5c20283ff02272182",
        .evm_extra_wei_decimals = -2,
    });
    const out = p.written();
    try std.testing.expectEqual(@as(u8, 0x82), out[0]); // outer map(2)
    // -2 packs as negative fixint 0xfe
    try std.testing.expect(std.mem.indexOfScalar(u8, out, 0xfe) != null);
    // address present verbatim (lowercase)
    try std.testing.expect(std.mem.indexOf(u8, out, "0x8cde56336e289c028c8f7cf5c20283ff02272182") != null);
}

test "finalizeEvmContract is top-level with variant inputs" {
    var buf: [128]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionFinalizeEvmContract(&p, 2195, .first_storage_slot);
    const s = p.written();
    try std.testing.expectEqual(@as(u8, 0x83), s[0]); // map(3): type, token, input
    try std.testing.expect(std.mem.indexOf(u8, s, "finalizeEvmContract") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "firstStorageSlot") != null);

    var buf2: [128]u8 = undefined;
    var p2 = msgpack.Packer.init(&buf2);
    try packActionFinalizeEvmContract(&p2, 2195, .{ .create = 42 });
    const c = p2.written();
    try std.testing.expect(std.mem.indexOf(u8, c, "create") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "nonce") != null);
}

// ── Perp Deploy Actions ───────────────────────────────────────

pub const PerpDeployRegisterAsset = struct {
    dex: []const u8,
    max_gas: ?u64,
    coin: []const u8,
    sz_decimals: u32,
    oracle_px: []const u8,
    margin_table_id: u32,
    only_isolated: bool,
    // Optional schema — set all three or none
    schema_full_name: ?[]const u8,
    schema_collateral_token: ?u32,
    schema_oracle_updater: ?[]const u8,
};

/// Pack a perpDeploy registerAsset action.
/// Caller must pass lowercase hex address for `schema_oracle_updater`  — exchange expects lowercase hex.
pub fn packActionPerpDeployRegisterAsset(p: *msgpack.Packer, ra: PerpDeployRegisterAsset) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("perpDeploy");
    try p.packStr("registerAsset");
    try p.packMapHeader(4);
    try p.packStr("maxGas");
    if (ra.max_gas) |mg| {
        try p.packUint(mg);
    } else {
        try p.packNil();
    }
    try p.packStr("assetRequest");
    try p.packMapHeader(5);
    try p.packStr("coin");
    try p.packStr(ra.coin);
    try p.packStr("szDecimals");
    try p.packUint(@intCast(ra.sz_decimals));
    try p.packStr("oraclePx");
    try p.packStr(ra.oracle_px);
    try p.packStr("marginTableId");
    try p.packUint(@intCast(ra.margin_table_id));
    try p.packStr("onlyIsolated");
    try p.packBool(ra.only_isolated);
    try p.packStr("dex");
    try p.packStr(ra.dex);
    try p.packStr("schema");
    if (ra.schema_full_name) |fn_| {
        try p.packMapHeader(3);
        try p.packStr("fullName");
        try p.packStr(fn_);
        try p.packStr("collateralToken");
        if (ra.schema_collateral_token) |ct| {
            try p.packUint(@intCast(ct));
        } else {
            try p.packNil();
        }
        try p.packStr("oracleUpdater");
        if (ra.schema_oracle_updater) |ou| {
            try p.packStr(ou);
        } else {
            try p.packNil();
        }
    } else {
        try p.packNil();
    }
}

/// OraclePx entry: [coin, px] sorted pair
pub const OraclePxEntry = struct { coin: []const u8, px: []const u8 };

/// Pack a perpDeploy setOracle action.
/// IMPORTANT: All entry arrays (oracle_pxs, each mark_pxs group, external_perp_pxs)
/// must be lexicographically sorted by coin name before calling this function.
/// Unsorted inputs produce a different hash and the signature will be rejected.
pub fn packActionPerpDeploySetOracle(
    p: *msgpack.Packer,
    dex: []const u8,
    oracle_pxs: []const OraclePxEntry,
    mark_pxs: []const []const OraclePxEntry,
    external_perp_pxs: []const OraclePxEntry,
) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("perpDeploy");
    try p.packStr("setOracle");
    try p.packMapHeader(4);
    try p.packStr("dex");
    try p.packStr(dex);
    try p.packStr("oraclePxs");
    try p.packArrayHeader(@intCast(oracle_pxs.len));
    for (oracle_pxs) |entry| {
        try p.packArrayHeader(2);
        try p.packStr(entry.coin);
        try p.packStr(entry.px);
    }
    try p.packStr("markPxs");
    try p.packArrayHeader(@intCast(mark_pxs.len));
    for (mark_pxs) |group| {
        try p.packArrayHeader(@intCast(group.len));
        for (group) |entry| {
            try p.packArrayHeader(2);
            try p.packStr(entry.coin);
            try p.packStr(entry.px);
        }
    }
    try p.packStr("externalPerpPxs");
    try p.packArrayHeader(@intCast(external_perp_pxs.len));
    for (external_perp_pxs) |entry| {
        try p.packArrayHeader(2);
        try p.packStr(entry.coin);
        try p.packStr(entry.px);
    }
}

// ── Validator/Signer Actions ──────────────────────────────────

pub fn packActionCSignerJailSelf(p: *msgpack.Packer) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("CSignerAction");
    try p.packStr("jailSelf");
    try p.packNil();
}

pub fn packActionCSignerUnjailSelf(p: *msgpack.Packer) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("CSignerAction");
    try p.packStr("unjailSelf");
    try p.packNil();
}

pub const ValidatorProfile = struct {
    node_ip: []const u8,
    name: []const u8,
    description: []const u8,
    delegations_disabled: bool,
    commission_bps: u32,
    signer: []const u8,
};

pub const ValidatorRegister = struct {
    profile: ValidatorProfile,
    unjailed: bool,
    initial_wei: u64,
};

pub fn packActionCValidatorRegister(
    p: *msgpack.Packer,
    profile: ValidatorProfile,
    unjailed: bool,
    initial_wei: u64,
) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("CValidatorAction");
    try p.packStr("register");
    try p.packMapHeader(3);
    try p.packStr("profile");
    try p.packMapHeader(6);
    try p.packStr("node_ip");
    try p.packMapHeader(1);
    try p.packStr("Ip");
    try p.packStr(profile.node_ip);
    try p.packStr("name");
    try p.packStr(profile.name);
    try p.packStr("description");
    try p.packStr(profile.description);
    try p.packStr("delegations_disabled");
    try p.packBool(profile.delegations_disabled);
    try p.packStr("commission_bps");
    try p.packUint(@intCast(profile.commission_bps));
    try p.packStr("signer");
    try p.packStr(profile.signer);
    try p.packStr("unjailed");
    try p.packBool(unjailed);
    try p.packStr("initial_wei");
    try p.packUint(initial_wei);
}

pub const ValidatorProfileChange = struct {
    node_ip: ?[]const u8,
    name: ?[]const u8,
    description: ?[]const u8,
    unjailed: bool,
    disable_delegations: ?bool,
    commission_bps: ?u32,
    signer: ?[]const u8,
};

pub fn packActionCValidatorChangeProfile(p: *msgpack.Packer, c: ValidatorProfileChange) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("CValidatorAction");
    try p.packStr("changeProfile");
    try p.packMapHeader(7);
    try p.packStr("node_ip");
    if (c.node_ip) |ip| {
        try p.packMapHeader(1);
        try p.packStr("Ip");
        try p.packStr(ip);
    } else {
        try p.packNil();
    }
    try p.packStr("name");
    if (c.name) |n| { try p.packStr(n); } else { try p.packNil(); }
    try p.packStr("description");
    if (c.description) |d| { try p.packStr(d); } else { try p.packNil(); }
    try p.packStr("unjailed");
    try p.packBool(c.unjailed);
    try p.packStr("disable_delegations");
    if (c.disable_delegations) |dd| { try p.packBool(dd); } else { try p.packNil(); }
    try p.packStr("commission_bps");
    if (c.commission_bps) |cb| { try p.packUint(@intCast(cb)); } else { try p.packNil(); }
    try p.packStr("signer");
    if (c.signer) |s| { try p.packStr(s); } else { try p.packNil(); }
}

pub fn packActionCValidatorUnregister(p: *msgpack.Packer) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("CValidatorAction");
    try p.packStr("unregister");
    try p.packNil();
}


test "packActionSpotDeployTokenAction: enableFreezePrivilege" {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionSpotDeployTokenAction(&p, "enableFreezePrivilege", 42);
    const written = p.written();
    // Must start with map header for 2 fields
    try std.testing.expectEqual(@as(u8, 0x82), written[0]);
    // Contains "spotDeploy" as the type
    try std.testing.expect(std.mem.indexOf(u8, written, "spotDeploy") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "enableFreezePrivilege") != null);
}

test "packActionSpotDeployTokenAction: enableQuoteToken variant name" {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionSpotDeployTokenAction(&p, "enableQuoteToken", 2195);
    const written = p.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "enableQuoteToken") != null);
    // token index 2195 = 0x893 — packs as uint16 (cd 08 93)
    try std.testing.expect(std.mem.indexOf(u8, written, &[_]u8{ 0xcd, 0x08, 0x93 }) != null);
}

test "packActionSpotDeployTokenAction: enableAlignedQuoteToken variant name" {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionSpotDeployTokenAction(&p, "enableAlignedQuoteToken", 7);
    const written = p.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "enableAlignedQuoteToken") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "token") != null);
}

test "packActionCSignerJailSelf: structure" {
    var buf: [128]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionCSignerJailSelf(&p);
    const written = p.written();
    try std.testing.expectEqual(@as(u8, 0x82), written[0]); // map of 2
    try std.testing.expect(std.mem.indexOf(u8, written, "CSignerAction") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "jailSelf") != null);
}

test "packActionCValidatorUnregister: structure" {
    var buf: [128]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionCValidatorUnregister(&p);
    const written = p.written();
    try std.testing.expectEqual(@as(u8, 0x82), written[0]); // map of 2
    try std.testing.expect(std.mem.indexOf(u8, written, "CValidatorAction") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "unregister") != null);
}

test "packActionSpotDeployRegisterSpot: structure" {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionSpotDeployRegisterSpot(&p, .{ .base_token = 1, .quote_token = 0 });
    const written = p.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "spotDeploy") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "registerSpot") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "tokens") != null);
}

test "packActionTwapOrder: structure" {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionTwapOrder(&p, .{
        .asset = 0,
        .is_buy = true,
        .sz = Decimal.fromString("1.5") catch unreachable,
        .reduce_only = false,
        .duration_min = 60,
        .randomize = true,
    });
    const written = p.written();
    try std.testing.expectEqual(@as(u8, 0x82), written[0]); // outer map of 2: {type, twap}
    try std.testing.expect(std.mem.indexOf(u8, written, "twapOrder") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "twap") != null);
}

test "packActionVaultTransfer: structure" {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionVaultTransfer(&p, .{
        .vault_address = "0x1234567890abcdef1234567890abcdef12345678",
        .is_deposit = true,
        .usd = 100,
    });
    const written = p.written();
    try std.testing.expectEqual(@as(u8, 0x84), written[0]); // map of 4
    try std.testing.expect(std.mem.indexOf(u8, written, "vaultTransfer") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "isDeposit") != null);
}

test "cloidToHex: zero cloid" {
    const hex = cloidToHex(ZERO_CLOID);
    try std.testing.expectEqualStrings("0x00000000000000000000000000000000", &hex);
}

test "packActionOrder: matches Rust Action::Order msgpack vector" {
    // From rust_vectors.json: action_order_msgpack_hex (74 bytes)
    // This is the Action with serde tag, which is what actually gets hashed for signing
    // Zero cloid is omitted from serialization to match server hashing
    const expected_hex = "83a474797065a56f72646572a66f72646572739186a16100a162c3a170a53530303030a173a3302e31a172c2a17481a56c696d697481a3746966a3477463a867726f7570696e67a26e61";

    var expected: [74]u8 = undefined;
    for (0..74) |i| {
        expected[i] = std.fmt.parseInt(u8, expected_hex[i * 2 ..][0..2], 16) catch unreachable;
    }

    const order = OrderRequest{
        .asset = 0,
        .is_buy = true,
        .limit_px = Decimal.fromString("50000") catch unreachable,
        .sz = Decimal.fromString("0.1") catch unreachable,
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = ZERO_CLOID,
    };

    const batch = BatchOrder{
        .orders = &[_]OrderRequest{order},
        .grouping = .na,
    };

    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionOrder(&p, batch);

    try std.testing.expectEqualSlices(u8, &expected, p.written());
}

test "packActionAgentSendAsset: structure" {
    const asa = AgentSendAsset{
        .destination = [_]u8{0x42} ** 20,
        .source_dex = "",
        .destination_dex = "",
        .token = "USDC",
        .amount = "100.0",
        .from_sub_account = "",
        .nonce = 1234567890,
    };

    var buf: [512]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionAgentSendAsset(&p, asa);

    const out = p.written();
    try std.testing.expectEqual(@as(u8, 0x88), out[0]);
    try std.testing.expect(std.mem.indexOf(u8, out, "agentSendAsset") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0x4242424242424242424242424242424242424242") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fromSubAccount") != null);
}

test "packActionOrder: includes builder field when set" {
    const order = OrderRequest{
        .asset = 0,
        .is_buy = true,
        .limit_px = Decimal.fromString("50000") catch unreachable,
        .sz = Decimal.fromString("0.1") catch unreachable,
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = ZERO_CLOID,
    };

    const builder_addr: [20]u8 = [_]u8{0x42} ** 20;
    const batch = BatchOrder{
        .orders = &[_]OrderRequest{order},
        .grouping = .na,
        .builder = .{ .address = builder_addr, .fee_tenths_bps = 100 },
    };

    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionOrder(&p, batch);

    const out = p.written();
    try std.testing.expectEqual(@as(u8, 0x84), out[0]);
    try std.testing.expect(std.mem.indexOf(u8, out, "\xa7builder") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0x4242424242424242424242424242424242424242") != null);
    // Fee 100 → 0x64 positive-fixint, no marker byte.
    try std.testing.expect(std.mem.indexOfScalar(u8, out[out.len - 3 ..], 0x64) != null);
}

test "packBatchOrder: matches Rust msgpack vector" {
    // From rust_vectors.json: order_msgpack_hex (zero cloid omitted)
    const expected_hex = "82a66f72646572739186a16100a162c3a170a53530303030a173a3302e31a172c2a17481a56c696d697481a3746966a3477463a867726f7570696e67a26e61";

    var expected: [63]u8 = undefined;
    for (0..63) |i| {
        expected[i] = std.fmt.parseInt(u8, expected_hex[i * 2 ..][0..2], 16) catch unreachable;
    }

    const order = OrderRequest{
        .asset = 0,
        .is_buy = true,
        .limit_px = Decimal.fromString("50000") catch unreachable,
        .sz = Decimal.fromString("0.1") catch unreachable,
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = ZERO_CLOID,
    };

    const batch = BatchOrder{
        .orders = &[_]OrderRequest{order},
        .grouping = .na,
    };

    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packBatchOrder(&p, batch);

    try std.testing.expectEqualSlices(u8, &expected, p.written());
}
