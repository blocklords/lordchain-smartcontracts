const hre = require("hardhat");

async function deployGovernance() {
    console.log("Starting to get contract factory...");

    const Governance = await hre.ethers.getContractFactory("Governance");
    console.log("Governance contract factory obtained successfully. Starting to deploy contract...");

    const [deployer] = await hre.ethers.getSigners();
    console.log("Deploying contract from address:", deployer.address);

    const masterValidatorAddress = "0xCf083e2f84f432CD388834168142Dd170C297910";
    const validatorFactoryAddress = "0xFb5F6187Ab905BD224732549705B03cB89163e94";

    const governance = await Governance.deploy(masterValidatorAddress, validatorFactoryAddress, deployer.address);
    await governance.waitForDeployment();
    
    const governanceAddress = await governance.getAddress();
    console.log("Governance contract deployed successfully. Address is:", governanceAddress);
}

deployGovernance()
   .then((governance) => {
        console.log("Governance deployment completed.");
        process.exit(0);
    })
   .catch((error) => {
        console.error("Error occurred during deployment:", error);
        process.exit(1);
    });
