//! Minimal argument parser for the `hl` CLI.
//!
//! No external dependencies — just iterates std.process.args().
//! Supports subcommands, flags (--flag value), and positional args.

const std = @import("std");

pub const Command = union(enum) {
    keys: KeysArgs,
    mids: MidsArgs,
    positions: UserQuery,
    orders: UserQuery,
    fills: FillsArgs,
    balance: UserQuery,
    perps: MarketArgs,
    spot: MarketArgs,
    outcomes: MarketArgs,
    dexes: void,
    buy: OrderArgs,
    sell: OrderArgs,
    cancel: CancelArgs,
    modify: ModifyArgs,
    send: SendArgs,
    stream: StreamArgs,
    status: StatusArgs,
    funding: FundingArgs,
    book: BookArgs,
    markets: void,
    trade: TradeArgs,
    leverage: LeverageArgs,
    price: PriceArgs,
    portfolio: UserQuery,
    referral: ReferralArgs,
    twap: TwapArgs,
    batch: BatchArgs,
    approve_agent: ApproveAgentArgs,
    withdraw: WithdrawArgs,
    transfer: TransferArgs,
    fees: UserQuery,
    rate_limit: UserQuery,
    stake: StakeArgs,
    vault: VaultArgs,
    ledger: LedgerArgs,
    approve_builder: ApproveBuilderArgs,
    subaccount: SubAccountArgs,
    account: AccountArgs,
    deploy: DeployArgs,
    config: void,
    help: HelpArgs,
    version: void,
};

pub const DeployArgs = struct {
    action: DeployAction = .help,
};

/// Nested deploy subcommands. Individual variants get filled in one at a time
/// as their handlers land; `.help` renders the tree.
pub const DeployAction = union(enum) {
    help,
    status: DeployStatusArgs,
    spot_register: DeploySpotRegisterArgs,
    spot_user_genesis: DeploySpotUserGenesisArgs,
    spot_genesis: DeploySpotGenesisArgs,
};

pub const DeployStatusArgs = struct {
    pair: bool = false,
};

pub const DeploySpotRegisterArgs = struct {
    name: []const u8,
    sz_decimals: u32,
    wei_decimals: u32,
    /// maxGas in HYPE wei (8 decimals) — the CLI accepts `--max-gas` in whole HYPE and multiplies.
    max_gas_hype: u64,
    full_name: ?[]const u8 = null,
    dry_run: bool = false,
};

pub const DeploySpotUserGenesisArgs = struct {
    token: u32,
    /// Raw slots referencing --alloc addr:wei entries.
    user_allocs: [64]?[]const u8 = .{null} ** 64,
    user_count: usize = 0,
    /// Raw slots referencing --from-token tid:wei entries.
    existing_allocs: [16]?[]const u8 = .{null} ** 16,
    existing_count: usize = 0,
    dry_run: bool = false,
};

pub const DeploySpotGenesisArgs = struct {
    token: u32,
    max_supply: []const u8,
    no_hyperliquidity: bool = false,
    dry_run: bool = false,
};

pub const HelpTopic = enum {
    keys,
    mids,
    positions,
    orders,
    fills,
    balance,
    perps,
    spot,
    outcomes,
    dexes,
    buy,
    sell,
    cancel,
    modify,
    send,
    stream,
    status,
    funding,
    book,
    markets,
    trade,
    leverage,
    price,
    portfolio,
    referral,
    twap,
    batch,
    approve_agent,
    withdraw,
    transfer,
    fees,
    rate_limit,
    stake,
    vault,
    ledger,
    approve_builder,
    subaccount,
    account,
    deploy,
    config,
    help,
    version,

    pub fn commandName(self: HelpTopic) []const u8 {
        return switch (self) {
            .approve_agent => "approve-agent",
            .rate_limit => "rate-limit",
            .approve_builder => "approve-builder",
            else => @tagName(self),
        };
    }
};

pub const HelpArgs = struct {
    topic: ?HelpTopic = null,
    invalid_topic: ?[]const u8 = null,
};

pub const MidsArgs = struct {
    coin: ?[]const u8 = null,
    dex: ?[]const u8 = null,
    all: bool = false,
    page: usize = 1,
};

pub const UserQuery = struct {
    address: ?[]const u8 = null,
    dex: ?[]const u8 = null,
    all_dexes: bool = false,
};

pub const MarketArgs = struct {
    dex: ?[]const u8 = null,
    all: bool = false,
    page: usize = 1,
    filter: ?[]const u8 = null,
};

pub const OrderArgs = struct {
    coin: []const u8,
    size: []const u8,
    price: ?[]const u8 = null,
    slippage: ?[]const u8 = null,
    reduce_only: bool = false,
    tif: []const u8 = "gtc",
    trigger_px: ?[]const u8 = null,
    trigger_is_tp: bool = true,
    tp: ?[]const u8 = null,
    sl: ?[]const u8 = null,
    dry_run: bool = false,
    builder: ?[]const u8 = null,
    builder_fee: ?[]const u8 = null,
};

pub const CancelArgs = struct {
    coin: ?[]const u8 = null,
    oid: ?[]const u8 = null,
    cloid: ?[]const u8 = null,
    all: bool = false,
};

pub const SendArgs = struct {
    amount: []const u8,
    token: []const u8 = "USDC",
    destination: ?[]const u8 = null, // null = self (internal transfer)
    from: []const u8 = "perp",
    to: []const u8 = "perp",
    subaccount: ?[]const u8 = null,
    agent: bool = false,
};

pub const ModifyArgs = struct {
    coin: []const u8,
    oid: []const u8,
    size: []const u8,
    price: []const u8,
};

