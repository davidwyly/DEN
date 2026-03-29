# DEN Swap Flow Diagrams

## System Architecture

```mermaid
graph TB
    subgraph User Layer
        UI[Frontend / Mobile App]
    end

    subgraph DEN Contracts
        DEN[DecentralizedExchangeNetwork]
        EST[DENEstimator]
        LIB[V4SwapLib]
    end

    subgraph Uniswap Pools
        V2[V2 Pair Pools]
        V3[V3 Concentrated Pools]
        V4[V4 PoolManager Singleton]
    end

    subgraph Fee Receivers
        SYS[Eclipse DAO<br/>System Fee 0.15%]
        PART[Partner App<br/>Partner Fee 0.50%]
    end

    UI -->|"1. estimateAmountOut()"| EST
    UI -->|"2. getBestRate()"| DEN
    UI -->|"3. swapETHForToken()"| DEN
    EST -.->|delegatecall| LIB
    DEN -.->|delegatecall| LIB
    DEN -->|swap| V2
    DEN -->|swap + callback| V3
    DEN -->|unlock + callback| V4
    DEN -->|ETH fees| SYS
    DEN -->|ETH fees| PART
```

## Frontend Swap Flow (High Level)

```mermaid
sequenceDiagram
    actor User
    participant UI as Frontend
    participant EST as DENEstimator
    participant DEN as DEN Contract
    participant Pool as Uniswap Pool

    User->>UI: Enter swap details<br/>(token, amount)

    rect rgb(240, 248, 255)
        Note over UI,EST: Phase 1 — Price Discovery (view calls, no gas)
        UI->>DEN: getBestRate(WETH, token, amount, feeTier)
        DEN-->>UI: routerUsed, version, bestOutput, v4PoolIndex
        UI->>EST: estimateAmountOut(pool, WETH, amount, fees...)
        EST-->>UI: estimatedOutput
        UI->>UI: amountOutMin = estimate * (1 - slippage)
    end

    UI-->>User: Show quote:<br/>~2,015 USDC<br/>min: 2,005 USDC<br/>via Uniswap V3

    User->>UI: Confirm swap

    rect rgb(255, 248, 240)
        Note over UI,Pool: Phase 2 — Execution (gas cost)
        UI->>UI: deadline = now + 5 minutes
        UI->>DEN: swapETHForToken(pool, token, amountOutMin, deadline)<br/>{value: ethAmount}
        DEN->>DEN: Deduct fees, accumulate in contract
        DEN->>Pool: Execute swap
        Pool-->>User: Output tokens sent directly
        DEN-->>UI: Transaction receipt
    end
    Note over DEN: Fees held in contract until<br/>claimSystemFeesETH() / claimPartnerFeesETH()

    UI-->>User: Swap complete!<br/>Received: 2,012 USDC
```

## ETH → Token (V2 Path)

```mermaid
sequenceDiagram
    actor User
    participant DEN
    participant WETH as WETH Contract
    participant V2 as V2 Pair Pool

    User->>DEN: swapETHForToken(pool, tokenOut, minOut, deadline)<br/>{value: 1 ETH}

    Note over DEN: Check deadline not expired
    Note over DEN: getFees(1 ETH, 50)<br/>systemFee = 0.0015 ETH<br/>partnerFee = 0.005 ETH<br/>remaining = 0.9935 ETH

    Note over DEN: Accumulate fees (pull-based):<br/>pendingSystemFeesETH += 0.0015<br/>pendingPartnerFeesETH += 0.005

    DEN->>WETH: deposit{0.9935 ETH}()
    Note over DEN: DEN now holds 0.9935 WETH

    DEN->>V2: transfer 0.9935 WETH to pair
    DEN->>V2: getReserves()
    Note over DEN: Calculate output via<br/>constant product (997/1000)
    DEN->>V2: swap(amount0Out, amount1Out, user, "")
    V2-->>User: USDC sent directly to user

    Note over DEN: Verify: USDC received >= minOut
```

## ETH → Token (V3 Path)

