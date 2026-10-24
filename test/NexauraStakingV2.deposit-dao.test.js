const { expect } = require("chai");
const { ethers } = require("hardhat");

const DAY = 24 * 60 * 60;
const e = (n) => ethers.parseEther(String(n));

async function pass(seconds) {
  await ethers.provider.send("evm_increaseTime", [Math.floor(seconds)]);
  await ethers.provider.send("evm_mine");
}

// 17 funded users in u[0..16]; first stake of $100 mints 81 tokens at the initial $1 rate.
async function deploy() {
  const signers = await ethers.getSigners();
  const [owner, creatorFee, treasury] = signers;
  const u = signers.slice(3);

  const usdt = await (await ethers.getContractFactory("MockUSDT")).deploy();
  const reserve = await (await ethers.getContractFactory("InsurancePool")).deploy(owner.address);
  const token = await (await ethers.getContractFactory("NexauraTokenV2")).deploy(
    owner.address,
    await usdt.getAddress(),
    "Nexaura",
    "NXA",
    treasury.address,
    await reserve.getAddress()
  );
  const staking = await (await ethers.getContractFactory("NexauraStakingV2")).deploy(
    owner.address,
    await usdt.getAddress(),
    creatorFee.address
  );
  await token.setStakingContract(await staking.getAddress());
  await staking.setTokenAddress(await token.getAddress());

  for (const x of u) {
    await usdt.mint(x.address, e(5000));
    await usdt.connect(x).approve(await staking.getAddress(), e(5000));
  }
  return { owner, creatorFee, treasury, u, usdt, reserve, token, staking };
}

async function join(staking, user, referral, amount) {
  await staking.connect(user).regUser(referral.address);
  await staking.connect(user).makeStake(e(amount));
}

describe("NexauraStakingV2 revised deposit and DAO funding", function () {
  it("splits USDT 90/5/5 and only mints locked user tokens", async function () {
    const { owner, creatorFee, u, usdt, token, staking } = await deploy();
    await join(staking, u[0], owner, 100);
    expect(await usdt.balanceOf(creatorFee.address)).to.equal(e(5));
    expect(await usdt.balanceOf(await staking.getAddress())).to.equal(e(5));
    expect(await usdt.balanceOf(await token.getAddress())).to.equal(e(90));
    expect(await token.internalReserve()).to.equal(e(90));
    expect(await token.totalSupply()).to.equal(e(81));
    expect(await token.balanceOf(await staking.getAddress())).to.equal(e(81));
    expect(await token.balanceOf(creatorFee.address)).to.equal(0n);
    expect(await token.balanceOf(await token.getAddress())).to.equal(0n);
    expect(await token.balanceOf(u[0].address)).to.equal(0n);
    expect(await staking.DAO_Amount()).to.equal(e(5));
  });

  it("mints DAO tokens at distribution with backing, and claims do not mint again", async function () {
    const { owner, u, usdt, token, staking } = await deploy();
    await join(staking, u[0], owner, 100);
    await join(staking, u[1], u[0], 500);
    const pool = await staking.DAO_Amount();
    const rate = await token.rateInUSDT();
    const tokens = pool * e(1) / rate;
    const backing = (tokens * rate + e(1) - 1n) / e(1);
    const supply = await token.totalSupply();
    const reserve = await token.internalReserve();
    const interval = Number(await staking.DAO_DIST_INTERVAL());
    await pass(interval);
    await staking.distributeDAO();
    expect((await staking.bonusInfos(u[0].address)).daoGains).to.equal(tokens);
    expect(await token.totalSupply()).to.equal(supply + tokens);
    expect(await token.internalReserve()).to.equal(reserve + backing);
    expect(await usdt.balanceOf(await staking.getAddress())).to.equal(pool - backing);
    expect(await staking.DAO_Amount()).to.equal(pool - backing);
    const supplyAfter = await token.totalSupply();
    await staking.connect(u[0]).claimDaoGains();
    expect(await token.totalSupply()).to.equal(supplyAfter);
    expect(await token.balanceOf(u[0].address)).to.equal(tokens - tokens * 500n / 10000n * 2n);
  });

  it("retains DAO USDT and mints nothing when nobody qualifies", async function () {
    const { owner, u, usdt, token, staking } = await deploy();
    await join(staking, u[0], owner, 100);
    const supply = await token.totalSupply();
    await pass(Number(await staking.DAO_DIST_INTERVAL()));
    await staking.distributeDAO();
    expect(await staking.DAO_Amount()).to.equal(e(5));
    expect(await usdt.balanceOf(await staking.getAddress())).to.equal(e(5));
    expect(await token.totalSupply()).to.equal(supply);
  });
});