pub const StreamArgs = struct {
    kind: StreamKind = .trades,
    coin: ?[]const u8 = null,
    address: ?[]const u8 = null,
    interval: []const u8 = "1m",
    filter: ?[]const u8 = null,
};

pub const StreamKind = enum {
    trades,
    bbo,
    book,
    candles,
    mids,
    fills,
    orders,
};

pub const StatusArgs = struct {
    oid: []const u8,
};

pub const FundingArgs = struct {
    top: usize = 20,
    all: bool = false,
    page: usize = 1,
    filter: ?[]const u8 = null,
    dex: ?[]const u8 = null,
};

pub const TradeArgs = struct {
    coin: []const u8 = "BTC",
};

pub const BookArgs = struct {
    coin: []const u8,
    depth: usize = 15,
    live: bool = false,
};

pub const LeverageArgs = struct {
    coin: []const u8,
    leverage: ?[]const u8 = null, // null = query only
    cross: bool = true, // --isolated flips to false
};

pub const PriceArgs = struct {
    coin: []const u8,
    dex: ?[]const u8 = null,
    quote: ?[]const u8 = null,
    all: bool = false,
};

pub const ReferralArgs = struct {
    action: ReferralAction = .status,
    code: ?[]const u8 = null,
};

pub const ReferralAction = enum { status, set };

pub const TwapArgs = struct {
    coin: []const u8,
    side: []const u8, // "buy" or "sell"
    size: []const u8,
    duration: []const u8 = "1h", // 5m, 15m, 1h, 4h, etc.
    slices: usize = 10,
    slippage_pct: f64 = 1.0, // max slippage per slice (%)
};

pub const BatchArgs = struct {
    orders: [16]?[]const u8 = .{null} ** 16,
    count: usize = 0,
    stdin: bool = false,
    builder: ?[]const u8 = null,
    builder_fee: ?[]const u8 = null,
};

pub const KeysArgs = struct {
    action: KeysAction = .ls,
    name: ?[]const u8 = null,
    key_hex: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

pub const KeysAction = enum { ls, new, import_, rm, export_, default };

pub const FillsArgs = struct {
    address: ?[]const u8 = null,
    start_time: ?[]const u8 = null,
    end_time: ?[]const u8 = null,
};

pub const WithdrawArgs = struct {
    amount: []const u8,
    destination: ?[]const u8 = null,
};

pub const TransferArgs = struct {
    amount: []const u8,
    direction: TransferDirection,
};

pub const TransferDirection = enum { to_spot, to_perp };

pub const StakeArgs = struct {
    action: StakeAction = .status,
    validator: ?[]const u8 = null,
    amount: ?[]const u8 = null,
};

pub const StakeAction = enum { status, delegate, undelegate, rewards, history };

pub const VaultArgs = struct {
    action: VaultAction = .info,
    vault_address: ?[]const u8 = null,
    amount: ?[]const u8 = null,
};

pub const VaultAction = enum { info, deposit, withdraw };

pub const LedgerArgs = struct {
    address: ?[]const u8 = null,
    start_time: ?[]const u8 = null,
    end_time: ?[]const u8 = null,
};

pub const ApproveBuilderArgs = struct {
    builder: []const u8,
    max_fee_rate: []const u8,
};

pub const SubAccountArgs = struct {
    action: SubAccountAction = .list,
    name: ?[]const u8 = null,
    sub_address: ?[]const u8 = null,
    amount: ?[]const u8 = null,
    token: ?[]const u8 = null,
    is_deposit: bool = true,
};

pub const SubAccountAction = enum { list, create, transfer, spot_transfer };

pub const AccountArgs = struct {
    mode: ?AccountMode = null, // null = show help / current info
    invalid_mode: ?[]const u8 = null, // set when user typed unrecognized mode
};

/// Maps to Hyperliquid's abstraction modes.
/// See: https://hyperliquid.gitbook.io/hyperliquid-docs/trading/account-abstraction-modes
pub const AccountMode = enum {
    standard,
    unified,
    portfolio,

    /// Returns the API string value for userSetAbstraction.
    pub fn toApiString(self: AccountMode) []const u8 {
        return switch (self) {
            .standard => "disabled",
            .unified => "unifiedAccount",
            .portfolio => "portfolioMargin",
        };
    }

    pub fn displayName(self: AccountMode) []const u8 {
        return switch (self) {
            .standard => "standard",
            .unified => "unified account",
            .portfolio => "portfolio margin",
        };
    }
};

pub const ApproveAgentArgs = struct {
    agent_address: ?[]const u8 = null,
    agent_name: ?[]const u8 = null,
};

pub const GlobalFlags = struct {
    chain: []const u8 = "mainnet",
    output: OutputFormat = .pretty,
    output_explicit: bool = false,
    quiet: bool = false,
    key: ?[]const u8 = null,
    key_name: ?[]const u8 = null,
    address: ?[]const u8 = null,
};

pub const OutputFormat = enum {
    pretty,
    json,
    csv,

    pub fn fromStr(s: []const u8) ?OutputFormat {
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "csv")) return .csv;
        if (std.mem.eql(u8, s, "pretty") or std.mem.eql(u8, s, "table")) return .pretty;
        return null;
    }
};

pub const ParseResult = struct {
    command: ?Command,
    flags: GlobalFlags,
};

pub const ParseError = error{
    MissingArgument,
    UnknownCommand,
    InvalidFlag,
};