```mermaid
sequenceDiagram
    actor User
    participant DEN
    participant CB as DEN Callback Handler
    participant WETH as WETH Contract
    participant V3 as V3 Pool

    User->>DEN: swapETHForToken(pool, tokenOut, minOut, deadline)<br/>{value: 1 ETH}

    Note over DEN: Check deadline not expired
    Note over DEN: Deduct fees, wrap remaining to WETH

    Note over DEN: Accumulate fees (pull-based):<br/>pendingSystemFeesETH += 0.0015<br/>pendingPartnerFeesETH += 0.005

    DEN->>WETH: deposit{0.9935 ETH}()

    DEN->>DEN: currentSwapPool = V3 pool address
    DEN->>V3: pool.swap(user, zeroForOne, amountIn, priceLimit, callbackData)

    rect rgb(255, 245, 238)
        Note over V3,CB: V3 Callback (pool calls DEN)
        V3->>CB: fallback(amount0Delta, amount1Delta, data)
        Note over CB: Verify msg.sender == currentSwapPool
        CB->>CB: Decode (tokenIn, payer) from data
        CB->>WETH: transfer WETH from DEN to pool
    end

    V3-->>User: USDC sent directly to user
    DEN->>DEN: currentSwapPool = address(1)

    Note over DEN: Verify: USDC received >= minOut
```

## ETH → Token (V4 Path)

```mermaid
sequenceDiagram
    actor User
    participant DEN
    participant PM as V4 PoolManager

    User->>DEN: swapETHForTokenV4(poolId, tokenOut, minOut, deadline)<br/>{value: 1 ETH}

    Note over DEN: Check deadline not expired
    Note over DEN: Deduct fees from ETH

    Note over DEN: Accumulate fees (pull-based):<br/>pendingSystemFeesETH += 0.0015<br/>pendingPartnerFeesETH += 0.005

    Note over DEN: Build V4SwapCallbackData struct<br/>amountSpecified = -0.9935 ETH (negative = exact input)

    DEN->>DEN: v4SwapInProgress = true
    DEN->>PM: unlock(encodedCallbackData)

    rect rgb(245, 255, 245)
        Note over PM,DEN: V4 Unlock Callback
        PM->>DEN: unlockCallback(data)
        Note over DEN: Verify msg.sender == PM<br/>Verify v4SwapInProgress == true
        DEN->>PM: swap(poolKey, params, "")
        PM-->>DEN: BalanceDelta (packed int256)
        Note over DEN: Decode: amount0 < 0 (owe ETH)<br/>amount1 > 0 (receive USDC)

        DEN->>PM: settle{value: |amount0|}()
        Note over PM: ETH received, debt cleared
        DEN->>PM: take(USDC, user, amount1)
        PM-->>User: USDC sent to user
    end

    DEN->>DEN: v4SwapInProgress = false
    Note over DEN: Verify: USDC received >= minOut
```

## Token → ETH (All Versions)

```mermaid
sequenceDiagram
    actor User
    participant DEN
    participant Pool as V2/V3/V4 Pool
    participant WETH as WETH Contract

    Note over User: Must approve DEN first:<br/>token.approve(DEN, amount)

    User->>DEN: swapTokenForETH(pool, tokenIn, amountIn, minOut, deadline)

    Note over DEN: Check deadline not expired
    Note over DEN: NO fee deduction yet<br/>(fees taken from output)

    DEN->>Pool: Execute swap<br/>(user's tokens → pool → WETH to DEN)
    Pool-->>DEN: WETH received

    Note over DEN: getFees(wethReceived, 50)<br/>systemFee = 0.15% of output<br/>partnerFee = 0.50% of output

    DEN->>WETH: withdraw(totalWETH)
    Note over DEN: WETH → ETH

    Note over DEN: Accumulate fees (pull-based):<br/>pendingSystemFeesETH += systemFee<br/>pendingPartnerFeesETH += partnerFee

    DEN->>User: remaining ETH (output - fees)

    Note over DEN: Verify: ETH sent to user >= minOut
```

## Fee Claiming Flow

