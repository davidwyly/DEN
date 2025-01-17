import {
    time,
    loadFixture,
  } from "@nomicfoundation/hardhat-toolbox/network-helpers";

import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { BaseContract, Contract, ContractFactory, Wallet } from "ethers"; 
import { SwapRouterAbi } from "./SwapRouterABI"

// Import generated contract types
import {
    DecentralizedExchangeNetwork,
} from "../typechain-types";

const stableTokenAddress = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"; // USDC on Base
const stableTokenDecimals = 6; // USDC has 6 decimals
const usdtStableTokenAddress = "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2" // USDT on Base
const usdtStableTokenDecimals = 6; // USDT has 6 decimals
const wrappedEthAddress = "0x4200000000000000000000000000000000000006" // Wrapped ETH on Base
// const uniswapSwapRouter = "0x2626664c2603336E57B271c5C0b26F421741e481"; // Uniswap v3 SwapRouter on Base
const swapETHForUSDCAmount = "1"; // Amount of ETH to swap for USDC
const zeroAddress = "0x0000000000000000000000000000000000000000";
const affiliateAddress = "0x2ad465E01aca8Ed427C493B47FD98aeF16B071EC"; // Affiliate address
const referrerAddress = "0xBF38F7e7d9c7Aabda3fbB9e25EaB66821813e230"; // Referrer address
const uniswapV2RouterOnBase = "0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24" // Uniswap v2 router on Base
const uniswapV2USDCPool = "0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C"; // USDC pool on Uniswap v2
const uniswapV3FactoryOnBase = "0x33128a8fC17869897dcE68Ed026d694621f6FDfD" // Uniswap v3 factory on Base
const uniswapV3USDCWithFee3000PoolOnBase = "0x6c561B446416E1A00E8E93E221854d6eA4171372"; // USDC pool on Uniswap v3 with fee of 3000 (0.3%)
const partnerFeeNumerator = 50; // 0.5% partner fee

const usdcAbi = [
    "function approve(address spender, uint256 amount) returns (bool)",
    "function balanceOf(address owner) view returns (uint256)",
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
    "function transfer(address to, uint amount) returns (bool)",
    "event Transfer(address indexed from, address indexed to, uint amount)",
    "function nonces(address owner) view returns (uint256)",
    "function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)",
];

// function to deploy the DEN contract
async function deployDENContract(
    deployer: HardhatEthersSigner,
    partner: HardhatEthersSigner,
    systemFeeReceiver: HardhatEthersSigner,
    partnerFeeReceiver: HardhatEthersSigner,
    partnerFeeNumerator: number
): Promise<DecentralizedExchangeNetwork> {
    const denFactory = await ethers.getContractFactory("DecentralizedExchangeNetwork");
    const den = (await denFactory.connect(deployer).deploy(
        wrappedEthAddress,
        partner,
        systemFeeReceiver,
        partnerFeeReceiver,
        partnerFeeNumerator
    )) as DecentralizedExchangeNetwork;
    return den;
}

describe("Contracts", function () {
    let den: DecentralizedExchangeNetwork;
    let usdc: Contract;
    let deployer: HardhatEthersSigner;
    let partner: HardhatEthersSigner;
    let systemFeeReceiver: HardhatEthersSigner;
    let partnerFeeReceiver: HardhatEthersSigner;

    this.beforeEach(async function () {
        [deployer, partner, systemFeeReceiver, partnerFeeReceiver] = await ethers.getSigners();
        den = await deployDENContract(deployer, partner, systemFeeReceiver, partnerFeeReceiver, partnerFeeNumerator);
        usdc = await ethers.getContractAt(usdcAbi, stableTokenAddress);
    });

    it("should deploy the DEN contract", async function () {
        expect(den).to.not.be.undefined;
    });

    it("should set the correct wrapped ETH address", async function () {
        expect(await den.WETH()).to.equal(wrappedEthAddress);
    });

    it("should set the correct partner address", async function () {
        expect(await den.partner()).to.equal(partner.address);
    });

    it("should set the correct system fee receiver address", async function () {
        expect(await den.systemFeeReceiver()).to.equal(systemFeeReceiver.address);
    });

    it("should set the correct partner fee receiver address", async function () {
        expect(await den.partnerFeeReceiver()).to.equal(partnerFeeReceiver.address);
    });

    it("should set the correct partner fee numerator", async function () {
        expect(await den.partnerFeeNumerator()).to.equal(partnerFeeNumerator);
    });

    it("should get USDC v2 pool from Uniswap v2 router", async function () {
        const v2PoolAddress = await den.getV2PoolFromRouter(uniswapV2RouterOnBase, stableTokenAddress, wrappedEthAddress);
        expect(v2PoolAddress).to.equal(uniswapV2USDCPool);
    });

    it("should have USDC v2 pool supported", async function () {
        expect(await den.isPoolSupported(uniswapV2USDCPool)).to.be.true;
    });

    it("should get USDC v3 pool with a fee of 0.3% from Uniswap v3 router", async function () {
        const v3PoolAddress = await den.getV3PoolFromFactory(uniswapV3FactoryOnBase, stableTokenAddress, wrappedEthAddress, 3000);
        expect(v3PoolAddress).to.equal(uniswapV3USDCWithFee3000PoolOnBase);
    });

    it("Should have the USDC v3 pool with a fee of 0.3% supported", async function () {
        expect(await den.isPoolSupported(uniswapV3USDCWithFee3000PoolOnBase)).to.be.true;
    });

    it("Deployer should have starting ETH balance", async function () {
        const balance = await ethers.provider.getBalance(deployer.address);
        expect(balance).to.be.gt(0);
    });

    it("Should estimate amount out for swapping ETH for USDC on Uniswap v3 using the DEN contract", async function () {
        const swapAmount = ethers.parseEther(swapETHForUSDCAmount);
        const amountOut = await den.estimateAmountOut(
            uniswapV3USDCWithFee3000PoolOnBase,
            wrappedEthAddress,
            swapAmount
        );
        expect(amountOut).to.be.gt(0);
    });

    it("Should swap ETH for USDC on Uniswap v3 using the DEN contract", async function () {
        const systemFeeStartingBalance = await ethers.provider.getBalance(systemFeeReceiver.address);
        const partnerFeeStartingBalance = await ethers.provider.getBalance(partnerFeeReceiver.address);
        const swapAmount = ethers.parseEther(swapETHForUSDCAmount);
        expect(await den.swapETHForToken(
            uniswapV3USDCWithFee3000PoolOnBase,
            stableTokenAddress,
            100,
            {
                value: swapAmount, // Set msg.value for ETH to be sent
            },
        )).to.not.be.reverted;
        const systemFeeEndingBalance = await ethers.provider.getBalance(systemFeeReceiver.address);
        const partnerFeeEndingBalance = await ethers.provider.getBalance(partnerFeeReceiver.address);
        expect(systemFeeEndingBalance).to.be.gt(systemFeeStartingBalance);
        expect(partnerFeeEndingBalance).to.be.gt(partnerFeeStartingBalance);
        expect(await usdc.balanceOf(deployer.address)).to.be.gt(0);
    });
});