pub fn parse(allocator: std.mem.Allocator, args: std.process.Args) ParseError!ParseResult {
    var args_iter = args.iterateAllocator(allocator) catch return .{ .command = .{ .help = {} }, .flags = .{} };
    defer args_iter.deinit();

    _ = args_iter.next(); // skip binary name

    var flags = GlobalFlags{};
    var positionals: [64][]const u8 = undefined;
    var pos_count: usize = 0;

    // First pass: extract global flags and collect positionals
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--chain")) {
            flags.chain = args_iter.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            const val = args_iter.next() orelse return error.MissingArgument;
            flags.output = OutputFormat.fromStr(val) orelse return error.InvalidFlag;
            flags.output_explicit = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            flags.output = .json;
            flags.output_explicit = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            flags.quiet = true;
        } else if (std.mem.eql(u8, arg, "--key") or std.mem.eql(u8, arg, "-k")) {
            flags.key = args_iter.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--key-name")) {
            flags.key_name = args_iter.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--address") or std.mem.eql(u8, arg, "-a")) {
            flags.address = args_iter.next() orelse return error.MissingArgument;
        } else {
            if (pos_count < positionals.len) {
                positionals[pos_count] = arg;
                pos_count += 1;
            }
        }
    }

    if (pos_count == 0) return .{ .command = .{ .help = .{} }, .flags = flags };

    const cmd_str = positionals[0];
    const rest = positionals[1..pos_count];

    if (canonicalHelpTopic(cmd_str)) |topic| {
        if (topic != .help and hasHelpFlag(rest)) {
            return .{ .command = .{ .help = .{ .topic = topic } }, .flags = flags };
        }
    }

    const command: Command = if (std.mem.eql(u8, cmd_str, "keys") or std.mem.eql(u8, cmd_str, "key"))
        .{ .keys = parseKeys(rest) }
    else if (std.mem.eql(u8, cmd_str, "mids") or std.mem.eql(u8, cmd_str, "mid"))
        .{ .mids = parseMids(rest) }
    else if (std.mem.eql(u8, cmd_str, "positions") or std.mem.eql(u8, cmd_str, "pos"))
        .{ .positions = parseUserQuery(rest) }
    else if (std.mem.eql(u8, cmd_str, "orders") or std.mem.eql(u8, cmd_str, "ord"))
        .{ .orders = parseUserQuery(rest) }
    else if (std.mem.eql(u8, cmd_str, "fills"))
        .{ .fills = parseFills(rest) }
    else if (std.mem.eql(u8, cmd_str, "balance") or std.mem.eql(u8, cmd_str, "bal"))
        .{ .balance = parseUserQuery(rest) }
    else if (std.mem.eql(u8, cmd_str, "perps"))
        .{ .perps = parseMarket(rest) }
    else if (std.mem.eql(u8, cmd_str, "spot"))
        .{ .spot = parseMarket(rest) }
    else if (std.mem.eql(u8, cmd_str, "outcomes") or std.mem.eql(u8, cmd_str, "outcome"))
        .{ .outcomes = parseMarket(rest) }
    else if (std.mem.eql(u8, cmd_str, "dexes") or std.mem.eql(u8, cmd_str, "dex"))
        .{ .dexes = {} }
    else if (std.mem.eql(u8, cmd_str, "buy") or std.mem.eql(u8, cmd_str, "long"))
        .{ .buy = parseOrder(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "sell") or std.mem.eql(u8, cmd_str, "short"))
        .{ .sell = parseOrder(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "cancel"))
        .{ .cancel = parseCancel(rest) }
    else if (std.mem.eql(u8, cmd_str, "modify") or std.mem.eql(u8, cmd_str, "mod"))
        .{ .modify = parseModify(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "send"))
        .{ .send = parseSend(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "stream") or std.mem.eql(u8, cmd_str, "sub"))
        .{ .stream = parseStream(rest) }
    else if (std.mem.eql(u8, cmd_str, "status"))
        .{ .status = .{ .oid = if (rest.len > 0) rest[0] else return error.MissingArgument } }
    else if (std.mem.eql(u8, cmd_str, "funding") or std.mem.eql(u8, cmd_str, "fund"))
        .{ .funding = parseFunding(rest) }
    else if (std.mem.eql(u8, cmd_str, "markets") or std.mem.eql(u8, cmd_str, "m"))
        .{ .markets = {} }
    else if (std.mem.eql(u8, cmd_str, "book") or std.mem.eql(u8, cmd_str, "ob"))
        .{ .book = parseBook(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "trade") or std.mem.eql(u8, cmd_str, "t"))
        .{ .trade = parseTrade(rest) }
    else if (std.mem.eql(u8, cmd_str, "leverage") or std.mem.eql(u8, cmd_str, "lev"))
        .{ .leverage = parseLeverage(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "price"))
        .{ .price = parsePrice(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "portfolio") or std.mem.eql(u8, cmd_str, "folio"))
        .{ .portfolio = parseUserQuery(rest) }
    else if (std.mem.eql(u8, cmd_str, "referral"))
        .{ .referral = parseReferral(rest) }
    else if (std.mem.eql(u8, cmd_str, "twap"))
        .{ .twap = parseTwap(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "batch"))
        .{ .batch = parseBatch(rest) }
    else if (std.mem.eql(u8, cmd_str, "approve-agent") or std.mem.eql(u8, cmd_str, "approve"))
        .{ .approve_agent = parseApproveAgent(rest) }
    else if (std.mem.eql(u8, cmd_str, "withdraw"))
        .{ .withdraw = parseWithdraw(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "transfer"))
        .{ .transfer = parseTransfer(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "fees") or std.mem.eql(u8, cmd_str, "fee"))
        .{ .fees = parseUserQuery(rest) }
    else if (std.mem.eql(u8, cmd_str, "rate-limit") or std.mem.eql(u8, cmd_str, "ratelimit"))
        .{ .rate_limit = parseUserQuery(rest) }
    else if (std.mem.eql(u8, cmd_str, "stake") or std.mem.eql(u8, cmd_str, "staking"))
        .{ .stake = parseStake(rest) }
    else if (std.mem.eql(u8, cmd_str, "vault"))
        .{ .vault = parseVault(rest) }
    else if (std.mem.eql(u8, cmd_str, "ledger"))
        .{ .ledger = parseLedger(rest) }
    else if (std.mem.eql(u8, cmd_str, "approve-builder"))
        .{ .approve_builder = parseApproveBuilder(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "subaccount"))
        .{ .subaccount = parseSubAccount(rest) }
    else if (std.mem.eql(u8, cmd_str, "account"))
        .{ .account = parseAccount(rest) }
    else if (std.mem.eql(u8, cmd_str, "deploy"))
        .{ .deploy = parseDeploy(rest) }
    else if (std.mem.eql(u8, cmd_str, "config"))
        .{ .config = {} }
    else if (std.mem.eql(u8, cmd_str, "help") or std.mem.eql(u8, cmd_str, "--help") or std.mem.eql(u8, cmd_str, "-h"))
        .{ .help = parseHelp(rest) }
    else if (std.mem.eql(u8, cmd_str, "version") or std.mem.eql(u8, cmd_str, "--version") or std.mem.eql(u8, cmd_str, "-V"))
        .{ .version = {} }
    else
        return error.UnknownCommand;

    return .{ .command = command, .flags = flags };
}

