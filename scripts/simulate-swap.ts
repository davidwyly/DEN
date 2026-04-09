import { ethers, network } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Simulates swaps through DENHelper against a Base mainnet fork.
 *
 * Demonstrates the two patterns for app developers:
 *   1. ETH → Token : direct staticCall (no approvals / state setup needed).
 *   2. Token → X   : state-override pattern — fund the user's token balance via
 *                    hardhat_setStorageAt, then impersonate them to approve the
 *                    Helper and execute a read-only simulation of the swap.
 *
 *     Run: npx hardhat run scripts/simulate-swap.ts --network hardhat
 *
 * Uses the pre-configured fork in hardhat.config.ts and deploys fresh contracts
 * on top of it — this avoids the hardfork-history issue with resetting to latest,
 * and still exercises the full real-pool routing logic because the fork has all
 * live Uniswap V2/V3/V4 state.
 */

// Base Uniswap addresses present on the fork
const WETH  = "0x4200000000000000000000000000000000000006";
const USDC  = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const AERO  = "0x940181a94A35A4569E4529A3CDfB74e38FD98631";
const CBETH = "0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22";
const ZERO  = "0x0000000000000000000000000000000000000000";

const V2_ROUTER = "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24";
const V3_ROUTER = "0x2626664c2603336E57B271c5C0b26F421741e481";
const V4_PM     = "0x498581fF718922c3f8e6A244956aF099B2652b2b";
const V4_ETH_USDC = {
    currency0: ZERO,
    currency1: USDC,
    fee: 500,
    tickSpacing: 10,
    hooks: ZERO,
};

const helperAbi = [
    "function swapETHForBestToken(address tokenOut, uint256 amountOutMin, uint256 deadline) payable returns (uint256)",
    "function swapTokenForBestETH(address tokenIn, uint256 amountIn, uint256 amountOutMin, uint256 deadline) returns (uint256)",
    "function swapTokenForBestToken(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 deadline) returns (uint256)",
];

const estimatorAbi = [
    "function getBestRateAllTiers(address tokenIn, address tokenOut, uint256 amountIn) view returns (address routerUsed, uint8 versionUsed, uint256 highestOut, uint256 v4PoolIndex, uint24 bestFeeTier)",
];

const erc20Abi = [
    "function balanceOf(address) view returns (uint256)",
    "function approve(address,uint256) returns (bool)",
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
];

// ============================================================
//  STATE-OVERRIDE HELPERS
// ============================================================

/**
 * Finds the mapping slot that stores balances[address] for an ERC20 on the
 * current fork by probing candidate slots and verifying via balanceOf().
 *
 * Works for tokens that use a standard `mapping(address => uint256) _balances`
 * — covers OpenZeppelin, Circle FiatToken, most proxies.
 */
async function findBalanceSlot(tokenAddr: string, holder: string): Promise<number> {
    const token = await ethers.getContractAt(erc20Abi, tokenAddr);
    const testValue = 1337n;

    for (let slot = 0; slot < 25; slot++) {
        const storageKey = ethers.keccak256(
            ethers.AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [holder, slot])
        );
        // Snapshot original
        const original = await ethers.provider.getStorage(tokenAddr, storageKey);

        // Overwrite
        await network.provider.send("hardhat_setStorageAt", [
            tokenAddr,
            storageKey,
            ethers.toBeHex(testValue, 32),
        ]);

        // Verify
        const bal: bigint = await token.balanceOf(holder);

        // Restore
        await network.provider.send("hardhat_setStorageAt", [
            tokenAddr,
            storageKey,
            original,
        ]);

        if (bal === testValue) return slot;
    }
    throw new Error(`Could not locate balance mapping slot for ${tokenAddr}`);
}

/**
 * Gives `holder` exactly `amount` of `tokenAddr` by overwriting their storage slot.
 */
async function giveTokens(
    tokenAddr: string,
    holder: string,
    amount: bigint,
    slot: number
): Promise<void> {
    const storageKey = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [holder, slot])
    );
    await network.provider.send("hardhat_setStorageAt", [
        tokenAddr,
        storageKey,
        ethers.toBeHex(amount, 32),
    ]);
}

// ============================================================
//  DEMO HELPERS
// ============================================================

function fmt(value: bigint, dec: number): string {
    return Number(ethers.formatUnits(value, dec)).toLocaleString(undefined, {
        minimumFractionDigits: 2,
        maximumFractionDigits: 6,
    });
}

