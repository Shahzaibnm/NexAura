const { expect } = require("chai");
const { ethers } = require("hardhat");

const DAY = 24 * 60 * 60;
const e = (n) => ethers.parseEther(String(n));

async function pass(seconds) {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine");
}

async function deploy() {
  const [owner, creatorFee, treasury, alice, bob, carol, dave] = await ethers.getSigners();

  const usdt = await (await ethers.getContractFactory("MockUSDT")).deploy();
  const reserve = await (await ethers.getContractFactory("ReservePool")).deploy(
    owner.address,
    await usdt.getAddress()
  );
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

  for (const u of [alice, bob, carol, dave]) {
    await usdt.mint(u.address, e(5000));
    await usdt.connect(u).approve(await staking.getAddress(), e(5000));
  }
  return { owner, alice, bob, carol, dave, usdt, token, staking };
}

// owner -> alice -> bob -> (carol, dave); everyone stakes $100 at day 0.
async function chain(ctx) {
  const { owner, alice, bob, carol, dave, staking } = ctx;
  await staking.connect(alice).regUser(owner.address);
  await staking.connect(alice).makeStake(e(100));
  await staking.connect(bob).regUser(alice.address);
  await staking.connect(bob).makeStake(e(100));
  await staking.connect(carol).regUser(bob.address);
  await staking.connect(carol).makeStake(e(100));
  await staking.connect(dave).regUser(bob.address);
  await staking.connect(dave).makeStake(e(100));
}

describe("NexauraStakingV2 — lock period, fixed ROI, 17-day income window", function () {
  it("nobody can claim an order before the 10-day lock ends", async function () {
    const ctx = await deploy();
    await chain(ctx);
    const { alice, staking } = ctx;

    await pass(9 * DAY + 23 * 3600); // just under 10 days
    await expect(staking.connect(alice).claimOrder(1)).to.be.revertedWith("Order not mature");

    await pass(2 * 3600); // now past 10 days
    await expect(staking.connect(alice).claimOrder(1)).to.emit(staking, "OrderClaimed");
  });

  it("ROI stops at 10 days: claiming at day 40 pays the same 12.5% as claiming at day 10", async function () {
    const ctx = await deploy();
    await chain(ctx);
    const { alice, bob, staking } = ctx;

    const aliceLocked = (await staking.stakeInfos(1)).lockedTokens;
    const bobLocked = (await staking.stakeInfos(2)).lockedTokens;
    expect(aliceLocked).to.equal(bobLocked);

    await pass(10 * DAY + 60);
    await staking.connect(alice).claimOrder(1); // claimed right at maturity
    const aliceRoi = (await staking.bonusInfos(alice.address)).roiGains;

    await pass(30 * DAY); // bob waits until day ~40
    await staking.connect(bob).claimOrder(2);
    const bobRoi = (await staking.bonusInfos(bob.address)).roiGains;

    const expected = (bobLocked * 1250n) / 10000n;
    expect(aliceRoi).to.equal(expected);
    expect(bobRoi).to.equal(expected); // no extra ROI for the 30 days of waiting
  });

  it("no direct income once the upline's last stake is past 10 days + 7 days grace", async function () {
    const ctx = await deploy();
    const { owner, alice, bob, carol, staking } = ctx;
    await staking.connect(alice).regUser(owner.address);
    await staking.connect(alice).makeStake(e(100)); // alice's last stake, day 0
    await staking.connect(bob).regUser(alice.address);
    await staking.connect(carol).regUser(alice.address);

    await staking.connect(bob).makeStake(e(100)); // inside the window
    const before = (await staking.bonusInfos(alice.address)).referralGains;
    expect(before).to.be.gt(0n); // control: income is paid while alice is within the window

    await pass(18 * DAY); // past 17 days
    await staking.connect(carol).makeStake(e(100));
    const after = (await staking.bonusInfos(alice.address)).referralGains;
    expect(after).to.equal(before); // nothing new credited
  });

  it("no level income once the upline's last stake is past 10 days + 7 days grace", async function () {
    const ctx = await deploy();
    await chain(ctx);
    const { alice, carol, dave, staking } = ctx;

    // carol claims on day 12: alice (level 2 above carol) is inside grace, so she is paid
    await pass(12 * DAY);
    await staking.connect(carol).claimOrder(3);
    const inGrace = (await staking.bonusInfos(alice.address)).levelGains;
    expect(inGrace).to.be.gt(0n); // control

    // dave claims on day ~19: alice's last stake is now past 17 days, so she is not paid
    await pass(7 * DAY);
    await staking.connect(dave).claimOrder(4);
    const afterWindow = (await staking.bonusInfos(alice.address)).levelGains;
    expect(afterWindow).to.equal(inGrace);
  });
});