fn parseMids(args: []const []const u8) MidsArgs {
    var result = MidsArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dex") and i + 1 < args.len) {
            i += 1;
            result.dex = args[i];
        } else if (std.mem.eql(u8, args[i], "--all")) {
            result.all = true;
        } else if (std.mem.eql(u8, args[i], "--page") and i + 1 < args.len) {
            i += 1;
            result.page = std.fmt.parseInt(usize, args[i], 10) catch 1;
        } else {
            result.coin = args[i];
        }
    }
    return result;
}

fn parseMarket(args: []const []const u8) MarketArgs {
    var result = MarketArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dex") and i + 1 < args.len) {
            i += 1;
            result.dex = args[i];
        } else if (std.mem.eql(u8, args[i], "--all")) {
            result.all = true;
        } else if (std.mem.eql(u8, args[i], "--page") and i + 1 < args.len) {
            i += 1;
            result.page = std.fmt.parseInt(usize, args[i], 10) catch 1;
        } else if (std.mem.eql(u8, args[i], "--filter") and i + 1 < args.len) {
            i += 1;
            result.filter = args[i];
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            result.filter = args[i]; // positional = filter
        }
    }
    return result;
}

fn parseUserQuery(args: []const []const u8) UserQuery {
    var result = UserQuery{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dex") and i + 1 < args.len) {
            i += 1;
            result.dex = args[i];
        } else if (std.mem.eql(u8, args[i], "--all-dexes")) {
            result.all_dexes = true;
        } else {
            result.address = args[i];
        }
    }
    return result;
}

// buy ETH 0.1 @1950   or   buy ETH 0.1  (market)
fn parseOrder(args: []const []const u8) ?OrderArgs {
    if (args.len < 2) return null;
    var result = OrderArgs{
        .coin = args[0],
        .size = args[1],
    };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len > 0 and a[0] == '@') {
            result.price = a[1..];
        } else if (std.mem.eql(u8, a, "--reduce-only")) {
            result.reduce_only = true;
        } else if (std.mem.eql(u8, a, "--tif") and i + 1 < args.len) {
            i += 1;
            result.tif = args[i];
        } else if (std.mem.eql(u8, a, "--slippage") and i + 1 < args.len) {
            i += 1;
            result.slippage = args[i];
        } else if (std.mem.eql(u8, a, "--dry-run") or std.mem.eql(u8, a, "-n")) {
            result.dry_run = true;
        } else if (std.mem.eql(u8, a, "--trigger-above") and i + 1 < args.len) {
            i += 1;
            result.trigger_px = args[i];
            result.trigger_is_tp = true;
        } else if (std.mem.eql(u8, a, "--trigger-below") and i + 1 < args.len) {
            i += 1;
            result.trigger_px = args[i];
            result.trigger_is_tp = false;
        } else if (std.mem.eql(u8, a, "--tp") and i + 1 < args.len) {
            i += 1;
            result.tp = args[i];
        } else if (std.mem.eql(u8, a, "--sl") and i + 1 < args.len) {
            i += 1;
            result.sl = args[i];
        } else if (std.mem.eql(u8, a, "--builder") and i + 1 < args.len) {
            i += 1;
            result.builder = args[i];
        } else if (std.mem.eql(u8, a, "--builder-fee") and i + 1 < args.len) {
            i += 1;
            result.builder_fee = args[i];
        } else {
            // Might be price without @
            result.price = a;
        }
    }
    return result;
}

// cancel ETH 12345  or  cancel --all  or  cancel ETH --cloid 0x...
fn parseCancel(args: []const []const u8) CancelArgs {
    var result = CancelArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--all")) {
            result.all = true;
        } else if (std.mem.eql(u8, a, "--cloid") and i + 1 < args.len) {
            i += 1;
            result.cloid = args[i];
        } else if (result.coin == null and result.oid == null and std.fmt.parseInt(u64, a, 10) catch null != null) {
            result.oid = a;
        } else if (result.coin == null) {
            result.coin = a;
        } else {
            result.oid = a;
        }
    }
    return result;
}

// modify ETH 12345 1.5 @3400
fn parseModify(args: []const []const u8) ?ModifyArgs {
    if (args.len < 4) return null;
    var price = args[3];
    if (price.len > 0 and price[0] == '@') price = price[1..];
    return ModifyArgs{
        .coin = args[0],
        .oid = args[1],
        .size = args[2],
        .price = price,
    };
}

