const { expect } = require("chai");
const { ethers } = require("hardhat");

const e = (n) => ethers.parseEther(String(n));
const MIN = 60;
const DAY = 24 * 60 * 60;
const pass = async (s) => {
  await ethers.provider.send("evm_increaseTime", [Math.floor(s)]);
  await ethers.provider.send("evm_mine");
};

async function deploy() {
  const signers = await ethers.getSigners();
  const [owner, creatorFee, treasury] = signers;
  const u = signers.slice(3);
  const usdt = await (await ethers.getContractFactory("MockUSDT")).deploy();
  const reserve = await (await ethers.getContractFactory("InsurancePool")).deploy(owner.address);
  const token = await (await ethers.getContractFactory("NexauraTokenV2")).deploy(
    owner.address, await usdt.getAddress(), "Nexaura", "NXA", await reserve.getAddress(), treasury.address
  );
  const staking = await (await ethers.getContractFactory("NexauraStakingV2")).deploy(
    owner.address, await usdt.getAddress(), creatorFee.address
  );
  await token.setStakingContract(await staking.getAddress());
  await staking.setTokenAddress(await token.getAddress());
  await reserve.setTokenAddress(await token.getAddress());
  for (const x of u) {
    await usdt.mint(x.address, e(10000));
    await usdt.connect(x).approve(await staking.getAddress(), e(10000));
  }
  return { owner, creatorFee, u, usdt, reserve, token, staking };
}

const join = async (staking, user, ref, amt) => {
  await staking.connect(user).regUser(ref.address);
  await staking.connect(user).makeStake(e(amt));
};
const info = (staking, a) => staking.bonusInfos(a.address);

