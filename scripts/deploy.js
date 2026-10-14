const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

// Deploys the full NEXAURA system: MockUSDT (a testnet stand-in for real BSC USDT — swap in
// the real USDT address for mainnet), NexauraToken, NexauraStaking, wires them together, and
// writes out the addresses + ABIs the frontend needs.
//
// Usage:
//   npx hardhat run scripts/deploy.js --network localhost   (for local testing)
//   npx hardhat run scripts/deploy.js --network bscTestnet  (real testnet deploy)
async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  console.log("Network:", hre.network.name);

  const MockUSDT = await hre.ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();
  await usdt.waitForDeployment();
  const usdtAddress = await usdt.getAddress();
  console.log("MockUSDT deployed:", usdtAddress);

  // Give the deployer some test USDT to play with in the frontend.
  await (await usdt.mint(deployer.address, hre.ethers.parseEther("100000"))).wait();

  // ponytail: fee/treasury/LP/reserve addresses default to the deployer for a basic testnet
  // deploy. Production deployment should use separate, dedicated addresses (ideally multisigs).
  const NexauraToken = await hre.ethers.getContractFactory("NexauraToken");
  const token = await NexauraToken.deploy(
    deployer.address,
    usdtAddress,
    "Nexaura",
    "NXA",
    deployer.address, // liquidityPoolAddress
    deployer.address // reservePoolAddress
  );
  await token.waitForDeployment();
  const tokenAddress = await token.getAddress();
  console.log("NexauraToken deployed:", tokenAddress);
  const NexauraStaking = await hre.ethers.getContractFactory("NexauraStaking");
  const staking = await NexauraStaking.deploy(
    deployer.address,
    usdtAddress,
    deployer.address // creatorFeeAddress
  );
  await staking.waitForDeployment();
  const stakingAddress = await staking.getAddress();
  console.log("NexauraStaking deployed:", stakingAddress);

  await (await token.setStakingContract(stakingAddress)).wait();
  await (await staking.setTokenAddress(tokenAddress)).wait();
  console.log("Wired token <-> staking contracts");

  // Write addresses + ABIs for the frontend to consume.
  const artifactsDir = path.join(__dirname, "..", "artifacts", "contracts");
  const tokenArtifact = JSON.parse(
    fs.readFileSync(path.join(artifactsDir, "NexauraToken.sol", "NexauraToken.json"))
  );
  const stakingArtifact = JSON.parse(
    fs.readFileSync(path.join(artifactsDir, "NexauraStaking.sol", "NexauraStaking.json"))
  );
  const usdtArtifact = JSON.parse(
    fs.readFileSync(path.join(artifactsDir, "mocks", "MockUSDT.sol", "MockUSDT.json"))
  );

  const outDir = path.join(__dirname, "..", "frontend", "src", "contracts");
  fs.mkdirSync(outDir, { recursive: true });

  fs.writeFileSync(
    path.join(outDir, "addresses.json"),
    JSON.stringify(
      {
        network: hre.network.name,
        chainId: Number((await hre.ethers.provider.getNetwork()).chainId),
        usdt: usdtAddress,
        token: tokenAddress,
        staking: stakingAddress,
      },
      null,
      2
    )
  );
  fs.writeFileSync(
    path.join(outDir, "NexauraToken.json"),
    JSON.stringify(tokenArtifact.abi, null, 2)
  );
  fs.writeFileSync(
    path.join(outDir, "NexauraStaking.json"),
    JSON.stringify(stakingArtifact.abi, null, 2)
  );
  fs.writeFileSync(path.join(outDir, "MockUSDT.json"), JSON.stringify(usdtArtifact.abi, null, 2));

  console.log("Wrote frontend/src/contracts/addresses.json + ABIs");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