fn parseFunding(args: []const []const u8) FundingArgs {
    var result = FundingArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--top") and i + 1 < args.len) {
            i += 1;
            result.top = std.fmt.parseInt(usize, args[i], 10) catch 20;
        } else if (std.mem.eql(u8, args[i], "--all")) {
            result.all = true;
        } else if (std.mem.eql(u8, args[i], "--page") and i + 1 < args.len) {
            i += 1;
            result.page = std.fmt.parseInt(usize, args[i], 10) catch 1;
        } else if (std.mem.eql(u8, args[i], "--filter") and i + 1 < args.len) {
            i += 1;
            result.filter = args[i];
        } else if (std.mem.eql(u8, args[i], "--dex") and i + 1 < args.len) {
            i += 1;
            result.dex = args[i];
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            result.filter = args[i]; // positional = filter
        }
    }
    return result;
}

fn hasHelpFlag(args: []const []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return true;
    }
    return false;
}

fn canonicalHelpTopic(name: []const u8) ?HelpTopic {
    if (std.mem.eql(u8, name, "keys") or std.mem.eql(u8, name, "key")) return .keys;
    if (std.mem.eql(u8, name, "mids") or std.mem.eql(u8, name, "mid")) return .mids;
    if (std.mem.eql(u8, name, "positions") or std.mem.eql(u8, name, "pos")) return .positions;
    if (std.mem.eql(u8, name, "orders") or std.mem.eql(u8, name, "ord")) return .orders;
    if (std.mem.eql(u8, name, "fills")) return .fills;
    if (std.mem.eql(u8, name, "balance") or std.mem.eql(u8, name, "bal")) return .balance;
    if (std.mem.eql(u8, name, "perps")) return .perps;
    if (std.mem.eql(u8, name, "spot")) return .spot;
    if (std.mem.eql(u8, name, "outcomes") or std.mem.eql(u8, name, "outcome")) return .outcomes;
    if (std.mem.eql(u8, name, "dexes") or std.mem.eql(u8, name, "dex")) return .dexes;
    if (std.mem.eql(u8, name, "buy") or std.mem.eql(u8, name, "long")) return .buy;
    if (std.mem.eql(u8, name, "sell") or std.mem.eql(u8, name, "short")) return .sell;
    if (std.mem.eql(u8, name, "cancel")) return .cancel;
    if (std.mem.eql(u8, name, "modify") or std.mem.eql(u8, name, "mod")) return .modify;
    if (std.mem.eql(u8, name, "send")) return .send;
    if (std.mem.eql(u8, name, "stream") or std.mem.eql(u8, name, "sub")) return .stream;
    if (std.mem.eql(u8, name, "status")) return .status;
    if (std.mem.eql(u8, name, "funding") or std.mem.eql(u8, name, "fund")) return .funding;
    if (std.mem.eql(u8, name, "book") or std.mem.eql(u8, name, "ob")) return .book;
    if (std.mem.eql(u8, name, "markets") or std.mem.eql(u8, name, "m")) return .markets;
    if (std.mem.eql(u8, name, "trade") or std.mem.eql(u8, name, "t")) return .trade;
    if (std.mem.eql(u8, name, "leverage") or std.mem.eql(u8, name, "lev")) return .leverage;
    if (std.mem.eql(u8, name, "price")) return .price;
    if (std.mem.eql(u8, name, "portfolio") or std.mem.eql(u8, name, "folio")) return .portfolio;
    if (std.mem.eql(u8, name, "referral")) return .referral;
    if (std.mem.eql(u8, name, "twap")) return .twap;
    if (std.mem.eql(u8, name, "batch")) return .batch;
    if (std.mem.eql(u8, name, "approve-agent") or std.mem.eql(u8, name, "approve")) return .approve_agent;
    if (std.mem.eql(u8, name, "withdraw")) return .withdraw;
    if (std.mem.eql(u8, name, "transfer")) return .transfer;
    if (std.mem.eql(u8, name, "fees") or std.mem.eql(u8, name, "fee")) return .fees;
    if (std.mem.eql(u8, name, "rate-limit") or std.mem.eql(u8, name, "ratelimit")) return .rate_limit;
    if (std.mem.eql(u8, name, "stake") or std.mem.eql(u8, name, "staking")) return .stake;
    if (std.mem.eql(u8, name, "vault")) return .vault;
    if (std.mem.eql(u8, name, "ledger")) return .ledger;
    if (std.mem.eql(u8, name, "approve-builder")) return .approve_builder;
    if (std.mem.eql(u8, name, "subaccount")) return .subaccount;
    if (std.mem.eql(u8, name, "account")) return .account;
    if (std.mem.eql(u8, name, "config")) return .config;
    if (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) return .help;
    if (std.mem.eql(u8, name, "version") or std.mem.eql(u8, name, "--version") or std.mem.eql(u8, name, "-V")) return .version;
    return null;
}

fn parseHelp(args: []const []const u8) HelpArgs {
    var result = HelpArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) continue;
        if (std.mem.startsWith(u8, arg, "--")) continue;
        if (canonicalHelpTopic(arg)) |topic| {
            result.topic = topic;
        } else {
            result.invalid_topic = arg;
        }
        break;
    }
    return result;
}

fn parsePrice(args: []const []const u8) ?PriceArgs {
    if (args.len < 1) return null;
    var result = PriceArgs{ .coin = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dex") and i + 1 < args.len) {
            i += 1;
            result.dex = args[i];
        } else if (std.mem.eql(u8, args[i], "--quote") and i + 1 < args.len) {
            i += 1;
            result.quote = args[i];
        } else if (std.mem.eql(u8, args[i], "--all")) {
            result.all = true;
        }
    }
    return result;
}

