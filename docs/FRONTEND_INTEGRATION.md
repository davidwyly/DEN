# DEN Frontend Integration Guide

## Architecture Overview

The DEN consists of three deployed contracts:

| Contract | Purpose | Mutability |
|---|---|---|
| **V4SwapLib** | External library (linked at deploy time) | Immutable |
| **DecentralizedExchangeNetwork** | Main swap contract | Owner-configurable |
| **DENEstimator** | Price estimation for UI display | Immutable |

The frontend interacts with **DEN** for swaps and configuration, and **DENEstimator** for price quotes.

---

## Contract Addresses (Base Mainnet)

These must be populated after deployment:

```typescript
const CONTRACTS = {
  den: "0x...",           // DecentralizedExchangeNetwork
  estimator: "0x...",     // DENEstimator
  weth: "0x4200000000000000000000000000000000000006",
};

// Known Uniswap infrastructure on Base
const UNISWAP = {
  v2Router: "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24",
  v3Factory: "0x33128a8fC17869897dcE68Ed026d694621f6FDfD",
  v3Router: "0x2626664c2603336E57B271c5C0b26F421741e481",
  v4PoolManager: "0x498581fF718922c3f8e6A244956aF099B2652b2b",
};
```

---

## Fee Structure

| Fee | Rate | Recipient | When Deducted |
|---|---|---|---|
| System fee | 0.15% (15/10000) | Eclipse DAO | Always |
| Partner fee | 0.50% default (50/10000), max 2.35% | Partner app | Always |
| V2 pool fee | 0.30% | Liquidity providers | During swap |
| V3 pool fee | Varies (0.01%, 0.05%, 0.30%, 1.00%) | Liquidity providers | During swap |
| V4 pool fee | Varies | Liquidity providers | During swap |

**Fee deduction timing:**
- **ETH → Token**: DEN fees deducted from input ETH *before* swap
- **Token → ETH**: DEN fees deducted from output ETH *after* swap
- **Token → Token**: DEN fees deducted from output tokens *after* swap

**Important**: The DEN fees and pool fees are independent. Total cost = DEN fee + pool fee.

---

## Step-by-Step Swap Flow

### 1. Find Available Pools

```typescript
import { ethers } from "ethers";

// Query registered routers and pools
const v2Routers = await den.getSupportedV2Routers();
const v3Routers = await den.getSupportedV3Routers();
const v4Pools = await den.getSupportedV4Pools();
```

### 2. Look Up the Pool for Your Token Pair

```typescript
// V2: get pool address from router
const v2Pool = await den.getV2PoolFromRouter(
  UNISWAP.v2Router,
  tokenAddress,
  CONTRACTS.weth
);

// V3: get pool address from factory (specify fee tier)
const v3Pool = await den.getV3PoolFromFactory(
  UNISWAP.v3Factory,
  tokenAddress,
  CONTRACTS.weth,
  3000  // fee tier: 500, 3000, or 10000
);

// V4: compute pool ID from pool key
const v4PoolKey = {
  currency0: "0x0000000000000000000000000000000000000000", // native ETH
  currency1: tokenAddress,                                  // must be > currency0
  fee: 500,
  tickSpacing: 10,
  hooks: "0x0000000000000000000000000000000000000000",
};
const v4PoolId = await den.getV4PoolId(v4PoolKey);
const isRegistered = await den.isV4PoolSupported(v4PoolId);
```

### 3. Get a Price Quote

Use the **DENEstimator** contract (view-only, no gas cost):

```typescript
// V2 or V3 estimate
const estimatedOutput = await estimator.estimateAmountOut(
  poolAddress,        // V2 or V3 pool address
  CONTRACTS.weth,     // tokenIn (WETH for ETH swaps)
  amountIn,           // amount in wei
  50,                 // partnerFeeNumerator (0.5%)
  15,                 // systemFeeNumerator (0.15%)
  10000               // feeDenominator
);

// V4 estimate
const v4Estimate = await estimator.estimateAmountOutV4(
  v4PoolKey,
  CONTRACTS.weth,     // tokenIn (use WETH address for ETH)
  tokenAddress,       // tokenOut
  amountIn
);
```

