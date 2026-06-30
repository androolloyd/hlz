# CLI Overview

`hlz` is a 41-command CLI for Hyperliquid. 895KB static binary, zero config required for market data.

## Design Principles

- **Pipe-aware** — Tables on TTY, JSON when piped. No surprises.
- **Agent-native** — Structured output, semantic exit codes, no interactive prompts.
- **One binary** — Everything in 895KB. No runtime dependencies.
- **Smart defaults** — Works out of the box. Power users customize.

## Command Categories

| Category | Commands | Auth Required |
|----------|----------|---------------|
| [Market Data](/cli/market-data) | `price`, `mids`, `funding`, `book`, `perps`, `spot`, `outcomes`, `dexes` | No |
| [Trading](/cli/trading) | `buy`, `sell`, `cancel`, `modify`, `leverage`, `twap`, `batch` | Yes |
| [Account](/cli/account) | `portfolio`, `positions`, `orders`, `fills`, `balance`, `status`, `referral` | Address only |
| [Transfers](/cli/transfers) | `send` | Yes |
| [Streaming](/cli/streaming) | `stream` | No (public) / Yes (user events) |
| [Keys](/cli/keys) | `keys ls/new/import/export/default/rm` | No |
| [Deploy](/cli/deploy) | `deploy status`, `deploy spot <register\|user-genesis\|genesis\|register-pair\|hyperliquidity\|fee-share\|freeze\|token-action\|request-evm\|finalize-evm\|enable-quote\|enable-aligned>` | Read: no · Write: yes |
| [TUI](/terminal) | `trade`, `markets` | Yes (trading) / No (viewing) |

## Global Flags

```
--output json|pretty|csv    Output format (auto-json when piped)
--json                      Shorthand for --output json
--quiet, -q                 Minimal output (just result value)
--chain mainnet|testnet     Target chain
--key <HEX>                 Private key (prefer keystore)
--key-name <NAME>           Use named keystore key
--address <ADDR>            User address for queries
--dry-run, -n               Preview trade without sending
```

## Exit Codes

| Code | Meaning | Example |
|------|---------|---------|
| `0` | Success | Command completed |
| `1` | Error | API error, invalid response |
| `2` | Usage error | Bad arguments, unknown command |
| `3` | Auth error | Missing key or address |
| `4` | Network error | Connection refused, timeout |

## Asset Name Syntax

hlz uses a unified asset syntax across all commands:

| Format | Example | Description |
|--------|---------|-------------|
| `SYMBOL` | `BTC`, `ETH` | Perpetual on Hyperliquid DEX |
| `BASE/QUOTE` | `PURR/USDC` | Spot market |
| `dex:SYMBOL` | `xyz:BTC` | HIP-3 DEX perpetual |
| `#ENCODING` | `#12730` | Outcome market side |