fn parseTrade(args: []const []const u8) TradeArgs {
    var result = TradeArgs{};
    if (args.len >= 1 and args[0].len > 0 and args[0][0] != '-') {
        result.coin = args[0];
    }
    return result;
}

fn parseBook(args: []const []const u8) ?BookArgs {
    if (args.len < 1) return null;
    var result = BookArgs{ .coin = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--depth") and i + 1 < args.len) {
            i += 1;
            result.depth = std.fmt.parseInt(usize, args[i], 10) catch 15;
        } else if (std.mem.eql(u8, args[i], "--live")) {
            result.live = true;
        }
    }
    return result;
}

// send 100 USDC 0xabc...       → send USDC to another user
// send 100 USDC --to spot      → self transfer perp→spot
// send 100 HYPE --from spot --to 0xabc...   → send from spot
// send 100 USDC --from perp --to xyz        → perp → DEX
// send 100 USDC --subaccount alice --to 0x...
fn parseSend(args: []const []const u8) ?SendArgs {
    if (args.len < 2) return null;
    var result = SendArgs{ .amount = args[0] };
    var i: usize = 1;
    // Second arg: token name or destination (if starts with 0x)
    if (i < args.len) {
        const a = args[i];
        if (a.len >= 2 and a[0] == '0' and a[1] == 'x') {
            result.destination = a;
        } else if (std.mem.eql(u8, a, "--from") or std.mem.eql(u8, a, "--to") or std.mem.eql(u8, a, "--subaccount")) {
            // flags start here, token defaults to USDC
        } else {
            result.token = a;
            i += 1;
        }
    }
    // Remaining: destination or flags
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--from") and i + 1 < args.len) {
            i += 1;
            result.from = args[i];
        } else if (std.mem.eql(u8, a, "--to") and i + 1 < args.len) {
            i += 1;
            result.to = args[i];
        } else if (std.mem.eql(u8, a, "--subaccount") and i + 1 < args.len) {
            i += 1;
            result.subaccount = args[i];
        } else if (std.mem.eql(u8, a, "--agent")) {
            result.agent = true;
        } else if (result.destination == null) {
            result.destination = a;
        }
    }
    return result;
}

// leverage BTC 10 --isolated  or  leverage BTC (query)
fn parseLeverage(args: []const []const u8) ?LeverageArgs {
    if (args.len < 1) return null;
    var result = LeverageArgs{ .coin = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--isolated")) {
            result.cross = false;
        } else if (std.mem.eql(u8, a, "--cross")) {
            result.cross = true;
        } else if (!std.mem.startsWith(u8, a, "--")) {
            result.leverage = a;
        }
    }
    return result;
}

fn parseReferral(args: []const []const u8) ReferralArgs {
    var result = ReferralArgs{};
    if (args.len >= 2 and std.mem.eql(u8, args[0], "set")) {
        result.action = .set;
        result.code = args[1];
    } else if (args.len >= 1 and std.mem.eql(u8, args[0], "status")) {
        result.action = .status;
    } else if (args.len >= 1 and !std.mem.startsWith(u8, args[0], "--")) {
        // `hlz referral MYCODE` = shorthand for set
        result.action = .set;
        result.code = args[0];
    }
    return result;
}

// twap BTC buy 10.0 --duration 1h --slices 12
fn parseTwap(args: []const []const u8) ?TwapArgs {
    if (args.len < 3) return null;
    var result = TwapArgs{
        .coin = args[0],
        .side = args[1],
        .size = args[2],
    };
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--duration") and i + 1 < args.len) {
            i += 1;
            result.duration = args[i];
        } else if (std.mem.eql(u8, a, "--slices") and i + 1 < args.len) {
            i += 1;
            result.slices = std.fmt.parseInt(usize, args[i], 10) catch 10;
        } else if (std.mem.eql(u8, a, "--slippage") and i + 1 < args.len) {
            i += 1;
            result.slippage_pct = std.fmt.parseFloat(f64, args[i]) catch 1.0;
        }
    }
    return result;
}

// batch "buy BTC 0.1 @98000" "sell ETH 1.0 @3400"
fn parseBatch(args: []const []const u8) BatchArgs {
    var result = BatchArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--stdin")) {
            result.stdin = true;
        } else if (std.mem.eql(u8, a, "--builder") and i + 1 < args.len) {
            i += 1;
            result.builder = args[i];
        } else if (std.mem.eql(u8, a, "--builder-fee") and i + 1 < args.len) {
            i += 1;
            result.builder_fee = args[i];
        } else if (result.count < 16) {
            result.orders[result.count] = a;
            result.count += 1;
        }
    }
    return result;
}

fn parseFills(args: []const []const u8) FillsArgs {
    var result = FillsArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--from") and i + 1 < args.len) {
            i += 1;
            result.start_time = args[i];
        } else if (std.mem.eql(u8, args[i], "--to") and i + 1 < args.len) {
            i += 1;
            result.end_time = args[i];
        } else {
            result.address = args[i];
        }
    }
    return result;
}

// withdraw 100 0xdest  or  withdraw 100 (to self)
fn parseWithdraw(args: []const []const u8) ?WithdrawArgs {
    if (args.len < 1) return null;
    var result = WithdrawArgs{ .amount = args[0] };
    if (args.len >= 2) result.destination = args[1];
    return result;
}

// transfer 100 --to-spot  or  transfer 100 --to-perp
// Direction flag is required — omitting it is an error to prevent accidental transfers.
fn parseTransfer(args: []const []const u8) ?TransferArgs {
    if (args.len < 2) return null; // need amount + direction flag
    var direction: ?TransferDirection = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--to-perp")) {
            direction = .to_perp;
        } else if (std.mem.eql(u8, args[i], "--to-spot")) {
            direction = .to_spot;
        }
    }
    return .{
        .amount = args[0],
        .direction = direction orelse return null, // missing flag → MissingArgument
    };
}

