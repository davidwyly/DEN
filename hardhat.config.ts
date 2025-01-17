import dotenv from "dotenv";
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-chai-matchers";

dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      //viaIR: true,
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      chainId: 84532,
      allowUnlimitedContractSize: false,
      forking: {
        url: "https://mainnet.base.org",
      },
    },
    base: {
      chainId: 8453,
      url: "https://mainnet.base.org",
      accounts: [process.env.PRIVATE_KEY as string],
    },
    sepolia: {
      //Base Testnet
      chainId: 80002,
      url: "	https://sepolia.base.org",
      accounts: [process.env.PRIVATE_KEY as string],
    },
  },
  etherscan: {
    apiKey: {
      base: process.env.BASESCAN_API_KEY,
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  mocha: {
    timeout: 40000,
  },
};

export default config;
