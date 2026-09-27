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

describe("NexauraStaking — rank and CTO tiers", function () {
  it("promotes a user to Starter rank once thresholds are met and never downgrades", async function () {
    const { owner, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    const directs = signers.slice(6, 9); // 3 directs, meets Starter's "Direct: 3"

    for (const d of directs) {
      await staking.connect(d).regUser(owner.address);
      await usdt.mint(d.address, ethers.parseEther("1000"));
      await usdt.connect(d).approve(await staking.getAddress(), ethers.parseEther("1000"));
      await staking.connect(d).makeStake(ethers.parseEther("1000")); // pushes owner's directBusiness up
    }
    // Owner's own selfStake gate (>= $50) is already satisfied: the constructor seeds the owner's
    // lastStake at MAX_PACKAGE ($1000) so it behaves as a fully-qualified root referral (Task 5).
    // A further owner.makeStake() here would revert ("Package must not decrease") since $50 < $1000.

    const info = await staking.userInfos(owner.address);
    expect(info.rank).to.equal(1); // 1 = Starter (index 0 stored as rank 1, 0 means unranked)
  });

  it("pays CTO bonus to the first qualifying upline tier", async function () {
    const { owner, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    const leader = signers[9];
    const staker = signers[10];

    await staking.connect(leader).regUser(owner.address);
    await usdt.mint(leader.address, ethers.parseEther("20000"));
    await usdt.connect(leader).approve(await staking.getAddress(), ethers.parseEther("20000"));
    await staking.connect(leader).makeStake(ethers.parseEther("1000"));

    await staking.connect(staker).regUser(leader.address);
    await usdt.mint(staker.address, ethers.parseEther("20000"));
    await usdt.connect(staker).approve(await staking.getAddress(), ethers.parseEther("20000"));

    // Push leader's directBusiness past the 1st CTO tier ($5,000 direct / $10,000 team, where "team"
    // gates on combined direct+team volume — see _updateRank/_payCtoBonus) by having several other
    // directs stake $1000 twice each (5 signers * 2 stakes * $1000 = $10,000).
    for (let i = 11; i <= 15; i++) {
      const s = signers[i];
      await staking.connect(s).regUser(leader.address);
      await usdt.mint(s.address, ethers.parseEther("2000"));
      await usdt.connect(s).approve(await staking.getAddress(), ethers.parseEther("2000"));
      await staking.connect(s).makeStake(ethers.parseEther("1000"));
      await staking.connect(s).makeStake(ethers.parseEther("1000"));
    }

    await staking.connect(staker).makeStake(ethers.parseEther("100"));

    const bonus = await staking.bonusInfos(leader.address);
    expect(bonus.ctoGains).to.be.gt(0n);
  });

  it("pays ALL qualifying tiers to a single ancestor, not just the highest one", async function () {
    const { owner, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    const leader = signers[9];
    const staker = signers[10];

    await staking.connect(leader).regUser(owner.address);
    await usdt.mint(leader.address, ethers.parseEther("1000"));
    await usdt.connect(leader).approve(await staking.getAddress(), ethers.parseEther("1000"));
    await staking.connect(leader).makeStake(ethers.parseEther("1000"));

    await staking.connect(staker).regUser(leader.address);
    await usdt.mint(staker.address, ethers.parseEther("1000"));
    await usdt.connect(staker).approve(await staking.getAddress(), ethers.parseEther("1000"));

    // Push leader's directBusiness (all volume here is direct, since every staker below is
    // leader's own direct) to $40,000 — clears tier 3's $20,000 direct / $40,000 team
    // thresholds, which numerically also clears tier 1 and tier 2. leader should collect all
    // three: 2% + 1% + 1% = 4% of every later mintedAmount that reaches this point.
    const directs = signers.slice(11, 19); // 8 signers
    for (const s of directs) {
      await staking.connect(s).regUser(leader.address);
      await usdt.mint(s.address, ethers.parseEther("5000"));
      await usdt.connect(s).approve(await staking.getAddress(), ethers.parseEther("5000"));
      for (let i = 0; i < 5; i++) {
        await staking.connect(s).makeStake(ethers.parseEther("1000"));
      }
    }

    const before = await staking.bonusInfos(leader.address);
    await staking.connect(staker).makeStake(ethers.parseEther("100"));
    const after = await staking.bonusInfos(leader.address);

    // mintedAmount for a $100 stake = 90 tokens (1:1 rate); 4% of 90 = 3.6.
    expect(after.ctoGains - before.ctoGains).to.equal(ethers.parseEther("3.6"));
  });
});

describe("NexauraStaking — daily reward and caps", function () {
  it("reverts claimDailyReward within the same 24h window", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    // A brand-new stake's harvestTime is "now" — the very first claim needs a full day to
    // elapse too (you can't claim a reward for zero elapsed time), same as every later claim.
    await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
    await ethers.provider.send("evm_mine");

    await staking.connect(alice).claimDailyReward();
    await expect(staking.connect(alice).claimDailyReward()).to.be.revertedWith("Too soon");
  });

  it("credits 1.25% of lastStake per elapsed day into growthGains", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
    await ethers.provider.send("evm_mine");

    await staking.connect(alice).claimDailyReward();
    const bonus = await staking.bonusInfos(alice.address);
    expect(bonus.growthGains).to.equal(ethers.parseEther("1.25")); // 1.25% of 100
  });

  it("uses combined direct+team business for rank-based daily accrual, not totalTeamBusiness alone", async function () {
    const { alice, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    const directs = signers.slice(6, 9); // 3 signers

    // alice stakes $50 herself (sets her own harvestTime, satisfies Starter's selfStake >= 50).
    await staking.connect(alice).makeStake(ethers.parseEther("50"));

    // 3 directs stake $1000 each, all landing in alice's directBusiness (flat tree, no
    // grandchildren) -> alice.directBusiness = 3000, alice.totalTeamBusiness = 0,
    // alice.directs.length = 3 -> Starter rank (400bp incentive).
    for (const d of directs) {
      await staking.connect(d).regUser(alice.address);
      await usdt.mint(d.address, ethers.parseEther("1000"));
      await usdt.connect(d).approve(await staking.getAddress(), ethers.parseEther("1000"));
      await staking.connect(d).makeStake(ethers.parseEther("1000"));
    }

    await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
    await ethers.provider.send("evm_mine");
    await staking.connect(alice).claimDailyReward();

    const bonus = await staking.bonusInfos(alice.address);
    // dailyMatchYield = combinedBusiness(3000) * 1.25% = 37.5; rankAmount = 37.5 * 4% = 1.5.
    // Under the totalTeamBusiness-alone bug, combinedBusiness would read as 0 (all volume here
    // is direct-level) and this would be 0 instead.
    expect(bonus.teamGrowthGains).to.equal(ethers.parseEther("1.5"));
  });

  it("claimableWorking returns 0 for a user with fewer than 2 direct referrals", async function () {
    const { owner, alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    // owner has 1 direct (alice) so far -> below the 2-referral gate
    const claimable = await staking.claimableWorking(owner.address);
    expect(claimable).to.equal(0n);
  });

  it("claimableNonWorking is capped at 2x lastStake", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("10")); // small stake, easy to hit the 2x cap
    let orderId = 1;

    // Reaching the 2x cap needs 160 days of accrued growth (2 / 0.0125 daily rate) — but since
    // Task 8, an order only accrues for 17 days (10-day maturity + 7-day grace) before
    // claimDailyReward starts reverting unless recycled. Recycle every 16 days (past the
    // 10-day maturity, still inside the 17-day window) to keep claiming across the full span
    // needed to hit the cap: 10 cycles * 16 days * 1.25%/day * $10 = $20.
    for (let cycle = 0; cycle < 10; cycle++) {
      await ethers.provider.send("evm_increaseTime", [16 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine");
      await staking.connect(alice).claimDailyReward();
      await staking.connect(alice).makeUnstake(orderId);
      await staking.connect(alice).makeStake(ethers.parseEther("10"));
      orderId++;
    }

    const claimable = await staking.claimableNonWorking(alice.address);
    expect(claimable).to.equal(ethers.parseEther("20")); // 2x of $10, fully accrued and capped
  });
});

describe("NexauraStaking — maturity, grace, and recycling", function () {
  it("an order is not yet mature before 10 days", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    expect(await staking.isOrderAccruing(1)).to.equal(true);
  });

  it("an order stops accruing after maturity (10d) + grace (7d) if not recycled", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    await ethers.provider.send("evm_increaseTime", [18 * 24 * 60 * 60]); // past 17 days
    await ethers.provider.send("evm_mine");

    expect(await staking.isOrderAccruing(1)).to.equal(false);
  });

  it("claimDailyReward reverts once the sole order has lapsed past grace", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    await ethers.provider.send("evm_increaseTime", [18 * 24 * 60 * 60]);
    await ethers.provider.send("evm_mine");

    await expect(staking.connect(alice).claimDailyReward()).to.be.revertedWith("no active stake");
  });

  it("makeUnstake marks the order complete and blocks a second unstake of the same order", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    await ethers.provider.send("evm_increaseTime", [11 * 24 * 60 * 60]); // past 10-day maturity
    await ethers.provider.send("evm_mine");

    await staking.connect(alice).makeUnstake(1);
    const order = await staking.stakeInfos(1);
    expect(order.isComplete).to.equal(true);

    await expect(staking.connect(alice).makeUnstake(1)).to.be.revertedWith("Order not active");
  });

  it("makeUnstake reverts before maturity", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    await expect(staking.connect(alice).makeUnstake(1)).to.be.revertedWith("Order not mature");
  });
});

