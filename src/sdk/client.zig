//! HTTP client for Hyperliquid API (info + exchange endpoints).

const std = @import("std");
const json_mod = @import("json.zig");
const signing = @import("signing.zig");
const runtime = @import("../lib/runtime.zig");
const types = @import("types.zig");
const resp_types = @import("response.zig");
const signer_mod = @import("../lib/crypto/signer.zig");
const eip712 = @import("../lib/crypto/eip712.zig");
const Decimal = @import("../lib/math/decimal.zig").Decimal;
const msgpack = @import("../lib/encoding/msgpack.zig");

const Signer = signer_mod.Signer;
const Address = signer_mod.Address;
const Signature = signer_mod.Signature;
const Chain = signing.Chain;

pub const MAINNET_URL = "https://api.hyperliquid.xyz";
pub const TESTNET_URL = "https://api.hyperliquid-testnet.xyz";

pub const ClientError = error{
    HttpRequestFailed,
    JsonParseFailed,
    ApiError,
    BufferOverflow,
    InvalidResponse,
} || std.http.Client.RequestError || std.http.Client.Connection.ReadError || std.mem.Allocator.Error || signing.SignError;

/// HTTP client for the Hyperliquid API.
pub const Client = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    base_url: []const u8,
    chain: Chain,

    /// Create a mainnet client.
    pub fn mainnet(allocator: std.mem.Allocator) Client {
        return init(allocator, .mainnet, MAINNET_URL);
    }

    /// Create a testnet client.
    pub fn testnet(allocator: std.mem.Allocator) Client {
        return init(allocator, .testnet, TESTNET_URL);
    }

    /// Create a client with a custom URL.
    pub fn withUrl(allocator: std.mem.Allocator, chain: Chain, base_url: []const u8) Client {
        return init(allocator, chain, base_url);
    }

    fn init(allocator: std.mem.Allocator, chain: Chain, base_url: []const u8) Client {
        return .{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator, .io = runtime.io() },
            .base_url = base_url,
            .chain = chain,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    // ── Info Endpoints ────────────────────────────────────────────

    /// Fetch mid prices for all markets.
    /// Returns parsed JSON. Caller must deinit.
    pub fn allMids(self: *Client, dex_name: ?[]const u8) !InfoResult {
        if (dex_name) |d| {
            var buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&buf,
                \\{{"type":"allMids","dex":"{s}"}}
            , .{d}) catch return error.Overflow;
            return self.infoRequestDyn(body);
        }
        return self.infoRequest(
            \\{"type":"allMids"}
        );
    }

    /// Fetch open orders for a user.
    pub fn openOrders(self: *Client, user: []const u8, dex_name: ?[]const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBody(&buf, "frontendOpenOrders", user, dex_name);
        return self.infoRequestDyn(body);
    }

    /// Fetch user fills.
    pub fn userFills(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userFills", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch clearinghouse state.
    pub fn clearinghouseState(self: *Client, user: []const u8, dex_name: ?[]const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBody(&buf, "clearinghouseState", user, dex_name);
        return self.infoRequestDyn(body);
    }

    /// Fetch spot balances.
    pub fn spotBalances(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "spotClearinghouseState", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch candle snapshot.
    pub fn candleSnapshot(
        self: *Client,
        coin: []const u8,
        interval: []const u8,
        start_time: u64,
        end_time: u64,
    ) !InfoResult {
        var buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"candleSnapshot","req":{{"coin":"{s}","interval":"{s}","startTime":{d},"endTime":{d}}}}}
        , .{ coin, interval, start_time, end_time }) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch historical orders.
    /// Fetch user funding payments.
    pub fn userFunding(self: *Client, user: []const u8, start_time: u64, end_time: ?u64) !InfoResult {
        var buf: [512]u8 = undefined;
        const body = if (end_time) |et|
            std.fmt.bufPrint(&buf,
                \\{{"type":"userFunding","user":"{s}","startTime":{d},"endTime":{d}}}
            , .{ user, start_time, et }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&buf,
                \\{{"type":"userFunding","user":"{s}","startTime":{d}}}
            , .{ user, start_time }) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    pub fn historicalOrders(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "historicalOrders", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch funding history.
    pub fn fundingHistory(
        self: *Client,
        coin: []const u8,
        start_time: u64,
        end_time: ?u64,
    ) !InfoResult {
        var buf: [512]u8 = undefined;
        const body = if (end_time) |et|
            std.fmt.bufPrint(&buf,
                \\{{"type":"fundingHistory","coin":"{s}","startTime":{d},"endTime":{d}}}
            , .{ coin, start_time, et }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&buf,
                \\{{"type":"fundingHistory","coin":"{s}","startTime":{d}}}
            , .{ coin, start_time }) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch order status.
    pub fn orderStatus(self: *Client, user: []const u8, oid: u64) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"orderStatus","user":"{s}","oid":{d}}}
        , .{ user, oid }) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch user role.
    pub fn userRole(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userRole", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch subaccounts.
    pub fn subaccounts(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "subAccounts", user);
        return self.infoRequestDyn(body);
    }

    // ── Exchange Endpoints ────────────────────────────────────────

    /// Place a batch of orders.
    pub fn place(
        self: *Client,
        s: Signer,
        batch: types.BatchOrder,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signOrder(s, batch, nonce, self.chain, vault_address, expires_after);
        return self.sendExchange(batch, sig, nonce, vault_address, expires_after);
    }

    /// Cancel a batch of orders.
    pub fn cancel(
        self: *Client,
        s: Signer,
        batch: types.BatchCancel,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signCancel(s, batch, nonce, self.chain, vault_address, expires_after);
        return self.sendExchange(batch, sig, nonce, vault_address, expires_after);
    }

    /// Cancel a batch of orders by cloid.
    pub fn cancelByCloid(
        self: *Client,
        s: Signer,
        batch: types.BatchCancelCloid,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signCancelByCloid(s, batch, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRawFull(sig, nonce, batch, .cancelByCloid, vault_address, expires_after);
    }

    /// Modify a batch of orders.
    pub fn modify(
        self: *Client,
        s: Signer,
        batch: types.BatchModify,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signModify(s, batch, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRawFull(sig, nonce, batch, .batchModify, vault_address, expires_after);
    }

    /// Schedule cancellation of all orders.
    pub fn scheduleCancel(
        self: *Client,
        s: Signer,
        sc: types.ScheduleCancel,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signScheduleCancel(s, sc, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRawFull(sig, nonce, sc, .scheduleCancel, vault_address, expires_after);
    }

    /// Update isolated margin.
    pub fn updateIsolatedMargin(
        self: *Client,
        s: Signer,
        uim: types.UpdateIsolatedMargin,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signUpdateIsolatedMargin(s, uim, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRawFull(sig, nonce, uim, .updateIsolatedMargin, vault_address, expires_after);
    }

    /// Update leverage for an asset.
    pub fn updateLeverage(
        self: *Client,
        s: Signer,
        ul: types.UpdateLeverage,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signUpdateLeverage(s, ul, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRawFull(sig, nonce, ul, .updateLeverage, vault_address, expires_after);
    }

    /// Set referrer code.
    pub fn setReferrer(
        self: *Client,
        s: Signer,
        sr: types.SetReferrer,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signSetReferrer(s, sr, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRawFull(sig, nonce, sr, .setReferrer, vault_address, expires_after);
    }

    /// Toggle big blocks.
    pub fn evmUserModify(
        self: *Client,
        s: Signer,
        using_big_blocks: bool,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signEvmUserModify(s, using_big_blocks, nonce, self.chain, vault_address, expires_after);
        var body_buf: [512]u8 = undefined;
        var w_storage: std.Io.Writer = .fixed(&body_buf);
        const w = &w_storage;
        const sig_json = sigJsonStr(sig);
        try w.print("{{\"action\":{{\"type\":\"evmUserModify\",\"usingBigBlocks\":{s}}},\"nonce\":{d},\"signature\":{s}", .{
            if (using_big_blocks) "true" else "false",
            nonce,
            sigJsonSlice(&sig_json),
        });
        try writeOptionalAddress(w, ",\"vaultAddress\":", vault_address);
        try writeOptionalU64(w, ",\"expiresAfter\":", expires_after);
        try w.writeAll("}");
        return self.exchangeRequestDyn(w.buffered());
    }

    /// Invalidate a nonce (noop).
    pub fn noop(
        self: *Client,
        s: Signer,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signNoop(s, nonce, self.chain, vault_address, expires_after);
        var body_buf: [512]u8 = undefined;
        var w_storage: std.Io.Writer = .fixed(&body_buf);
        const w = &w_storage;
        const sig_json = sigJsonStr(sig);
        try w.print("{{\"action\":{{\"type\":\"noop\"}},\"nonce\":{d},\"signature\":{s}", .{ nonce, sigJsonSlice(&sig_json) });
        try writeOptionalAddress(w, ",\"vaultAddress\":", vault_address);
        try writeOptionalU64(w, ",\"expiresAfter\":", expires_after);
        try w.writeAll("}");
        return self.exchangeRequestDyn(w.buffered());
    }

    /// Send USDC to another address.
    pub fn sendUsdc(
        self: *Client,
        s: Signer,
        destination: Address,
        amount: []const u8,
        time: u64,
    ) !ExchangeResult {
        const sig = try eip712.signUsdSend(s, self.chain.isMainnet(), destination, amount, time);
        const chain_str = self.chain.name();
        const dest_hex = addressToHex(destination);

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"usdSend","signatureChainId":"{s}","hyperliquidChain":"{s}","destination":"{s}","amount":"{s}","time":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{
            self.chain.sigChainId(),
            chain_str,
            &dest_hex,
            amount,
            time,
            time,
            sigJsonSlice(&sigJsonStr(sig)),
        }) catch return error.BufferOverflow;

        return self.exchangeRequestDyn(body);
    }

    /// Spot send (spot → spot transfer).
    pub fn spotSend(
        self: *Client,
        s: Signer,
        destination: Address,
        token: []const u8,
        amount: []const u8,
        time: u64,
    ) !ExchangeResult {
        const sig = try signing.signSpotSend(s, self.chain, destination, token, amount, time);
        const chain_str = self.chain.name();
        const sig_chain_id = self.chain.sigChainId();
        const dest_hex = addressToHex(destination);

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"spotSend","signatureChainId":"{s}","hyperliquidChain":"{s}","destination":"{s}","token":"{s}","amount":"{s}","time":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{ sig_chain_id, chain_str, &dest_hex, token, amount, time, time, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    /// Send asset (perp ↔ spot, or cross-dex).
    pub fn sendAsset(
        self: *Client,
        s: Signer,
        destination: Address,
        source_dex: []const u8,
        destination_dex: []const u8,
        token: []const u8,
        amount: []const u8,
        from_sub_account: []const u8,
        nonce: u64,
    ) !ExchangeResult {
        const sig = try signing.signSendAsset(s, self.chain, destination, source_dex, destination_dex, token, amount, from_sub_account, nonce);
        const chain_str = self.chain.name();
        const sig_chain_id = self.chain.sigChainId();
        const dest_hex = addressToHex(destination);

        var body_buf: [2048]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"sendAsset","signatureChainId":"{s}","hyperliquidChain":"{s}","destination":"{s}","sourceDex":"{s}","destinationDex":"{s}","token":"{s}","amount":"{s}","fromSubAccount":"{s}","nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{ sig_chain_id, chain_str, &dest_hex, source_dex, destination_dex, token, amount, from_sub_account, nonce, nonce, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    /// Agent-signed self-transfer. Signs via the L1 RMP path, not EIP-712.
    pub fn agentSendAsset(
        self: *Client,
        s: Signer,
        asa: types.AgentSendAsset,
    ) !ExchangeResult {
        const sig = try signing.signAgentSendAsset(s, asa, asa.nonce, self.chain, null, null);
        const dest_hex = addressToHex(asa.destination);
        var body_buf: [2048]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"agentSendAsset","destination":"{s}","sourceDex":"{s}","destinationDex":"{s}","token":"{s}","amount":"{s}","fromSubAccount":"{s}","nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{
            &dest_hex,
            asa.source_dex,
            asa.destination_dex,
            asa.token,
            asa.amount,
            asa.from_sub_account,
            asa.nonce,
            asa.nonce,
            sigJsonSlice(&sigJsonStr(sig)),
        }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    /// Approve an agent wallet.
    pub fn approveAgent(
        self: *Client,
        s: Signer,
        agent_address: Address,
        agent_name: ?[]const u8,
        nonce: u64,
    ) !ExchangeResult {
        const name = agent_name orelse "";
        const sig = try signing.signApproveAgent(s, self.chain, agent_address, name, nonce);
        const chain_str = self.chain.name();
        const sig_chain_id = self.chain.sigChainId();
        const addr_hex = addressToHex(agent_address);

        var body_buf: [1024]u8 = undefined;
        const body = if (agent_name != null)
            std.fmt.bufPrint(&body_buf,
                \\{{"action":{{"type":"approveAgent","signatureChainId":"{s}","hyperliquidChain":"{s}","agentAddress":"{s}","agentName":"{s}","nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
            , .{ sig_chain_id, chain_str, &addr_hex, name, nonce, nonce, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&body_buf,
                \\{{"action":{{"type":"approveAgent","signatureChainId":"{s}","hyperliquidChain":"{s}","agentAddress":"{s}","agentName":null,"nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
            , .{ sig_chain_id, chain_str, &addr_hex, nonce, nonce, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    /// Convert account to multi-sig.
    pub fn convertToMultisig(
        self: *Client,
        s: Signer,
        signers_json: []const u8,
        nonce: u64,
    ) !ExchangeResult {
        const sig = try signing.signConvertToMultiSig(s, self.chain, signers_json, nonce);
        const chain_str = self.chain.name();
        const sig_chain_id = self.chain.sigChainId();

        var body_buf: [2048]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"convertToMultiSigUser","signatureChainId":"{s}","hyperliquidChain":"{s}","signers":"{s}","nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{ sig_chain_id, chain_str, signers_json, nonce, nonce, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    // ── Market & Meta Info ───────────────────────────────────────

    /// Fetch perpetual markets metadata.
    pub fn perps(self: *Client, dex_name: ?[]const u8) !InfoResult {
        if (dex_name) |d| {
            var buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&buf,
                \\{{"type":"meta","dex":"{s}"}}
            , .{d}) catch return error.BufferOverflow;
            return self.infoRequestDyn(body);
        }
        return self.infoRequest(
            \\{"type":"meta"}
        );
    }

    /// Fetch spot markets metadata.
    pub fn spot(self: *Client) !InfoResult {
        return self.infoRequest(
            \\{"type":"spotMeta"}
        );
    }

    /// Fetch outcome markets metadata.
    pub fn outcomeMeta(self: *Client) !InfoResult {
        return self.infoRequest(
            \\{"type":"outcomeMeta"}
        );
    }

    /// Fetch available perpetual DEXes.
    pub fn perpDexs(self: *Client) !InfoResult {
        return self.infoRequest(
            \\{"type":"perpDexs"}
        );
    }

    /// Fetch multi-sig config for a user.
    pub fn multiSigConfig(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userToMultiSigSigners", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch API agents for a user.
    pub fn apiAgents(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "extraAgents", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch vault details.
    pub fn vaultDetails(self: *Client, vault_address: []const u8, user: ?[]const u8) !InfoResult {
        var buf: [512]u8 = undefined;
        const body = if (user) |u|
            std.fmt.bufPrint(&buf,
                \\{{"type":"vaultDetails","vaultAddress":"{s}","user":"{s}"}}
            , .{ vault_address, u }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&buf,
                \\{{"type":"vaultDetails","vaultAddress":"{s}"}}
            , .{vault_address}) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch user vault equities.
    pub fn userVaultEquities(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userVaultEquities", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch L2 order book snapshot for a coin.
    pub fn l2Book(self: *Client, coin: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"type\":\"l2Book\",\"coin\":\"{s}\"}}", .{coin}) catch return error.Overflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch recent trades for a coin.
    pub fn recentTrades(self: *Client, coin: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"type\":\"recentTrades\",\"coin\":\"{s}\"}}", .{coin}) catch return error.Overflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch user's active asset data (leverage, available-to-trade).
    pub fn activeAssetData(self: *Client, user: []const u8, coin: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"activeAssetData","user":"{s}","coin":"{s}"}}
        , .{ user, coin }) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch referral status for a user.
    pub fn referral(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"referral","user":"{s}"}}
        , .{user}) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch user fills filtered by time range.
    pub fn userFillsByTime(self: *Client, user: []const u8, start_time: u64, end_time: ?u64) !InfoResult {
        var buf: [512]u8 = undefined;
        const body = if (end_time) |et|
            std.fmt.bufPrint(&buf,
                \\{{"type":"userFillsByTime","user":"{s}","startTime":{d},"endTime":{d}}}
            , .{ user, start_time, et }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&buf,
                \\{{"type":"userFillsByTime","user":"{s}","startTime":{d}}}
            , .{ user, start_time }) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch user fees.
    pub fn userFees(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userFees", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch user rate limit.
    pub fn userRateLimit(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userRateLimit", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch portfolio (detailed position view).
    pub fn portfolio(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "portfolio", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch predicted fundings for all markets.
    pub fn predictedFundings(self: *Client) !InfoResult {
        return self.infoRequest(
            \\{"type":"predictedFundings"}
        );
    }

    /// Fetch perps at open interest cap.
    pub fn perpsAtOpenInterestCap(self: *Client) !InfoResult {
        return self.infoRequest(
            \\{"type":"perpsAtOpenInterestCap"}
        );
    }

    /// Fetch spot meta and asset contexts.
    pub fn spotMetaAndAssetCtxs(self: *Client) !InfoResult {
        return self.infoRequest(
            \\{"type":"spotMetaAndAssetCtxs"}
        );
    }

    /// Fetch token details by token ID.
    pub fn tokenDetails(self: *Client, token_id: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"tokenDetails","tokenId":"{s}"}}
        , .{token_id}) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch user non-funding ledger updates.
    pub fn userNonFundingLedgerUpdates(self: *Client, user: []const u8, start_time: u64, end_time: ?u64) !InfoResult {
        var buf: [512]u8 = undefined;
        const body = if (end_time) |et|
            std.fmt.bufPrint(&buf,
                \\{{"type":"userNonFundingLedgerUpdates","user":"{s}","startTime":{d},"endTime":{d}}}
            , .{ user, start_time, et }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&buf,
                \\{{"type":"userNonFundingLedgerUpdates","user":"{s}","startTime":{d}}}
            , .{ user, start_time }) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch user TWAP slice fills.
    pub fn userTwapSliceFills(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userTwapSliceFills", user);
        return self.infoRequestDyn(body);
    }

    // ── Staking Info ──────────────────────────────────────────────

    /// Fetch delegator summary.
    pub fn delegatorSummary(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "delegatorSummary", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch delegations.
    pub fn delegations(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "delegations", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch delegator rewards.
    pub fn delegatorRewards(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "delegatorRewards", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch delegator history.
    pub fn delegatorHistory(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "delegatorHistory", user);
        return self.infoRequestDyn(body);
    }

    // ── Deploy Auction Info ───────────────────────────────────────

    /// Fetch perp deploy auction status.
    pub fn perpDeployAuctionStatus(self: *Client) !InfoResult {
        return self.infoRequest(
            \\{"type":"perpDeployAuctionStatus"}
        );
    }

    /// Fetch spot deploy state.
    pub fn spotDeployState(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "spotDeployState", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch the Dutch-auction status for spot pair deployments between an
    /// existing base and existing quote token (separate auction from the
    /// registerToken2 gas auction — this one runs on registerSpot for
    /// existing-vs-existing pairs).
    pub fn spotPairDeployAuctionStatus(self: *Client) !InfoResult {
        return self.infoRequest(
            \\{"type":"spotPairDeployAuctionStatus"}
        );
    }

    // ── Borrow/Lend Info ──────────────────────────────────────────

    /// Fetch borrow/lend user state.
    pub fn borrowLendUserState(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "borrowLendUserState", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch max builder fee for a user/builder pair.
    pub fn maxBuilderFee(self: *Client, user: []const u8, builder: []const u8) !InfoResult {
        var buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"maxBuilderFee","user":"{s}","builder":"{s}"}}
        , .{ user, builder }) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Query user's account abstraction mode.
    /// Returns a JSON string: "disabled", "unifiedAccount", or "portfolioMargin".
    pub fn userAbstraction(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userAbstraction", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch spot clearinghouse state for a user.
    pub fn spotClearinghouseState(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"spotClearinghouseState","user":"{s}"}}
        , .{user}) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch perp meta + asset contexts (funding, OI, mark prices).
    pub fn metaAndAssetCtxs(self: *Client) !InfoResult {
        return self.infoRequestDyn("{\"type\":\"metaAndAssetCtxs\"}");
    }

    /// Withdraw USDC from the bridge.
    pub fn withdraw(
        self: *Client,
        s: Signer,
        destination: Address,
        amount: []const u8,
        time: u64,
    ) !ExchangeResult {
        const sig = try signing.signWithdraw(s, self.chain, destination, amount, time);
        const chain_str = self.chain.name();
        const dest_hex = addressToHex(destination);

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"withdraw3","signatureChainId":"{s}","hyperliquidChain":"{s}","destination":"{s}","amount":"{s}","time":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{
            self.chain.sigChainId(),
            chain_str,
            &dest_hex,
            amount,
            time,
            time,
            sigJsonSlice(&sigJsonStr(sig)),
        }) catch return error.BufferOverflow;

        return self.exchangeRequestDyn(body);
    }

    /// Transfer USDC between spot and perp.
    pub fn usdClassTransfer(
        self: *Client,
        s: Signer,
        amount: []const u8,
        to_perp: bool,
        nonce: u64,
    ) !ExchangeResult {
        const sig = try signing.signUsdClassTransfer(s, self.chain, amount, to_perp, nonce);
        const chain_str = self.chain.name();

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"usdClassTransfer","signatureChainId":"{s}","hyperliquidChain":"{s}","amount":"{s}","toPerp":{s},"nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{
            self.chain.sigChainId(),
            chain_str,
            amount,
            if (to_perp) "true" else "false",
            nonce,
            nonce,
            sigJsonSlice(&sigJsonStr(sig)),
        }) catch return error.BufferOverflow;

        return self.exchangeRequestDyn(body);
    }

    /// Delegate or undelegate tokens (staking).
    pub fn tokenDelegate(
        self: *Client,
        s: Signer,
        validator: Address,
        wei: u64,
        is_undelegate: bool,
        nonce: u64,
    ) !ExchangeResult {
        const sig = try signing.signTokenDelegate(s, self.chain, validator, wei, is_undelegate, nonce);
        const chain_str = self.chain.name();
        const val_hex = addressToHex(validator);

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"tokenDelegate","signatureChainId":"{s}","hyperliquidChain":"{s}","validator":"{s}","wei":{d},"isUndelegate":{s},"nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{
            self.chain.sigChainId(),
            chain_str,
            &val_hex,
            wei,
            if (is_undelegate) "true" else "false",
            nonce,
            nonce,
            sigJsonSlice(&sigJsonStr(sig)),
        }) catch return error.BufferOverflow;

        return self.exchangeRequestDyn(body);
    }

    /// Approve builder fee.
    pub fn approveBuilderFee(
        self: *Client,
        s: Signer,
        max_fee_rate: []const u8,
        builder: Address,
        nonce: u64,
    ) !ExchangeResult {
        const sig = try signing.signApproveBuilderFee(s, self.chain, max_fee_rate, builder, nonce);
        const chain_str = self.chain.name();
        const builder_hex = addressToHex(builder);

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"approveBuilderFee","signatureChainId":"{s}","hyperliquidChain":"{s}","maxFeeRate":"{s}","builder":"{s}","nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{
            self.chain.sigChainId(),
            chain_str,
            max_fee_rate,
            &builder_hex,
            nonce,
            nonce,
            sigJsonSlice(&sigJsonStr(sig)),
        }) catch return error.BufferOverflow;

        return self.exchangeRequestDyn(body);
    }

    /// Transfer to/from a vault.
    pub fn vaultTransfer(
        self: *Client,
        s: Signer,
        vt: types.VaultTransfer,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signVaultTransfer(s, vt, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRawFull(sig, nonce, vt, .vaultTransfer, vault_address, expires_after);
    }

    /// Create a sub-account.
    pub fn createSubAccount(
        self: *Client,
        s: Signer,
        csa: types.CreateSubAccount,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signCreateSubAccount(s, csa, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRawFull(sig, nonce, csa, .createSubAccount, vault_address, expires_after);
    }

    /// Transfer USDC to/from a sub-account.
    pub fn subAccountTransfer(
        self: *Client,
        s: Signer,
        sat: types.SubAccountTransfer,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signSubAccountTransfer(s, sat, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRawFull(sig, nonce, sat, .subAccountTransfer, vault_address, expires_after);
    }

    /// Transfer spot tokens to/from a sub-account.
    pub fn subAccountSpotTransfer(
        self: *Client,
        s: Signer,
        sst: types.SubAccountSpotTransfer,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signSubAccountSpotTransfer(s, sst, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRawFull(sig, nonce, sst, .subAccountSpotTransfer, vault_address, expires_after);
    }

    /// Place a native TWAP order.
    pub fn twapOrder(
        self: *Client,
        s: Signer,
        tw: types.TwapOrder,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signTwapOrder(s, tw, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRawFull(sig, nonce, tw, .twapOrder, vault_address, expires_after);
    }

    /// Cancel a native TWAP order.
    pub fn twapCancel(
        self: *Client,
        s: Signer,
        tc: types.TwapCancel,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signTwapCancel(s, tc, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRawFull(sig, nonce, tc, .twapCancel, vault_address, expires_after);
    }

    // ── Dex Abstraction ─────────────────────────────────────────

    /// Enable dex abstraction for the agent.
    pub fn agentEnableDexAbstraction(
        self: *Client,
        s: Signer,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signAgentEnableDexAbstraction(s, nonce, self.chain, vault_address, expires_after);
        var body_buf: [512]u8 = undefined;
        var w_storage: std.Io.Writer = .fixed(&body_buf);
        const w = &w_storage;
        const sig_json = sigJsonStr(sig);
        try w.print("{{\"action\":{{\"type\":\"agentEnableDexAbstraction\"}},\"nonce\":{d},\"signature\":{s}", .{ nonce, sigJsonSlice(&sig_json) });
        try writeOptionalAddress(w, ",\"vaultAddress\":", vault_address);
        try writeOptionalU64(w, ",\"expiresAfter\":", expires_after);
        try w.writeAll("}");
        return self.exchangeRequestDyn(w.buffered());
    }

    pub fn agentSetAbstraction(
        self: *Client,
        s: Signer,
        abstraction_json: []const u8,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signAgentSetAbstraction(s, abstraction_json, nonce, self.chain, vault_address, expires_after);
        var body_buf: [2048]u8 = undefined;
        var w_storage: std.Io.Writer = .fixed(&body_buf);
        const w = &w_storage;
        const sig_json = sigJsonStr(sig);
        try w.print("{{\"action\":{{\"type\":\"agentSetAbstraction\",\"abstraction\":\"{s}\"}},\"nonce\":{d},\"signature\":{s}", .{ abstraction_json, nonce, sigJsonSlice(&sig_json) });
        try writeOptionalAddress(w, ",\"vaultAddress\":", vault_address);
        try writeOptionalU64(w, ",\"expiresAfter\":", expires_after);
        try w.writeAll("}");
        return self.exchangeRequestDyn(w.buffered());
    }

    pub fn userDexAbstraction(
        self: *Client,
        s: Signer,
        user: Address,
        enabled: bool,
        nonce: u64,
    ) !ExchangeResult {
        const sig = try signing.signUserDexAbstraction(s, self.chain, user, enabled, nonce);
        const chain_str = self.chain.name();
        const user_hex = addressToHex(user);
        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"userDexAbstraction","signatureChainId":"{s}","hyperliquidChain":"{s}","user":"{s}","enabled":{s},"nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{
            self.chain.sigChainId(),          chain_str, &user_hex,
            if (enabled) "true" else "false", nonce,     nonce,
            sigJsonSlice(&sigJsonStr(sig)),
        }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    pub fn userSetAbstraction(
        self: *Client,
        s: Signer,
        user: Address,
        abstraction: []const u8,
        nonce: u64,
    ) !ExchangeResult {
        const sig = try signing.signUserSetAbstraction(s, self.chain, user, abstraction, nonce);
        const chain_str = self.chain.name();
        const user_hex = addressToHex(user);
        var body_buf: [2048]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"userSetAbstraction","signatureChainId":"{s}","hyperliquidChain":"{s}","user":"{s}","abstraction":"{s}","nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{
            self.chain.sigChainId(),        chain_str, &user_hex,
            abstraction,                    nonce,     nonce,
            sigJsonSlice(&sigJsonStr(sig)),
        }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    // ── Spot Deploy ───────────────────────────────────────────────

    /// Generic spot deploy: signs and sends a pre-packed msgpack action.
    fn sendSpotDeploy(
        self: *Client,
        s: Signer,
        packed_action: []const u8,
        json_body: []const u8,
        nonce: u64,
    ) !ExchangeResult {
        const sig = try signing.signSpotDeploy(s, packed_action, nonce, self.chain, null);
        var body_buf: [4096]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{s},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{ json_body, nonce, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    pub fn spotDeployRegisterToken(self: *Client, s: Signer, rt: types.SpotDeployRegisterToken, nonce: u64) !ExchangeResult {
        var buf: [1024]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionSpotDeployRegisterToken(&p, rt);
        var json_buf: [1024]u8 = undefined;
        const json_body = std.fmt.bufPrint(&json_buf,
            \\{{"type":"spotDeploy","registerToken2":{{"spec":{{"name":"{s}","szDecimals":{d},"weiDecimals":{d}}},"maxGas":{d},"fullName":"{s}"}}}}
        , .{ rt.name, rt.sz_decimals, rt.wei_decimals, rt.max_gas, rt.full_name }) catch return error.BufferOverflow;
        return self.sendSpotDeploy(s, p.written(), json_body, nonce);
    }

    pub fn spotDeployGenesis(self: *Client, s: Signer, g: types.SpotDeployGenesis, nonce: u64) !ExchangeResult {
        var buf: [512]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionSpotDeployGenesis(&p, g);
        var json_buf: [512]u8 = undefined;
        const nh = if (g.no_hyperliquidity) ",\"noHyperliquidity\":true" else "";
        const json_body = std.fmt.bufPrint(&json_buf,
            \\{{"type":"spotDeploy","genesis":{{"token":{d},"maxSupply":"{s}"{s}}}}}
        , .{ g.token, g.max_supply, nh }) catch return error.BufferOverflow;
        return self.sendSpotDeploy(s, p.written(), json_body, nonce);
    }

    pub fn spotDeployRegisterSpot(self: *Client, s: Signer, rs: types.SpotDeployRegisterSpot, nonce: u64) !ExchangeResult {
        var buf: [256]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionSpotDeployRegisterSpot(&p, rs);
        var json_buf: [256]u8 = undefined;
        const json_body = std.fmt.bufPrint(&json_buf,
            \\{{"type":"spotDeploy","registerSpot":{{"tokens":[{d},{d}]}}}}
        , .{ rs.base_token, rs.quote_token }) catch return error.BufferOverflow;
        return self.sendSpotDeploy(s, p.written(), json_body, nonce);
    }

    pub fn spotDeployTokenAction(self: *Client, s: Signer, variant: []const u8, token: u32, nonce: u64) !ExchangeResult {
        var buf: [256]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionSpotDeployTokenAction(&p, variant, token);
        var json_buf: [256]u8 = undefined;
        const json_body = std.fmt.bufPrint(&json_buf,
            \\{{"type":"spotDeploy","{s}":{{"token":{d}}}}}
        , .{ variant, token }) catch return error.BufferOverflow;
        return self.sendSpotDeploy(s, p.written(), json_body, nonce);
    }

    /// Enable a permissionless quote token — after this, other deployers can
    /// pair against it in registerSpot.
    pub fn spotDeployEnableQuoteToken(self: *Client, s: Signer, token: u32, nonce: u64) !ExchangeResult {
        return self.spotDeployTokenAction(s, "enableQuoteToken", token, nonce);
    }

    /// Enable an aligned quote token. Requires the extra 800k HYPE stake and
    /// validator vote off-chain — see docs/hypercore/aligned-quote-assets.md.
    pub fn spotDeployEnableAlignedQuoteToken(self: *Client, s: Signer, token: u32, nonce: u64) !ExchangeResult {
        return self.spotDeployTokenAction(s, "enableAlignedQuoteToken", token, nonce);
    }

    pub fn spotDeployUserGenesis(self: *Client, s: Signer, ug: types.SpotDeployUserGenesis, nonce: u64) !ExchangeResult {
        var buf: [4096]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionSpotDeployUserGenesis(&p, ug);
        var json_buf: [8192]u8 = undefined;
        var w_storage: std.Io.Writer = .fixed(&json_buf);
        const w = &w_storage;
        try w.writeAll("{\"type\":\"spotDeploy\",\"userGenesis\":{\"token\":");
        try w.print("{d}", .{ug.token});
        try w.writeAll(",\"userAndWei\":[");
        for (ug.user_and_wei, 0..) |pair, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("[\"{s}\",\"{s}\"]", .{ pair[0], pair[1] });
        }
        try w.writeAll("],\"existingTokenAndWei\":[");
        for (ug.existing_token_and_wei, 0..) |pair, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("[{d},\"{s}\"]", .{ pair.token, pair.wei });
        }
        try w.writeAll("]}}");
        return self.sendSpotDeploy(s, p.written(), w.buffered(), nonce);
    }

    pub fn spotDeployRegisterHyperliquidity(self: *Client, s: Signer, rh: types.SpotDeployRegisterHyperliquidity, nonce: u64) !ExchangeResult {
        var buf: [512]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionSpotDeployRegisterHyperliquidity(&p, rh);
        var json_buf: [512]u8 = undefined;
        var w_storage: std.Io.Writer = .fixed(&json_buf);
        const w = &w_storage;
        try w.print("{{\"type\":\"spotDeploy\",\"registerHyperliquidity\":{{\"spot\":{d},\"startPx\":\"{s}\",\"orderSz\":\"{s}\",\"nOrders\":{d}", .{ rh.spot, rh.start_px, rh.order_sz, rh.n_orders });
        if (rh.n_seeded_levels) |nsl| {
            try w.print(",\"nSeededLevels\":{d}", .{nsl});
        }
        try w.writeAll("}}");
        return self.sendSpotDeploy(s, p.written(), w.buffered(), nonce);
    }

    pub fn spotDeployFreezeUser(self: *Client, s: Signer, token: u32, user: []const u8, freeze: bool, nonce: u64) !ExchangeResult {
        var buf: [256]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionSpotDeployFreezeUser(&p, token, user, freeze);
        var json_buf: [256]u8 = undefined;
        const json_body = std.fmt.bufPrint(&json_buf,
            \\{{"type":"spotDeploy","freezeUser":{{"token":{d},"user":"{s}","freeze":{s}}}}}
        , .{ token, user, if (freeze) "true" else "false" }) catch return error.BufferOverflow;
        return self.sendSpotDeploy(s, p.written(), json_body, nonce);
    }

    pub fn spotDeploySetTradingFeeShare(self: *Client, s: Signer, token: u32, share: []const u8, nonce: u64) !ExchangeResult {
        var buf: [256]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionSpotDeploySetTradingFeeShare(&p, token, share);
        var json_buf: [256]u8 = undefined;
        const json_body = std.fmt.bufPrint(&json_buf,
            \\{{"type":"spotDeploy","setDeployerTradingFeeShare":{{"token":{d},"share":"{s}"}}}}
        , .{ token, share }) catch return error.BufferOverflow;
        return self.sendSpotDeploy(s, p.written(), json_body, nonce);
    }

    // ── EVM Contract Linking (HyperCore <-> HyperEVM) ─────────────

    /// Request linking a HIP-1 token to a HyperEVM ERC-20 (spotDeploy action,
    /// sent by the Core spot deployer). `r.address` must be lowercase hex.
    pub fn spotDeployRequestEvmContract(self: *Client, s: Signer, r: types.SpotDeployRequestEvmContract, nonce: u64) !ExchangeResult {
        var buf: [256]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionSpotDeployRequestEvmContract(&p, r);
        var json_buf: [256]u8 = undefined;
        const json_body = std.fmt.bufPrint(&json_buf,
            \\{{"type":"spotDeploy","requestEvmContract":{{"token":{d},"address":"{s}","evmExtraWeiDecimals":{d}}}}}
        , .{ r.token, r.address, r.evm_extra_wei_decimals }) catch return error.BufferOverflow;
        return self.sendSpotDeploy(s, p.written(), json_body, nonce);
    }

    /// Finalize an EVM contract link (top-level action, sent by the EVM
    /// contract's deployer). Signed via the same L1-action path as spotDeploy.
    pub fn finalizeEvmContract(self: *Client, s: Signer, token: u32, input: types.FinalizeEvmContractInput, nonce: u64) !ExchangeResult {
        var buf: [256]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionFinalizeEvmContract(&p, token, input);
        var json_buf: [256]u8 = undefined;
        var w_storage: std.Io.Writer = .fixed(&json_buf);
        const w = &w_storage;
        try w.print("{{\"type\":\"finalizeEvmContract\",\"token\":{d},\"input\":", .{token});
        switch (input) {
            .create => |create_nonce| try w.print("{{\"create\":{{\"nonce\":{d}}}}}", .{create_nonce}),
            .first_storage_slot => try w.writeAll("\"firstStorageSlot\""),
            .custom_storage_slot => try w.writeAll("\"customStorageSlot\""),
        }
        try w.writeAll("}");
        return self.sendSpotDeploy(s, p.written(), w.buffered(), nonce);
    }

    // ── Perp Deploy ───────────────────────────────────────────────

    fn sendPerpDeploy(
        self: *Client,
        s: Signer,
        packed_action: []const u8,
        json_body: []const u8,
        nonce: u64,
    ) !ExchangeResult {
        const sig = try signing.signPerpDeploy(s, packed_action, nonce, self.chain, null);
        var body_buf: [8192]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{s},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{ json_body, nonce, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    pub fn perpDeployRegisterAsset(self: *Client, s: Signer, ra: types.PerpDeployRegisterAsset, nonce: u64) !ExchangeResult {
        var buf: [2048]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionPerpDeployRegisterAsset(&p, ra);
        var json_buf: [2048]u8 = undefined;
        var w_storage: std.Io.Writer = .fixed(&json_buf);
        const w = &w_storage;
        try w.writeAll("{\"type\":\"perpDeploy\",\"registerAsset\":{");
        if (ra.max_gas) |mg| {
            try w.print("\"maxGas\":{d},", .{mg});
        }
        try w.print("\"assetRequest\":{{\"coin\":\"{s}\",\"szDecimals\":{d},\"oraclePx\":\"{s}\",\"marginTableId\":{d},\"onlyIsolated\":{s}}}", .{
            ra.coin,                                   ra.sz_decimals, ra.oracle_px, ra.margin_table_id,
            if (ra.only_isolated) "true" else "false",
        });
        try w.print(",\"dex\":\"{s}\"", .{ra.dex});
        if (ra.schema_full_name != null or ra.schema_collateral_token != null or ra.schema_oracle_updater != null) {
            try w.writeAll(",\"schema\":{");
            try w.print("\"fullName\":\"{s}\"", .{ra.schema_full_name orelse ""});
            if (ra.schema_collateral_token) |ct| {
                try w.print(",\"collateralToken\":{d}", .{ct});
            }
            if (ra.schema_oracle_updater) |ou| {
                try w.print(",\"oracleUpdater\":\"{s}\"", .{ou});
            } else {
                try w.writeAll(",\"oracleUpdater\":null");
            }
            try w.writeAll("}");
        } else {
            try w.writeAll(",\"schema\":null");
        }
        try w.writeAll("}}");
        return self.sendPerpDeploy(s, p.written(), w.buffered(), nonce);
    }

    pub fn perpDeploySetOracle(
        self: *Client,
        s: Signer,
        dex: []const u8,
        oracle_pxs: []const types.OraclePxEntry,
        mark_pxs: []const []const types.OraclePxEntry,
        external_perp_pxs: []const types.OraclePxEntry,
        nonce: u64,
    ) !ExchangeResult {
        var buf: [8192]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionPerpDeploySetOracle(&p, dex, oracle_pxs, mark_pxs, external_perp_pxs);
        var json_buf: [8192]u8 = undefined;
        var w_storage: std.Io.Writer = .fixed(&json_buf);
        const w = &w_storage;
        try w.print("{{\"type\":\"perpDeploy\",\"setOracle\":{{\"dex\":\"{s}\",\"oraclePxs\":[", .{dex});
        for (oracle_pxs, 0..) |entry, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("[\"{s}\",\"{s}\"]", .{ entry.coin, entry.px });
        }
        try w.writeAll("],\"markPxs\":[");
        for (mark_pxs, 0..) |group, gi| {
            if (gi > 0) try w.writeAll(",");
            try w.writeAll("[");
            for (group, 0..) |entry, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("[\"{s}\",\"{s}\"]", .{ entry.coin, entry.px });
            }
            try w.writeAll("]");
        }
        try w.writeAll("],\"externalPerpPxs\":[");
        for (external_perp_pxs, 0..) |entry, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("[\"{s}\",\"{s}\"]", .{ entry.coin, entry.px });
        }
        try w.writeAll("]}}");
        return self.sendPerpDeploy(s, p.written(), w.buffered(), nonce);
    }

    // ── Validator/Signer ──────────────────────────────────────────

    fn sendCSigner(
        self: *Client,
        s: Signer,
        packed_action: []const u8,
        json_body: []const u8,
        nonce: u64,
    ) !ExchangeResult {
        const sig = try signing.signCSignerAction(s, packed_action, nonce, self.chain, null);
        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{s},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{ json_body, nonce, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    pub fn cSignerJailSelf(self: *Client, s: Signer, nonce: u64) !ExchangeResult {
        var buf: [128]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionCSignerJailSelf(&p);
        return self.sendCSigner(s, p.written(), "{\"type\":\"CSignerAction\",\"jailSelf\":null}", nonce);
    }

    pub fn cSignerUnjailSelf(self: *Client, s: Signer, nonce: u64) !ExchangeResult {
        var buf: [128]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionCSignerUnjailSelf(&p);
        return self.sendCSigner(s, p.written(), "{\"type\":\"CSignerAction\",\"unjailSelf\":null}", nonce);
    }

    fn sendCValidator(
        self: *Client,
        s: Signer,
        packed_action: []const u8,
        json_body: []const u8,
        nonce: u64,
    ) !ExchangeResult {
        const sig = try signing.signCValidatorAction(s, packed_action, nonce, self.chain, null);
        var body_buf: [4096]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{s},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{ json_body, nonce, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    pub fn cValidatorRegister(self: *Client, s: Signer, reg: types.ValidatorRegister, nonce: u64) !ExchangeResult {
        var buf: [1024]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionCValidatorRegister(&p, reg.profile, reg.unjailed, reg.initial_wei);
        var json_buf: [2048]u8 = undefined;
        var w_storage: std.Io.Writer = .fixed(&json_buf);
        const w = &w_storage;
        try w.print("{{\"type\":\"CValidatorAction\",\"register\":{{\"profile\":{{\"node_ip\":{{\"Ip\":\"{s}\"}},\"name\":\"{s}\",\"description\":\"{s}\",\"delegations_disabled\":{s},\"commission_bps\":{d},\"signer\":\"{s}\"}},\"unjailed\":{s},\"initial_wei\":{d}}}}}", .{
            reg.profile.node_ip,                                       reg.profile.name,           reg.profile.description,
            if (reg.profile.delegations_disabled) "true" else "false", reg.profile.commission_bps, reg.profile.signer,
            if (reg.unjailed) "true" else "false",                     reg.initial_wei,
        });
        return self.sendCValidator(s, p.written(), w.buffered(), nonce);
    }

    pub fn cValidatorChangeProfile(self: *Client, s: Signer, cp: types.ValidatorProfileChange, nonce: u64) !ExchangeResult {
        var buf: [1024]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionCValidatorChangeProfile(&p, cp);
        var json_buf: [2048]u8 = undefined;
        var w_storage: std.Io.Writer = .fixed(&json_buf);
        const w = &w_storage;
        try w.writeAll("{\"type\":\"CValidatorAction\",\"changeProfile\":{");
        if (cp.node_ip) |ip| {
            try w.print("\"node_ip\":{{\"Ip\":\"{s}\"}}", .{ip});
        } else {
            try w.writeAll("\"node_ip\":null");
        }
        if (cp.name) |n| {
            try w.print(",\"name\":\"{s}\"", .{n});
        } else {
            try w.writeAll(",\"name\":null");
        }
        if (cp.description) |d| {
            try w.print(",\"description\":\"{s}\"", .{d});
        } else {
            try w.writeAll(",\"description\":null");
        }
        try w.print(",\"unjailed\":{s}", .{if (cp.unjailed) "true" else "false"});
        if (cp.disable_delegations) |dd| {
            try w.print(",\"disable_delegations\":{s}", .{if (dd) "true" else "false"});
        } else {
            try w.writeAll(",\"disable_delegations\":null");
        }
        if (cp.commission_bps) |cb| {
            try w.print(",\"commission_bps\":{d}", .{cb});
        } else {
            try w.writeAll(",\"commission_bps\":null");
        }
        if (cp.signer) |sg| {
            try w.print(",\"signer\":\"{s}\"", .{sg});
        } else {
            try w.writeAll(",\"signer\":null");
        }
        try w.writeAll("}}");
        return self.sendCValidator(s, p.written(), w.buffered(), nonce);
    }

    pub fn cValidatorUnregister(self: *Client, s: Signer, nonce: u64) !ExchangeResult {
        var buf: [128]u8 = undefined;
        var p = msgpack.Packer.init(&buf);
        try types.packActionCValidatorUnregister(&p);
        return self.sendCValidator(s, p.written(), "{\"type\":\"CValidatorAction\",\"unregister\":null}", nonce);
    }

    /// Send a pre-built ActionRequest (for advanced use / multi-sig).
    pub fn sendRaw(self: *Client, body: []const u8) !ExchangeResult {
        return self.exchangeRequestDyn(body);
    }

    // ── Typed Info Endpoints ──────────────────────────────────────

    const R = resp_types;
    const Parsed = std.json.Parsed;

    pub fn getClearinghouseState(self: *Client, user: []const u8, dex_name: ?[]const u8) !Parsed(R.ClearinghouseState) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBody(&buf, "clearinghouseState", user, dex_name);
        return self.infoTyped(R.ClearinghouseState, body);
    }

    pub fn getSpotBalances(self: *Client, user: []const u8) !Parsed(R.SpotClearinghouseState) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "spotClearinghouseState", user);
        return self.infoTyped(R.SpotClearinghouseState, body);
    }

    pub fn getOpenOrders(self: *Client, user: []const u8, dex_name: ?[]const u8) !Parsed([]R.BasicOrder) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBody(&buf, "frontendOpenOrders", user, dex_name);
        return self.infoTyped([]R.BasicOrder, body);
    }

    pub fn getUserFills(self: *Client, user: []const u8) !Parsed([]R.Fill) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userFills", user);
        return self.infoTyped([]R.Fill, body);
    }

    pub fn getHistoricalOrders(self: *Client, user: []const u8) !Parsed([]R.HistoricalOrder) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "historicalOrders", user);
        return self.infoTyped([]R.HistoricalOrder, body);
    }

    pub fn getUserFunding(self: *Client, user: []const u8, start_time: u64, end_time: ?u64) !Parsed([]R.UserFunding) {
        var buf: [512]u8 = undefined;
        const body = if (end_time) |et|
            std.fmt.bufPrint(&buf,
                \\{{"type":"userFunding","user":"{s}","startTime":{d},"endTime":{d}}}
            , .{ user, start_time, et }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&buf,
                \\{{"type":"userFunding","user":"{s}","startTime":{d}}}
            , .{ user, start_time }) catch return error.BufferOverflow;
        return self.infoTyped([]R.UserFunding, body);
    }

    pub fn getFundingHistory(self: *Client, coin: []const u8, start_time: u64, end_time: ?u64) !Parsed([]R.FundingRate) {
        var buf: [512]u8 = undefined;
        const body = if (end_time) |et|
            std.fmt.bufPrint(&buf,
                \\{{"type":"fundingHistory","coin":"{s}","startTime":{d},"endTime":{d}}}
            , .{ coin, start_time, et }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&buf,
                \\{{"type":"fundingHistory","coin":"{s}","startTime":{d}}}
            , .{ coin, start_time }) catch return error.BufferOverflow;
        return self.infoTyped([]R.FundingRate, body);
    }

    pub fn getCandleSnapshot(self: *Client, coin: []const u8, interval: []const u8, start_time: u64, end_time: u64) !Parsed([]R.Candle) {
        var buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"candleSnapshot","req":{{"coin":"{s}","interval":"{s}","startTime":{d},"endTime":{d}}}}}
        , .{ coin, interval, start_time, end_time }) catch return error.BufferOverflow;
        return self.infoTyped([]R.Candle, body);
    }

    pub fn getUserRole(self: *Client, user: []const u8) !Parsed(R.UserRole) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userRole", user);
        return self.infoTyped(R.UserRole, body);
    }

    pub fn getApiAgents(self: *Client, user: []const u8) !Parsed([]R.ApiAgent) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "extraAgents", user);
        return self.infoTyped([]R.ApiAgent, body);
    }

    pub fn getSubaccounts(self: *Client, user: []const u8) !Parsed([]R.SubAccount) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "subAccounts", user);
        return self.infoTyped([]R.SubAccount, body);
    }

    fn infoTypedFilteredOptional(self: *Client, comptime T: type, body: []const u8) !Parsed([]T) {
        const parsed = try self.infoTyped([]?T, body);

        var count: usize = 0;
        for (parsed.value) |entry| {
            if (entry != null) count += 1;
        }

        const filtered = try parsed.arena.allocator().alloc(T, count);
        var i: usize = 0;
        for (parsed.value) |entry| {
            if (entry) |value| {
                filtered[i] = value;
                i += 1;
            }
        }

        return .{ .arena = parsed.arena, .value = filtered };
    }

    pub fn getDexInfos(self: *Client) !Parsed([]R.DexInfo) {
        return self.infoTypedFilteredOptional(R.DexInfo, "{\"type\":\"perpDexs\"}");
    }

    pub fn getPerpDexs(self: *Client) !Parsed([]R.Dex) {
        return self.infoTypedFilteredOptional(R.Dex,
            \\{"type":"perpDexs"}
        );
    }

    pub fn getPerps(self: *Client, dex_name: ?[]const u8) !Parsed(R.PerpUniverse) {
        if (dex_name) |d| {
            var buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&buf,
                \\{{"type":"meta","dex":"{s}"}}
            , .{d}) catch return error.BufferOverflow;
            return self.infoTyped(R.PerpUniverse, body);
        }
        return self.infoTyped(R.PerpUniverse,
            \\{"type":"meta"}
        );
    }

    pub fn getSpotMeta(self: *Client) !Parsed(R.SpotMeta) {
        return self.infoTyped(R.SpotMeta,
            \\{"type":"spotMeta"}
        );
    }

    pub fn getOutcomeMeta(self: *Client) !Parsed(R.OutcomeMeta) {
        return self.infoTyped(R.OutcomeMeta,
            \\{"type":"outcomeMeta"}
        );
    }

    /// Parse spotMetaAndAssetCtxs — heterogeneous [spotMeta, [ctx, ...]] tuple.
    pub fn getSpotMetaAndAssetCtxs(self: *Client) !SpotMetaAndAssetCtxsResult {
        var raw = try self.infoRequest(
            \\{"type":"spotMetaAndAssetCtxs"}
        );
        defer raw.deinit();
        const val = try raw.json();
        if (val != .array or val.array.items.len < 2) return error.Overflow;
        const meta_val = val.array.items[0];
        const ctxs_val = val.array.items[1];

        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const meta = try std.json.parseFromValue(R.SpotMeta, a, meta_val, R.ParseOpts);

        const ctx_arr = if (ctxs_val == .array) ctxs_val.array.items else return error.Overflow;
        var ctxs = try a.alloc(R.SpotAssetCtx, ctx_arr.len);
        var count: usize = 0;
        for (ctx_arr) |item| {
            const ctx = std.json.parseFromValue(R.SpotAssetCtx, a, item, R.ParseOpts) catch continue;
            ctxs[count] = ctx.value;
            count += 1;
        }
        return .{ .arena = arena, .meta = meta.value, .ctxs = ctxs[0..count] };
    }

    pub const SpotMetaAndAssetCtxsResult = struct {
        arena: std.heap.ArenaAllocator,
        meta: R.SpotMeta,
        ctxs: []R.SpotAssetCtx,

        pub fn deinit(self: *SpotMetaAndAssetCtxsResult) void {
            self.arena.deinit();
        }
    };

    pub fn getTokenDetails(self: *Client, token_id: []const u8) !Parsed(R.TokenDetails) {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"type\":\"tokenDetails\",\"tokenId\":\"{s}\"}}", .{token_id}) catch return error.Overflow;
        return self.infoTyped(R.TokenDetails, body);
    }

    pub fn getRecentTrades(self: *Client, coin: []const u8) !Parsed([]R.Trade) {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"type\":\"recentTrades\",\"coin\":\"{s}\"}}", .{coin}) catch return error.Overflow;
        return self.infoTyped([]R.Trade, body);
    }

    /// Parse metaAndAssetCtxs — heterogeneous [meta, [ctx, ...]] tuple.
    /// Returns a slice of MetaAndAssetCtx pairing each PerpMeta with its AssetContext.
    pub fn getMetaAndAssetCtxs(self: *Client, dex_name: ?[]const u8) !MetaAndAssetCtxsResult {
        var raw = if (dex_name) |d| blk: {
            var buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&buf, "{{\"type\":\"metaAndAssetCtxs\",\"dexName\":\"{s}\"}}", .{d}) catch return error.Overflow;
            break :blk try self.infoRequest(body);
        } else try self.metaAndAssetCtxs();
        defer raw.deinit();
        const val = try raw.json();
        if (val != .array or val.array.items.len < 2) return error.Overflow;
        const meta_val = val.array.items[0];
        const ctxs_val = val.array.items[1];
        const universe_arr = if (meta_val == .object)
            if (meta_val.object.get("universe")) |u| (if (u == .array) u.array.items else null) else null
        else
            null;
        const ctx_arr = if (ctxs_val == .array) ctxs_val.array.items else null;
        const u_arr = universe_arr orelse return error.Overflow;
        const c_arr = ctx_arr orelse return error.Overflow;
        const n = @min(u_arr.len, c_arr.len);

        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var entries = try a.alloc(R.MetaAndAssetCtx, n);
        var count: usize = 0;
        for (0..n) |i| {
            const meta = std.json.parseFromValue(R.PerpMeta, a, u_arr[i], R.ParseOpts) catch continue;
            const ctx = std.json.parseFromValue(R.AssetContext, a, c_arr[i], R.ParseOpts) catch continue;
            entries[count] = .{ .meta = meta.value, .ctx = ctx.value };
            count += 1;
        }
        return .{ .arena = arena, .entries = entries[0..count] };
    }

    pub const MetaAndAssetCtxsResult = struct {
        arena: std.heap.ArenaAllocator,
        entries: []R.MetaAndAssetCtx,

        pub fn deinit(self: *MetaAndAssetCtxsResult) void {
            self.arena.deinit();
        }
    };

    pub fn getL2Book(self: *Client, coin: []const u8) !Parsed(R.L2Book) {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"type\":\"l2Book\",\"coin\":\"{s}\"}}", .{coin}) catch return error.Overflow;
        return self.infoTyped(R.L2Book, body);
    }

    pub fn getAllMids(self: *Client, dex_name: ?[]const u8) !Parsed(std.json.Value) {
        if (dex_name) |d| {
            var buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&buf, "{{\"type\":\"allMids\",\"dexName\":\"{s}\"}}", .{d}) catch return error.Overflow;
            return self.infoTyped(std.json.Value, body);
        }
        return self.infoTyped(std.json.Value, "{\"type\":\"allMids\"}");
    }

    pub fn getReferral(self: *Client, user: []const u8) !Parsed(R.Referral) {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"type\":\"referral\",\"user\":\"{s}\"}}", .{user}) catch return error.Overflow;
        return self.infoTyped(R.Referral, body);
    }

    pub fn getActiveAssetData(self: *Client, user: []const u8, coin: []const u8) !Parsed(R.ActiveAssetData) {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"activeAssetData","user":"{s}","coin":"{s}"}}
        , .{ user, coin }) catch return error.BufferOverflow;
        return self.infoTyped(R.ActiveAssetData, body);
    }

    pub fn getUserFees(self: *Client, user: []const u8) !Parsed(R.UserFees) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userFees", user);
        return self.infoTyped(R.UserFees, body);
    }

    pub fn getUserRateLimit(self: *Client, user: []const u8) !Parsed(R.UserRateLimit) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userRateLimit", user);
        return self.infoTyped(R.UserRateLimit, body);
    }

    pub fn getUserFillsByTime(self: *Client, user: []const u8, start_time: u64, end_time: ?u64) !Parsed([]R.Fill) {
        var buf: [512]u8 = undefined;
        const body = if (end_time) |et|
            std.fmt.bufPrint(&buf,
                \\{{"type":"userFillsByTime","user":"{s}","startTime":{d},"endTime":{d}}}
            , .{ user, start_time, et }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&buf,
                \\{{"type":"userFillsByTime","user":"{s}","startTime":{d}}}
            , .{ user, start_time }) catch return error.BufferOverflow;
        return self.infoTyped([]R.Fill, body);
    }

    // ── Internal HTTP helpers ─────────────────────────────────────

    pub const InfoResult = struct {
        allocator: std.mem.Allocator,
        body: []u8,
        parsed: ?std.json.Parsed(std.json.Value),
        status: std.http.Status,

        pub fn json(self: *InfoResult) !std.json.Value {
            if (self.parsed == null) {
                self.parsed = try std.json.parseFromSlice(
                    std.json.Value,
                    self.allocator,
                    self.body,
                    .{ .allocate = .alloc_always },
                );
            }
            return self.parsed.?.value;
        }

        pub fn deinit(self: *InfoResult) void {
            if (self.parsed) |*p| p.deinit();
            self.allocator.free(self.body);
        }
    };

    pub const ExchangeResult = struct {
        allocator: std.mem.Allocator,
        body: []u8,
        parsed: ?std.json.Parsed(std.json.Value),
        status: std.http.Status,

        pub fn json(self: *ExchangeResult) !std.json.Value {
            if (self.parsed == null) {
                self.parsed = try std.json.parseFromSlice(
                    std.json.Value,
                    self.allocator,
                    self.body,
                    .{ .allocate = .alloc_always },
                );
            }
            return self.parsed.?.value;
        }

        pub fn isOk(self: *ExchangeResult) !bool {
            const val = try self.json();
            const status_str = json_mod.getString(val, "status") orelse return false;
            return std.mem.eql(u8, status_str, "ok");
        }

        pub fn deinit(self: *ExchangeResult) void {
            if (self.parsed) |*p| p.deinit();
            self.allocator.free(self.body);
        }
    };

    /// Typed info request: HTTP POST → parse JSON → typed struct.
    /// Uses std.json.parseFromSlice with ignore_unknown_fields.
    fn infoTyped(self: *Client, comptime T: type, body: []const u8) !std.json.Parsed(T) {
        var raw = try self.infoRequestDyn(body);
        defer raw.deinit();
        return std.json.parseFromSlice(T, self.allocator, raw.body, resp_types.ParseOpts) catch
            return error.JsonParseFailed;
    }

    fn infoRequest(self: *Client, body: []const u8) !InfoResult {
        return self.infoRequestDyn(body);
    }

    fn infoRequestDyn(self: *Client, body: []const u8) !InfoResult {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/info", .{self.base_url}) catch return error.BufferOverflow;

        const response_body = try self.doPost(url, body);
        errdefer self.allocator.free(response_body.body);
        return InfoResult{
            .allocator = self.allocator,
            .body = response_body.body,
            .parsed = null,
            .status = response_body.status,
        };
    }

    fn exchangeRequestDyn(self: *Client, body: []const u8) !ExchangeResult {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/exchange", .{self.base_url}) catch return error.BufferOverflow;

        const response_body = try self.doPost(url, body);
        errdefer self.allocator.free(response_body.body);
        return ExchangeResult{
            .allocator = self.allocator,
            .body = response_body.body,
            .parsed = null,
            .status = response_body.status,
        };
    }

    fn sendExchange(
        self: *Client,
        action_data: anytype,
        sig: Signature,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        var body_buf: [8192]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&body_buf);

        try writer.writeAll("{\"action\":");
        try writeActionJson(&writer, action_data);
        const sig_json_1 = sigJsonStr(sig);
        try writer.print(",\"nonce\":{d},\"signature\":{s}", .{
            nonce,
            sigJsonSlice(&sig_json_1),
        });
        try writeOptionalAddress(&writer, ",\"vaultAddress\":", vault_address);
        try writeOptionalU64(&writer, ",\"expiresAfter\":", expires_after);
        try writer.writeAll("}");
        return self.exchangeRequestDyn(writer.buffered());
    }

    /// Generic exchange endpoint for RMP-path actions that need JSON serialization.
    fn sendExchangeRaw(
        self: *Client,
        sig: Signature,
        nonce: u64,
        action_data: anytype,
        tag: types.ActionTag,
    ) !ExchangeResult {
        return self.sendExchangeRawFull(sig, nonce, action_data, tag, null, null);
    }

    fn sendExchangeRawFull(
        self: *Client,
        sig: Signature,
        nonce: u64,
        action_data: anytype,
        tag: types.ActionTag,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        var body_buf: [8192]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&body_buf);

        try writer.writeAll("{\"action\":");
        try writeActionJsonTagged(&writer, action_data, tag);
        const sig_json = sigJsonStr(sig);
        try writer.print(",\"nonce\":{d},\"signature\":{s}", .{
            nonce,
            sigJsonSlice(&sig_json),
        });
        try writeOptionalAddress(&writer, ",\"vaultAddress\":", vault_address);
        try writeOptionalU64(&writer, ",\"expiresAfter\":", expires_after);
        try writer.writeAll("}");
        return self.exchangeRequestDyn(writer.buffered());
    }

    fn writeOptionalAddress(writer: anytype, prefix: []const u8, addr: ?Address) !void {
        try writer.writeAll(prefix);
        if (addr) |a| {
            try writer.writeAll("\"0x");
            for (a) |b| {
                const hex = "0123456789abcdef";
                try writer.writeAll(&[_]u8{ hex[b >> 4], hex[b & 0xf] });
            }
            try writer.writeAll("\"");
        } else {
            try writer.writeAll("null");
        }
    }

    fn writeOptionalU64(writer: anytype, prefix: []const u8, val: ?u64) !void {
        try writer.writeAll(prefix);
        if (val) |v| {
            try writer.print("{d}", .{v});
        } else {
            try writer.writeAll("null");
        }
    }

    /// Format Address as "0x" + lowercase hex into a fixed buffer.
    const addressToHex = eip712.addressToHex;

    /// Parse a hex address string ("0x..." or raw hex) into 20 bytes.
    pub fn parseAddress(hex: []const u8) !Address {
        const s = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) hex[2..] else hex;
        if (s.len != 40) return error.InvalidAddress;
        var addr: Address = undefined;
        for (0..20) |i| {
            addr[i] = std.fmt.parseInt(u8, s[i * 2 ..][0..2], 16) catch return error.InvalidAddress;
        }
        return addr;
    }

    const HttpResponse = struct {
        status: std.http.Status,
        body: []u8,
    };

    fn doPost(self: *Client, url: []const u8, payload: []const u8) !HttpResponse {
        const uri = std.Uri.parse(url) catch return error.HttpRequestFailed;

        var req = try std.http.Client.request(&self.http_client, .POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = try req.sendBody(&.{});
        try body_writer.writer.writeAll(payload);
        try body_writer.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});
        var reader = response.reader(&.{});
        const body = reader.allocRemaining(self.allocator, @enumFromInt(8 * 1024 * 1024)) catch
            return error.HttpRequestFailed;

        return .{
            .status = response.head.status,
            .body = body,
        };
    }
};

