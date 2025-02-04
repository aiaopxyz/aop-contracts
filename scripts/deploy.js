const { ethers, upgrades } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // Deploy AIVault with proxy
  const AIVault = await ethers.getContractFactory("AIVault");
  console.log("Deploying AIVault...");
  
  // Replace these values with actual addresses for your deployment
  const asset = "0x..."; // Your ERC20 token address
  const revenuePool = "0x..."; // Revenue pool address
  const profitPool = "0x..."; // Profit pool address

  const aiVault = await upgrades.deployProxy(AIVault, [asset, revenuePool, profitPool], {
    initializer: "initialize",
    kind: "uups"
  });

  await aiVault.deployed();

  console.log("AIVault proxy deployed to:", aiVault.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
