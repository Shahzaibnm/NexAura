const { expect } = require("chai");
const { ethers } = require("hardhat");

async function deployFixture() {
  const [owner, creatorFee, treasury, alice, bob, carol] = await ethers.getSigners();

  const MockUSDT = await ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();

  const NexauraToken = await ethers.getContractFactory("NexauraToken");
  const token = await NexauraToken.deploy(owner.address, await usdt.getAddress(), "Nexaura", "NXA");

  const NexauraStaking = await ethers.getContractFactory("NexauraStaking");
  const staking = await NexauraStaking.deploy(
    owner.address,
    await usdt.getAddress(),
    creatorFee.address,
    treasury.address
  );

  await token.connect(owner).setStakingContract(await staking.getAddress());
  await staking.connect(owner).setTokenAddress(await token.getAddress());

  return { owner, creatorFee, treasury, alice, bob, carol, usdt, token, staking };
}

describe("NexauraStaking — core", function () {
  it("registers the owner as joined at deploy time", async function () {
    const { owner, staking } = await deployFixture();
    const info = await staking.userInfos(owner.address);
    expect(info.joined).to.equal(true);
  });

  it("regUser requires an already-joined referral", async function () {
    const { alice, bob, staking } = await deployFixture();
    await expect(staking.connect(alice).regUser(bob.address)).to.be.revertedWith("Invalid referral");
  });

  it("regUser succeeds under a joined referral (the owner)", async function () {
    const { owner, alice, staking } = await deployFixture();
    await staking.connect(alice).regUser(owner.address);
    const info = await staking.userInfos(alice.address);
    expect(info.joined).to.equal(true);
    expect(info.referral).to.equal(owner.address);
  });

  it("cannot register twice", async function () {
    const { owner, alice, staking } = await deployFixture();
    await staking.connect(alice).regUser(owner.address);
    await expect(staking.connect(alice).regUser(owner.address)).to.be.revertedWith("Already registered");
  });

  it("only the owner can set the token address and fee addresses", async function () {
    const { alice, staking, token } = await deployFixture();
    await expect(
      staking.connect(alice).setTokenAddress(await token.getAddress())
    ).to.be.revertedWithCustomError(staking, "OwnableUnauthorizedAccount");
    await expect(
      staking.connect(alice).setFeeAddresses(alice.address, alice.address)
    ).to.be.revertedWithCustomError(staking, "OwnableUnauthorizedAccount");
  });
});
