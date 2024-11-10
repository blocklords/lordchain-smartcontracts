const hre = require("hardhat");

async function deployValidator() {
    
    console.log("Starting to get contract factory...");

    const Validator = await hre.ethers.getContractFactory("Validator");
    console.log("Contract factory obtained successfully. Starting to deploy contract...");

    const validator = await Validator.deploy();
    console.log("Contract is being deployed. Please wait...");

    await validator.waitForDeployment();
    const address = await validator.getAddress();
    console.log("Validator contract deployed successfully. Address is:", address);
}

deployValidator()
   .then(() => process.exit(0))
   .catch((error) => {
        console.error("Error occurred during deployment:", error);
        process.exit(1);
    });