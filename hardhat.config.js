require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },

  networks: {
    baseTestnet: {
      url: "https://sepolia.base.org",
      accounts: [`0x${process.env.KEY_TESTNET}`],
    },
  },
};