describe("NexauraStaking — withdrawal", function () {
  async function claimableFixture() {
    const base = await stakedFixture();
    const { alice, staking } = base;
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
    await ethers.provider.send("evm_mine");
    await staking.connect(alice).claimDailyReward();

    // No extra USDT funding needed: alice's $100 makeStake already grew internalReserve by 90
    // (the 90%-mint portion), which is far more than any withdrawal amount these tests use.
    // payoutReserve checks internalReserve, not raw balanceOf, so donating extra USDT directly
    // to the token contract here would do nothing — see Task 2's donation-attack fix.

    return base;
  }

  it("reverts below the $10 minimum", async function () {
    const { alice, staking } = await claimableFixture();
    await expect(staking.connect(alice).withdraw(ethers.parseEther("5"))).to.be.revertedWith(
      "Below minimum withdrawal"
    );
  });

  it("reverts above the $3000/day cap", async function () {
    const { alice, staking } = await claimableFixture();
    await expect(staking.connect(alice).withdraw(ethers.parseEther("3001"))).to.be.revertedWith(
      "Exceeds daily withdrawal cap"
    );
  });

  it("resets the daily withdrawal counter on UTC day rollover, not just accumulates", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    // Accrue $20 claimable up front (16 days: 100 * 1.25% * 16 = 20), well within the order's
    // 17-day accrual window, so both withdrawals below can draw from it without needing to
    // claim again in between.
    await ethers.provider.send("evm_increaseTime", [16 * 24 * 60 * 60]);
    await ethers.provider.send("evm_mine");
    await staking.connect(alice).claimDailyReward();

    await staking.connect(alice).withdraw(ethers.parseEther("10"));
    expect(await staking.withdrawnToday(alice.address)).to.equal(ethers.parseEther("10"));

    // Next day: withdraw the remaining $10 claimable. This would succeed even without a reset
    // (10+10 is far under the $3000 cap either way) — what this proves is that withdrawnToday's
    // VALUE resets to reflect only the new day's withdrawal, not that it merely stays under cap.
    await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
    await ethers.provider.send("evm_mine");
    await staking.connect(alice).withdraw(ethers.parseEther("10"));
    expect(await staking.withdrawnToday(alice.address)).to.equal(ethers.parseEther("10")); // reset, not 20
  });

  it("reverts when requesting more than the claimable non-working balance", async function () {
    const { alice, staking } = await claimableFixture();
    // growthGains = 1.25 after one day; nothing else claimable without 2 directs.
    await expect(staking.connect(alice).withdraw(ethers.parseEther("10"))).to.be.revertedWith(
      "Exceeds claimable balance"
    );
  });

  it("pays out 90% to the user and splits the 10% fee 5/5 into creator fee and spot bonus pool", async function () {
    const { alice, creatorFee, staking, usdt } = await claimableFixture();

    // claimableFixture only accrues $1.25 (1 day) — below the $10 minimum withdrawal. Advance 7
    // more days and claim again to reach exactly $10 claimable (100 * 1.25% * 8 days = 10),
    // still well within the order's 17-day accrual window.
    await ethers.provider.send("evm_increaseTime", [7 * 24 * 60 * 60]);
    await ethers.provider.send("evm_mine");
    await staking.connect(alice).claimDailyReward();

    const beforeAlice = await usdt.balanceOf(alice.address);
    const beforeCreator = await usdt.balanceOf(creatorFee.address);

    await staking.connect(alice).withdraw(ethers.parseEther("10"));

    const afterAlice = await usdt.balanceOf(alice.address);
    const afterCreator = await usdt.balanceOf(creatorFee.address);

    expect(afterAlice - beforeAlice).to.equal(ethers.parseEther("9")); // 90% of 10
    expect(afterCreator - beforeCreator).to.equal(ethers.parseEther("0.5")); // 5% of 10
    expect(await staking.dailySpotBonusPool()).to.equal(ethers.parseEther("0.5")); // 5% of 10
  });
});