// stake delegate 0xvalidator 1000   or  stake status  or  stake rewards
fn parseStake(args: []const []const u8) StakeArgs {
    var result = StakeArgs{};
    if (args.len == 0) return result;

    if (std.mem.eql(u8, args[0], "delegate")) {
        result.action = .delegate;
        if (args.len >= 2) result.validator = args[1];
        if (args.len >= 3) result.amount = args[2];
    } else if (std.mem.eql(u8, args[0], "undelegate")) {
        result.action = .undelegate;
        if (args.len >= 2) result.validator = args[1];
        if (args.len >= 3) result.amount = args[2];
    } else if (std.mem.eql(u8, args[0], "rewards")) {
        result.action = .rewards;
    } else if (std.mem.eql(u8, args[0], "history")) {
        result.action = .history;
    } else if (std.mem.eql(u8, args[0], "status")) {
        result.action = .status;
    }
    return result;
}

// vault 0xaddr              → info
// vault info 0xaddr         → info (explicit)
// vault deposit 0xaddr 100  → deposit
// vault withdraw 0xaddr 100 → withdraw
fn parseVault(args: []const []const u8) VaultArgs {
    var result = VaultArgs{};
    if (args.len == 0) return result;

    if (std.mem.eql(u8, args[0], "deposit")) {
        result.action = .deposit;
        if (args.len >= 2) result.vault_address = args[1];
        if (args.len >= 3) result.amount = args[2];
    } else if (std.mem.eql(u8, args[0], "withdraw")) {
        result.action = .withdraw;
        if (args.len >= 2) result.vault_address = args[1];
        if (args.len >= 3) result.amount = args[2];
    } else if (std.mem.eql(u8, args[0], "info")) {
        // Explicit "vault info 0xaddr" form
        if (args.len >= 2) result.vault_address = args[1];
    } else {
        // Bare "vault 0xaddr" form
        result.vault_address = args[0];
    }
    return result;
}

fn parseLedger(args: []const []const u8) LedgerArgs {
    var result = LedgerArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--from") and i + 1 < args.len) {
            i += 1;
            result.start_time = args[i];
        } else if (std.mem.eql(u8, args[i], "--to") and i + 1 < args.len) {
            i += 1;
            result.end_time = args[i];
        } else {
            result.address = args[i];
        }
    }
    return result;
}

// approve-builder 0xbuilder 0.001
fn parseApproveBuilder(args: []const []const u8) ?ApproveBuilderArgs {
    if (args.len < 2) return null;
    return .{ .builder = args[0], .max_fee_rate = args[1] };
}

// subaccount list  or  subaccount create "my-sub"  or  subaccount transfer 0xsub 100
fn parseSubAccount(args: []const []const u8) SubAccountArgs {
    var result = SubAccountArgs{};
    if (args.len == 0) return result;

    if (std.mem.eql(u8, args[0], "create")) {
        result.action = .create;
        if (args.len >= 2) result.name = args[1];
    } else if (std.mem.eql(u8, args[0], "transfer")) {
        result.action = .transfer;
        if (args.len >= 2) result.sub_address = args[1];
        if (args.len >= 3) result.amount = args[2];
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--withdraw")) result.is_deposit = false;
            if (std.mem.eql(u8, args[i], "--token") and i + 1 < args.len) {
                i += 1;
                result.token = args[i];
                result.action = .spot_transfer;
            }
        }
    } else if (std.mem.eql(u8, args[0], "list") or std.mem.eql(u8, args[0], "ls")) {
        result.action = .list;
    }
    return result;
}

// account [standard|unified|portfolio]
// account [standard|unified|portfolio]
fn parseAccount(args: []const []const u8) AccountArgs {
    if (args.len == 0) return .{};
    const mode = std.meta.stringToEnum(AccountMode, args[0]);
    return .{
        .mode = mode,
        .invalid_mode = if (mode == null) args[0] else null,
    };
}

// hlz deploy status [--pair]
// hlz deploy spot <subcmd>
fn parseDeploy(args: []const []const u8) DeployArgs {
    if (args.len == 0) return .{};
    const first = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, first, "status")) {
        var st = DeployStatusArgs{};
        for (rest) |a| {
            if (std.mem.eql(u8, a, "--pair")) st.pair = true;
        }
        return .{ .action = .{ .status = st } };
    }
    if (std.mem.eql(u8, first, "spot")) return parseDeploySpot(rest);
    return .{};
}

