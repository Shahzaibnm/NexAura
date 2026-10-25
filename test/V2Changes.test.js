const { expect } = require("chai");
const { ethers } = require("hardhat");

const e = (n) => ethers.parseEther(String(n));
const MIN = 60;
const pass = async (s) => {
  await ethers.provider.send("evm_increaseTime", [Math.floor(s)]);
  await ethers.provider.send("evm_mine");
};

async function deploy() {
  const signers = await ethers.getSigners();
  const [owner, creatorFee, treasury, sink] = signers;
  const u = signers.slice(4);
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
    await usdt.mint(x.address, e(5000));
    await usdt.connect(x).approve(await staking.getAddress(), e(5000));
  }
  return { owner, creatorFee, sink, u, usdt, reserve, token, staking };
}

const join = async (staking, user, ref, amt) => {
  await staking.connect(user).regUser(ref.address);
  await staking.connect(user).makeStake(e(amt));
};
const info = (staking, a) => staking.bonusInfos(a.address);
const usdOf = async (token, tokens) => (tokens * (await token.rateInUSDT())) / e(1);

describe("V2 changes", function () {
  it("per-user serials: getUserOrderCount / getUserOrder(index)", async function () {
    const { owner, u, staking } = await deploy();
    const [a, b] = u;
    await join(staking, a, owner, 50);
    await join(staking, b, owner, 100);
    await staking.connect(a).makeStake(e(60));
    await staking.connect(a).makeStake(e(70));
    expect(await staking.getUserOrderCount(a.address)).to.equal(3n);
    expect(await staking.getUserOrderCount(b.address)).to.equal(1n);
    const o0 = await staking.getUserOrder(a.address, 0);
    const o1 = await staking.getUserOrder(a.address, 1);
    const o2 = await staking.getUserOrder(a.address, 2);
    expect([o0.orderId, o1.orderId, o2.orderId]).to.deep.equal([1n, 3n, 4n]); // b's order is global id 2
    expect([o0.usdAmount, o1.usdAmount, o2.usdAmount]).to.deep.equal([e(50), e(60), e(70)]);
    expect((await staking.getUserOrder(b.address, 0)).orderId).to.equal(2n);
    await expect(staking.getUserOrder(a.address, 3)).to.be.revertedWith("Invalid serial");
  });

  it("claimOrder: principal = USD at the LIVE rate, ROI 12.5% of it, paid from balance with no mint", async function () {
    const { owner, creatorFee, u, token, staking } = await deploy();
    const [a] = u;
    await join(staking, a, owner, 100);
    await pass(10 * MIN + 30);
    await staking.connect(a).makeStake(e(100)); // recycle
    const rate = await token.rateInUSDT();
    expect(rate).to.be.gt(e(1)); // price rose from the 9% reserve credit
    const principal = (e(100) * e(1)) / rate;
    const roi = (principal * 1250n) / 10000n;
    const cut = (roi * 500n) / 10000n;
    const supplyBefore = await token.totalSupply();
    const feeBefore = await token.balanceOf(creatorFee.address);
    const balBefore = await token.balanceOf(a.address);

    await staking.connect(a).claimOrder(1);

    expect(await token.balanceOf(a.address) - balBefore).to.equal(principal + roi - 2n * cut);
    expect(await token.balanceOf(creatorFee.address) - feeBefore).to.equal(cut);
    expect(await token.totalSupply()).to.equal(supplyBefore); // nothing minted
    expect((await info(staking, a)).roiGains).to.equal(roi);
    await expect(staking.connect(a).claimOrder(1)).to.be.revertedWith("Already claimed");
    console.log("      live rate:", ethers.formatEther(rate), "principal tokens:", ethers.formatEther(principal));
  });

  it("cap is USD: 2x with <2 directs, 3x with 2+, income cut to the USD room, independent of price", async function () {
    const { owner, u, token, staking } = await deploy();
    const [a, b, c, d] = u;
    await join(staking, a, owner, 10); // 1 direct later -> 2x = $20
    expect(await staking.capOf(a.address)).to.equal(e(20));
    await join(staking, b, a, 1000); // direct income would be $50 -> cut to $20
    expect(await staking.capOf(a.address)).to.equal(e(20)); // price moved, cap did not
    expect(await staking.capUsedUsd(a.address)).to.equal(e(20));
    expect((await info(staking, a)).referralGains).to.equal(e(20)); // direct income is credited in USD

    await join(staking, c, a, 1000); // 2 directs -> 3x = $30, only $10 more room
    expect(await staking.capOf(a.address)).to.equal(e(30));
    expect(await staking.capUsedUsd(a.address)).to.equal(e(30));

    const before = await info(staking, a);
    await join(staking, d, a, 1000); // cap full: nothing more
    const after = await info(staking, a);
    expect(after.referralGains).to.equal(before.referralGains);
    expect(await staking.capUsedUsd(a.address)).to.equal(e(30));
  });

  it("income withdrawal: USDT paid from the token contract, 5% creator + 5% to the spot pool, 90% to user", async function () {
    const { owner, creatorFee, u, usdt, token, staking } = await deploy();
    const [a, b] = u;
    await join(staking, a, owner, 100);
    await join(staking, b, a, 300); // direct income $15
    const amount = await staking.claimableReferralGains(a.address);
    expect(amount).to.equal(e(15));
    const tokenUsdt = await usdt.balanceOf(await token.getAddress());
    const reserve = await token.internalReserve();
    const supply = await token.totalSupply();
    const feeBefore = await usdt.balanceOf(creatorFee.address);
    const userBefore = await usdt.balanceOf(a.address);
    const poolBefore = await staking.dailySpotBonusPool();

    await staking.connect(a).claimReferralGains();
    await staking.connect(a).withdrawFromWallet(await staking.withdrawalWallet(a.address));

    expect((await usdt.balanceOf(a.address)) - userBefore).to.equal(e("13.5"));
    expect((await usdt.balanceOf(creatorFee.address)) - feeBefore).to.equal(e("0.75"));
    expect((await staking.dailySpotBonusPool()) - poolBefore).to.equal(e("0.75"));
    expect(tokenUsdt - (await usdt.balanceOf(await token.getAddress()))).to.equal(e("14.25")); // creator + net leave
    expect(await token.internalReserve()).to.equal(reserve); // reserve untouched
    expect(await token.totalSupply()).to.equal(supply);
    expect((await info(staking, a)).referralClaimed).to.equal(e(15));
  });

  it("reserve top-up: order claim with staking short of tokens pulls the shortfall from the insurance pool, no burn", async function () {
    const { owner, creatorFee, sink, u, token, staking, reserve } = await deploy();
    const [a] = u;
    await join(staking, a, owner, 100);
    await pass(10 * MIN + 30);
    await staking.connect(a).makeStake(e(100)); // recycle
    const sAddr = await staking.getAddress();
    await ethers.provider.send("hardhat_impersonateAccount", [sAddr]);
    await ethers.provider.send("hardhat_setBalance", [sAddr, "0x56BC75E2D63100000"]);
    const s = await ethers.getSigner(sAddr);
    const bal = await token.balanceOf(sAddr);
    await token.connect(s).transfer(await reserve.getAddress(), e(100)); // staking sender: no burn
    await token.connect(s).transfer(sink.address, bal - e(100)); // drain staking to 0
    expect(await token.balanceOf(sAddr)).to.equal(0n);

    const rate = await token.rateInUSDT();
    const principal = (e(100) * e(1)) / rate;
    const roi = (principal * 1250n) / 10000n;
    const cut = (roi * 500n) / 10000n;
    const need = principal + roi - cut; // net + creator cut
    await reserve.approveSpender(sAddr, need - 1n);
    await expect(staking.connect(a).claimOrder(1)).to.be.revertedWith(
      "NexauraToken: transfer amount exceeds allowance"
    );
    await reserve.approveSpender(sAddr, need);
    const poolBefore = await token.balanceOf(await reserve.getAddress());
    await staking.connect(a).claimOrder(1);
    expect(poolBefore - (await token.balanceOf(await reserve.getAddress()))).to.equal(need); // exact, no burn
    expect(await token.balanceOf(a.address)).to.equal(principal + roi - 2n * cut);
  });

  it("level income: first upline gets 5% of the claimer's ROI, second 3%", async function () {
    const { owner, u, token, staking } = await deploy();
    const [a, b, c] = u;
    await join(staking, a, owner, 100);
    await join(staking, b, a, 100);
    await join(staking, c, b, 100);
    await pass(10 * MIN + 30);
    await staking.connect(c).makeStake(e(100)); // recycle
    await staking.connect(c).claimOrder(3);
    const roi = (await info(staking, c)).roiGains;
    expect(roi).to.be.gt(0n);
    const roiUsd = await usdOf(token, roi); // level income is credited in USD
    expect((await info(staking, b)).levelGains).to.equal((roiUsd * 500n) / 10000n); // level 1 = 5%
    expect((await info(staking, a)).levelGains).to.equal((roiUsd * 300n) / 10000n); // level 2 = 3%
  });

  it("configures all 11 ranks with the supplied requirements and incentives", async function () {
    const { staking } = await deploy();
    const tiers = [
      [50, 3, 2500, 400, "1.25"],
      [100, 6, 5000, 600, "3.75"],
      [200, 9, 7500, 800, "7.5"],
      [300, 12, 10000, 1000, "12.5"],
      [500, 15, 25000, 1200, "37.5"],
      [700, 18, 50000, 1400, "87.5"],
      [900, 25, 100000, 1600, "200"],
      [1200, 30, 250000, 1800, "562.5"],
      [2500, 35, 500000, 2000, "1250"],
      [5000, 40, 1000000, 2500, "3125"],
      [10000, 60, 2500000, 2800, "8750"],
    ];
    for (let i = 0; i < tiers.length; i++) {
      const [self, directs, business, incentive, daily] = tiers[i];
      const tier = await staking.rankTiers(i);
      expect(tier.selfStake).to.equal(e(self));
      expect(tier.directsCount).to.equal(BigInt(directs));
      expect(tier.teamBusiness).to.equal(e(business));
      expect(tier.incentiveBp).to.equal(BigInt(incentive));
      const dailyUsd = tier.teamBusiness * (await staking.RANK_DAILY_BP()) / 10000n
        * tier.incentiveBp / 10000n;
      expect(dailyUsd).to.equal(e(daily));
    }
  });

  describe("rank (Silver: $50 self, 3 directs, $2,500 match = $1,250 strong + $1,250 other)", function () {
    async function tree(strongStake, strongChild, d2, d3) {
      const x = await deploy();
      const [a, d1, d1c, e2, e3] = x.u;
      await join(x.staking, a, x.owner, 100);
      await join(x.staking, d1, a, strongStake);
      if (strongChild) await join(x.staking, d1c, d1, strongChild);
      await join(x.staking, e2, a, d2);
      await join(x.staking, e3, a, d3);
      return { ...x, a, d1 };
    }
    const rankOf = async (staking, a) => (await staking.userInfos(a.address)).rank;

    it("leg helpers + rank 1 when both sides >= $1,250", async function () {
      const { a, d1, staking } = await tree(1000, 300, 700, 700);
      const [leg, biz] = await staking.getStrongestLeg(a.address);
      expect(leg).to.equal(d1.address);
      expect(biz).to.equal(e(1300));
      expect(await staking.getTeamsExcludingStrongest(a.address)).to.equal(e(1400));
      expect(await rankOf(staking, a)).to.equal(1);
    });

    it("no rank if strongest leg < $1,250", async function () {
      const { a, staking } = await tree(1000, 0, 700, 700);
      expect(await rankOf(staking, a)).to.equal(0);
    });

    it("no rank if other legs < $1,250", async function () {
      const { a, staking } = await tree(1000, 300, 100, 100);
      expect(await rankOf(staking, a)).to.equal(0);
    });

    it("daily reward = 1.25% x 2,500 x 4% = $1.25/day, claimable via claimTeamGrowthGains", async function () {
      const { a, usdt, staking } = await tree(1000, 300, 700, 700);
      await pass(9 * MIN + 20); // 9 rank-days
      const before = await usdt.balanceOf(a.address);
      await staking.connect(a).claimTeamGrowthGains();
      const claimed = (await info(staking, a)).teamGrowthClaimed;
      expect(claimed).to.equal(e("11.25")); // credited and claimed in USD
      expect((await usdt.balanceOf(a.address)) - before).to.equal(0n);
      expect(await staking.withdrawalWallet(a.address)).to.equal(e("11.25"));
    });

    it("allows rank income claims below $10", async function () {
      const { a, usdt, staking } = await tree(1000, 300, 700, 700);
      await pass(3 * MIN + 20); // ~$3.75
      const before = await usdt.balanceOf(a.address);
      await staking.connect(a).claimTeamGrowthGains();
      expect((await usdt.balanceOf(a.address)) - before).to.equal(0n);
      expect(await staking.withdrawalWallet(a.address)).to.equal(e("3.75"));
    });

    it("stops 17 days after the newest order (16 whole days = $20)", async function () {
      const { a, staking } = await tree(1000, 300, 700, 700);
      await pass(40 * MIN);
      await staking.connect(a).claimTeamGrowthGains();
      const claimed = (await info(staking, a)).teamGrowthClaimed;
      expect(claimed).to.equal(e(20));
      await pass(10 * MIN); // still nothing new
      await expect(staking.connect(a).claimTeamGrowthGains()).to.be.revertedWith("Nothing to claim");
    });
  });
});