**Or use rate shopping** to find the best price across all registered venues:

```typescript
const [routerUsed, versionUsed, bestOutput, v4PoolIndex] = await den.getBestRate(
  CONTRACTS.weth,     // tokenIn
  tokenAddress,       // tokenOut
  amountIn,
  3000                // V3 fee tier to check
);

// versionUsed: 2 = V2, 3 = V3, 4 = V4
// routerUsed: the router/PM address that won
// v4PoolIndex: index in getSupportedV4Pools() (only valid when versionUsed == 4)
```

### 4. Calculate Slippage Protection

```typescript
const SLIPPAGE_BPS = 50; // 0.5% slippage tolerance

// amountOutMin = estimate * (1 - slippage)
const amountOutMin = estimatedOutput * BigInt(10000 - SLIPPAGE_BPS) / 10000n;
```

### 5. Execute the Swap

#### ETH → Token

```typescript
// V2 or V3 (auto-detected by pool type)
const tx = await den.swapETHForToken(
  poolAddress,        // V2 or V3 pool address
  tokenAddress,       // output token
  amountOutMin,       // minimum output (slippage protection)
  { value: amountIn } // ETH to swap
);

// V4
const tx = await den.swapETHForTokenV4(
  v4PoolId,           // bytes32 pool identifier
  tokenAddress,       // output token
  amountOutMin,
  { value: amountIn }
);
```

#### Token → ETH

**User must approve the DEN contract first:**

```typescript
// Step 1: Approve
const tokenContract = new ethers.Contract(tokenAddress, erc20Abi, signer);
await tokenContract.approve(denAddress, amountIn);

// Step 2: Swap
const tx = await den.swapTokenForETH(
  poolAddress,        // V2 or V3 pool address
  tokenAddress,       // input token
  amountIn,           // amount of tokens to swap
  amountOutMin        // minimum ETH output
);

// V4 variant
const tx = await den.swapTokenForETHV4(
  v4PoolId,
  tokenAddress,
  amountIn,
  amountOutMin
);
```

#### Token → Token

**User must approve the DEN contract first. Neither token can be WETH.**

```typescript
await tokenIn.approve(denAddress, amountIn);

const tx = await den.swapTokenForToken(
  poolAddress,
  tokenInAddress,
  tokenOutAddress,
  amountIn,
  amountOutMin
);

// V4 variant
const tx = await den.swapTokenForTokenV4(
  v4PoolId,
  tokenInAddress,
  tokenOutAddress,
  amountIn,
  amountOutMin
);
```

---

## Critical Rules for the Frontend

### Never Pass WETH as tokenIn or tokenOut

The contract rejects WETH in user-facing parameters. WETH is used internally only.
- For ETH input: use `swapETHForToken` / `swapETHForTokenV4` with `msg.value`
- For ETH output: use `swapTokenForETH` / `swapTokenForETHV4`
- Token → Token: neither token can be WETH

### V4 Pool Keys Must Be Canonically Ordered

`currency0` must be numerically less than `currency1`. Native ETH is `address(0)`, which is always the lowest.

```typescript
// Correct: address(0) < USDC address
{ currency0: "0x000...000", currency1: "0x833...913", ... }

// WRONG: will be rejected by the contract
{ currency0: "0x833...913", currency1: "0x000...000", ... }
```

### Minimum Fee Enforcement

The `WithCustomFee` variants require `partnerFeeNumerator >= 1`. Passing 0 reverts.

### Estimates Are Approximate

The DENEstimator gives a spot-price estimate that does not account for:
- Price impact on large trades
- Pending transactions that may change the pool state
- V3/V4 tick crossing (estimate uses the current tick only)

Always apply slippage tolerance. For larger trades, use higher slippage.

### Token Approval Lifecycle

