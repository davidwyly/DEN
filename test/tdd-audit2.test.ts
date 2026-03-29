import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { Contract } from "ethers";
import { DecentralizedExchangeNetwork, DENEstimator } from "../typechain-types";

const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const WETH_ADDR = "0x4200000000000000000000000000000000000006";
const ZERO = "0x0000000000000000000000000000000000000000";
const V2_ROUTER = "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24";
const V2_USDC_POOL = "0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C";
const V3_USDC_3000 = "0x6c561B446416E1A00E8E93E221854d6eA4171372";
const V4_PM = "0x498581fF718922c3f8e6A244956aF099B2652b2b";
const PARTNER_FEE = 50;

let v4SwapLibAddress: string;

async function futureDeadline(): Promise<number> {
    return (await ethers.provider.getBlock("latest"))!.timestamp + 3600;
}

const erc20Abi = [
    "function approve(address spender, uint256 amount) returns (bool)",
    "function balanceOf(address owner) view returns (uint256)",
];

async function deployDEN(
    deployer: HardhatEthersSigner,
    partner: HardhatEthersSigner,
    sysFR: HardhatEthersSigner,
    partFR: HardhatEthersSigner,
): Promise<DecentralizedExchangeNetwork> {
    if (!v4SwapLibAddress) {
        const libFactory = await ethers.getContractFactory("V4SwapLib");
        const lib = await libFactory.connect(deployer).deploy();
        await lib.waitForDeployment();
        v4SwapLibAddress = await lib.getAddress();
    }
    const f = await ethers.getContractFactory("DecentralizedExchangeNetwork", {
        libraries: { V4SwapLib: v4SwapLibAddress },
    });
    return (await f.connect(deployer).deploy(
        WETH_ADDR, partner, sysFR, partFR, PARTNER_FEE
    )) as DecentralizedExchangeNetwork;
}

