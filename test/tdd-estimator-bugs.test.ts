import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { DecentralizedExchangeNetwork, DENEstimator } from "../typechain-types";

// Base mainnet addresses (same block as fork: 28_000_000)
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const DAI  = "0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb";
const WETH_ADDR = "0x4200000000000000000000000000000000000006";
const ZERO = "0x0000000000000000000000000000000000000000";
const V2_ROUTER = "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24";
const V3_ROUTER = "0x2626664c2603336E57B271c5C0b26F421741e481";
const V4_PM     = "0x498581fF718922c3f8e6A244956aF099B2652b2b";

const PARTNER_FEE = 50;
const SYS_FEE = 15;         // from contract
const FEE_DENOMINATOR = 10000;

// Base Uniswap V3 QuoterV2 — canonical oracle we compare against
const V3_QUOTER = "0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a";
// Real Base WETH/USDC 0.05% V3 pool
const V3_WETH_USDC_500 = "0xd0b53D9277642d899DF5C87A3966A349A798F224";

const V4_ETH_USDC = {
    currency0: ZERO,
    currency1: USDC,
    fee: 500,
    tickSpacing: 10,
    hooks: ZERO,
};

let v4SwapLibAddress: string;

async function deployLib(deployer: HardhatEthersSigner): Promise<string> {
    const f = await ethers.getContractFactory("V4SwapLib");
    const lib = await f.connect(deployer).deploy();
    await lib.waitForDeployment();
    return await lib.getAddress();
}

async function deployDEN(
    deployer: HardhatEthersSigner,
    partner: HardhatEthersSigner,
    sysFR: HardhatEthersSigner,
    partFR: HardhatEthersSigner
): Promise<DecentralizedExchangeNetwork> {
    const f = await ethers.getContractFactory("DecentralizedExchangeNetwork", {
        libraries: { V4SwapLib: v4SwapLibAddress },
    });
    return (await f.connect(deployer).deploy(
        WETH_ADDR, partner, sysFR, partFR, PARTNER_FEE
    )) as DecentralizedExchangeNetwork;
}

async function deployEstimator(denAddress: string): Promise<DENEstimator> {
    const f = await ethers.getContractFactory("DENEstimator", {
        libraries: { V4SwapLib: v4SwapLibAddress },
    });
    return (await f.deploy(denAddress, WETH_ADDR, V4_PM)) as DENEstimator;
}

async function registerAll(den: DecentralizedExchangeNetwork) {
    await (await den.addV2Router(V2_ROUTER)).wait();
    await (await den.addV3Router(V3_ROUTER)).wait();
    await (await den.setV4PoolManager(V4_PM)).wait();
    await (await den.addV4Pool(V4_ETH_USDC)).wait();
}