fn writeActionJson(writer: anytype, action_data: anytype) !void {
    const T = @TypeOf(action_data);
    if (T == types.BatchOrder) {
        try writer.writeAll("{\"type\":\"order\",\"orders\":[");
        for (action_data.orders, 0..) |order, i| {
            if (i > 0) try writer.writeAll(",");
            try writeOrderJson(writer, order);
        }
        try writer.print("],\"grouping\":\"{s}\"", .{@tagName(action_data.grouping)});
        if (action_data.builder) |bi| {
            var addr_buf: [42]u8 = undefined;
            addr_buf[0] = '0';
            addr_buf[1] = 'x';
            const hex_chars = "0123456789abcdef";
            for (bi.address, 0..) |b, i| {
                addr_buf[2 + i * 2] = hex_chars[b >> 4];
                addr_buf[2 + i * 2 + 1] = hex_chars[b & 0x0f];
            }
            try writer.print(",\"builder\":{{\"b\":\"{s}\",\"f\":{d}}}", .{ addr_buf[0..42], bi.fee_tenths_bps });
        }
        try writer.writeAll("}");
    } else if (T == types.BatchCancel) {
        try writer.writeAll("{\"type\":\"cancel\",\"cancels\":[");
        for (action_data.cancels, 0..) |c, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"a\":{d},\"o\":{d}}}", .{ c.asset, c.oid });
        }
        try writer.writeAll("]}");
    } else {
        @compileError("unsupported action type for writeActionJson");
    }
}

