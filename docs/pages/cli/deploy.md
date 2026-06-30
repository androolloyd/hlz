# Deploy

HIP-1 spot token deployment and the admin ops on top of it. All write
subcommands require authentication (see [Configuration](/introduction/configuration))
and support `--dry-run` (or `-n`) to preview without signing.

## Read

### `hlz deploy status [--pair]`

Show the live Dutch-auction gas price for one or both auctions:

```bash
# both perp deploy + spot pair auctions
hlz deploy status

# only the base/quote spot-pair auction
hlz deploy status --pair
```

Renders the start / current / floor gas in HYPE plus elapsed and
remaining minutes for the current auction window. `--json` returns the
raw upstream bodies wrapped as `{perp, spotPair}` (or `spotPair` alone
when `--pair` is set) so scripts get the exact wire shape.

## HIP-1 Spot Deploy Flow

The full flow is five ordered steps. Each step is idempotent within
itself but the exchange enforces order across steps.

### 1. `hlz deploy spot register <NAME>`

Bid the HIP-1 gas auction for a fresh ticker.

```bash
hlz deploy spot register XD \
  --sz-dec 2 --wei-dec 8 \
  --max-gas 500 \
  --full-name "XD Token" \
  --dry-run
```

`--max-gas` is the max HYPE you'll pay if the auction clears at or below
that price (500 HYPE is the floor). The CLI multiplies by 10^8 to reach
wei internally. `--full-name` defaults to `<NAME>` when omitted.

### 2. `hlz deploy spot user-genesis <TOKEN>`

Allocate wei to specific users and/or holders of an existing token.
Both flags are repeatable and can be mixed:

```bash
hlz deploy spot user-genesis 2195 \
  --alloc 0xabc...:1000000000 \
  --alloc 0xdef...:500000000 \
  --from-token 1:100000
```

- `--alloc <addr>:<wei>` grants wei to a single 0x address.
- `--from-token <tid>:<wei>` grants the total to holders of token
  `tid`, proportionally.

### 3. `hlz deploy spot genesis <TOKEN>`

Fix the token's max supply. The exchange rejects unless it exactly
matches the sum of every user-genesis allocation.

```bash
hlz deploy spot genesis 2195 --max-supply 100000000000
# skip HIP-2 seeding entirely (external MM will bootstrap)
hlz deploy spot genesis 2195 --max-supply 100000000000 --no-hyperliquidity
```

### 4. `hlz deploy spot register-pair <BASE> <QUOTE>`

Pair the token against an existing quote (0 = USDC):

```bash
hlz deploy spot register-pair 2195 0
```

Deployments where both sides already exist run through the separate
spot-pair Dutch auction — check `hlz deploy status --pair` first.

### 5. `hlz deploy spot hyperliquidity <SPOT_INDEX>`

Seed the HIP-2 book on the pair returned by step 4:

```bash
hlz deploy spot hyperliquidity 200 \
  --start-px 1.5 \
  --order-sz 100 \
  --n-orders 10 \
  --seeded-levels 3
```

Skipped for tokens whose genesis used `--no-hyperliquidity`.

## Admin

### `hlz deploy spot fee-share <TOKEN> <PCT>`

Set the deployer trading-fee share. Resendable at any time — share can
only decrease.

```bash
hlz deploy spot fee-share 2195 50%
hlz deploy spot fee-share 2195 0.5%
```

### `hlz deploy spot freeze <TOKEN> <USER> [--unfreeze]`

Freeze a user's balance (or unfreeze with the flag). Requires the token
to have `enableFreezePrivilege` set via `token-action`.

```bash
hlz deploy spot freeze 2195 0xabc...
hlz deploy spot freeze 2195 0xabc... --unfreeze
```

### `hlz deploy spot token-action <TOKEN> <VARIANT>`

Generic router for the enable/revoke variants:

```bash
hlz deploy spot token-action 2195 enableFreezePrivilege
hlz deploy spot token-action 2195 revokeFreezePrivilege
```

## EVM Linking

Link a HIP-1 spot token to a HyperEVM ERC-20 (e.g. a LayerZero OFT) so
the two can be bridged through the Core asset-bridge address.

### `hlz deploy spot request-evm <TOKEN> <ERC20> --extra-wei-dec <N>`

Core-side deployer call. `--extra-wei-dec` is `evmWeiDecimals - coreWeiDecimals`
(range `[-2, 18]`).

```bash
hlz deploy spot request-evm 2195 0x8cde56336e289c028c8f7cf5c20283ff02272182 --extra-wei-dec -2
```

The address must be lowercase — the exchange signs over the exact
bytes, so mixed-case breaks the link. The CLI rejects at the boundary.

### `hlz deploy spot finalize-evm <TOKEN> <proof>`

EVM-side deployer call proving control over the ERC-20. Choose exactly
one proof:

```bash
# EOA case: nonce that deployed the contract
hlz deploy spot finalize-evm 2195 --create-nonce 42

# contract-deployed case: first storage slot points to Core deployer
hlz deploy spot finalize-evm 2195 --first-slot

# contract-deployed case: custom storage slot
hlz deploy spot finalize-evm 2195 --custom-slot
```

## Quote-Token Toggles

### `hlz deploy spot enable-quote <TOKEN>`

Enable the token as a permissionless quote asset. Once set, other
deployers can register spot pairs against it.

### `hlz deploy spot enable-aligned <TOKEN>`

Enable the token as an aligned quote asset — see
[Aligned Quote Assets](https://hyperliquid.gitbook.io/hyperliquid-docs/hypercore/aligned-quote-assets).
Requires 800k additional staked HYPE and validator vote off-chain.
