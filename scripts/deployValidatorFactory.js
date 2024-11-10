const hre = require("hardhat");

async function deployValidatorFactory() {

    const validatorAddress = "0x6fB9417EF7BfadD6ABF7f66Bc05dB540Abf57E2D";
    console.log("Using existing Validator contract address:", validatorAddress);

    console.log("Starting to deploy ValidatorFactory with Validator address as parameter...");
    
    const ValidatorFactory = await hre.ethers.getContractFactory("ValidatorFactory");
    const validatorFactory = await ValidatorFactory.deploy(validatorAddress);
    await validatorFactory.waitForDeployment();
    
    const validatorFactoryAddress = await validatorFactory.getAddress();
    console.log("ValidatorFactory deployed successfully. Address is:", validatorFactoryAddress);
}

deployValidatorFactory()
   .then(({ validatorFactory }) => {
        console.log("Deployment completed.");
        process.exit(0);
    })
   .catch((error) => {
        console.error("Error occurred during deployment:", error);
        process.exit(1);
    });