After calling `approve(denAddress, amount)`, the DEN pulls exactly the specified `amountIn` during the swap. Any remaining approval persists (standard ERC20 behavior). The DEN never approves third-party contracts — it transfers tokens directly.

---

## Tracking Swap Results

### Events

Listen for swap events to confirm execution:

```typescript
// V2/V3 swaps
den.on("Swap", (caller, pool, uniswapVersion, tokenIn, tokenOut) => {
  console.log(`Swap: ${caller} via ${pool} (V${uniswapVersion})`);
});

// V4 swaps
den.on("SwapV4", (caller, poolId, tokenIn, tokenOut) => {
  console.log(`V4 Swap: ${caller} pool ${poolId}`);
});
```

### Measuring Actual Output

The contract does not return the output amount in the transaction receipt. Measure it by comparing token balances before and after:

```typescript
const balanceBefore = await token.balanceOf(userAddress);
const tx = await den.swapETHForToken(pool, token, amountOutMin, { value: amountIn });
await tx.wait();
const balanceAfter = await token.balanceOf(userAddress);
const received = balanceAfter - balanceBefore;
```

---

## Error Handling

The contract uses custom errors. Decode them in the frontend:

```typescript
try {
  await den.swapETHForToken(pool, token, amountOutMin, { value: amountIn });
} catch (error) {
  const decoded = den.interface.parseError(error.data);
  switch (decoded?.name) {
    case "ReceivedLessThanMinimum":
      alert("Price moved too much. Try increasing slippage tolerance.");
      break;
    case "ZeroValueForMsgValue":
      alert("No ETH amount specified.");
      break;
    case "CannotHaveWETHAsTokenOut":
      alert("Cannot swap to WETH directly. Use ETH.");
      break;
    case "InsufficientTokenBalance":
      alert("Insufficient token balance.");
      break;
    case "InsufficientTokenAllowance":
      alert("Please approve the DEN contract to spend your tokens.");
      break;
    case "UnsupportedDEX":
      alert("This pool type is not supported.");
      break;
    default:
      alert(`Swap failed: ${decoded?.name || "Unknown error"}`);
  }
}
```

### Common Errors

| Error | Cause | User Action |
|---|---|---|
| `ReceivedLessThanMinimum` | Price moved beyond slippage tolerance | Increase slippage or retry |
| `ZeroValueForMsgValue` | No ETH sent with ETH→Token swap | Include ETH value |
| `ZeroValueForAmountOutMin` | amountOutMin is 0 | Set a minimum output |
| `ZeroValueForAmountIn` | amountIn is 0 | Specify an input amount |
| `CannotHaveWETHAsTokenIn` | Passed WETH address as tokenIn | Use swapETHForToken instead |
| `CannotHaveWETHAsTokenOut` | Passed WETH address as tokenOut | Use swapTokenForETH instead |
| `InsufficientTokenBalance` | User doesn't have enough tokens | Check balance first |
| `InsufficientTokenAllowance` | DEN not approved to spend tokens | Call token.approve() first |
| `InvalidTokensForV2Pair` | Pool doesn't contain the specified tokens | Use correct pool for the pair |
| `InvalidTokensForV3Pool` | Pool doesn't contain the specified tokens | Use correct pool for the pair |
| `UnsupportedDEX` | Pool address is not a recognized V2 or V3 pool | Verify pool address |
| `V4PoolManagerNotSet` | V4 PM not configured | Admin must call setV4PoolManager |
| `V4PoolNotRegistered` | V4 pool ID not in the supported list | Admin must call addV4Pool |
| `PartnerFeeTooHigh` | Custom fee is 0 or > 235 | Use fee between 1 and 235 |

---

## Complete TypeScript Example