describe("V2 USD incomes", function () {
  it("claims order principal and ROI above the daily limit without consuming it", async function () {
    const { owner, u, usdt, token, staking } = await deploy();
    const [a] = u;
    await usdt.mint(a.address, e(60000));
    await usdt.connect(a).approve(await staking.getAddress(), e(60000));
    await join(staking, a, owner, 30000);
    await pass(10 * MIN + 30);
    await staking.connect(a).makeStake(e(30000));
    const before = await token.balanceOf(a.address);
    const rate = await token.rateInUSDT();
    await staking.connect(a).claimOrder(1);
    const roi = (await info(staking, a)).roiClaimed;
    const netRoi = roi - (roi * 500n / 10000n) * 2n;
    expect(netRoi * rate / e(1)).to.be.gt(await staking.MAX_DAILY_WITHDRAW());
    expect(await token.balanceOf(a.address)).to.be.gt(before);
    expect(await staking.withdrawnToday(a.address)).to.equal(0n);
    expect((await staking.getUserOrder(a.address, 0)).claimed).to.equal(true);
  });

  it("direct income: 5% of new money, credited in USD", async function () {
    const { owner, u, staking } = await deploy();
    const [a, b] = u;
    await join(staking, a, owner, 100);
    await join(staking, b, a, 500);
    expect((await info(staking, a)).referralGains).to.equal(e(25));
    expect(await staking.capUsedUsd(a.address)).to.equal(e(25));
  });

  it("applies the $10 minimum only to wallet withdrawals", async function () {
    const { owner, creatorFee, u, usdt, token, staking } = await deploy();
    const [a, b, c] = u;
    await join(staking, a, owner, 200);
    await join(staking, b, a, 100); // $5, below the minimum
    await staking.connect(a).claimAll();
    await expect(staking.connect(a).withdrawFromWallet(e(5))).to.be.revertedWith("Below minimum withdrawal");
    expect(await staking.withdrawalWallet(a.address)).to.equal(e(5));
    await join(staking, c, a, 300); // +$15 -> $20
    expect(await staking.claimableReferralGains(a.address)).to.equal(e(15));

    await staking.connect(a).claimAll();
    expect(await staking.withdrawalWallet(a.address)).to.equal(e(20));
    const tokenBefore = await usdt.balanceOf(await token.getAddress());
    const userBefore = await usdt.balanceOf(a.address);
    const feeBefore = await usdt.balanceOf(creatorFee.address);
    await staking.connect(a).withdrawFromWallet(e(20));
    expect((await usdt.balanceOf(a.address)) - userBefore).to.equal(e(18));
    expect((await usdt.balanceOf(creatorFee.address)) - feeBefore).to.equal(e(1));
    expect(tokenBefore - (await usdt.balanceOf(await token.getAddress()))).to.equal(e(19));
    expect(await staking.dailySpotBonusPool()).to.equal(e(1));
    await expect(staking.connect(a).withdrawFromWallet(1)).to.be.revertedWith("Insufficient wallet balance");
  });

  it("pays individual referral income below $10", async function () {
    const { owner, u, usdt, staking } = await deploy();
    const [a, b] = u;
    await join(staking, a, owner, 200);
    await join(staking, b, a, 100);
    const before = await usdt.balanceOf(a.address);
    await staking.connect(a).claimReferralGains();
    expect((await usdt.balanceOf(a.address)) - before).to.equal(e("4.5"));
    expect(await staking.claimableReferralGains(a.address)).to.equal(0n);
  });

  it("order claim: principal+ROI in tokens, 5% creator + 5% spot pool of the ROI, level income in USD", async function () {
    const { owner, u, token, staking } = await deploy();
    const [a, b] = u;
    await join(staking, a, owner, 100);
    await join(staking, b, a, 100);
    await pass(10 * MIN + 30);
    await staking.connect(b).makeStake(e(100)); // recycle
    const poolBefore = await staking.dailySpotBonusPool();
    const balBefore = await token.balanceOf(b.address);
    await staking.connect(b).claimOrder(2);
    const roi = (await info(staking, b)).roiGains;
    expect(roi).to.be.gt(0n);
    const rate = await token.rateInUSDT();
    const roiUsd = (roi * rate) / e(1);
    // spot cut is 5% of the ROI, converted to USD at the live rate
    expect((await staking.dailySpotBonusPool()) - poolBefore).to.be.closeTo(
      (roiUsd * 500n) / 10000n, e("0.0001")
    );
    expect((await info(staking, a)).levelGains).to.equal((roiUsd * 500n) / 10000n);
    expect((await token.balanceOf(b.address)) - balBefore).to.be.gt(0n);
  });

  it("DAO: pool credited to gains in USD, USDT moves to the token contract without touching its reserve", async function () {
    const { owner, u, usdt, token, staking } = await deploy();
    const [a, b] = u;
    await join(staking, a, owner, 100);
    await join(staking, b, a, 600); // a: $600 direct business -> DAO tier 1
    const pool = await staking.DAO_Amount();
    expect(pool).to.equal(e(35)); // 5% of 700
    await pass(7 * MIN + 1);
    const tokenUsdt = await usdt.balanceOf(await token.getAddress());
    const stakingUsdt = await usdt.balanceOf(await staking.getAddress());
    const reserve = await token.internalReserve();
    const supply = await token.totalSupply();

    await staking.distributeDAO();

    expect((await info(staking, a)).daoGains).to.equal(pool);
    expect(await staking.DAO_Amount()).to.equal(0n);
    expect((await usdt.balanceOf(await token.getAddress())) - tokenUsdt).to.equal(pool);
    expect(stakingUsdt - (await usdt.balanceOf(await staking.getAddress()))).to.equal(pool);
    expect(await token.internalReserve()).to.equal(reserve); // no creditReserve
    expect(await token.totalSupply()).to.equal(supply); // no mint

    const before = await usdt.balanceOf(a.address);
    await staking.connect(a).claimDaoGains();
    expect((await usdt.balanceOf(a.address)) - before).to.equal(e("31.5")); // 90% of 35
  });

  it("CTO: pool = tier % of month volume in USD, duplicates paid once, claimable in USDT", async function () {
    const { owner, u, usdt, staking } = await deploy();
    const [a, b] = u;
    await join(staking, a, owner, 1000);
    await join(staking, b, a, 5000); // a: $5000 direct business -> CTO tier 1 (2%)
    expect(await staking.monthVolumeUsd()).to.equal(e(6000));
    await pass(30 * MIN + 1);
    await staking.connect(a).makeStake(e(1000)); // recycle: keeps a inside the 17-day income window
    await staking.distributeCTO([a.address, a.address, b.address]);
    expect((await info(staking, a)).ctoGains).to.equal(e(120)); // 2% of 6000, paid once
    expect((await info(staking, b)).ctoGains).to.equal(0n);
    expect(await staking.monthVolumeUsd()).to.equal(0n);

    const before = await usdt.balanceOf(a.address);
    await staking.connect(a).claimCtoGains();
    expect((await usdt.balanceOf(a.address)) - before).to.equal(e(108));
  });

  describe("spot bonus pool (30% / 70%)", function () {
    // f funds the pool through a claim; p1 has 1 qualifying direct, p2 has 2; f also has 1 (g).
    async function setup() {
      const x = await deploy();
      const [f, g, p1, h1, p2, h2, h3, low, lowDirect] = x.u;
      await join(x.staking, f, x.owner, 100);
      await join(x.staking, g, f, 1000); // f direct income $50
      await x.staking.connect(f).claimReferralGains(); // 5% spot cut = $2.50 -> pool
      await join(x.staking, p1, x.owner, 100);
      await join(x.staking, h1, p1, 50);
      await join(x.staking, p2, x.owner, 100);
      await join(x.staking, h2, p2, 50);
      await join(x.staking, h3, p2, 50);
      await join(x.staking, low, x.owner, 100);
      await join(x.staking, lowDirect, low, 20); // under $50 -> not a qualifier
      return { ...x, f, p1, p2, low };
    }
    const spot = (staking, a) => staking.bonusInfos(a.address).then((b) => b.spotBonusGains);

    it("pays 30% of the pool equally to 1-direct users and 70% equally to 2-direct users", async function () {
      const { staking, f, p1, p2, low } = await setup();
      const pool = await staking.dailySpotBonusPool();
      expect(pool).to.equal(e("2.5"));
      expect(await staking.spotTier(f.address)).to.equal(1n);
      expect(await staking.spotTier(p1.address)).to.equal(1n);
      expect(await staking.spotTier(p2.address)).to.equal(2n);
      expect(await staking.spotTier(low.address)).to.equal(0n);

      await staking.distributeSpotBonus(); // anyone can call; no candidate list

      const share1 = ((pool * 3000n) / 10000n) / 2n; // f and p1
      const share2 = (pool * 7000n) / 10000n; // p2
      expect(await spot(staking, f)).to.equal(share1);
      expect(await spot(staking, p1)).to.equal(share1);
      expect(await spot(staking, p2)).to.equal(share2);
      expect(await spot(staking, low)).to.equal(0n);
      expect(await staking.dailySpotBonusPool()).to.equal(0n);
      await expect(staking.distributeSpotBonus()).to.be.revertedWith("Too soon");
    });

    it("an empty tier's share stays in the pool; the next run only counts new directs", async function () {
      const x = await deploy();
      const [f, g, p1, h1, newDirect] = x.u;
      const { staking, owner } = x;
      await join(staking, f, owner, 100);
      await join(staking, g, f, 1000);
      await staking.connect(f).claimReferralGains(); // pool $2.50, f is tier 1 (g)
      await join(staking, p1, owner, 100);
      await join(staking, h1, p1, 50); // p1 tier 1 too -> nobody in tier 2
      const pool = await staking.dailySpotBonusPool();

      await staking.distributeSpotBonus();
      const share = ((pool * 3000n) / 10000n) / 2n;
      expect(await spot(staking, f)).to.equal(share);
      expect(await staking.dailySpotBonusPool()).to.equal(pool - 2n * share); // the 70% stays

      await pass(DAY + 1);
      await staking.connect(f).makeStake(e(100)); // recycle: keeps f inside the income window
      // old directs no longer count: only f's new direct does
      expect(await staking.spotTier(p1.address)).to.equal(0n);
      await join(staking, newDirect, f, 50);
      expect(await staking.spotTier(f.address)).to.equal(1n);
      const rest = await staking.dailySpotBonusPool();
      await staking.distributeSpotBonus();
      expect(await spot(staking, f)).to.equal(share + (rest * 3000n) / 10000n); // f alone in tier 1
      expect(await spot(staking, p1)).to.equal(share); // p1 not queued again
    });
  });
});