fn writeActionJsonTagged(writer: anytype, action_data: anytype, tag: types.ActionTag) !void {
    try writer.print("{{\"type\":\"{s}\"", .{@tagName(tag)});
    const T = @TypeOf(action_data);
    if (T == types.BatchCancelCloid) {
        try writer.writeAll(",\"cancels\":[");
        for (action_data.cancels, 0..) |c, i| {
            if (i > 0) try writer.writeAll(",");
            const hex = types.cloidToHex(c.cloid);
            try writer.print("{{\"asset\":{d},\"cloid\":\"{s}\"}}", .{ c.asset, @as([]const u8, &hex) });
        }
        try writer.writeAll("]}");
    } else if (T == types.BatchModify) {
        try writer.writeAll(",\"modifies\":[");
        for (action_data.modifies, 0..) |m, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"oid\":");
            switch (m.oid) {
                .oid => |oid| try writer.print("{d}", .{oid}),
                .cloid => |cloid| {
                    const hex = types.cloidToHex(cloid);
                    try writer.print("\"{s}\"", .{@as([]const u8, &hex)});
                },
            }
            try writer.writeAll(",\"order\":");
            try writeOrderJson(writer, m.order);
            try writer.writeAll("}");
        }
        try writer.writeAll("]}");
    } else if (T == types.ScheduleCancel) {
        if (action_data.time) |t| {
            try writer.print(",\"time\":{d}}}", .{t});
        } else {
            try writer.writeAll(",\"time\":null}");
        }
    } else if (T == types.UpdateIsolatedMargin) {
        try writer.print(",\"asset\":{d},\"isBuy\":{s},\"ntli\":{d}}}", .{
            action_data.asset,
            if (action_data.is_buy) "true" else "false",
            action_data.ntli,
        });
    } else if (T == types.UpdateLeverage) {
        try writer.print(",\"asset\":{d},\"isCross\":{s},\"leverage\":{d}}}", .{
            action_data.asset,
            if (action_data.is_cross) "true" else "false",
            action_data.leverage,
        });
    } else if (T == types.SetReferrer) {
        try writer.print(",\"code\":\"{s}\"}}", .{action_data.code});
    } else if (T == types.VaultTransfer) {
        try writer.print(",\"vaultAddress\":\"{s}\",\"isDeposit\":{s},\"usd\":{d}}}", .{
            action_data.vault_address,
            if (action_data.is_deposit) "true" else "false",
            action_data.usd,
        });
    } else if (T == types.CreateSubAccount) {
        try writer.print(",\"name\":\"{s}\"}}", .{action_data.name});
    } else if (T == types.SubAccountTransfer) {
        try writer.print(",\"subAccountUser\":\"{s}\",\"isDeposit\":{s},\"usd\":{d}}}", .{
            action_data.sub_account_user,
            if (action_data.is_deposit) "true" else "false",
            action_data.usd,
        });
    } else if (T == types.SubAccountSpotTransfer) {
        try writer.print(",\"subAccountUser\":\"{s}\",\"isDeposit\":{s},\"token\":\"{s}\",\"amount\":\"{s}\"}}", .{
            action_data.sub_account_user,
            if (action_data.is_deposit) "true" else "false",
            action_data.token,
            action_data.amount,
        });
    } else if (T == types.TwapOrder) {
        var sz_buf: [64]u8 = undefined;
        const sz_str = action_data.sz.normalize().toString(&sz_buf) catch return error.BufferOverflow;
        try writer.print(",\"twap\":{{\"a\":{d},\"b\":{s},\"s\":\"{s}\",\"r\":{s},\"m\":{d},\"t\":{s}}}}}", .{
            action_data.asset,
            if (action_data.is_buy) "true" else "false",
            sz_str,
            if (action_data.reduce_only) "true" else "false",
            action_data.duration_min,
            if (action_data.randomize) "true" else "false",
        });
    } else if (T == types.TwapCancel) {
        try writer.print(",\"a\":{d},\"t\":{d}}}", .{
            action_data.asset,
            action_data.twap_id,
        });
    } else {
        try writer.writeAll("}");
    }
}