function deltaLine(spot: bigint, actual: bigint): string {
    if (actual === 0n) return "  (actual = 0, cannot compute delta)";
    const diff = spot > actual ? spot - actual : actual - spot;
    const sign = spot > actual ? "+" : "-";
    const pct = Number((diff * 1_000_000n) / actual) / 10_000;
    return `  Spot vs actual delta: ${sign}${pct.toFixed(4)}%`;
}

// ============================================================
//  DEMO 1: ETH → Token (no approval required)
// ============================================================

async function demoEthToToken(
    user: HardhatEthersSigner,
    helper: any,
    estimator: any,
    tokenOut: string,
    symbol: string,
    decimals: number,
    amountIn: bigint,
    deadline: number
) {
    console.log(`\n══════ Demo 1: ${ethers.formatEther(amountIn)} ETH → ${symbol} ══════`);
    console.log(`  Pattern: direct staticCall (no token approvals needed)\n`);

    // Fast spot quote
    const [router, version, spotOut, , tier] = await estimator.getBestRateAllTiers(
        WETH, tokenOut, amountIn
    );
    console.log(`  Estimator spot:   ${fmt(spotOut, decimals).padStart(16)} ${symbol}   [V${version} fee=${tier}]`);

    // Exact simulation
    const actualOut = await helper.swapETHForBestToken.staticCall(
        tokenOut, 1n, deadline,
        { value: amountIn, from: user.address }
    );
    console.log(`  Static-call out:  ${fmt(actualOut, decimals).padStart(16)} ${symbol}`);
    console.log(deltaLine(spotOut, actualOut));
    console.log(`  (Actual is what the user would receive after real pool slippage.)`);
}

// ============================================================
//  DEMO 2: Token → ETH (requires approval via impersonation + setStorage)
// ============================================================

async function demoTokenToEth(
    user: HardhatEthersSigner,
    helperAddr: string,
    helper: any,
    estimator: any,
    tokenAddr: string,
    symbol: string,
    decimals: number,
    amountIn: bigint,
    deadline: number
) {
    console.log(`\n══════ Demo 2: ${fmt(amountIn, decimals)} ${symbol} → ETH ══════`);
    console.log(`  Pattern: setStorageAt for balance + approve via impersonation\n`);

    const token = await ethers.getContractAt(erc20Abi, tokenAddr);

    // Discover the balance storage slot and give the user tokens
    const slot = await findBalanceSlot(tokenAddr, user.address);
    console.log(`  Discovered balance slot: ${slot}`);
    await giveTokens(tokenAddr, user.address, amountIn, slot);
    const bal: bigint = await token.balanceOf(user.address);
    console.log(`  Funded user with:        ${fmt(bal, decimals)} ${symbol}`);

    // Approve Helper — this is a real state tx in the fork, not an override
    await (await token.connect(user).approve(helperAddr, amountIn)).wait();

    // Quote
    const [, version, spotOut, , tier] = await estimator.getBestRateAllTiers(
        tokenAddr, WETH, amountIn
    );
    console.log(`  Estimator spot:   ${fmt(spotOut, 18).padStart(16)} ETH    [V${version} fee=${tier}]`);

    // Simulate
    const actualOut = await helper.connect(user).swapTokenForBestETH.staticCall(
        tokenAddr, amountIn, 1n, deadline
    );
    console.log(`  Static-call out:  ${fmt(actualOut, 18).padStart(16)} ETH`);
    console.log(deltaLine(spotOut, actualOut));
}

// ============================================================
//  DEMO 3: Token → Token
// ============================================================

