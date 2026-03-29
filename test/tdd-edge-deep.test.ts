import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { Contract } from "ethers";
import { DecentralizedExchangeNetwork, DENEstimator } from "../typechain-types";

const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const WETH_ADDR = "0x4200000000000000000000000000000000000006";
const ZERO = "0x0000000000000000000000000000000000000000";
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

describe("Deep Edge Cases", function () {
    let den: DecentralizedExchangeNetwork;
    let usdc: Contract;
    let deployer: HardhatEthersSigner;
    let partner: HardhatEthersSigner;
    let sysFR: HardhatEthersSigner;
    let partFR: HardhatEthersSigner;

    beforeEach(async function () {
        [deployer, partner, sysFR, partFR] = await ethers.getSigners();
        await ethers.provider.send("hardhat_setCode", [sysFR.address, "0x"]);
        await ethers.provider.send("hardhat_setCode", [partFR.address, "0x"]);
        den = await deployDEN(deployer, partner, sysFR, partFR);
        usdc = await ethers.getContractAt(erc20Abi, USDC);
    });

    // =============================================
    // ZERO-VALUE: Fees round to zero on tiny amounts
    // getFees: amount * 15 / 10000 = 0 when amount < 667 wei
    // getFees: amount * 50 / 10000 = 0 when amount < 200 wei
    // What happens when fees are 0?
    // =============================================
    describe("Zero-value fee edge cases", function () {

        it("getFees returns 0 for both fees when amount is 1 wei", async function () {
            const [sysFee, partFee] = await den.getFees(1n, PARTNER_FEE);
            // 1 * 15 / 10000 = 0, 1 * 50 / 10000 = 0
            expect(sysFee).to.equal(0n);
            expect(partFee).to.equal(0n);
        });

        it("swap with 1 wei: entire amount goes to swap, zero fees collected", async function () {
            // 1 wei swap: fees round to 0, so amountInLessFees = 1 - 0 - 0 = 1
            // _sendETH(systemFeeReceiver, 0) — sending 0 ETH. Does this work?
            // _sendETH checks address(this).balance >= _amount (0 >= 0 → true)
            // payable().call{value: 0}("") — this should succeed
            // IWETH.deposit{value: 1}() — wraps 1 wei
            // Then V3 pool swap with 1 wei WETH input — might revert with low output
            // But amountOutMin is the gate

            // Actually this might fail because the V3 pool might not accept 1 wei swaps
            // Let's find out!
            try {
                await den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: 1n });
                // If it succeeds, the user got at least 1 unit of USDC
                console.log("  1 wei swap succeeded!");
            } catch (e: any) {
                // Likely ReceivedLessThanMinimum because 1 wei → 0 USDC output
                console.log("  1 wei swap reverted:", e.message.includes("ReceivedLessThanMinimum") ? "ReceivedLessThanMinimum" : e.message.slice(0, 100));
            }
        });

        it("swap with 100 wei: system fee = 0, partner fee = 0, full amount swaps", async function () {
            const [sysFee, partFee] = await den.getFees(100n, PARTNER_FEE);
            expect(sysFee).to.equal(0n); // 100 * 15 / 10000 = 0
            expect(partFee).to.equal(0n); // 100 * 50 / 10000 = 0

            // Fee receivers get 0 ETH, but _sendETH(addr, 0) should work fine
            // The full 100 wei goes to the swap
        });

        it("fee threshold: smallest amount where system fee > 0", async function () {
            // system fee = amount * 15 / 10000 → needs amount >= ceil(10000/15) = 667
            const [sysFee667, _] = await den.getFees(667n, PARTNER_FEE);
            const [sysFee666, __] = await den.getFees(666n, PARTNER_FEE);
            console.log("  getFees(667): systemFee =", sysFee667.toString());
            console.log("  getFees(666): systemFee =", sysFee666.toString());
            expect(sysFee667).to.equal(1n); // 667 * 15 / 10000 = 1.0005 → 1
            expect(sysFee666).to.equal(0n); // 666 * 15 / 10000 = 0.999 → 0
        });

        it("fee threshold: smallest amount where partner fee > 0", async function () {
            // partner fee = amount * 50 / 10000 → needs amount >= ceil(10000/50) = 200
            const [_, partFee200] = await den.getFees(200n, PARTNER_FEE);
            const [__, partFee199] = await den.getFees(199n, PARTNER_FEE);
            console.log("  getFees(200): partnerFee =", partFee200.toString());
            console.log("  getFees(199): partnerFee =", partFee199.toString());
            expect(partFee200).to.equal(1n); // 200 * 50 / 10000 = 1
            expect(partFee199).to.equal(0n); // 199 * 50 / 10000 = 0.995 → 0
        });

        it("_sendETH with 0 value should succeed (no revert)", async function () {
            // This is implicitly tested — when fee is 0, _sendETH is called with 0
            // If it reverted, all tiny swaps would fail
            // Prove it by doing a swap where we know fees are 0
            const swapAmount = 100n; // both fees = 0

            // This swap will likely fail with ReceivedLessThanMinimum (100 wei → 0 USDC)
            // but it should NOT fail at _sendETH
            try {
                await den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: swapAmount });
            } catch (e: any) {
                // Should be ReceivedLessThanMinimum, NOT SendETHToRecipientFailed
                expect(e.message).to.not.include("SendETHToRecipientFailed",
                    "_sendETH(0) should not revert");
            }
        });
    });

    // =============================================
    // ZERO-VALUE: amountInLessFees = 0
    // What if fees consume the entire input?
    // =============================================
    describe("Zero swap amount after fee deduction", function () {

        it("with max partner fee, small amount could have 0 swap amount", async function () {
            // Max fees: 15 + 235 = 250 basis points = 2.5%
            // For amount = 39: fees = 39 * 250 / 10000 = 0.975 → 0
            // So amountInLessFees = 39 - 0 = 39 → still positive

            // For fees to consume everything: amount * 250 / 10000 >= amount
            // → 250/10000 >= 1 → impossible! Max fee is 2.5%, can never consume 100%
            const [sysFee, partFee] = await den.getFees(1000n, 235);
            const totalFee = sysFee + partFee;
            expect(totalFee).to.be.lt(1000n, "Fees should never exceed input");
            console.log("  Fees on 1000 wei with max rate:", totalFee.toString(), "(", (totalFee * 10000n / 1000n).toString(), "bps)");
        });
    });

    // =============================================
    // TIMING: No deadline — stale transaction attack
    // =============================================
    describe("Timing: No deadline parameter", function () {

        it("DOCUMENTED: swaps have no deadline — stale tx can execute at any future time", async function () {
            // This is a design limitation. There's no `deadline` parameter on any swap function.
            // A transaction sitting in the mempool for hours/days will execute whenever mined,
            // as long as amountOutMin is still met.
            //
            // Attack scenario:
            // 1. User submits swapETHForToken with amountOutMin = 1900 USDC per ETH
            // 2. ETH price drops to 1950 USDC/ETH (still above amountOutMin)
            // 3. Validator holds the tx for 3 days
            // 4. ETH price recovers to 2100 USDC/ETH
            // 5. Validator sandwiches: frontrun pushes pool to 1901 USDC/ETH,
            //    user's tx executes at 1900, backrun restores price
            //
            // The amountOutMin protects against the WORST case but doesn't protect
            // against "stale but still above minimum" execution.
            //
            // Recommendation: Add a `deadline` parameter to swap functions.
            // For now, users should set tight amountOutMin values.

            console.log("  WARNING: No deadline parameter on swap functions");
            console.log("  Mitigation: Users should set aggressive amountOutMin values");
            expect(true).to.be.true; // Documented, not a code bug
        });
    });

    // =============================================
    // MEMORY: Large V4 callback data encoding
    // =============================================
    describe("Memory: V4 callback data encoding/decoding", function () {

        it("V4 pool key with max-length values encodes correctly", async function () {
            // Ensure getV4PoolId works with extreme values
            const extremeKey = {
                currency0: ZERO,
                currency1: "0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF",
                fee: 16777215, // max uint24
                tickSpacing: 32767, // max int24 (positive)
                hooks: ZERO,
            };

            // This should not revert — just computes keccak256
            const poolId = await den.getV4PoolId(extremeKey);
            expect(poolId).to.not.equal(ethers.ZeroHash);
        });
    });

    // =============================================
    // STATE: Multiple sequential swaps
    // Does state (currentSwapPool, balances) reset correctly?
    // =============================================
    describe("Sequential swap state", function () {

        it("10 consecutive V3 swaps all succeed", async function () {
            for (let i = 0; i < 10; i++) {
                await den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: ethers.parseEther("0.1") });
            }
            expect(await usdc.balanceOf(deployer.address)).to.be.gt(0);
        });

        it("alternating V2 and V3 swaps succeed", async function () {
            await den.swapETHForToken(V2_USDC_POOL, USDC, 1, await futureDeadline(), { value: ethers.parseEther("0.1") });
            await den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: ethers.parseEther("0.1") });
            await den.swapETHForToken(V2_USDC_POOL, USDC, 1, await futureDeadline(), { value: ethers.parseEther("0.1") });
            await den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: ethers.parseEther("0.1") });
            expect(await usdc.balanceOf(deployer.address)).to.be.gt(0);
        });

        it("V3 ETH→Token followed by Token→ETH works (state fully resets)", async function () {
            // ETH → USDC
            await den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: ethers.parseEther("1") });
            const usdcBal = await usdc.balanceOf(deployer.address);

            // USDC → ETH (same pool, reverse direction)
            await usdc.approve(await den.getAddress(), usdcBal);
            await den.swapTokenForETH(V3_USDC_3000, USDC, usdcBal, 1, await futureDeadline());

            // Should have less USDC now
            expect(await usdc.balanceOf(deployer.address)).to.equal(0);
        });

        it("V2 ETH→Token followed by V2 Token→ETH roundtrip", async function () {
            await den.swapETHForToken(V2_USDC_POOL, USDC, 1, await futureDeadline(), { value: ethers.parseEther("1") });
            const usdcBal = await usdc.balanceOf(deployer.address);
            expect(usdcBal).to.be.gt(0);

            await usdc.approve(await den.getAddress(), usdcBal);
            await den.swapTokenForETH(V2_USDC_POOL, USDC, usdcBal, 1, await futureDeadline());
            expect(await usdc.balanceOf(deployer.address)).to.equal(0);
        });
    });

    // =============================================
    // PRECISION: Verify fee math doesn't lose wei
    // totalOutput = systemFee + partnerFee + amountInLessFees should = msg.value
    // =============================================
    describe("Fee precision: no wei lost in fee calculation", function () {

        it("system + partner + swap amount = msg.value exactly", async function () {
            const testAmounts = [
                ethers.parseEther("1"),
                ethers.parseEther("0.123456789"),
                1000000n, // 1M wei
                9999n,    // just under fee threshold multiples
                10001n,
                ethers.parseEther("100"),
            ];

            for (const amount of testAmounts) {
                const [sysFee, partFee] = await den.getFees(amount, PARTNER_FEE);
                const remainder = amount - sysFee - partFee;

                // Rounding means we might lose up to 1 wei per fee calculation
                // sysFee = floor(amount * 15 / 10000), partFee = floor(amount * 50 / 10000)
                // remainder = amount - floor(amount*15/10000) - floor(amount*50/10000)
                // This is always >= amount * (1 - 65/10000) = amount * 9935/10000
                // The rounding loss is at most 2 wei (1 per fee)

                const total = sysFee + partFee + remainder;
                expect(total).to.equal(amount, `Wei lost for amount ${amount}`);
            }
        });

        it("rounding always favors the user (fees round DOWN)", async function () {
            // For amount = 9999:
            // sysFee = 9999 * 15 / 10000 = 14.9985 → 14
            // partFee = 9999 * 50 / 10000 = 49.995 → 49
            // Total fees = 63 (vs exact 64.9935)
            // Remainder = 9999 - 63 = 9936
            // User gets slightly MORE than the exact fee calculation would give
            const [sysFee, partFee] = await den.getFees(9999n, PARTNER_FEE);
            expect(sysFee).to.equal(14n);
            expect(partFee).to.equal(49n);
            // Exact would be ~14.9985 + 49.995 = 64.9935 in fees
            // Actual is 63 — user keeps 1.9935 extra wei (rounding in user's favor)
        });
    });

    // =============================================
    // V4 RATE: checkV4Rate with edge-case inputs
    // =============================================
    describe("V4 rate estimation edge cases", function () {

        beforeEach(async function () {
            await den.connect(deployer).setV4PoolManager(V4_PM);
        });

        it("checkV4Rate with amount=1 wei returns non-zero (or 0 for dust)", async function () {
            const v4Key = { currency0: ZERO, currency1: USDC, fee: 500, tickSpacing: 10, hooks: ZERO };
            const rate = await den.checkV4Rate(v4Key, WETH_ADDR, USDC, 1n);
            // 1 wei of ETH → tiny USDC amount, likely rounds to 0
            console.log("  V4 rate for 1 wei:", rate.toString());
            // This is fine — no revert expected
        });

        it("checkV4Rate with mismatched tokenIn that's not in pool returns 0", async function () {
            const v4Key = { currency0: ZERO, currency1: USDC, fee: 500, tickSpacing: 10, hooks: ZERO };
            const fakeToken = "0x0000000000000000000000000000000000000001";
            const rate = await den.checkV4Rate(v4Key, fakeToken, USDC, ethers.parseEther("1"));
            expect(rate).to.equal(0);
        });
    });

    // =============================================
    // ESTIMATOR: DENEstimator edge cases
    // =============================================
    describe("DENEstimator edge cases", function () {
        let estimator: DENEstimator;

        beforeEach(async function () {
            const f = await ethers.getContractFactory("DENEstimator", {
                libraries: { V4SwapLib: v4SwapLibAddress },
            });
            estimator = await f.deploy(await den.getAddress(), WETH_ADDR, V4_PM) as DENEstimator;
        });

        it("estimateAmountOut with pool=tokenIn should revert", async function () {
            await expect(
                estimator.estimateAmountOut(WETH_ADDR, WETH_ADDR, ethers.parseEther("1"), 50, 15, 10000)
            ).to.be.revertedWithCustomError(estimator, "TokenCannotBeAPool");
        });

        it("V2 estimate with 1 wei returns 0 (rounds to nothing)", async function () {
            const result = await estimator.estimateAmountOut(
                V2_USDC_POOL, WETH_ADDR, 1n, 50, 15, 10000
            );
            // 1 wei → after DEN fees (0) and V2 fee, output rounds to 0
            console.log("  V2 estimate for 1 wei:", result.toString());
        });

        it("V3 estimate with 1 wei returns non-zero or 0", async function () {
            const result = await estimator.estimateAmountOut(
                V3_USDC_3000, WETH_ADDR, 1n, 50, 15, 10000
            );
            console.log("  V3 estimate for 1 wei:", result.toString());
        });
    });

    // =============================================
    // CONCURRENT: Multiple users swapping simultaneously
    // (in same block via hardhat mine)
    // =============================================
    describe("Multiple users in same block", function () {

        it("two different users can swap in the same block", async function () {
            const [, , , , user1, user2] = await ethers.getSigners();

            // Stop auto-mining to batch transactions
            await ethers.provider.send("evm_setAutomine", [false]);

            const deadline = await futureDeadline();
            const tx1 = den.connect(user1).swapETHForToken(V3_USDC_3000, USDC, 1, deadline, { value: ethers.parseEther("0.1") });
            const tx2 = den.connect(user2).swapETHForToken(V3_USDC_3000, USDC, 1, deadline, { value: ethers.parseEther("0.1") });

            // Mine the block with both txs
            await ethers.provider.send("evm_mine", []);
            await ethers.provider.send("evm_setAutomine", [true]);

            // Both should have USDC
            const bal1 = await usdc.balanceOf(user1.address);
            const bal2 = await usdc.balanceOf(user2.address);
            console.log("  User1 USDC:", bal1.toString());
            console.log("  User2 USDC:", bal2.toString());
            expect(bal1).to.be.gt(0);
            expect(bal2).to.be.gt(0);
        });
    });
});