fn writeOrderJson(writer: anytype, order: types.OrderRequest) !void {
    var px_buf: [64]u8 = undefined;
    const px_str = order.limit_px.normalize().toString(&px_buf) catch return error.BufferOverflow;
    var sz_buf: [64]u8 = undefined;
    const sz_str = order.sz.normalize().toString(&sz_buf) catch return error.BufferOverflow;
    try writer.print("{{\"a\":{d},\"b\":{},\"p\":\"{s}\",\"s\":\"{s}\",\"r\":{}", .{
        order.asset,
        order.is_buy,
        px_str,
        sz_str,
        order.reduce_only,
    });

    // Order type
    switch (order.order_type) {
        .limit => |lim| {
            try writer.print(",\"t\":{{\"limit\":{{\"tif\":\"{s}\"}}}}", .{@tagName(lim.tif)});
        },
        .trigger => |trig| {
            var tpx_buf: [64]u8 = undefined;
            const tpx_str = trig.trigger_px.normalize().toString(&tpx_buf) catch return error.BufferOverflow;
            try writer.print(",\"t\":{{\"trigger\":{{\"isMarket\":{},\"triggerPx\":\"{s}\",\"tpsl\":\"{s}\"}}}}", .{
                trig.is_market,
                tpx_str,
                @tagName(trig.tpsl),
            });
        },
    }

    // c: cloid — omit when zero to match server hashing
    if (!std.mem.eql(u8, &order.cloid, &types.ZERO_CLOID)) {
        const cloid_hex = types.cloidToHex(order.cloid);
        try writer.print(",\"c\":\"{s}\"}}", .{@as([]const u8, &cloid_hex)});
    } else {
        try writer.writeAll("}");
    }
}

