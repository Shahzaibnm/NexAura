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

describe("NexauraStaking — makeStake", function () {
  async function stakedFixture() {
    const base = await deployFixture();
    const { owner, alice, usdt, staking } = base;

    await staking.connect(alice).regUser(owner.address);
    await usdt.mint(alice.address, ethers.parseEther("10000"));
    await usdt.connect(alice).approve(await staking.getAddress(), ethers.parseEther("10000"));

    return base;
  }

  it("rejects package amounts that aren't a multiple of $10", async function () {
    const { owner, alice, staking } = await stakedFixture();
    await expect(staking.connect(alice).makeStake(ethers.parseEther("15"))).to.be.revertedWith(
      "Invalid package amount"
    );
  });

  it("rejects package amounts below $10 or above $1000", async function () {
    const { alice, staking } = await stakedFixture();
    await expect(staking.connect(alice).makeStake(ethers.parseEther("0"))).to.be.revertedWith(
      "Invalid package amount"
    );
    await expect(staking.connect(alice).makeStake(ethers.parseEther("1010"))).to.be.revertedWith(
      "Invalid package amount"
    );
  });

  it("pulls USDT, splits 5% creator / 5% DAO / 90% mint, and creates an order", async function () {
    const { alice, creatorFee, staking, usdt } = await stakedFixture();

    const beforeCreator = await usdt.balanceOf(creatorFee.address);
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    const afterCreator = await usdt.balanceOf(creatorFee.address);

    expect(afterCreator - beforeCreator).to.equal(ethers.parseEther("5"));
    expect(await staking.DAO_Amount()).to.equal(ethers.parseEther("5"));

    const info = await staking.userInfos(alice.address);
    expect(info.lastStake).to.equal(ethers.parseEther("100"));

    const order = await staking.stakeInfos(1);
    expect(order.ownerAddress).to.equal(alice.address);
    expect(order.orderValue).to.equal(ethers.parseEther("100"));
    expect(order.isComplete).to.equal(false);
  });

  it("rejects a recycle package smaller than the previous one", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    await expect(staking.connect(alice).makeStake(ethers.parseEther("50"))).to.be.revertedWith(
      "Package must not decrease"
    );
  });

  it("registers the staker under the referral's directs on first stake", async function () {
    const { owner, alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    const directs = await staking.directsOf(owner.address);
    expect(directs).to.include(alice.address);
  });

  it("propagates business volume up the referral chain", async function () {
    const { owner, alice, bob, usdt, staking } = await stakedFixture();

    await staking.connect(bob).regUser(alice.address);
    await usdt.mint(bob.address, ethers.parseEther("1000"));
    await usdt.connect(bob).approve(await staking.getAddress(), ethers.parseEther("1000"));

    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    await staking.connect(bob).makeStake(ethers.parseEther("50"));

    const aliceInfo = await staking.userInfos(alice.address);
    expect(aliceInfo.directBusiness).to.equal(ethers.parseEther("50"));

    const ownerInfo = await staking.userInfos(owner.address);
    expect(ownerInfo.totalTeamBusiness).to.equal(ethers.parseEther("50"));
  });
});