async function demoTokenToToken(
    user: HardhatEthersSigner,
    helperAddr: string,
    helper: any,
    estimator: any,
    tokenInAddr: string,
    tokenInSymbol: string,
    tokenInDec: number,
    tokenOutAddr: string,
    tokenOutSymbol: string,
    tokenOutDec: number,
    amountIn: bigint,
    deadline: number
) {
    console.log(`\n══════ Demo 3: ${fmt(amountIn, tokenInDec)} ${tokenInSymbol} → ${tokenOutSymbol} ══════`);
    console.log(`  Pattern: same as Demo 2, for token → token route\n`);

    const tokenIn = await ethers.getContractAt(erc20Abi, tokenInAddr);

    const slot = await findBalanceSlot(tokenInAddr, user.address);
    await giveTokens(tokenInAddr, user.address, amountIn, slot);
    await (await tokenIn.connect(user).approve(helperAddr, amountIn)).wait();

    const [, version, spotOut, , tier] = await estimator.getBestRateAllTiers(
        tokenInAddr, tokenOutAddr, amountIn
    );
    console.log(`  Estimator spot:   ${fmt(spotOut, tokenOutDec).padStart(16)} ${tokenOutSymbol}  [V${version} fee=${tier}]`);

    const actualOut = await helper.connect(user).swapTokenForBestToken.staticCall(
        tokenInAddr, tokenOutAddr, amountIn, 1n, deadline
    );
    console.log(`  Static-call out:  ${fmt(actualOut, tokenOutDec).padStart(16)} ${tokenOutSymbol}`);
    console.log(deltaLine(spotOut, actualOut));
}

// ============================================================
//  MAIN
// ============================================================

async function main() {
    const signers = await ethers.getSigners();
    const deployer = signers[0];
    const user = signers[1];     // fresh signer we'll fund and impersonate as the "app user"
    const sysFR = signers[2];
    const partFR = signers[3];

    // Clear any fork contract code at fee receiver addresses (safety)
    await ethers.provider.send("hardhat_setCode", [sysFR.address, "0x"]);
    await ethers.provider.send("hardhat_setCode", [partFR.address, "0x"]);

    console.log("Deploying fresh DEN/Helper/Estimator on the Base fork...");

    const libF = await ethers.getContractFactory("V4SwapLib");
    const lib = await libF.connect(deployer).deploy();
    await lib.waitForDeployment();
    const libAddr = await lib.getAddress();

    const denF = await ethers.getContractFactory("DecentralizedExchangeNetwork", {
        libraries: { V4SwapLib: libAddr },
    });
    const den = await denF.connect(deployer).deploy(WETH, deployer.address, sysFR.address, partFR.address, 50);
    await den.waitForDeployment();
    const denAddr = await den.getAddress();

    const estF = await ethers.getContractFactory("DENEstimator", {
        libraries: { V4SwapLib: libAddr },
    });
    const est = await estF.connect(deployer).deploy(denAddr, WETH, V4_PM);
    await est.waitForDeployment();
    const estAddr = await est.getAddress();

    const helperF = await ethers.getContractFactory("DENHelper");
    const helperContract = await helperF.connect(deployer).deploy(denAddr, estAddr);
    await helperContract.waitForDeployment();
    const helperAddr = await helperContract.getAddress();

    // Register routers and V4 pool so the Helper can find routes
    await (await den.connect(deployer).addV2Router(V2_ROUTER)).wait();
    await (await den.connect(deployer).addV3Router(V3_ROUTER)).wait();
    await (await den.connect(deployer).setV4PoolManager(V4_PM)).wait();
    await (await den.connect(deployer).addV4Pool(V4_ETH_USDC)).wait();

    console.log(`  DEN:       ${denAddr}`);
    console.log(`  Estimator: ${estAddr}`);
    console.log(`  Helper:    ${helperAddr}`);
    console.log(`  User:      ${user.address}\n`);

    // Attach with the Helper ABI we'll use throughout the demos
    const helper    = new ethers.Contract(helperAddr, helperAbi, user);
    const estimator = new ethers.Contract(estAddr, estimatorAbi, user);

    const latest = await ethers.provider.getBlock("latest");
    const deadline = latest!.timestamp + 3600;

    await demoEthToToken(
        user, helper, estimator, USDC, "USDC", 6, ethers.parseEther("1"), deadline
    );

    await demoTokenToEth(
        user, helperAddr, helper, estimator, USDC, "USDC", 6,
        ethers.parseUnits("3000", 6), deadline
    );

    await demoTokenToToken(
        user, helperAddr, helper, estimator, USDC, "USDC", 6, CBETH, "cbETH", 18,
        ethers.parseUnits("1000", 6), deadline
    );

    console.log("\n────────────────────────────────────────────────────────");
    console.log("Takeaway:");
    console.log("  • ETH → Token    : use staticCall directly against live RPC");
    console.log("  • Token → X      : use eth_call + stateOverride (paid RPC)");
    console.log("                     OR fork + setStorage + impersonate (dev/test)");
    console.log("  • Always compare spot vs actual before signing");
    console.log("────────────────────────────────────────────────────────\n");
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
