import { ethers } from "hardhat";

/**
 * Registers V4 pools with the DEN contract.
 *
 * Usage:
 *   DEN_ADDRESS=0x... npx hardhat run scripts/add-v4-pool.ts --network base
 *
 * Edit the POOLS array below to add your V4 pool keys.
 * currency0 must be numerically less than currency1.
 * Use address(0) for native ETH.
 */

const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

// Add your V4 pool keys here
const POOLS = [
    {
        currency0: "0x0000000000000000000000000000000000000000", // native ETH
        currency1: USDC,
        fee: 500,
        tickSpacing: 10,
        hooks: "0x0000000000000000000000000000000000000000",
    },
    // Add more pools as needed:
    // { currency0: "0x...", currency1: "0x...", fee: 3000, tickSpacing: 60, hooks: "0x000...000" },
];

async function main() {
    const denAddress = process.env.DEN_ADDRESS;
    if (!denAddress) {
        throw new Error("Set DEN_ADDRESS env var to the deployed DEN contract address");
    }

    const [deployer] = await ethers.getSigners();
    const den = await ethers.getContractAt("DecentralizedExchangeNetwork", denAddress, deployer);

    console.log(`\nAdding ${POOLS.length} V4 pool(s) to DEN at ${denAddress}\n`);

    for (let i = 0; i < POOLS.length; i++) {
        const pool = POOLS[i];
        const poolId = await den.getV4PoolId(pool);
        const alreadyRegistered = await den.isV4PoolSupported(poolId);

        if (alreadyRegistered) {
            console.log(`  [${i + 1}/${POOLS.length}] Pool ${poolId.slice(0, 18)}... already registered, skipping`);
            continue;
        }

        console.log(`  [${i + 1}/${POOLS.length}] Adding pool ${poolId.slice(0, 18)}...`);
        console.log(`    currency0: ${pool.currency0}`);
        console.log(`    currency1: ${pool.currency1}`);
        console.log(`    fee: ${pool.fee}, tickSpacing: ${pool.tickSpacing}`);
        await (await den.addV4Pool(pool)).wait();
        console.log(`    Done.`);
    }

    const count = await den.getSupportedV4PoolCount();
    console.log(`\n${count} V4 pool(s) now registered.\n`);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