describe("DENEstimator Bug Reproduction (TDD Red)", function () {
    let den: DecentralizedExchangeNetwork;
    let estimator: DENEstimator;
    let deployer: HardhatEthersSigner;
    let partner: HardhatEthersSigner;
    let sysFR: HardhatEthersSigner;
    let partFR: HardhatEthersSigner;

    beforeEach(async function () {
        [deployer, partner, sysFR, partFR] = await ethers.getSigners();
        await ethers.provider.send("hardhat_setCode", [sysFR.address, "0x"]);
        await ethers.provider.send("hardhat_setCode", [partFR.address, "0x"]);

        if (!v4SwapLibAddress) {
            v4SwapLibAddress = await deployLib(deployer);
        }
        den = await deployDEN(deployer, partner, sysFR, partFR);
        estimator = await deployEstimator(await den.getAddress());
        await registerAll(den);
    });

    // ============================================================
    //  BUG 1: V4SwapLib.estimateV3 overflow on large sqrtPriceX96
    // ============================================================
    describe("BUG: estimateV3 panics with OVERFLOW(17) on sqrtPriceX96 > 2^128", function () {
        it("RED: should not revert when slot0 returns sqrtPriceX96 near uint160 max", async function () {
            // sqrtPriceX96 of 2^130 will cause sqrtPriceX96^2 = 2^260 > uint256 max
            const extremeSqrt = 2n ** 130n;

            const mockFactory = await ethers.getContractFactory("MockV3Pool");
            const mockPool = await mockFactory.deploy(
                WETH_ADDR, // token0
                USDC,      // token1
                3000,
                extremeSqrt
            );
            await mockPool.waitForDeployment();
            const poolAddr = await mockPool.getAddress();

            // This should either return 0 or a valid estimate — NOT panic
            await expect(
                estimator.estimateAmountOut(
                    poolAddr,
                    WETH_ADDR,
                    ethers.parseEther("1"),
                    PARTNER_FEE,
                    SYS_FEE,
                    FEE_DENOMINATOR
                )
            ).to.not.be.reverted;
        });

        it("RED: should handle sqrtPriceX96 = uint160 max without overflow", async function () {
            // Maximum legal V3 sqrtPriceX96 (~2^160)
            const maxSqrt = (2n ** 160n) - 1n;

            const mockFactory = await ethers.getContractFactory("MockV3Pool");
            const mockPool = await mockFactory.deploy(WETH_ADDR, USDC, 3000, maxSqrt);
            await mockPool.waitForDeployment();

            await expect(
                estimator.estimateAmountOut(
                    await mockPool.getAddress(),
                    WETH_ADDR,
                    ethers.parseEther("0.001"),
                    PARTNER_FEE,
                    SYS_FEE,
                    FEE_DENOMINATOR
                )
            ).to.not.be.reverted;
        });

        it("RED: estimator should return a quote (or zero) but never panic", async function () {
            // sqrtPriceX96 just above the overflow threshold
            const justOver = (2n ** 128n) + 1n;

            const mockFactory = await ethers.getContractFactory("MockV3Pool");
            const mockPool = await mockFactory.deploy(WETH_ADDR, USDC, 500, justOver);
            await mockPool.waitForDeployment();

            const result = await estimator.estimateAmountOut(
                await mockPool.getAddress(),
                WETH_ADDR,
                ethers.parseEther("1"),
                PARTNER_FEE,
                SYS_FEE,
                FEE_DENOMINATOR
            );
            // Just asserting we got back a uint256 without panic
            expect(result).to.be.a("bigint");
        });
    });

    // ============================================================
    //  BUG 2: V3 rate shop ignores pool fees
    // ============================================================
    describe("BUG: _bestV3Rate does not account for pool fees", function () {
        it("RED: a 0.05% pool should beat a 1% pool with identical sqrtPrice", async function () {
            // Two mock V3 pools with IDENTICAL spot price but different fees.
            // A correct estimator must pick the cheaper (0.05%) tier.
            const sqrtPrice = 79228162514264337593543950336n; // 2^96, represents price=1

            const mockFactory = await ethers.getContractFactory("MockV3Pool");
            const cheapPool = await mockFactory.deploy(WETH_ADDR, USDC, 500, sqrtPrice);
            const expensivePool = await mockFactory.deploy(WETH_ADDR, USDC, 10000, sqrtPrice);
            await cheapPool.waitForDeployment();
            await expensivePool.waitForDeployment();

            const amountIn = ethers.parseEther("1");
            const cheapOut = await estimator.estimateAmountOut(
                await cheapPool.getAddress(),
                WETH_ADDR,
                amountIn,
                PARTNER_FEE,
                SYS_FEE,
                FEE_DENOMINATOR
            );
            const expensiveOut = await estimator.estimateAmountOut(
                await expensivePool.getAddress(),
                WETH_ADDR,
                amountIn,
                PARTNER_FEE,
                SYS_FEE,
                FEE_DENOMINATOR
            );

            // The 0.05% pool MUST return more output than the 1% pool for the same spot price
            expect(cheapOut).to.be.gt(expensiveOut);
            // And the spread should approximate the fee difference: ~0.95% of input
            // amountIn = 1e18, so expected delta ≈ 9.5e15 wei-equivalent... but we're
            // comparing outputs, not inputs. At price=1, output diff ≈ (1% - 0.05%) * 1e18 = 9.5e15
            expect(cheapOut - expensiveOut).to.be.gt(ethers.parseEther("0.009"));
        });
    });

    // ============================================================
    //  BUG 3: DAI → USDC overflow on real Base fork
    // ============================================================
    describe("BUG: getBestRateAllTiers DAI→USDC reverts", function () {
        it("RED: should return a valid quote for 100 DAI -> USDC on fork", async function () {
            const amountIn = ethers.parseUnits("100", 18);
            // This MUST NOT revert with OVERFLOW(17)
            const result = await estimator.getBestRateAllTiers(DAI, USDC, amountIn);
            expect(result.highestOut).to.be.gt(0);
        });

        it("RED: should return a valid quote for the reverse direction USDC -> DAI", async function () {
            const amountIn = ethers.parseUnits("100", 6);
            const result = await estimator.getBestRateAllTiers(USDC, DAI, amountIn);
            expect(result.highestOut).to.be.gt(0);
        });
    });

    // ============================================================
    //  BUG 4: discoverAllPools reverts with missing data
    // ============================================================
    describe("BUG: discoverAllPools reverts on valid pairs", function () {
        it("RED: should discover pools for WETH/USDC without reverting", async function () {
            const pools = await estimator.discoverAllPools(WETH_ADDR, USDC);
            expect(pools.length).to.be.gt(0);
        });

        it("RED: should discover pools for DAI/USDC", async function () {
            const pools = await estimator.discoverAllPools(DAI, USDC);
            // At least one V2 or V3 pool should exist on Base at fork block
            expect(pools.length).to.be.gt(0);
        });
    });

    // ============================================================
    //  BUG 6: Zero-liquidity pool returns garbage (found on redeploy)
    //
    //  DAI→USDC on live mainnet returned 3.37e46 USDC because the
    //  fee=10000 pool has an extreme sqrtPriceX96 and no liquidity.
    //  Overflow-safe math no longer panics but passes through nonsense.
    //  Real fix: skip pools with zero active-tick liquidity.
    // ============================================================
    describe("BUG: zero-liquidity pools return nonsense prices", function () {
        it("RED: a pool with liquidity=0 should return 0 from estimateAmountOut", async function () {
            // Extreme sqrtPrice that would give a huge output if used blindly
            const extremePrice = 2n ** 140n;

            const mockFactory = await ethers.getContractFactory("MockV3Pool");
            const deadPool = await mockFactory.deploy(DAI, USDC, 10000, extremePrice);
            await deadPool.waitForDeployment();
            await (await deadPool.setLiquidity(0n)).wait();

            const amountIn = ethers.parseUnits("100", 18);
            const out = await estimator.estimateAmountOut(
                await deadPool.getAddress(), DAI, amountIn, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            expect(out).to.equal(0n);
        });

        it("RED: a pool with small non-zero liquidity should still return a quote", async function () {
            const TWO_96 = 2n ** 96n;
            const mockFactory = await ethers.getContractFactory("MockV3Pool");
            const livePool = await mockFactory.deploy(DAI, USDC, 500, TWO_96);
            await livePool.waitForDeployment();
            await (await livePool.setLiquidity(1n)).wait(); // tiny but non-zero

            const out = await estimator.estimateAmountOut(
                await livePool.getAddress(), DAI, ethers.parseUnits("100", 18), PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            expect(out).to.be.gt(0n);
        });
    });

    // ============================================================
    //  BUG 5: Round-trip WETH -> USDC -> WETH fails
    // ============================================================
    describe("BUG: round-trip quote fails", function () {
        it("RED: WETH → USDC → WETH at 0.1 ETH should return non-zero both legs", async function () {
            const amountIn = ethers.parseEther("0.1");
            const fwd = await estimator.getBestRateAllTiers(WETH_ADDR, USDC, amountIn);
            expect(fwd.highestOut).to.be.gt(0);

            const back = await estimator.getBestRateAllTiers(USDC, WETH_ADDR, fwd.highestOut);
            expect(back.highestOut).to.be.gt(0);

            // Round-trip loss should be reasonable (< 10%) if pool fees are deducted correctly
            const loss = (amountIn - back.highestOut) * 10000n / amountIn;
            expect(loss).to.be.lt(1000n); // less than 10%
        });
    });

    // ============================================================
    //  PRICE MATH VERIFICATION — ground-truth math with mocks
    //  These tests exercise exact decimal arithmetic so a wrong
    //  shift / missing zero / reversed ratio gets caught fast.
    // ============================================================
    describe("Price math: exact ground-truth checks with mock pools", function () {
        const TWO_96 = 2n ** 96n;

        async function deployMock(token0: string, token1: string, fee: number, sqrt: bigint) {
            const f = await ethers.getContractFactory("MockV3Pool");
            const pool = await f.deploy(token0, token1, fee, sqrt);
            await pool.waitForDeployment();
            return pool;
        }

        it("sqrtPrice=2^96 (raw price=1), fee=500: token0→token1 returns amountIn * 0.9995", async function () {
            const pool = await deployMock(WETH_ADDR, USDC, 500, TWO_96);
            const amountIn = ethers.parseEther("1");
            const out = await estimator.estimateAmountOut(
                await pool.getAddress(), WETH_ADDR, amountIn, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            // Expected: 1e18 * 999500/1e6 = 9.995e17
            expect(out).to.equal(999_500n * 10n ** 12n);
        });

        it("sqrtPrice=2^96, fee=3000: token0→token1 returns amountIn * 0.997", async function () {
            const pool = await deployMock(WETH_ADDR, USDC, 3000, TWO_96);
            const amountIn = ethers.parseEther("1");
            const out = await estimator.estimateAmountOut(
                await pool.getAddress(), WETH_ADDR, amountIn, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            expect(out).to.equal(997_000n * 10n ** 12n);
        });

        it("sqrtPrice=2^96, fee=10000: token0→token1 returns amountIn * 0.99", async function () {
            const pool = await deployMock(WETH_ADDR, USDC, 10000, TWO_96);
            const amountIn = ethers.parseEther("1");
            const out = await estimator.estimateAmountOut(
                await pool.getAddress(), WETH_ADDR, amountIn, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            expect(out).to.equal(990_000n * 10n ** 12n);
        });

        it("sqrtPrice=2^96, reverse direction: token1→token0 returns amountIn * 0.9995", async function () {
            const pool = await deployMock(WETH_ADDR, USDC, 500, TWO_96);
            const amountIn = ethers.parseEther("1");
            // tokenIn = token1 (USDC) this time
            const out = await estimator.estimateAmountOut(
                await pool.getAddress(), USDC, amountIn, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            expect(out).to.equal(999_500n * 10n ** 12n);
        });

        it("sqrtPrice=2^97 (raw price=4): token0→token1 returns 4 * amountIn * 0.9995", async function () {
            const pool = await deployMock(WETH_ADDR, USDC, 500, TWO_96 * 2n);
            const amountIn = ethers.parseEther("1");
            const out = await estimator.estimateAmountOut(
                await pool.getAddress(), WETH_ADDR, amountIn, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            // 1e18 * 4 * 999500/1e6 = 3.998e18
            expect(out).to.equal(4n * 999_500n * 10n ** 12n);
        });

        it("sqrtPrice=2^97 reverse: token1→token0 returns amountIn / 4 * 0.9995", async function () {
            const pool = await deployMock(WETH_ADDR, USDC, 500, TWO_96 * 2n);
            const amountIn = ethers.parseEther("4");
            const out = await estimator.estimateAmountOut(
                await pool.getAddress(), USDC, amountIn, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            // 4e18 / 4 * 999500/1e6 = 9.995e17
            expect(out).to.equal(999_500n * 10n ** 12n);
        });

        it("direction symmetry: round-trip loss equals (1 - (1-fee)^2)", async function () {
            const pool = await deployMock(WETH_ADDR, USDC, 500, TWO_96);
            const amountIn = ethers.parseEther("1");
            const fwd = await estimator.estimateAmountOut(
                await pool.getAddress(), WETH_ADDR, amountIn, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            const back = await estimator.estimateAmountOut(
                await pool.getAddress(), USDC, fwd, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            // (1e18 * 0.9995) * 0.9995 = 1e18 * (0.9995)^2 = 0.999000250e18
            // Expected: floor(floor(1e18 * 999500 / 1e6) * 999500 / 1e6)
            const step1 = (ethers.parseEther("1") * 999_500n) / 1_000_000n;
            const expected = (step1 * 999_500n) / 1_000_000n;
            expect(back).to.equal(expected);
        });

        it("sqrtPrice at overflow boundary 2^128 does not revert and returns reasonable value", async function () {
            const boundary = 2n ** 128n;
            const pool = await deployMock(WETH_ADDR, USDC, 500, boundary);
            // sqrtPrice = 2^128 means raw price = 2^64
            // For amountIn = 1, output should be raw price ≈ 2^64 (ignoring pool fee rounding)
            const out = await estimator.estimateAmountOut(
                await pool.getAddress(), WETH_ADDR, 1n, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            // The amountIn after fee is 0 (1 * 999500/1e6 = 0 due to integer division)
            // So output is 0 — acceptable, just must not revert
            expect(out).to.be.a("bigint");
        });

        it("decimal scaling sanity: DAI/USDC stable pool, sqrtPrice=1e-6 * 2^96", async function () {
            // DAI(18 dec) == USDC(6 dec) in value. DAI < USDC so token0 = DAI.
            // 1 wei DAI = 1e-18 $; 1 wei USDC = 1e-6 $.
            // So 1 wei DAI is worth 1e-12 wei USDC.
            // price01_raw = 1e-12, sqrtPrice = 1e-6, sqrtPriceX96 = 1e-6 * 2^96
            // Use exact integer: 79228162514264337593544 (2^96 / 1_000_000, rounded up)
            const sqrt = TWO_96 / 1_000_000n;
            const pool = await deployMock(DAI, USDC, 100, sqrt);

            const amountIn = ethers.parseUnits("100", 18); // 100 DAI
            const out = await estimator.estimateAmountOut(
                await pool.getAddress(), DAI, amountIn, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            // Expected: 100 DAI → ~100 USDC minus 0.01% fee
            // amountIn = 100e18
            // afterFee = 100e18 * 999900/1e6 = 9.999e19
            // _p = mulDiv(mulDiv(sqrt, sqrt, 2^96), 1e18, 2^96)
            //    = mulDiv(sqrt^2 / 2^96, 1e18, 2^96)
            // sqrt = 2^96 / 1e6 = 79228162514264337593543
            // sqrt^2 = sqrt * sqrt
            // sqrt^2 / 2^96 = sqrt (because sqrt = 2^96/1e6, so sqrt^2 = 2^192/1e12, /2^96 = 2^96/1e12)
            // _p = (2^96/1e12) * 1e18 / 2^96 = 1e18/1e12 = 1e6
            // _raw = _p = 1e6 (tokenIn == token0)
            // output = mulDiv(afterFee, 1e6, 1e18) = 9.999e19 * 1e6 / 1e18 = 9.999e7 = 99.99 USDC
            // Expected roughly 99.99 USDC = 99_990_000 (with slight rounding from integer sqrt)
            const lower = 99_000_000n;  // 99 USDC
            const upper = 100_100_000n; // 100.1 USDC
            expect(out).to.be.gte(lower);
            expect(out).to.be.lte(upper);
        });
    });

    // ============================================================
    //  FORK CROSS-CHECK against Uniswap's own QuoterV2
    //  For small amounts slippage is near zero, so our spot-price
    //  estimate should match QuoterV2 within a small tolerance.
    // ============================================================
    describe("Fork cross-check against Uniswap V3 QuoterV2", function () {
        it("WETH→USDC 0.05% pool: estimator matches QuoterV2 within 0.1%", async function () {
            const quoterAbi = [
                "function quoteExactInputSingle(tuple(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint160 sqrtPriceLimitX96) params) returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)"
            ];
            const quoter = new ethers.Contract(V3_QUOTER, quoterAbi, deployer);

            const amountIn = ethers.parseEther("0.01"); // small enough that slippage is negligible

            // Estimator path
            const estOut = await estimator.estimateAmountOut(
                V3_WETH_USDC_500, WETH_ADDR, amountIn, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );

            // Uniswap QuoterV2 — ground truth, the same function UIs use
            const quoted = await quoter.quoteExactInputSingle.staticCall({
                tokenIn: WETH_ADDR,
                tokenOut: USDC,
                amountIn,
                fee: 500,
                sqrtPriceLimitX96: 0,
            });
            const quoterOut: bigint = quoted[0];

            // Both should be in USDC units (6 decimals) and within 0.1% of each other
            const diff = estOut > quoterOut ? estOut - quoterOut : quoterOut - estOut;
            const tolerance = quoterOut / 1000n; // 0.1%
            expect(diff).to.be.lte(
                tolerance,
                `Estimator ${estOut} vs Quoter ${quoterOut} — diff ${diff} exceeds 0.1%`
            );
        });

        it("USDC→WETH 0.05% pool: estimator matches QuoterV2 within 0.1%", async function () {
            const quoterAbi = [
                "function quoteExactInputSingle(tuple(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint160 sqrtPriceLimitX96) params) returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)"
            ];
            const quoter = new ethers.Contract(V3_QUOTER, quoterAbi, deployer);

            const amountIn = ethers.parseUnits("30", 6); // 30 USDC

            const estOut = await estimator.estimateAmountOut(
                V3_WETH_USDC_500, USDC, amountIn, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );

            const quoted = await quoter.quoteExactInputSingle.staticCall({
                tokenIn: USDC,
                tokenOut: WETH_ADDR,
                amountIn,
                fee: 500,
                sqrtPriceLimitX96: 0,
            });
            const quoterOut: bigint = quoted[0];

            const diff = estOut > quoterOut ? estOut - quoterOut : quoterOut - estOut;
            const tolerance = quoterOut / 1000n; // 0.1%
            expect(diff).to.be.lte(
                tolerance,
                `Estimator ${estOut} vs Quoter ${quoterOut} — diff ${diff} exceeds 0.1%`
            );
        });

        it("decimals sanity: WETH→USDC at 1 ETH lands in $100-$10000 range at fork block", async function () {
            // Catches any missing-zero / decimal-shift regression.
            const amountIn = ethers.parseEther("1");
            const out = await estimator.estimateAmountOut(
                V3_WETH_USDC_500, WETH_ADDR, amountIn, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            // USDC has 6 decimals so $1000 = 1_000_000_000, $10_000 = 10_000_000_000
            expect(out).to.be.gte(100n * 10n ** 6n);      // at least $100/ETH
            expect(out).to.be.lte(10_000n * 10n ** 6n);   // at most $10k/ETH
        });

        it("decimals sanity: USDC→WETH at 3000 USDC lands in 0.1-10 ETH range", async function () {
            const amountIn = ethers.parseUnits("3000", 6);
            const out = await estimator.estimateAmountOut(
                V3_WETH_USDC_500, USDC, amountIn, PARTNER_FEE, SYS_FEE, FEE_DENOMINATOR
            );
            expect(out).to.be.gte(ethers.parseEther("0.1"));
            expect(out).to.be.lte(ethers.parseEther("10"));
        });
    });
});
