<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/public/hlz-wordmark-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/public/hlz-wordmark-light.svg">
    <img src="docs/public/hlz-wordmark-light.svg" alt="hlz" height="60" />
  </picture>
</p>

<p align="center">
  Zig tooling for <a href="https://hyperliquid.xyz">Hyperliquid</a> — SDK, CLI, and trading terminal.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-v0.7.0-blue" alt="version" />
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license" />
  <img src="https://img.shields.io/badge/status-beta-orange" alt="status" />
  <img src="https://img.shields.io/badge/platform-macOS_|_Linux-blue" alt="platform" />
  <img src="https://img.shields.io/badge/zig-0.16.0-F7A41D?logo=zig&logoColor=white" alt="zig" />
</p>

<p align="center">
  <img src="terminal.gif" alt="hlz trading terminal" width="720" />
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="https://dzmbs.github.io/hlz">Docs</a> ·
  <a href="#credits">Credits</a>
</p>

---

## What is this

A Zig implementation of the Hyperliquid SDK with a CLI and trading terminal. Two binaries:

| Binary | Size | What it does |
|--------|------|-------------|
| `hlz` | 895 KB | 41-command CLI — market data, trading, transfers, streaming |
| `hlz-terminal` | 1121 KB | Trading terminal — candlestick chart, order book, trade tape |

Both are static binaries. Pipe-aware — tables on TTY, JSON when piped.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/dzmbs/hlz/main/install.sh | sh
```

Or download a binary manually from [Releases](../../releases/latest).

**From source** (requires [Zig 0.16.0](https://ziglang.org/download/)):

```bash
git clone https://github.com/dzmbs/hlz
cd hlz
zig build -Doptimize=ReleaseSmall
# Binaries in zig-out/bin/hlz and zig-out/bin/hlz-terminal
```

**As a Zig dependency:**

```zig
.dependencies = .{
    .hlz = .{
        .url = "git+https://github.com/dzmbs/hlz#main",
    },
},
```

---

## Quick Start

```bash
# No auth needed for market data
hlz price BTC
hlz book ETH --live
hlz funding --top 10

# Set up a key for trading
hlz keys new trading
export HL_KEY_NAME=trading

# Trade
hlz buy BTC 0.1 @50000
hlz sell ETH 1.0
hlz cancel BTC --all

# Check account
hlz portfolio
hlz orders

# Stream real-time data
hlz stream trades BTC

# Trading terminal
hlz trade BTC
```

---

## SDK

```zig
const hlz = @import("hlz");
const Signer = hlz.crypto.signer.Signer;
const Decimal = hlz.math.decimal.Decimal;
const types = hlz.hypercore.types;
const signing = hlz.hypercore.signing;

const signer = try Signer.fromHex("your_64_char_hex_key");

const order = types.OrderRequest{
    .asset = 0,  // BTC
    .is_buy = true,
    .limit_px = try Decimal.fromString("50000"),
    .sz = try Decimal.fromString("0.1"),
    .reduce_only = false,
    .order_type = .{ .limit = .{ .tif = .Gtc } },
    .cloid = types.ZERO_CLOID,
};

const batch = types.BatchOrder{
    .orders = &[_]types.OrderRequest{order},
    .grouping = .na,
};

const nonce = @as(u64, @intCast(std.time.milliTimestamp()));
const sig = try signing.signOrder(signer, batch, nonce, .mainnet, null, null);

var client = hlz.hypercore.client.Client.mainnet(allocator);
defer client.deinit();
var result = try client.place(signer, batch, nonce, null, null);
defer result.deinit();
```

---

## CLI Commands

<details>
<summary><strong>Market Data</strong> (no auth)</summary>

| Command | Description |
|---------|-------------|
| `hlz price <COIN>` | Mid price + bid/ask spread |
| `hlz mids [COIN]` | All mid prices |
| `hlz funding [--top N]` | Funding rates |
| `hlz book <COIN> [--live]` | L2 order book |
| `hlz perps [--dex xyz]` | Perpetual markets |
| `hlz spot` | Spot markets |
| `hlz outcomes` | Outcome (prediction) markets |
| `hlz dexes` | HIP-3 DEXes |

</details>

<details>
<summary><strong>Trading</strong></summary>

| Command | Description |
|---------|-------------|
| `hlz buy <COIN> <SZ> [@PX]` | Limit or market buy |
| `hlz sell <COIN> <SZ> [@PX]` | Limit or market sell |
| `hlz cancel <COIN> [OID]` | Cancel order(s) |
| `hlz modify <COIN> <OID> <SZ> <PX>` | Modify order |
| `hlz leverage <COIN> [N]` | Query or set leverage |
| `hlz twap <COIN> buy\|sell <SZ> --duration 1h --slices 10` | TWAP execution |
| `hlz batch "order1" "order2"` | Batch orders |

**Flags:** `--reduce-only`, `--tp <PX>`, `--sl <PX>`, `--tif gtc|ioc|alo`, `--dry-run`

</details>

<details>
<summary><strong>Account</strong></summary>

| Command | Description |
|---------|-------------|
| `hlz portfolio [ADDR]` | Positions + spot balances |
| `hlz positions [ADDR]` | Open positions |
| `hlz orders [ADDR]` | Open orders |
| `hlz fills [ADDR]` | Recent fills |
| `hlz balance [ADDR]` | Balance + margin health |
| `hlz status <OID>` | Order status |

</details>

<details>
<summary><strong>Transfers & Streaming</strong></summary>

```bash
hlz send 100 USDC 0xAddress        # Send to address
hlz send 100 USDC --to spot        # Perp → spot