```mermaid
sequenceDiagram
    actor Caller as Anyone (keeper, receiver, UI)
    participant DEN
    participant SYS as System Fee Receiver
    participant PART as Partner Fee Receiver

    Note over DEN: Fees accumulated during swaps:<br/>pendingSystemFeesETH = X<br/>pendingPartnerFeesETH = Y

    Caller->>DEN: claimSystemFeesETH()
    Note over DEN: amount = pendingSystemFeesETH<br/>pendingSystemFeesETH = 0
    DEN->>SYS: send(amount) ETH

    Caller->>DEN: claimPartnerFeesETH()
    Note over DEN: amount = pendingPartnerFeesETH<br/>pendingPartnerFeesETH = 0
    DEN->>PART: send(amount) ETH

    Note over DEN: Token fees (from Token→Token swaps):

    Caller->>DEN: claimSystemFeesToken(USDC)
    Note over DEN: amount = pendingSystemFeesToken[USDC]<br/>pendingSystemFeesToken[USDC] = 0
    DEN->>SYS: USDC.transfer(amount)

    Caller->>DEN: claimPartnerFeesToken(USDC)
    Note over DEN: amount = pendingPartnerFeesToken[USDC]<br/>pendingPartnerFeesToken[USDC] = 0
    DEN->>PART: USDC.transfer(amount)
```

## Rate Shopping Flow

```mermaid
flowchart TD
    Start([getBestRate called])
    Start --> V2Loop

    subgraph V2["V2 Rate Check (view)"]
        V2Loop[Loop: supportedV2Routers]
        V2Loop --> V2Check[checkV2Rate:<br/>router.getAmountsOut]
        V2Check --> V2Compare{output > best?}
        V2Compare -->|Yes| V2Update[Update best:<br/>version = 2]
        V2Compare -->|No| V2Next[Next router]
        V2Update --> V2Next
        V2Next --> V2Loop
    end

    V2Loop -->|Done| V3Loop

    subgraph V3["V3 Rate Check (view)"]
        V3Loop[Loop: supportedV3Routers]
        V3Loop --> V3Check[checkV3Rate:<br/>sqrtPriceX96 estimate]
        V3Check --> V3Compare{output > best?}
        V3Compare -->|Yes| V3Update[Update best:<br/>version = 3]
        V3Compare -->|No| V3Next[Next router]
        V3Update --> V3Next
        V3Next --> V3Loop
    end

    V3Loop -->|Done| V4Loop

    subgraph V4["V4 Rate Check (view)"]
        V4Loop[Loop: supportedV4Pools]
        V4Loop --> V4Check[checkV4Rate:<br/>PM.extsload sqrtPriceX96]
        V4Check --> V4Compare{output > best?}
        V4Compare -->|Yes| V4Update[Update best:<br/>version = 4]
        V4Compare -->|No| V4Next[Next pool]
        V4Update --> V4Next
        V4Next --> V4Loop
    end

    V4Loop -->|Done| Return([Return: routerUsed,<br/>versionUsed, bestOutput,<br/>v4PoolIndex])

    style V2 fill:#e8f5e9
    style V3 fill:#e3f2fd
    style V4 fill:#fff3e0
```

## Fee Deduction Timing

```mermaid
flowchart LR
    subgraph ETH_TO_TOKEN["ETH → Token"]
        direction TB
        A1[User sends ETH] --> A2[Deduct DEN fees<br/>from INPUT]
        A2 --> A2b[Fees accumulate in contract]
        A2b --> A3[Swap remaining ETH]
        A3 --> A4[User receives tokens]
    end

    subgraph TOKEN_TO_ETH["Token → ETH"]
        direction TB
        B1[User sends tokens] --> B2[Swap full amount]
        B2 --> B3[Deduct DEN fees<br/>from OUTPUT ETH]
        B3 --> B3b[Fees accumulate in contract]
        B3b --> B4[User receives ETH]
    end

    subgraph TOKEN_TO_TOKEN["Token → Token"]
        direction TB
        C1[User sends tokens] --> C2[Swap full amount]
        C2 --> C3[Deduct DEN fees<br/>from OUTPUT tokens]
        C3 --> C3b[Fees accumulate in contract]
        C3b --> C4[User receives tokens]
    end

    style ETH_TO_TOKEN fill:#e8f5e9
    style TOKEN_TO_ETH fill:#e3f2fd
    style TOKEN_TO_TOKEN fill:#fff3e0
```

**Note:** All fees are pull-based. They accumulate inside the DEN contract during swaps. System and partner fee receivers claim their pending fees by calling `claimSystemFeesETH()` / `claimPartnerFeesETH()` (for ETH) or `claimSystemFeesToken(token)` / `claimPartnerFeesToken(token)` (for tokens). Anyone can trigger a claim — the funds always go to the designated receiver.