fn hexByte(buf: *[2]u8, byte: u8) void {
    const charset = "0123456789abcdef";
    buf[0] = charset[byte >> 4];
    buf[1] = charset[byte & 0x0f];
}

fn sigToHex(sig_bytes: [65]u8) [132]u8 {
    var hex: [132]u8 = undefined;
    hex[0] = '0';
    hex[1] = 'x';
    for (sig_bytes, 0..) |byte, i| hexByte(hex[2 + i * 2 ..][0..2], byte);
    return hex;
}

/// Format signature as JSON: {"r":"0x...64hex...","s":"0x...64hex...","v":27}
fn sigJsonStr(sig: Signature) [163]u8 {
    const bytes = sig.toEthBytes();
    var buf: [163]u8 = undefined;
    var pos: usize = 0;

    // r field
    const r_prefix = "{\"r\":\"0x";
    @memcpy(buf[pos..][0..r_prefix.len], r_prefix);
    pos += r_prefix.len;
    for (bytes[0..32]) |b| {
        hexByte(buf[pos..][0..2], b);
        pos += 2;
    }

    // s field
    const s_prefix = "\",\"s\":\"0x";
    @memcpy(buf[pos..][0..s_prefix.len], s_prefix);
    pos += s_prefix.len;
    for (bytes[32..64]) |b| {
        hexByte(buf[pos..][0..2], b);
        pos += 2;
    }

    const suffix = std.fmt.bufPrint(buf[pos..], "\",\"v\":{d}}}", .{bytes[64]}) catch unreachable;
    pos += suffix.len;
    @memset(buf[pos..], 0);
    return buf;
}

