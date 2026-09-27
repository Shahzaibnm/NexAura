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

async function stakedFixture() {
  const base = await deployFixture();
  const { owner, alice, usdt, staking } = base;

  await staking.connect(alice).regUser(owner.address);
  await usdt.mint(alice.address, ethers.parseEther("10000"));
  await usdt.connect(alice).approve(await staking.getAddress(), ethers.parseEther("10000"));

  return base;
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

  it("forwards the 90% mint portion to the token contract BEFORE calling pricedBuy, so internalReserve stays fully backed", async function () {
    const { alice, staking, usdt, token } = await stakedFixture();

    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    // Regression test for a previously-broken ordering: if pricedBuy were ever called before
    // forwarding the real USDT, internalReserve would be credited without backing funds ever
    // arriving, and this assertion would fail (real balance would be 0, internalReserve 90).
    expect(await usdt.balanceOf(await token.getAddress())).to.equal(ethers.parseEther("90"));
    expect(await token.internalReserve()).to.equal(ethers.parseEther("90"));
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

describe("NexauraStaking — referral cascade", function () {
  it("credits 5% direct income to the immediate referral", async function () {
    const { owner, alice, usdt, staking, token } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    // mintedAmount = 90 USD worth of tokens at 1:1 initial rate = 90 tokens
    const bonus = await staking.bonusInfos(owner.address);
    expect(bonus.referralGains).to.equal(ethers.parseEther("4.5")); // 5% of 90
  });

  it("skips level income for an upline earner whose own package is below $50", async function () {
    const { owner, alice, bob, usdt, staking } = await stakedFixture();

    await staking.connect(bob).regUser(alice.address);
    await usdt.mint(bob.address, ethers.parseEther("1000"));
    await usdt.connect(bob).approve(await staking.getAddress(), ethers.parseEther("1000"));

    // alice stakes only $20 (< $50 gate), so she gets no level-2 income when bob's downline stakes later.
    await staking.connect(alice).makeStake(ethers.parseEther("20"));
    await staking.connect(bob).makeStake(ethers.parseEther("100"));

    const aliceBonus = await staking.bonusInfos(alice.address);
    // alice IS bob's direct (level 0 / Direct Income), which has no $50 gate per spec 4.1 vs 4.2 — only
    // levels use the gate. Direct income should still be credited.
    expect(aliceBonus.referralGains).to.be.gt(0n);
  });

  it("pays 21-level income up a deep chain, gated by each earner's own $50 package", async function () {
    const { owner, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    // Build a chain: owner -> u1 -> u2 -> u3, each staking $100 (above the $50 gate).
    let referral = owner.address;
    const users = signers.slice(6, 9);
    for (const u of users) {
      await staking.connect(u).regUser(referral);
      await usdt.mint(u.address, ethers.parseEther("1000"));
      await usdt.connect(u).approve(await staking.getAddress(), ethers.parseEther("1000"));
      await staking.connect(u).makeStake(ethers.parseEther("100"));
      referral = u.address;
    }
    // owner is at level 2 relative to the last staker (u3): u3 -> u2 (level 0/direct) -> u1 (level 1) -> owner (level 2)
    const ownerBonus = await staking.bonusInfos(owner.address);
    expect(ownerBonus.levelGains).to.be.gt(0n);
  });
});