## V3 Callback Security Model

```mermaid
flowchart TD
    A[V3 Pool calls DEN fallback] --> B{msg.data >= 68 bytes?}
    B -->|No| C[REVERT: InsufficientCallbackData]
    B -->|Yes| D[Decode: amount0Delta, amount1Delta, data]
    D --> E{msg.sender == currentSwapPool?}
    E -->|No| F[REVERT: UnauthorizedCallback]
    E -->|Yes| G{amount0Delta > 0 OR amount1Delta > 0?}
    G -->|No| H[REVERT: NoTokensReceived]
    G -->|Yes| I[Decode inner data: tokenIn, payer]
    I --> J{payer == DEN contract?}
    J -->|Yes| K[Transfer WETH<br/>from DEN to pool]
    J -->|No| L[TransferFrom<br/>user to pool]
    K --> M[Callback complete]
    L --> M

    style C fill:#ffcdd2
    style F fill:#ffcdd2
    style H fill:#ffcdd2
    style M fill:#c8e6c9
```

## V4 Callback Security Model

```mermaid
flowchart TD
    A[PM calls DEN.unlockCallback] --> B{msg.sender == v4PoolManager?}
    B -->|No| C[REVERT: UnauthorizedUnlockCallback]
    B -->|Yes| D{v4SwapInProgress == true?}
    D -->|No| E[REVERT: UnauthorizedUnlockCallback]
    D -->|Yes| F[Decode V4SwapCallbackData]
    F --> G[PM.swap - get BalanceDelta]
    G --> H{currencyIn == address 0?}
    H -->|Yes: Native ETH| I[PM.settle with ETH value]
    H -->|No: ERC20| J[PM.sync → transfer → PM.settle]
    I --> K[PM.take output to recipient]
    J --> K
    K --> L[Return encoded amountOut]

    style C fill:#ffcdd2
    style E fill:#ffcdd2
    style L fill:#c8e6c9
```

## Access Control Model

```mermaid
graph TB
    subgraph Owner["Owner (Deployer)"]
        O1[setSystemFeeReceiver]
        O2[addV2Router / removeV2Router]
        O3[addV3Router / removeV3Router]
        O4[setV4PoolManager]
        O5[addV4Pool / removeV4Pool]
        O6[emergencyWithdrawETH]
        O7[emergencyWithdrawToken]
    end

    subgraph Partner["Partner"]
        P1[setPartnerFeeNumerator<br/>min: 1, max: 235]
        P2[setPartnerFeeReceiver]
        P3[transferPartnership]
    end

    subgraph Public["Any User"]
        U1[swapETHForToken]
        U2[swapTokenForETH]
        U3[swapTokenForToken]
        U4[swapETHForTokenV4]
        U5[swapTokenForETHV4]
        U6[swapTokenForTokenV4]
        U7["WithCustomFee variants<br/>(fee: 0–235)"]
        U8[getBestRate]
        U9[getFees]
        U10[getUniswapVersion]
        U11[checkV2Rate / checkV3Rate / checkV4Rate]
        U12["claimSystemFeesETH/Token<br/>(funds go to systemFeeReceiver)"]
        U13["claimPartnerFeesETH/Token<br/>(funds go to partnerFeeReceiver)"]
    end

    subgraph Callback["Restricted Callbacks"]
        CB1["fallback() — only currentSwapPool"]
        CB2["unlockCallback() — only v4PoolManager<br/>+ v4SwapInProgress"]
    end

    style Owner fill:#fff3e0
    style Partner fill:#e3f2fd
    style Public fill:#e8f5e9
    style Callback fill:#fce4ec
```

## Contract Deployment Order

```mermaid
flowchart TD
    A[1. Deploy V4SwapLib] --> B[2. Deploy DEN<br/>linked to V4SwapLib]
    A --> C[3. Deploy DENEstimator<br/>linked to V4SwapLib]
    B --> D[4. Configure DEN]
    D --> E[addV2Router]
    D --> F[addV3Router]
    D --> G[setV4PoolManager]
    G --> H[addV4Pool for each pair]

    style A fill:#e3f2fd
    style B fill:#e8f5e9
    style C fill:#e8f5e9
    style D fill:#fff3e0
```
