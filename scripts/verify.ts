import { run } from "hardhat";

/**
 * Verifies all deployed contracts on Basescan.
 *
 * Usage:
 *   Set the addresses below, then run:
 *   npx hardhat run scripts/verify.ts --network base
 *
 * Requires BASESCAN_API_KEY in .env
 */

// ── Fill in after deployment ────────────────────────────────────
const V4_SWAP_LIB = "0x1e4CA3d39d29BF4099F54cc2Cb49aF3183B50Ce1";
const DEN = "0x5E5B0846BA79046A8Cc8FA7A8529c4FdedA0F352";
const ESTIMATOR = "0xEe53856B87A73Ae3019A4B08B1AA99996488D7B5";
const HELPER = "0x1b99079A281bA462E99B085Ec0Cbf430C5e1E362";

// ── Must match what was passed to constructors ──────────────────
const BASE_WETH = "0x4200000000000000000000000000000000000006";
const V4_POOL_MANAGER = "0x498581fF718922c3f8e6A244956aF099B2652b2b";
const PARTNER = process.env.PARTNER_ADDRESS || "0x...";
const SYSTEM_FEE_RECEIVER = process.env.SYSTEM_FEE_RECEIVER || "0x...";
const PARTNER_FEE_RECEIVER = process.env.PARTNER_FEE_RECEIVER || "0x...";
const PARTNER_FEE_NUMERATOR = Number(process.env.PARTNER_FEE_NUMERATOR || "50");

async function verify(name: string, address: string, args: any[]) {
    console.log(`Verifying ${name} at ${address}...`);
    try {
        await run("verify:verify", { address, constructorArguments: args });
        console.log(`  ${name} verified.`);
    } catch (e: any) {
        if (e.message.includes("Already Verified")) {
            console.log(`  ${name} already verified.`);
        } else {
            console.error(`  ${name} verification failed:`, e.message);
        }
    }
}

async function main() {
    await verify("V4SwapLib", V4_SWAP_LIB, []);

    await verify("DecentralizedExchangeNetwork", DEN, [
        BASE_WETH,
        PARTNER,
        SYSTEM_FEE_RECEIVER,
        PARTNER_FEE_RECEIVER,
        PARTNER_FEE_NUMERATOR,
    ]);

    await verify("DENEstimator", ESTIMATOR, [DEN, BASE_WETH, V4_POOL_MANAGER]);

    await verify("DENHelper", HELPER, [DEN, ESTIMATOR]);

    console.log("\nAll verifications complete.");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
