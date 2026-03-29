import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { Contract } from "ethers";
import { DecentralizedExchangeNetwork } from "../typechain-types";

const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const WETH_ADDR = "0x4200000000000000000000000000000000000006";
const V3_USDC_3000 = "0x6c561B446416E1A00E8E93E221854d6eA4171372";
const V2_USDC_POOL = "0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C";
const PARTNER_FEE = 50;

let v4SwapLibAddress: string;
const erc20Abi = [
    "function approve(address, uint256) returns (bool)",
    "function balanceOf(address) view returns (uint256)",
];

async function deployDEN(deployer: HardhatEthersSigner, partner: HardhatEthersSigner, sysFR: HardhatEthersSigner, partFR: HardhatEthersSigner) {
    if (!v4SwapLibAddress) {
        const f = await ethers.getContractFactory("V4SwapLib");
        const lib = await f.connect(deployer).deploy();
        await lib.waitForDeployment();
        v4SwapLibAddress = await lib.getAddress();
    }
    const f = await ethers.getContractFactory("DecentralizedExchangeNetwork", { libraries: { V4SwapLib: v4SwapLibAddress } });
    return (await f.connect(deployer).deploy(WETH_ADDR, partner, sysFR, partFR, PARTNER_FEE)) as DecentralizedExchangeNetwork;
}

async function futureDeadline(): Promise<number> {
    return (await ethers.provider.getBlock("latest"))!.timestamp + 3600;
}

describe("Pull-Based Fees & Deadline", function () {
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

    describe("Pull-based fee accumulation", function () {
        it("ETH→Token swap accumulates fees in contract, not sent immediately", async function () {
            const sysBefore = await ethers.provider.getBalance(sysFR.address);
            const partBefore = await ethers.provider.getBalance(partFR.address);

            await den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: ethers.parseEther("1") });

            expect(await ethers.provider.getBalance(sysFR.address)).to.equal(sysBefore, "System fee should NOT be sent during swap");
            expect(await ethers.provider.getBalance(partFR.address)).to.equal(partBefore, "Partner fee should NOT be sent during swap");
            expect(await den.pendingSystemFeesETH()).to.be.gt(0);
            expect(await den.pendingPartnerFeesETH()).to.be.gt(0);
        });

        it("Token→ETH swap accumulates ETH fees in contract", async function () {
            await den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: ethers.parseEther("2") });
            const usdcBal = await usdc.balanceOf(deployer.address);
            await usdc.approve(await den.getAddress(), usdcBal);

            const sysBefore = await ethers.provider.getBalance(sysFR.address);
            await den.swapTokenForETH(V3_USDC_3000, USDC, usdcBal, 1, await futureDeadline());

            expect(await ethers.provider.getBalance(sysFR.address)).to.equal(sysBefore);
            expect(await den.pendingSystemFeesETH()).to.be.gt(0);
        });
    });

    describe("Fee claiming", function () {
        it("claimSystemFeesETH sends to systemFeeReceiver", async function () {
            await den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: ethers.parseEther("1") });
            const pending = await den.pendingSystemFeesETH();

            const sysBefore = await ethers.provider.getBalance(sysFR.address);
            await den.claimSystemFeesETH();
            expect((await ethers.provider.getBalance(sysFR.address)) - sysBefore).to.equal(pending);
            expect(await den.pendingSystemFeesETH()).to.equal(0);
        });

        it("claimPartnerFeesETH sends to partnerFeeReceiver", async function () {
            await den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: ethers.parseEther("1") });
            const pending = await den.pendingPartnerFeesETH();

            const partBefore = await ethers.provider.getBalance(partFR.address);
            await den.claimPartnerFeesETH();
            expect((await ethers.provider.getBalance(partFR.address)) - partBefore).to.equal(pending);
        });

        it("claim reverts when nothing pending", async function () {
            await expect(den.claimSystemFeesETH()).to.be.revertedWithCustomError(den, "NoFeesToClaim");
            await expect(den.claimPartnerFeesETH()).to.be.revertedWithCustomError(den, "NoFeesToClaim");
        });

        it("fees accumulate across multiple swaps", async function () {
            const dl = await futureDeadline();
            await den.swapETHForToken(V3_USDC_3000, USDC, 1, dl, { value: ethers.parseEther("1") });
            await den.swapETHForToken(V3_USDC_3000, USDC, 1, dl, { value: ethers.parseEther("2") });
            await den.swapETHForToken(V2_USDC_POOL, USDC, 1, dl, { value: ethers.parseEther("3") });

            // 6 ETH total, system fee 0.15% = 0.009 ETH
            expect(await den.pendingSystemFeesETH()).to.equal(ethers.parseEther("0.009"));
        });
    });

    describe("Reverting fee receiver no longer blocks swaps", function () {
        it("swap succeeds even when partner fee receiver reverts", async function () {
            await ethers.provider.send("hardhat_setCode", [partFR.address, "0x5f5ffd"]);

            const usdcBefore = await usdc.balanceOf(deployer.address);
            await den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: ethers.parseEther("1") });
            expect(await usdc.balanceOf(deployer.address)).to.be.gt(usdcBefore);
            expect(await den.pendingPartnerFeesETH()).to.be.gt(0);

            // Claiming fails (receiver reverts), but swap was NOT blocked
            await expect(den.claimPartnerFeesETH()).to.be.reverted;
        });
    });

    describe("Deadline enforcement", function () {
        it("swap reverts when deadline has passed", async function () {
            const past = (await ethers.provider.getBlock("latest"))!.timestamp - 1;
            await expect(
                den.swapETHForToken(V3_USDC_3000, USDC, 1, past, { value: ethers.parseEther("1") })
            ).to.be.revertedWithCustomError(den, "DeadlineExpired");
        });

        it("swap succeeds with future deadline", async function () {
            await expect(
                den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: ethers.parseEther("1") })
            ).to.not.be.reverted;
        });

        it("swapTokenForETH respects deadline", async function () {
            await den.swapETHForToken(V3_USDC_3000, USDC, 1, await futureDeadline(), { value: ethers.parseEther("2") });
            const bal = await usdc.balanceOf(deployer.address);
            await usdc.approve(await den.getAddress(), bal);

            const past = (await ethers.provider.getBlock("latest"))!.timestamp - 1;
            await expect(
                den.swapTokenForETH(V3_USDC_3000, USDC, bal, 1, past)
            ).to.be.revertedWithCustomError(den, "DeadlineExpired");
        });
    });
});