fn sigJsonSlice(buf: *const [163]u8) []const u8 {
    // Find the end (after the closing brace)
    for (buf, 0..) |c, i| {
        if (c == 0) return buf[0..i];
    }
    return buf;
}

fn formatInfoBody(buf: []u8, req_type: []const u8, user: []const u8, dex_name: ?[]const u8) ![]const u8 {
    if (dex_name) |d| {
        return std.fmt.bufPrint(buf,
            \\{{"type":"{s}","user":"{s}","dex":"{s}"}}
        , .{ req_type, user, d }) catch return error.BufferOverflow;
    }
    return formatInfoBodySimple(buf, req_type, user);
}

fn formatInfoBodySimple(buf: []u8, req_type: []const u8, user: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\{{"type":"{s}","user":"{s}"}}
    , .{ req_type, user }) catch return error.BufferOverflow;
}

test "sigToHex" {
    var sig_bytes: [65]u8 = [_]u8{0} ** 65;
    sig_bytes[0] = 0xab;
    sig_bytes[64] = 0x1c;
    const hex = sigToHex(sig_bytes);
    try std.testing.expect(std.mem.startsWith(u8, &hex, "0xab"));
    try std.testing.expect(std.mem.endsWith(u8, &hex, "1c"));
}

test "formatInfoBody: simple" {
    var buf: [256]u8 = undefined;
    const body = try formatInfoBodySimple(&buf, "userFills", "0xabc123");
    try std.testing.expectEqualStrings(
        \\{"type":"userFills","user":"0xabc123"}
    , body);
}

test "formatInfoBody: with dex" {
    var buf: [256]u8 = undefined;
    const body = try formatInfoBody(&buf, "clearinghouseState", "0xabc123", "myDex");
    try std.testing.expectEqualStrings(
        \\{"type":"clearinghouseState","user":"0xabc123","dex":"myDex"}
    , body);
}

test "writeOrderJson" {
    const order = types.OrderRequest{
        .asset = 0,
        .is_buy = true,
        .limit_px = Decimal.fromString("50000") catch unreachable,
        .sz = Decimal.fromString("0.1") catch unreachable,
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = types.ZERO_CLOID,
    };

    var buf: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeOrderJson(&writer, order);
    const json = writer.buffered();

    // Verify it contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"a\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"b\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"p\":\"50000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"s\":\"0.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tif\":\"Gtc\"") != null);
}
