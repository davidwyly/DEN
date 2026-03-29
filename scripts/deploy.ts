import { ethers } from "hardhat";

// Base mainnet addresses
const BASE = {
    WETH: "0x4200000000000000000000000000000000000006",
    V2_ROUTER: "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24",
    V3_ROUTER: "0x2626664c2603336E57B271c5C0b26F421741e481",
    V4_POOL_MANAGER: "0x498581fF718922c3f8e6A244956aF099B2652b2b",
};

async function main() {
    const [deployer] = await ethers.getSigners();
    const network = await ethers.provider.getNetwork();
    console.log(`\nDeploying DEN to chain ${network.chainId} with ${deployer.address}`);
    console.log(`Balance: ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} ETH\n`);

    // ── Configuration ──────────────────────────────────────────
    const partner = process.env.PARTNER_ADDRESS;
    const systemFeeReceiver = process.env.SYSTEM_FEE_RECEIVER;
    const partnerFeeReceiver = process.env.PARTNER_FEE_RECEIVER;
    const partnerFeeNumerator = Number(process.env.PARTNER_FEE_NUMERATOR || "50");

    if (!partner || !systemFeeReceiver || !partnerFeeReceiver) {
        throw new Error(
            "Missing env vars. Set PARTNER_ADDRESS, SYSTEM_FEE_RECEIVER, PARTNER_FEE_RECEIVER in .env"
        );
    }

    console.log("Configuration:");
    console.log(`  Partner:              ${partner}`);
    console.log(`  System fee receiver:  ${systemFeeReceiver}`);
    console.log(`  Partner fee receiver: ${partnerFeeReceiver}`);
    console.log(`  Partner fee:          ${partnerFeeNumerator / 100}% (${partnerFeeNumerator}/10000)`);
    console.log();

    // ── Step 1: Deploy V4SwapLib ────────────────────────────────
    console.log("Step 1/5: Deploying V4SwapLib...");
    const v4SwapLib = await (await ethers.getContractFactory("V4SwapLib")).deploy();
    await v4SwapLib.waitForDeployment();
    const libAddr = await v4SwapLib.getAddress();
    console.log(`  V4SwapLib: ${libAddr}`);

    // ── Step 2: Deploy DecentralizedExchangeNetwork ─────────────
    console.log("Step 2/5: Deploying DecentralizedExchangeNetwork...");
    const denFactory = await ethers.getContractFactory("DecentralizedExchangeNetwork", {
        libraries: { V4SwapLib: libAddr },
    });
    const den = await denFactory.deploy(
        BASE.WETH,
        partner,
        systemFeeReceiver,
        partnerFeeReceiver,
        partnerFeeNumerator
    );
    await den.waitForDeployment();
    const denAddr = await den.getAddress();
    console.log(`  DEN: ${denAddr}`);

    // ── Step 3: Deploy DENEstimator ─────────────────────────────
    console.log("Step 3/5: Deploying DENEstimator...");
    const estimatorFactory = await ethers.getContractFactory("DENEstimator", {
        libraries: { V4SwapLib: libAddr },
    });
    const estimator = await estimatorFactory.deploy(denAddr, BASE.WETH, BASE.V4_POOL_MANAGER);
    await estimator.waitForDeployment();
    const estimatorAddr = await estimator.getAddress();
    console.log(`  DENEstimator: ${estimatorAddr}`);

    // ── Step 4: Deploy DENHelper ────────────────────────────────
    console.log("Step 4/5: Deploying DENHelper...");
    const helper = await (await ethers.getContractFactory("DENHelper")).deploy(denAddr, estimatorAddr);
    await helper.waitForDeployment();
    const helperAddr = await helper.getAddress();
    console.log(`  DENHelper: ${helperAddr}`);

    // ── Step 5: Configure DEN ───────────────────────────────────
    console.log("Step 5/5: Configuring DEN...");

    console.log("  Adding V2 router...");
    await (await den.addV2Router(BASE.V2_ROUTER)).wait();

    console.log("  Adding V3 router...");
    await (await den.addV3Router(BASE.V3_ROUTER)).wait();

    console.log("  Setting V4 PoolManager...");
    await (await den.setV4PoolManager(BASE.V4_POOL_MANAGER)).wait();

    // ── Summary ─────────────────────────────────────────────────
    console.log("\n══════════════════════════════════════════════════");
    console.log("  Deployment complete!");
    console.log("══════════════════════════════════════════════════");
    console.log(`  V4SwapLib:   ${libAddr}`);
    console.log(`  DEN:         ${denAddr}`);
    console.log(`  Estimator:   ${estimatorAddr}`);
    console.log(`  Helper:      ${helperAddr}`);
    console.log("══════════════════════════════════════════════════");
    console.log("\nNext steps:");
    console.log("  1. Register V4 pools:  npx hardhat run scripts/add-v4-pool.ts --network base");
    console.log("  2. Verify contracts:   npx hardhat run scripts/verify.ts --network base");
    console.log();
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
