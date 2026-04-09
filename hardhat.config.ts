import dotenv from "dotenv";
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-chai-matchers";

dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      evmVersion: "cancun",
      optimizer: {
        enabled: true,
        runs: 1,
      },
    },
  },
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      chainId: 31337,
      allowUnlimitedContractSize: true,
      hardfork: "cancun",
      forking: {
        url: "https://mainnet.base.org",
        blockNumber: 28000000,
      },
      chains: {
        8453: {
          hardforkHistory: {
            berlin: 0,
            london: 0,
            merge: 0,
            shanghai: 0,
            cancun: 0,
          },
        },
      },
    },
    base: {
      chainId: 8453,
      url: "https://mainnet.base.org",
      accounts: [process.env.PRIVATE_KEY as string],
    },
    sepolia: {
      //Base Testnet
      chainId: 84532,
      url: "https://sepolia.base.org",
      accounts: [process.env.PRIVATE_KEY as string],
    },
  },
  etherscan: {
    apiKey: process.env.BASESCAN_API_KEY as string,
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  mocha: {
    timeout: 120000,
  },
};

export default config;
