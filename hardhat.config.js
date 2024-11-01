require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.28",

  networks: {
    baseTestnet: {
      url: "https://sepolia.base.org",
      accounts: [`0x${process.env.KEY_TESTNET}`], // 用你的私钥替换
    },
  },
};