describe("Audit Round 2 — TDD Fixes", function () {
    let den: DecentralizedExchangeNetwork;
    let usdc: Contract;
    let deployer: HardhatEthersSigner;
    let partner: HardhatEthersSigner;
    let sysFR: HardhatEthersSigner;
    let partFR: HardhatEthersSigner;
    let user: HardhatEthersSigner;

    beforeEach(async function () {
        [deployer, partner, sysFR, partFR, user] = await ethers.getSigners();
        await ethers.provider.send("hardhat_setCode", [sysFR.address, "0x"]);
        await ethers.provider.send("hardhat_setCode", [partFR.address, "0x"]);
        den = await deployDEN(deployer, partner, sysFR, partFR);
        usdc = await ethers.getContractAt(erc20Abi, USDC);
    });

    // =============================================
    // C-2: Custom fee allows zero partner fee
    // =============================================
    describe("C-2: Custom fee zero bypass", function () {

        it("RED: swapETHForTokenWithCustomFee with fee=0 should succeed (premium customer)", async function () {
            // Partner allows 0 fee for premium customers
            // Swap should succeed with only system fee deducted
            await expect(
                den.swapETHForTokenWithCustomFee(V3_USDC_3000, USDC, 1, 0, await futureDeadline(), { value: ethers.parseEther("1") })
            ).to.not.be.reverted;

            // System fee should still be collected, partner fee should be 0
            expect(await den.pendingSystemFeesETH()).to.equal(ethers.parseEther("0.0015"));
            expect(await den.pendingPartnerFeesETH()).to.equal(0);
        });

        it("RED: getFees with partnerFee=0 should return (systemFee, 0)", async function () {
            const [systemFee, partnerFee] = await den.getFees(ethers.parseEther("1"), 0);
            // System fee: 1 ETH * 15 / 10000 = 0.0015 ETH
            expect(systemFee).to.equal(ethers.parseEther("0.0015"));
            expect(partnerFee).to.equal(0);
        });
    });

    // =============================================
    // C-3: Fee receiver DOS
    // =============================================
    describe("C-3: Reverting fee receiver should not block swaps", function () {

        it("C-3 FIXED: reverting fee receiver does NOT block swaps (pull-based fees)", async function () {
            // Set partner fee receiver code to always-revert: PUSH0 PUSH0 REVERT
            await ethers.provider.send("hardhat_setCode", [partFR.address, "0x5f5ffd"]);

            // With pull-based fees, the swap succeeds and fees accumulate in the contract
            await expect(
                den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: ethers.parseEther("1") })
            ).to.not.be.reverted;

            // Verify fees accumulated in the contract
            expect(await den.pendingSystemFeesETH()).to.be.gt(0);
            expect(await den.pendingPartnerFeesETH()).to.be.gt(0);

            console.log("  C-3 FIXED: Pull-based fees allow swaps even with reverting fee receiver");
        });
    });

    // =============================================
    // M-4: estimateV2 missing V2 pool fee
    // =============================================
    describe("M-4: estimateV2 accuracy", function () {

        it("RED: V2 estimate should match actual V2 swap output within 1%", async function () {
            const estimatorFactory = await ethers.getContractFactory("DENEstimator", {
                libraries: { V4SwapLib: v4SwapLibAddress },
            });
            const estimator = await estimatorFactory.deploy(WETH_ADDR, V4_PM) as DENEstimator;
            await estimator.waitForDeployment();

            const swapAmount = ethers.parseEther("1");

            // Get estimate
            const estimate = await estimator.estimateAmountOut(
                V2_USDC_POOL, WETH_ADDR, swapAmount, PARTNER_FEE, 15, 10000
            );

            // Do actual swap and measure
            const usdcBefore = await usdc.balanceOf(deployer.address);
            await den.swapETHForToken(V2_USDC_POOL, USDC, 1, await futureDeadline(), { value: swapAmount });
            const usdcAfter = await usdc.balanceOf(deployer.address);
            const actualOutput = usdcAfter - usdcBefore;

            const ratio = (actualOutput * 10000n) / estimate;
            console.log("  V2 Estimate:", estimate.toString());
            console.log("  V2 Actual:  ", actualOutput.toString());
            console.log("  Ratio (actual/estimate * 10000):", ratio.toString());

            // The estimate should be within 0.15% of actual (tight bound)
            // Before fix: ratio was 9951 (0.5% off — missing V2 pool fee)
            // After fix: should be ~10000 (exact match)
            expect(ratio).to.be.gte(9985n, "V2 estimate too high vs actual — pool fee may be missing");
            expect(ratio).to.be.lte(10015n, "V2 estimate too low vs actual");
        });
    });

    // =============================================
    // L-5: V4 pool key ordering
    // =============================================
    describe("L-5: V4 pool key currency ordering", function () {

        it("RED: addV4Pool should reject pool key with currency0 > currency1", async function () {
            await den.connect(deployer).setV4PoolManager(V4_PM);

            // USDC address > ZERO address, so currency0=USDC, currency1=ZERO is wrong ordering
            const badKey = {
                currency0: USDC,          // higher address
                currency1: ZERO,          // lower address (should be currency0)
                fee: 500,
                tickSpacing: 10,
                hooks: ZERO,
            };

            await expect(
                den.connect(deployer).addV4Pool(badKey)
            ).to.be.revertedWithCustomError(den, "InvalidV4PoolKey");
        });
    });

    // =============================================
    // M-1: currentSwapPool initial sentinel
    // =============================================
    describe("M-1: currentSwapPool initialization", function () {

        it("Swaps should work on a freshly deployed contract without prior V3 activity", async function () {
            // This verifies that currentSwapPool=address(0) doesn't block swaps
            const usdcBefore = await usdc.balanceOf(deployer.address);
            await den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: ethers.parseEther("0.1") });
            expect(await usdc.balanceOf(deployer.address)).to.be.gt(usdcBefore);
        });
    });
});