```typescript
import { ethers } from "ethers";

const DEN_ABI = [...]; // import from artifacts
const ESTIMATOR_ABI = [...]; // import from artifacts
const ERC20_ABI = [
  "function approve(address, uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address, address) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
];

async function swapETHForToken(
  provider: ethers.BrowserProvider,
  denAddress: string,
  estimatorAddress: string,
  tokenOut: string,
  ethAmount: string,
  slippageBps: number = 50
) {
  const signer = await provider.getSigner();
  const den = new ethers.Contract(denAddress, DEN_ABI, signer);
  const estimator = new ethers.Contract(estimatorAddress, ESTIMATOR_ABI, provider);
  const token = new ethers.Contract(tokenOut, ERC20_ABI, provider);

  const amountIn = ethers.parseEther(ethAmount);

  // 1. Find best rate
  const [routerUsed, versionUsed, bestOutput, v4PoolIndex] =
    await den.getBestRate(
      "0x4200000000000000000000000000000000000006", // WETH
      tokenOut,
      amountIn,
      3000 // V3 fee tier
    );

  if (bestOutput === 0n) throw new Error("No liquidity found");

  // 2. Get estimate from the winning venue
  let estimate: bigint;
  let poolAddress: string;
  let poolId: string;

  if (versionUsed === 2 || versionUsed === 3) {
    // For V2/V3, find the specific pool
    if (versionUsed === 2) {
      poolAddress = await den.getV2PoolFromRouter(
        routerUsed,
        "0x4200000000000000000000000000000000000006",
        tokenOut
      );
    } else {
      const v3Factory = await new ethers.Contract(
        routerUsed,
        ["function factory() view returns (address)"],
        provider
      ).factory();
      poolAddress = await den.getV3PoolFromFactory(v3Factory, tokenOut, "0x4200000000000000000000000000000000000006", 3000);
    }
    estimate = await estimator.estimateAmountOut(poolAddress, "0x4200000000000000000000000000000000000006", amountIn, 50, 15, 10000);
  } else {
    // V4
    const pools = await den.getSupportedV4Pools();
    const poolKey = pools[Number(v4PoolIndex)];
    poolId = await den.getV4PoolId(poolKey);
    estimate = await estimator.estimateAmountOutV4(poolKey, "0x4200000000000000000000000000000000000006", tokenOut, amountIn);
  }

  // 3. Apply slippage
  const amountOutMin = estimate * BigInt(10000 - slippageBps) / 10000n;

  // 4. Display to user
  const decimals = await token.decimals();
  const symbol = await token.symbol();
  console.log(`Swapping ${ethAmount} ETH for ~${ethers.formatUnits(estimate, decimals)} ${symbol}`);
  console.log(`Minimum output: ${ethers.formatUnits(amountOutMin, decimals)} ${symbol}`);
  console.log(`Route: Uniswap V${versionUsed}`);

  // 5. Execute
  const balanceBefore = await token.balanceOf(await signer.getAddress());

  let tx;
  if (versionUsed === 4) {
    tx = await den.swapETHForTokenV4(poolId!, tokenOut, amountOutMin, { value: amountIn });
  } else {
    tx = await den.swapETHForToken(poolAddress!, tokenOut, amountOutMin, { value: amountIn });
  }

  const receipt = await tx.wait();
  const balanceAfter = await token.balanceOf(await signer.getAddress());
  const received = balanceAfter - balanceBefore;

  console.log(`Received: ${ethers.formatUnits(received, decimals)} ${symbol}`);
  console.log(`Tx: ${receipt.hash}`);

  return { received, txHash: receipt.hash };
}
```

---

## Known Limitations

1. **No deadline parameter**: Transactions have no expiry. Use tight `amountOutMin` values.
2. **V4 swaps require Cancun EVM**: The V4 PoolManager uses transient storage. Only works on chains with Cancun support (Base mainnet has this).
3. **Estimates are spot-price only**: Large trades will experience slippage beyond the estimate. The estimate does not simulate the full AMM curve.
4. **Rate shopping checks one V3 fee tier**: `getBestRate` takes a single `feeTier` parameter. To check multiple V3 fee tiers (500, 3000, 10000), call it multiple times or check individual pools.
5. **Token → Token requires pool with direct pair**: The DEN does not support multi-hop routing. Both tokens must exist in the same pool.
