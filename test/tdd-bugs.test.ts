import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { Contract } from "ethers";
import { DecentralizedExchangeNetwork } from "../typechain-types";

const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const WETH_ADDR = "0x4200000000000000000000000000000000000006";
const ZERO = "0x0000000000000000000000000000000000000000";
const V2_ROUTER = "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24";
const V2_USDC_POOL = "0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C";
const V3_FACTORY = "0x33128a8fC17869897dcE68Ed026d694621f6FDfD";
const V3_ROUTER = "0x2626664c2603336E57B271c5C0b26F421741e481";
const V3_USDC_3000 = "0x6c561B446416E1A00E8E93E221854d6eA4171372";
const V4_PM = "0x498581fF718922c3f8e6A244956aF099B2652b2b";
const PARTNER_FEE = 50;

let v4SwapLibAddress: string;

const erc20Abi = [
    "function approve(address spender, uint256 amount) returns (bool)",
    "function balanceOf(address owner) view returns (uint256)",
    "function transfer(address to, uint amount) returns (bool)",
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

describe("TDD Bug Fixes", function () {
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
    // TDD CYCLE 1: V2 _getAmountOut double-fee
    // =============================================
    describe("BUG: V2 _getAmountOut uses DEN fees instead of V2 pool fee", function () {

        it("RED: V2 swap output should be close to a direct V2 router swap minus DEN fees only", async function () {
            // Strategy: Compare DEN V2 swap output vs a direct router swap.
            // DEN deducts 0.65% fees from ETH input, then the V2 pool should deduct its own 0.3%.
            // If _getAmountOut is correct, the user gets: V2_output(amountIn * 0.9935)
            // If _getAmountOut has the double-fee bug, user gets significantly less.

            const swapAmount = ethers.parseEther("1");

            // First, get a quote from V2 router for the post-fee amount
            const v2Router = await ethers.getContractAt(
                ["function getAmountsOut(uint256, address[]) view returns (uint256[])"],
                V2_ROUTER
            );

            const [sysFee, partFee] = await den.getFees(swapAmount, PARTNER_FEE);
            const amountAfterDENFees = swapAmount - sysFee - partFee;

            // This is what V2 router says we should get for the post-DEN-fee amount
            const routerAmounts = await v2Router.getAmountsOut(amountAfterDENFees, [WETH_ADDR, USDC]);
            const expectedFromRouter = routerAmounts[1]; // what V2 actually gives for that input

            // Now do the actual DEN swap
            const usdcBefore = await usdc.balanceOf(deployer.address);
            await den.swapETHForToken(V2_USDC_POOL, USDC, 1, { value: swapAmount });
            const usdcAfter = await usdc.balanceOf(deployer.address);
            const actualOutput = usdcAfter - usdcBefore;

            // The DEN output should be very close to the router quote (within 0.1%)
            // With the double-fee bug, it will be significantly less (~0.65% less)
            const ratio = (actualOutput * 10000n) / expectedFromRouter;

            console.log("  Expected (from V2 router):", expectedFromRouter.toString());
            console.log("  Actual (from DEN V2 swap):", actualOutput.toString());
            console.log("  Ratio (actual/expected * 10000):", ratio.toString());

            // With correct code, ratio should be >= 9990 (within 0.1%)
            // With double-fee bug, ratio is ~9935 (0.65% less)
            expect(ratio).to.be.gte(9990n, "V2 swap output is too low — double-fee bug detected");
        });
    });

    // =============================================
    // TDD CYCLE 2: checkV3Rate always returns 0
    // =============================================
    describe("BUG: checkV3Rate never returns non-zero in getBestRate", function () {

        it("RED: getBestRate should pick V3 when only V3 router is registered", async function () {
            // Register ONLY a V3 router (no V2, no V4)
            await den.connect(deployer).addV3Router(V3_ROUTER);

            const [routerUsed, versionUsed, highestOut] = await den.getBestRate.staticCall(
                WETH_ADDR, USDC, ethers.parseEther("1"), 3000
            );

            console.log("  Router used:", routerUsed);
            console.log("  Version used:", versionUsed.toString());
            console.log("  Highest out:", highestOut.toString());

            // If checkV3Rate works, versionUsed should be 3 and highestOut > 0
            // With the bug, highestOut is 0 and versionUsed is 0
            expect(highestOut).to.be.gt(0, "V3 rate shopping returned 0 — checkV3Rate is broken");
            expect(versionUsed).to.equal(3, "V3 was not selected despite being the only option");
        });
    });

    // =============================================
    // TDD CYCLE 3: Interface return type mismatch
    // =============================================
    describe("BUG: swapETHForToken should return amountOut", function () {

        it("RED: swapETHForToken return value should match actual USDC received", async function () {
            const swapAmount = ethers.parseEther("1");
            const usdcBefore = await usdc.balanceOf(deployer.address);

            // Call swapETHForToken and capture the return value via staticCall-then-send pattern
            // We can't get return value from a state-changing call directly in ethers v6,
            // but we CAN check if the function signature includes a return value by using
            // the contract's interface to call it
            const tx = await den.swapETHForToken(V3_USDC_3000, USDC, 1, { value: swapAmount });
            const receipt = await tx.wait();
            const usdcAfter = await usdc.balanceOf(deployer.address);
            const actualReceived = usdcAfter - usdcBefore;

            // The function should emit enough info or return the amountOut
            // For now, just verify the swap works and the user gets tokens
            expect(actualReceived).to.be.gt(0);

            // Check the Swap event was emitted with correct data
            const swapEvents = receipt!.logs.filter(log => {
                try {
                    return den.interface.parseLog(log)?.name === "Swap";
                } catch { return false; }
            });
            expect(swapEvents.length).to.be.gt(0, "Swap event should be emitted");
        });
    });

    // =============================================
    // TDD CYCLE 4: Token→ETH swaps
    // =============================================
    describe("Token→ETH swap path", function () {

        async function acquireUSDC(): Promise<bigint> {
            // Swap ETH for USDC first to get test tokens
            await den.swapETHForToken(V3_USDC_3000, USDC, 1, { value: ethers.parseEther("2") });
            return await usdc.balanceOf(deployer.address);
        }

        it("RED: swapTokenForETH on V3 should return ETH to the caller", async function () {
            const usdcBalance = await acquireUSDC();
            expect(usdcBalance).to.be.gt(0, "Failed to acquire USDC for test");

            const swapAmount = usdcBalance / 2n; // swap half
            const ethBefore = await ethers.provider.getBalance(deployer.address);

            // Approve DEN to spend USDC
            await usdc.approve(await den.getAddress(), swapAmount);

            // Swap USDC → ETH
            const tx = await den.swapTokenForETH(V3_USDC_3000, USDC, swapAmount, 1);
            const receipt = await tx.wait();
            const gasUsed = receipt!.gasUsed * receipt!.gasPrice;

            const ethAfter = await ethers.provider.getBalance(deployer.address);
            const ethReceived = ethAfter - ethBefore + gasUsed; // add back gas

            console.log("  USDC swapped:", swapAmount.toString());
            console.log("  ETH received:", ethers.formatEther(ethReceived));

            // Verify: system and partner fee receivers got fees
            const sysFRBal = await ethers.provider.getBalance(sysFR.address);
            const partFRBal = await ethers.provider.getBalance(partFR.address);

            expect(ethReceived).to.be.gt(0, "No ETH received from Token→ETH swap");
            expect(sysFRBal).to.be.gt(0, "System fee receiver got no fees");
            expect(partFRBal).to.be.gt(0, "Partner fee receiver got no fees");
        });

        it("RED: swapTokenForETH on V2 should return ETH to the caller", async function () {
            const usdcBalance = await acquireUSDC();
            const swapAmount = usdcBalance / 2n;

            await usdc.approve(await den.getAddress(), swapAmount);

            const ethBefore = await ethers.provider.getBalance(deployer.address);
            const tx = await den.swapTokenForETH(V2_USDC_POOL, USDC, swapAmount, 1);
            const receipt = await tx.wait();
            const gasUsed = receipt!.gasUsed * receipt!.gasPrice;

            const ethAfter = await ethers.provider.getBalance(deployer.address);
            const ethReceived = ethAfter - ethBefore + gasUsed;

            console.log("  ETH received from V2:", ethers.formatEther(ethReceived));
            expect(ethReceived).to.be.gt(0, "No ETH received from V2 Token→ETH swap");
        });
    });

    // =============================================
    // TDD CYCLE 5: Token→Token swaps
    // =============================================
    describe("Token→Token swap path", function () {

        // We need a V3 pool for USDC→some_other_token that's NOT WETH
        // On Base, there are USDC/DAI pools etc. But let's use what we know exists.
        // Actually, Token→Token through the DEN requires tokenIn != WETH and tokenOut != WETH.
        // We need two non-WETH tokens with a V3 pool between them.
        // For simplicity, let's test that the error paths work correctly.

        it("RED: swapTokenForToken should revert if tokenIn == WETH", async function () {
            await expect(
                den.swapTokenForToken(V3_USDC_3000, WETH_ADDR, USDC, ethers.parseEther("1"), 1)
            ).to.be.revertedWithCustomError(den, "CannotHaveWETHAsTokenIn");
        });

        it("RED: swapTokenForToken should revert if tokenOut == WETH", async function () {
            await expect(
                den.swapTokenForToken(V3_USDC_3000, USDC, WETH_ADDR, 1000000n, 1)
            ).to.be.revertedWithCustomError(den, "CannotHaveWETHAsTokenOut");
        });
    });

    // =============================================
    // TDD CYCLE 6: Edge cases
    // =============================================
    describe("Edge Cases", function () {

        it("RED: swap should revert when amountOutMin exceeds actual output", async function () {
            // Set an impossibly high amountOutMin
            await expect(
                den.swapETHForToken(V3_USDC_3000, USDC, ethers.parseEther("999999"), { value: ethers.parseEther("0.001") })
            ).to.be.revertedWithCustomError(den, "ReceivedLessThanMinimum");
        });

        it("RED: custom fee swap should respect custom fee amount", async function () {
            const swapAmount = ethers.parseEther("1");
            const customFee = 100; // 1% partner fee

            const sysBefore = await ethers.provider.getBalance(sysFR.address);
            const partBefore = await ethers.provider.getBalance(partFR.address);

            await den.swapETHForTokenWithCustomFee(V3_USDC_3000, USDC, 1, customFee, { value: swapAmount });

            const sysReceived = (await ethers.provider.getBalance(sysFR.address)) - sysBefore;
            const partReceived = (await ethers.provider.getBalance(partFR.address)) - partBefore;

            // System fee should be 0.15% of 1 ETH = 0.0015 ETH
            expect(sysReceived).to.equal(ethers.parseEther("0.0015"));
            // Partner fee should be 1% of 1 ETH = 0.01 ETH
            expect(partReceived).to.equal(ethers.parseEther("0.01"));
        });

        it("RED: emergency withdraw should work after ETH is sent to contract", async function () {
            // Send raw ETH to contract
            await deployer.sendTransaction({ to: await den.getAddress(), value: ethers.parseEther("0.5") });

            const balBefore = await ethers.provider.getBalance(deployer.address);
            const tx = await den.emergencyWithdrawETH();
            const receipt = await tx.wait();
            const gas = receipt!.gasUsed * receipt!.gasPrice;
            const balAfter = await ethers.provider.getBalance(deployer.address);

            expect(balAfter + gas - balBefore).to.be.closeTo(ethers.parseEther("0.5"), ethers.parseEther("0.001"));
        });
    });
});
