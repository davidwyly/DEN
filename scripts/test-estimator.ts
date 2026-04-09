import { ethers } from "ethers";

/**
 * Sanity-check DENEstimator against common Base tokens.
 * Probes getBestRateAllTiers for several pairs in both directions
 * and directly queries the V4 ETH/USDC pool we registered.
 */

const ESTIMATOR = "0xEe53856B87A73Ae3019A4B08B1AA99996488D7B5";
const DEN       = "0x5E5B0846BA79046A8Cc8FA7A8529c4FdedA0F352";
const RPC       = "https://mainnet.base.org";

// Common Base token addresses
const T = {
    WETH:  { addr: "0x4200000000000000000000000000000000000006", dec: 18, sym: "WETH"  },
    USDC:  { addr: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", dec: 6,  sym: "USDC"  },
    USDbC: { addr: "0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA", dec: 6,  sym: "USDbC" },
    DAI:   { addr: "0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb", dec: 18, sym: "DAI"   },
    cbETH: { addr: "0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22", dec: 18, sym: "cbETH" },
    cbBTC: { addr: "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf", dec: 8,  sym: "cbBTC" },
    AERO:  { addr: "0x940181a94A35A4569E4529A3CDfB74e38FD98631", dec: 18, sym: "AERO"  },
};

type Token = typeof T[keyof typeof T];

const estimatorAbi = [
    "function getBestRateAllTiers(address tokenIn, address tokenOut, uint256 amountIn) view returns (address routerUsed, uint8 versionUsed, uint256 highestOut, uint256 v4PoolIndex, uint24 bestFeeTier)",
    "function estimateAmountOutV4(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, address tokenIn, address tokenOut, uint256 amountIn) view returns (uint256)",
    "function discoverAllPools(address tokenA, address tokenB) view returns (tuple(uint8 version, address poolAddress, bytes32 poolId, uint24 fee)[])",
];

const denAbi = [
    "function getSupportedV4Pools() view returns (tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)[])",
];

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function retryCall<T>(fn: () => Promise<T>, retries = 3, delayMs = 400): Promise<T> {
    for (let i = 0; i < retries; i++) {
        try {
            return await fn();
        } catch (e: any) {
            const msg = e.info?.error?.message || e.shortMessage || e.message || "";
            if (i < retries - 1 && (msg.includes("rate limit") || msg.includes("missing revert data"))) {
                await sleep(delayMs * (i + 1) * 2);
                continue;
            }
            throw e;
        }
    }
    throw new Error("unreachable");
}

async function quote(
    estimator: ethers.Contract,
    tokenIn: Token,
    tokenOut: Token,
    humanAmount: string
): Promise<void> {
    const amountIn = ethers.parseUnits(humanAmount, tokenIn.dec);
    const label = `${humanAmount.padStart(10)} ${tokenIn.sym.padEnd(6)} → ${tokenOut.sym.padEnd(6)}`;

    try {
        const [router, version, out, v4Idx, feeTier] = await retryCall(() =>
            estimator.getBestRateAllTiers(tokenIn.addr, tokenOut.addr, amountIn)
        );
        if (out === 0n) {
            console.log(`  ${label}   ✗ no route (version=${version})`);
            return;
        }

        const outHuman = ethers.formatUnits(out, tokenOut.dec);
        const outFmt = Number(outHuman).toLocaleString(undefined, {
            minimumFractionDigits: 2,
            maximumFractionDigits: 6,
        });

        const v = Number(version);
        const routeTag =
            v === 2 ? `V2  ${router.slice(0, 10)}...` :
            v === 3 ? `V3  ${router.slice(0, 10)}... fee=${feeTier}` :
            v === 4 ? `V4  poolIdx=${v4Idx}` :
            `unknown(${v})`;

        console.log(`  ${label} = ${outFmt.padStart(18)} ${tokenOut.sym.padEnd(6)}  [${routeTag}]`);
    } catch (e: any) {
        const msg = e.info?.error?.message || e.shortMessage || e.message;
        console.log(`  ${label}   ✗ ${msg}`);
    }
    await sleep(250);
}

async function main() {
    const provider = new ethers.JsonRpcProvider(RPC);
    const estimator = new ethers.Contract(ESTIMATOR, estimatorAbi, provider);
    const den = new ethers.Contract(DEN, denAbi, provider);

    console.log(`\nTesting DENEstimator at ${ESTIMATOR}\n`);

    console.log("── Registered V4 pools on DEN ─────────────────────────────────");
    const v4Pools = await den.getSupportedV4Pools();
    v4Pools.forEach((p: any, i: number) => {
        console.log(`  [${i}] c0=${p.currency0}`);
        console.log(`      c1=${p.currency1}`);
        console.log(`      fee=${p.fee}  tickSpacing=${p.tickSpacing}  hooks=${p.hooks}`);
    });

    console.log("\n── Direct V4 quote on registered ETH/USDC pool ───────────────");
    // Copy frozen Result into plain object for re-encoding
    const ethUsdcPool = {
        currency0: v4Pools[0].currency0,
        currency1: v4Pools[0].currency1,
        fee: v4Pools[0].fee,
        tickSpacing: v4Pools[0].tickSpacing,
        hooks: v4Pools[0].hooks,
    };
    // V4 uses native ETH (address(0)) as currency0, not WETH
    const amounts = ["0.001", "0.01", "0.1", "1.0"];
    for (const a of amounts) {
        const amtIn = ethers.parseEther(a);
        try {
            const out = await retryCall(() =>
                estimator.estimateAmountOutV4(ethUsdcPool, ethers.ZeroAddress, T.USDC.addr, amtIn)
            );
            const usdcOut = Number(ethers.formatUnits(out, 6));
            console.log(`  ${a.padStart(6)} ETH  → V4 pool = ${usdcOut.toFixed(6).padStart(14)} USDC`);
        } catch (e: any) {
            console.log(`  ${a.padStart(6)} ETH  → V4 pool   ✗ ${e.shortMessage || e.message}`);
        }
        await sleep(250);
    }

    console.log("\n── discoverAllPools WETH/USDC ────────────────────────────────");
    await sleep(1000); // extra pacing to rule out RPC rate-limit from prior burst
    try {
        const pools = await retryCall(() => estimator.discoverAllPools(T.WETH.addr, T.USDC.addr));
        pools.forEach((p: any, i: number) => {
            const loc = p.version === 4n ? `poolId=${p.poolId.slice(0, 18)}...` : `@ ${p.poolAddress}`;
            console.log(`  [${i}] V${p.version} fee=${p.fee} ${loc}`);
        });
    } catch (e: any) {
        console.log(`  ✗ ${e.shortMessage || e.message}`);
    }
    await sleep(500);

    console.log("\n── Forward rates from WETH ───────────────────────────────────");
    await quote(estimator, T.WETH, T.USDC,  "0.1");
    await quote(estimator, T.WETH, T.USDC,  "1.0");
    await quote(estimator, T.WETH, T.USDbC, "0.1");
    await quote(estimator, T.WETH, T.DAI,   "0.1");
    await quote(estimator, T.WETH, T.cbETH, "0.1");
    await quote(estimator, T.WETH, T.cbBTC, "0.1");
    await quote(estimator, T.WETH, T.AERO,  "0.1");

    console.log("\n── Reverse rates into WETH ───────────────────────────────────");
    await quote(estimator, T.USDC,  T.WETH, "300");
    await quote(estimator, T.USDbC, T.WETH, "300");
    await quote(estimator, T.DAI,   T.WETH, "300");
    await quote(estimator, T.cbETH, T.WETH, "0.1");
    await quote(estimator, T.cbBTC, T.WETH, "0.01");
    await quote(estimator, T.AERO,  T.WETH, "1000");

    console.log("\n── Token-to-token routes (no WETH leg) ───────────────────────");
    await quote(estimator, T.USDC, T.AERO,  "100");
    await quote(estimator, T.USDC, T.cbETH, "300");
    await quote(estimator, T.USDC, T.cbBTC, "1000");
    await quote(estimator, T.AERO, T.USDC,  "1000");
    await quote(estimator, T.DAI,  T.USDC,  "100");

    console.log("\n── Round-trip WETH → USDC → WETH at 0.1 ETH ──────────────────");
    const oneTenth = ethers.parseEther("0.1");
    try {
        const [, , usdcOut] = await retryCall(() =>
            estimator.getBestRateAllTiers(T.WETH.addr, T.USDC.addr, oneTenth)
        );
        await sleep(250);
        const [, , wethBack] = await retryCall(() =>
            estimator.getBestRateAllTiers(T.USDC.addr, T.WETH.addr, usdcOut)
        );
        const loss = ((Number(oneTenth - wethBack) / Number(oneTenth)) * 100).toFixed(3);
        console.log(`  0.1 WETH → ${ethers.formatUnits(usdcOut, 6)} USDC → ${ethers.formatEther(wethBack)} WETH`);
        console.log(`  Round-trip loss: ${loss}%`);
    } catch (e: any) {
        console.log(`  ✗ ${e.shortMessage || e.message}`);
    }

    console.log();
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