hlz stream trades BTC               # Real-time trades
hlz stream book ETH                 # Order book updates
```

</details>

<details>
<summary><strong>Key Management</strong></summary>

```bash
hlz keys new <NAME>                  # Generate encrypted key
hlz keys import <NAME>               # Import existing key
hlz keys ls                          # List keys
hlz keys default <NAME>              # Set default
hlz approve-agent <ADDR>             # Approve API wallet
```

</details>

<details>
<summary><strong>Deploy</strong> (HIP-1 spot tokens)</summary>

```bash
hlz deploy status                         # live auction gas curves
hlz deploy spot register XD --max-gas 500 # step 1: bid the ticker auction
hlz deploy spot user-genesis 2195 \
  --alloc 0xabc...:1000000000             # step 2: allocations
hlz deploy spot genesis 2195 --max-supply 1500000000        # step 3
hlz deploy spot register-pair 2195 0                        # step 4
hlz deploy spot hyperliquidity 200 --start-px 1 --order-sz 10 --n-orders 5  # step 5
hlz deploy spot request-evm 2195 0x<erc20> --extra-wei-dec -2   # link a HyperEVM ERC-20
```

Every write subcommand supports `--dry-run` to preview without signing.
See `hlz deploy` for the full tree.

</details>

<details>
<summary><strong>Global Flags & Environment</strong></summary>

```
--json              JSON output (auto when piped)
--quiet, -q         Minimal output
--chain testnet     Use testnet
--dry-run, -n       Preview without sending
--key-name <NAME>   Select keystore key
```

```bash
HL_KEY=...          # Private key
HL_ADDRESS=...      # Default address
HL_CHAIN=...        # mainnet or testnet
HL_OUTPUT=json      # Default format
```

Exit codes: `0` success, `1` error, `2` usage, `3` auth, `4` network

</details>

---

## Agent Integration

Built for automation and AI agents:

- JSON when piped, `--json` flag always available
- Semantic exit codes (0/1/2/3/4)
- `--dry-run` to preview any trade
- `--quiet` for just the value
- Stdin batch: `echo "buy BTC 0.1" | hlz batch --stdin`
- No interactive prompts ever

```bash
PRICE=$(hlz price BTC -q)
hlz buy BTC 0.1 @${PRICE} --json
hlz orders --json | jq '.data[] | select(.coin == "BTC")'
```

---

## Architecture

```
src/
├── lib/          Primitives (crypto, encoding, math) — no Hyperliquid knowledge
├── sdk/          Hyperliquid SDK (client, ws, signing, types) — imports lib/
├── tui/          TUI framework (Buffer, Terminal, Layout, List, Chart) — standalone
├── cli/          CLI tool (41 commands) — imports sdk/ + tui/
└── terminal/     Trading terminal — imports sdk/ + tui/
```

Dependencies point down only. `lib/` and `tui/` depend on nothing.

---

## Numbers

| | |
|---|---|
| `hlz` binary | 895 KB |
| `hlz-terminal` binary | 1121 KB |
| Source | ~18,800 lines |
| Commands | 44 |
| HTTP endpoints | 60+ (info + exchange) |
| WS subscriptions | 13 types |
| Response types | 62 |
| Unit tests | 183 |
| E2E tests | 17 |

---

## Building

```bash
zig build                              # Debug
zig build -Doptimize=ReleaseSmall      # Small binary (895KB)
zig build -Doptimize=ReleaseFast       # Fast binary
zig build -Dfast-crypto=true           # Custom GLV (~3.4x faster signing)
zig build test                         # Unit tests (183)
zig build bench                        # Signing benchmarks
zig build e2e                          # Live API tests
```

---

## Credits

Inspired by [hypersdk](https://github.com/infinitefield/hypersdk) & [hypecli](https://github.com/infinitefield/hypersdk/tree/main/hypecli) (Rust SDK & CLI), [hyperliquid-cli](https://github.com/chrisling-dev/hyperliquid-cli) (TypeScript CLI), and [zabi](https://github.com/Raiden1411/zabi) (Zig Ethereum tooling).

<p align="center">
  <a href="https://ziglang.org"><img src="docs/public/zig-mark.svg" alt="Zig" height="28" /></a>
  &nbsp;&nbsp;×&nbsp;&nbsp;
  <a href="https://hyperliquid.xyz"><img src="docs/public/hl-symbol.svg" alt="Hyperliquid" height="28" /></a>
</p>

---

MIT · Not affiliated with Hyperliquid.
