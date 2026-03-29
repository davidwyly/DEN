## Decentralized Exchange Network (Smart Contracts)

This repository contains the smart contracts for the Decentralized Exchange Network project for the Eclipse DAO (the system), to be used by the All For One mobile application (the partner).

## Features

Facilitates trading of ERC20 tokens on EVM-compatible blockchains:

- **Uniswap V2, V3, and V4 support** — swap through any version with a unified interface
- **Rate shopping** — `getBestRate()` compares prices across all registered V2 routers, V3 routers, and V4 pools to find the optimal route
- **Fee collection** on every trade in the native token:
    - System fee (Eclipse DAO): fixed 0.15%
    - Partner fee (All For One): configurable 0.01%–2.35%, default 0.50%
- **V3 fork compatibility** — the fallback callback handler accepts any V3-like pool callback regardless of function name, supporting PancakeSwap, SushiSwap, QuickSwap/Algebra, FusionX, Beamswap, Kyberswap, and others
- **V4 native ETH** — V4 swaps use native ETH directly (no WETH wrapping) for gas efficiency
- **Separate estimator contract** — `DENEstimator` provides view-only price quotes for V2, V3, and V4 pools without gas cost

## Architecture

| Contract | Purpose | Size |
|---|---|---|
| `V4SwapLib` | External library for V4 operations, rate estimation, and pool validation | Deployed separately |
| `DecentralizedExchangeNetwork` | Main swap contract with fee collection | Under 24KB (Spurious Dragon compliant) |
| `DENEstimator` | Price estimation for frontend display | Immutable after deployment |

The main contract stays under the 24KB deployment limit by delegating V4 callback settlement, price estimation, and pool validation to `V4SwapLib` (an external library linked at deploy time).

### Deployment Order

1. Deploy `V4SwapLib`
2. Deploy `DecentralizedExchangeNetwork` (linked to V4SwapLib)
3. Deploy `DENEstimator` (linked to V4SwapLib)
4. Configure: `addV2Router()`, `addV3Router()`, `setV4PoolManager()`, `addV4Pool()`

## Swap Paths

All swap functions require a `deadline` parameter (Unix timestamp). The transaction reverts if `block.timestamp > deadline`.

| Direction | V2 | V3 | V4 |
|---|---|---|---|
| ETH → Token | `swapETHForToken(pool, tokenOut, minOut, deadline)` | Same function (auto-detected) | `swapETHForTokenV4(poolId, tokenOut, minOut, deadline)` |
| Token → ETH | `swapTokenForETH(pool, tokenIn, amountIn, minOut, deadline)` | Same function | `swapTokenForETHV4(poolId, tokenIn, amountIn, minOut, deadline)` |
| Token → Token | `swapTokenForToken(pool, tokenIn, tokenOut, amountIn, minOut, deadline)` | Same function | `swapTokenForTokenV4(poolId, tokenIn, tokenOut, amountIn, minOut, deadline)` |

Each swap function has a `WithCustomFee` variant that accepts a custom partner fee numerator (0–235). Passing 0 skips the partner fee entirely — only the system fee (0.15%) is collected. This allows partners to offer fee discounts or fee-free swaps to premium customers. Users who interact with the contract directly may also set the partner fee to 0; the system fee is always enforced regardless.

## Fee Timing

- **ETH → Token**: DEN fees deducted from input ETH *before* swap
- **Token → ETH**: DEN fees deducted from output ETH *after* swap
- **Token → Token**: DEN fees deducted from output tokens *after* swap

Pool fees (V2 0.3%, V3 variable, V4 variable) are always applied by the pool independently.

## Fee Collection

Fees use a **pull-based** model — they accumulate inside the DEN contract during swaps and must be claimed separately:

- `claimSystemFeesETH()` / `claimSystemFeesToken(token)` — sends to `systemFeeReceiver`
- `claimPartnerFeesETH()` / `claimPartnerFeesToken(token)` — sends to `partnerFeeReceiver`

Anyone can call these functions; funds always go to the designated receiver. Swaps are never blocked by a reverting fee receiver — fees simply continue to accumulate until claimed.

## Testing

```bash
npm install
npx hardhat test
```

**151 tests** covering:
- All swap directions on V2 and V3 (ETH→Token, Token→ETH roundtrips)
- V4 pool management, rate checking, and error paths
- Fee calculation precision and zero-value edge cases
- Exploit path analysis (callback manipulation, approval drainage, reentrancy, payer spoofing)
- Rate shopping across V2 + V3 + V4
- Emergency functions, access control, and partner management
- Sequential and concurrent swap state integrity

V4 swap execution tests require a Cancun-compatible fork (transient storage). The Hardhat Base fork has a known limitation ([#5511](https://github.com/NomicFoundation/hardhat/issues/5511)) that prevents V4 PoolManager interaction in fork mode. V4 swap tests are marked pending and need Base Sepolia testnet validation.

## Target Chain

Base (Chain ID 8453). The Hardhat config forks Base mainnet for testing.

## Limitations

- **Single-hop only** — no multi-hop routing across multiple pools
- **Pool awareness required** — the caller must specify the pool address (V2/V3) or pool ID (V4); use `getBestRate()` for discovery
- **WETH cannot be tokenIn or tokenOut** — use the ETH swap functions for native ETH
- **V4 pool keys must be canonically ordered** — `currency0 < currency1`
- **Fee receiver must accept ETH** — if a fee receiver is a contract that reverts on ETH receive, fee claiming will fail (swaps are unaffected)

## Documentation

- [`docs/FRONTEND_INTEGRATION.md`](docs/FRONTEND_INTEGRATION.md) — complete frontend integration guide with TypeScript examples
- [`docs/SWAP_FLOW_DIAGRAMS.md`](docs/SWAP_FLOW_DIAGRAMS.md) — Mermaid sequence diagrams for all swap flows, callback security, rate shopping, and access control

## Credit

David Wyly (main author)
DeFi Mark (contributor)
