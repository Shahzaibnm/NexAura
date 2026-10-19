const { expect } = require("chai");
const { ethers } = require("hardhat");

const e = (n) => ethers.parseEther(String(n));

async function deploy() {
  const signers = await ethers.getSigners();
  const [owner, creatorFee, treasury] = signers;
  const u = signers.slice(3);
  const usdt = await (await ethers.getContractFactory("MockUSDT")).deploy();
  const reserve = await (await ethers.getContractFactory("ReservePool")).deploy(owner.address);
  const token = await (await ethers.getContractFactory("NexauraTokenV2")).deploy(
    owner.address, await usdt.getAddress(), "Nexaura", "NXA", treasury.address, await reserve.getAddress()
  );
  const staking = await (await ethers.getContractFactory("NexauraStakingV2")).deploy(
    owner.address, await usdt.getAddress(), creatorFee.address
  );
  await token.setStakingContract(await staking.getAddress());
  await staking.setTokenAddress(await token.getAddress());
  for (const x of u) {
    await usdt.mint(x.address, e(5000));
    await usdt.connect(x).approve(await staking.getAddress(), e(5000));
  }
  return { owner, u, token, staking };
}

async function join(staking, user, referral, amount) {
  await staking.connect(user).regUser(referral.address);
  await staking.connect(user).makeStake(e(amount));
}

const spot = async (staking, a) => (await staking.bonusInfos(a.address)).spotBonusGains;
// tokens worth `usd` at the live rate (rate after the join tx == rate when the bonus was paid)
const tokensFor = async (token, usd) => (e(usd) * e(1)) / (await token.rateInUSDT());

describe("spot bonus on join", function () {
  it("50 + 20 (one under $50): no bonus", async function () {
    const { owner, u, staking } = await deploy();
    const [up, a, b] = u;
    await join(staking, up, owner, 100);
    await join(staking, a, up, 50);
    await join(staking, b, up, 20);
    expect(await spot(staking, up)).to.equal(0n);
  });

  it("50 + 100 same day: 5% of both = $7.5 worth of tokens", async function () {
    const { owner, u, token, staking } = await deploy();
    const [up, a, b] = u;
    await join(staking, up, owner, 100);
    await join(staking, a, up, 50);
    expect(await spot(staking, up)).to.equal(0n);
    await join(staking, b, up, 100);
    const got = await spot(staking, up);
    console.log("      50+100 bonus tokens:", ethers.formatEther(got), "(= $7.5 at live rate)");
    expect(got).to.equal(await tokensFor(token, 7.5));
  });

  it("50, 30, then 70 same day: the 70 is the 2nd $50+ join -> 5% of 50+70 = $6", async function () {
    const { owner, u, token, staking } = await deploy();
    const [up, a, b, c] = u;
    await join(staking, up, owner, 100);
    await join(staking, a, up, 50);
    await join(staking, b, up, 30);
    expect(await spot(staking, up)).to.equal(0n);
    await join(staking, c, up, 70);
    const got = await spot(staking, up);
    console.log("      50,30,70 bonus tokens:", ethers.formatEther(got), "(= $6 at live rate)");
    expect(got).to.equal(await tokensFor(token, 6));
  });

  it("a 3rd $50+ join in the same window pays nothing more", async function () {
    const { owner, u, staking } = await deploy();
    const [up, a, b, c] = u;
    await join(staking, up, owner, 100);
    await join(staking, a, up, 50);
    await join(staking, b, up, 100);
    const before = await spot(staking, up);
    await join(staking, c, up, 100);
    expect(await spot(staking, up)).to.equal(before);
  });

  it("$25 is not a valid package (must be a multiple of $10)", async function () {
    const { owner, u, staking } = await deploy();
    await staking.connect(u[0]).regUser(owner.address);
    await expect(staking.connect(u[0]).makeStake(e(25))).to.be.revertedWith("Invalid package amount");
  });
});