fn parseDeploySpot(args: []const []const u8) DeployArgs {
    if (args.len == 0) return .{};
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "register")) {
        if (rest.len < 1) return .{};
        var r = DeploySpotRegisterArgs{
            .name = rest[0],
            .sz_decimals = 2,
            .wei_decimals = 8,
            .max_gas_hype = 0,
        };
        var i: usize = 1;
        while (i < rest.len) : (i += 1) {
            const a = rest[i];
            if (std.mem.eql(u8, a, "--sz-dec") and i + 1 < rest.len) {
                i += 1;
                r.sz_decimals = std.fmt.parseInt(u32, rest[i], 10) catch continue;
            } else if (std.mem.eql(u8, a, "--wei-dec") and i + 1 < rest.len) {
                i += 1;
                r.wei_decimals = std.fmt.parseInt(u32, rest[i], 10) catch continue;
            } else if (std.mem.eql(u8, a, "--max-gas") and i + 1 < rest.len) {
                i += 1;
                r.max_gas_hype = std.fmt.parseInt(u64, rest[i], 10) catch continue;
            } else if (std.mem.eql(u8, a, "--full-name") and i + 1 < rest.len) {
                i += 1;
                r.full_name = rest[i];
            } else if (std.mem.eql(u8, a, "--dry-run") or std.mem.eql(u8, a, "-n")) {
                r.dry_run = true;
            }
        }
        return .{ .action = .{ .spot_register = r } };
    }
    if (std.mem.eql(u8, sub, "user-genesis")) {
        if (rest.len < 1) return .{};
        var g = DeploySpotUserGenesisArgs{
            .token = std.fmt.parseInt(u32, rest[0], 10) catch return .{},
        };
        var i: usize = 1;
        while (i < rest.len) : (i += 1) {
            const a = rest[i];
            if (std.mem.eql(u8, a, "--alloc") and i + 1 < rest.len and g.user_count < g.user_allocs.len) {
                i += 1;
                g.user_allocs[g.user_count] = rest[i];
                g.user_count += 1;
            } else if (std.mem.eql(u8, a, "--from-token") and i + 1 < rest.len and g.existing_count < g.existing_allocs.len) {
                i += 1;
                g.existing_allocs[g.existing_count] = rest[i];
                g.existing_count += 1;
            } else if (std.mem.eql(u8, a, "--dry-run") or std.mem.eql(u8, a, "-n")) {
                g.dry_run = true;
            }
        }
        return .{ .action = .{ .spot_user_genesis = g } };
    }
    if (std.mem.eql(u8, sub, "genesis")) {
        if (rest.len < 1) return .{};
        const token = std.fmt.parseInt(u32, rest[0], 10) catch return .{};
        var g = DeploySpotGenesisArgs{ .token = token, .max_supply = "" };
        var i: usize = 1;
        while (i < rest.len) : (i += 1) {
            const a = rest[i];
            if (std.mem.eql(u8, a, "--max-supply") and i + 1 < rest.len) {
                i += 1;
                g.max_supply = rest[i];
            } else if (std.mem.eql(u8, a, "--no-hyperliquidity")) {
                g.no_hyperliquidity = true;
            } else if (std.mem.eql(u8, a, "--dry-run") or std.mem.eql(u8, a, "-n")) {
                g.dry_run = true;
            }
        }
        return .{ .action = .{ .spot_genesis = g } };
    }
    return .{};
}

fn parseApproveAgent(args: []const []const u8) ApproveAgentArgs {
    var result = ApproveAgentArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--name") and i + 1 < args.len) {
            i += 1;
            result.agent_name = args[i];
        } else if (!std.mem.startsWith(u8, a, "--")) {
            if (result.agent_address == null) result.agent_address = a;
        }
    }
    return result;
}

fn parseKeys(args: []const []const u8) KeysArgs {
    var result = KeysArgs{};
    if (args.len == 0) return result;

    const action = args[0];
    if (std.mem.eql(u8, action, "new")) {
        result.action = .new;
    } else if (std.mem.eql(u8, action, "import")) {
        result.action = .import_;
    } else if (std.mem.eql(u8, action, "rm") or std.mem.eql(u8, action, "remove")) {
        result.action = .rm;
    } else if (std.mem.eql(u8, action, "export")) {
        result.action = .export_;
    } else if (std.mem.eql(u8, action, "default") or std.mem.eql(u8, action, "use")) {
        result.action = .default;
    } else if (std.mem.eql(u8, action, "ls") or std.mem.eql(u8, action, "list")) {
        result.action = .ls;
    } else {
        // Bare name = ls or maybe the name for another action
        result.name = action;
        return result;
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--password") and i + 1 < args.len) {
            i += 1;
            result.password = args[i];
        } else if ((std.mem.eql(u8, a, "--private-key") or std.mem.eql(u8, a, "--pk")) and i + 1 < args.len) {
            i += 1;
            result.key_hex = args[i];
        } else if (!std.mem.startsWith(u8, a, "--")) {
            result.name = a;
        }
    }
    return result;
}

// stream trades ETH  or  stream bbo BTC  or  stream fills 0x...
fn parseStream(args: []const []const u8) StreamArgs {
    var result = StreamArgs{};
    var i: usize = 0;
    if (i < args.len) {
        const kind_str = args[i];
        if (std.mem.eql(u8, kind_str, "trades") or std.mem.eql(u8, kind_str, "trade")) {
            result.kind = .trades;
        } else if (std.mem.eql(u8, kind_str, "bbo")) {
            result.kind = .bbo;
        } else if (std.mem.eql(u8, kind_str, "book") or std.mem.eql(u8, kind_str, "orderbook")) {
            result.kind = .book;
        } else if (std.mem.eql(u8, kind_str, "candles") or std.mem.eql(u8, kind_str, "candle")) {
            result.kind = .candles;
        } else if (std.mem.eql(u8, kind_str, "mids") or std.mem.eql(u8, kind_str, "mid")) {
            result.kind = .mids;
        } else if (std.mem.eql(u8, kind_str, "fills") or std.mem.eql(u8, kind_str, "fill")) {
            result.kind = .fills;
        } else if (std.mem.eql(u8, kind_str, "orders") or std.mem.eql(u8, kind_str, "order")) {
            result.kind = .orders;
        } else {
            // If first arg doesn't match a kind, treat as coin for default (trades)
            result.coin = kind_str;
            i += 1;
        }
        if (result.coin == null) i += 1;
    }
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--interval") and i + 1 < args.len) {
            i += 1;
            result.interval = args[i];
        } else if (std.mem.eql(u8, a, "--filter") and i + 1 < args.len) {
            i += 1;
            result.filter = a;
        } else if (result.coin == null and result.address == null) {
            // If starts with 0x, it's an address, otherwise coin
            if (a.len >= 2 and a[0] == '0' and a[1] == 'x') {
                result.address = a;
            } else {
                result.coin = a;
            }
        }
    }
    return result;
}
