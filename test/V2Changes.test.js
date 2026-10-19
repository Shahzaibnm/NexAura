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
  const reserve = await (await ethers.getContractFactory("ReservePool")).deploy(owner.address);
  const token = await (await ethers.getContractFactory("NexauraTokenV2")).deploy(
    owner.address, await usdt.getAddress(), "Nexaura", "NXA", treasury.address, await reserve.getAddress()
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
    const worth = await usdOf(token, (await info(staking, a)).referralGains);
    expect(worth).to.be.closeTo(e(20), e("0.000001"));

    await join(staking, c, a, 1000); // 2 directs -> 3x = $30, only $10 more room
    expect(await staking.capOf(a.address)).to.equal(e(30));
    expect(await staking.capUsedUsd(a.address)).to.equal(e(30));

    const before = await info(staking, a);
    await join(staking, d, a, 1000); // cap full: nothing more
    const after = await info(staking, a);
    expect(after.referralGains).to.equal(before.referralGains);
    expect(await staking.capUsedUsd(a.address)).to.equal(e(30));
  });

  it("income withdrawal: no mint, 5% creator + 5% spot pool kept, 90% to user", async function () {
    const { owner, creatorFee, u, token, staking } = await deploy();
    const [a, b] = u;
    await join(staking, a, owner, 100);
    await join(staking, b, a, 300); // direct income $15
    const amount = await staking.claimableReferralGains(a.address);
    expect(await usdOf(token, amount)).to.be.closeTo(e(15), e("0.000001"));
    const creator = (amount * 500n) / 10000n;
    const supply = await token.totalSupply();
    const feeBefore = await token.balanceOf(creatorFee.address);
    const poolBefore = await staking.dailySpotBonusPool();

    await staking.connect(a).claimReferralGains();

    expect(await token.balanceOf(a.address)).to.equal(amount - 2n * creator);
    expect(await token.balanceOf(creatorFee.address) - feeBefore).to.equal(creator);
    expect(await staking.dailySpotBonusPool() - poolBefore).to.equal(creator);
    expect(await token.totalSupply()).to.equal(supply);
  });

  it("reserve top-up: staking short of tokens pulls the shortfall from the reserve pool, no burn", async function () {
    const { owner, sink, u, token, staking, reserve } = await deploy();
    const [a, b] = u;
    await join(staking, a, owner, 100);
    await join(staking, b, a, 300);
    const sAddr = await staking.getAddress();
    await ethers.provider.send("hardhat_impersonateAccount", [sAddr]);
    await ethers.provider.send("hardhat_setBalance", [sAddr, "0x56BC75E2D63100000"]);
    const s = await ethers.getSigner(sAddr);
    const bal = await token.balanceOf(sAddr);
    await token.connect(s).transfer(await reserve.getAddress(), e(100)); // staking sender: no burn
    await token.connect(s).transfer(sink.address, bal - e(100)); // drain staking to 0
    expect(await token.balanceOf(sAddr)).to.equal(0n);

    const amount = await staking.claimableReferralGains(a.address);
    const need = amount - 2n * ((amount * 500n) / 10000n) + (amount * 500n) / 10000n; // net + creator
    // allowance too small -> reverts
    await reserve.approveSpender(sAddr, need - 1n);
    await expect(staking.connect(a).claimReferralGains()).to.be.revertedWith(
      "NexauraToken: transfer amount exceeds allowance"
    );
    await reserve.approveSpender(sAddr, need);
    const poolBefore = await token.balanceOf(await reserve.getAddress());
    await staking.connect(a).claimReferralGains();
    expect(poolBefore - (await token.balanceOf(await reserve.getAddress()))).to.equal(need); // exact, no burn
    expect(await token.balanceOf(a.address)).to.equal(amount - 2n * ((amount * 500n) / 10000n));
  });

  it("level income: first upline gets 5% of the claimer's ROI, second 3%", async function () {
    const { owner, u, staking } = await deploy();
    const [a, b, c] = u;
    await join(staking, a, owner, 100);
    await join(staking, b, a, 100);
    await join(staking, c, b, 100);
    await pass(10 * MIN + 30);
    await staking.connect(c).makeStake(e(100)); // recycle
    await staking.connect(c).claimOrder(3);
    const roi = (await info(staking, c)).roiGains;
    expect(roi).to.be.gt(0n);
    expect((await info(staking, b)).levelGains).to.equal((roi * 500n) / 10000n); // level 1 = 5%
    expect((await info(staking, a)).levelGains).to.equal((roi * 300n) / 10000n); // level 2 = 3%
  });

  describe("rank (Starter: $50 self, 3 directs, $2,500 match = $1,250 strong + $1,250 other)", function () {
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
      const { a, token, staking } = await tree(1000, 300, 700, 700);
      await pass(9 * MIN + 20); // 9 rank-days
      await staking.connect(a).claimTeamGrowthGains();
      const claimed = (await info(staking, a)).teamGrowthClaimed;
      expect(await usdOf(token, claimed)).to.be.closeTo(e("11.25"), e("0.001"));
    });

    it("small amount is blocked by the $10 minimum withdrawal", async function () {
      const { a, staking } = await tree(1000, 300, 700, 700);
      await pass(3 * MIN + 20); // ~$3.75
      await expect(staking.connect(a).claimTeamGrowthGains()).to.be.revertedWith("Below minimum withdrawal");
    });

    it("stops 17 days after the newest order (16 whole days = $20)", async function () {
      const { a, token, staking } = await tree(1000, 300, 700, 700);
      await pass(40 * MIN);
      await staking.connect(a).claimTeamGrowthGains();
      const claimed = (await info(staking, a)).teamGrowthClaimed;
      expect(await usdOf(token, claimed)).to.be.closeTo(e(20), e("0.001"));
      await pass(10 * MIN); // still nothing new
      await expect(staking.connect(a).claimTeamGrowthGains()).to.be.revertedWith("Nothing to claim");
    });
  });
});
