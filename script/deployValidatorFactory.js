const hre = require("hardhat");

async function deployValidatorFactory() {
    console.log("Starting to deploy Validator...");
    const Validator = await hre.ethers.getContractFactory("Validator");
    const validator = await Validator.deploy();
    await validator.waitForDeployment();
    const validatorAddress = await validator.getAddress();
    console.log("Validator deployed successfully. Address is:", validatorAddress);

    console.log("Starting to deploy ValidatorFactory with Validator address as parameter...");
    const ValidatorFactory = await hre.ethers.getContractFactory("ValidatorFactory");
    const validatorFactory = await ValidatorFactory.deploy(validatorAddress);
    await validatorFactory.waitForDeployment();
    const validatorFactoryAddress = await validatorFactory.getAddress();
    console.log("ValidatorFactory deployed successfully. Address is:", validatorFactoryAddress);

    return { validator, validatorFactory };
}

deployValidatorFactory()
   .then(({ validator, validatorFactory }) => {
        console.log("Deployment completed.");
        process.exit(0);
    })
   .catch((error) => {
        console.error("Error occurred during deployment:", error);
        process.exit(1);
    });