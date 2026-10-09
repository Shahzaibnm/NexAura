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

describe("NexauraStakingV2 — full behaviour", function () {
  describe("stake", function () {
    it("puts all $100 in the token and mints $5 creator / $5 DAO / $9 token-contract / $81 locked tokens", async function () {
      const { owner, creatorFee, u, usdt, token, staking } = await deploy();
      const [alice] = u;
      await join(staking, alice, owner, 100);

      expect(await usdt.balanceOf(creatorFee.address)).to.equal(0n); // creator is paid in tokens
      expect(await token.balanceOf(creatorFee.address)).to.equal(e(5));
      expect(await token.balanceOf(await token.getAddress())).to.equal(e(9)); // liquidity share
      expect(await staking.DAO_Amount()).to.equal(e(5)); // $5 of tokens, held for the DAO
      expect(await usdt.balanceOf(await staking.getAddress())).to.equal(0n); // no USDT left here
      expect(await usdt.balanceOf(await token.getAddress())).to.equal(e(100)); // whole deposit
      expect(await token.internalReserve()).to.equal(e(100));
      expect(await token.totalSupply()).to.equal(e(100)); // 81 + 5 + 5 + 9, rate stays $1

      const order = await staking.stakeInfos(1);
      expect(order.lockedTokens).to.equal(e(81));
      expect(order.usdAmount).to.equal(e(100));
      expect(await token.balanceOf(await staking.getAddress())).to.equal(e(86)); // 81 locked + 5 DAO
      expect(await token.balanceOf(alice.address)).to.equal(0n); // nothing to the user's wallet
    });

    it("pays the upline direct income of 5% of the full stake ($5 -> 5 tokens), not 4.05", async function () {
      const { owner, u, staking } = await deploy();
      const [alice, bob] = u;
      await join(staking, alice, owner, 100);
      await join(staking, bob, alice, 100);
      expect((await staking.bonusInfos(alice.address)).referralGains).to.equal(e(5));
    });

    it("rejects bad package amounts, a decreasing package, and unstaked referrals", async function () {
      const { owner, u, staking } = await deploy();
      const [alice, bob] = u;
      await expect(staking.connect(bob).regUser(alice.address)).to.be.revertedWith(
        "Referral has not staked yet"
      );
      await staking.connect(alice).regUser(owner.address);
      await expect(staking.connect(alice).regUser(owner.address)).to.be.revertedWith("Already registered");
      for (const bad of [5, 15, 1010]) {
        await expect(staking.connect(alice).makeStake(e(bad))).to.be.revertedWith("Invalid package amount");
      }
      await staking.connect(alice).makeStake(e(100));
      await expect(staking.connect(alice).makeStake(e(50))).to.be.revertedWith("Package must not decrease");
    });

    it("lets a user stake again before day 10 as an independent order with its own clock", async function () {
      const { owner, u, staking } = await deploy();
      const [alice] = u;
      await join(staking, alice, owner, 100);
      await pass(6 * DAY);
      await staking.connect(alice).makeStake(e(100));

      await pass(4 * DAY + 60); // order 1 is now 10d+, order 2 only ~4d
      await expect(staking.connect(alice).claimOrder(1)).to.emit(staking, "OrderClaimed");
      await expect(staking.connect(alice).claimOrder(2)).to.be.revertedWith("Order not mature");
    });
  });

  describe("claimOrder", function () {
    it("returns principal with no 1% burn, mints 12.5% ROI less the 10% fee, and fills the spot pool", async function () {
      const { owner, creatorFee, u, token, staking } = await deploy();
      const [alice] = u;
      await join(staking, alice, owner, 100);
      await pass(10 * DAY + 60);
      const creatorBefore = await token.balanceOf(creatorFee.address);
      await staking.connect(alice).claimOrder(1);

      // roi = 81 * 12.5% = 10.125; creator 5% = 0.50625; spot pool 5% = 0.50625; net = 9.1125
      expect(await token.balanceOf(alice.address)).to.equal(e(81) + e("9.1125"));
      expect((await token.balanceOf(creatorFee.address)) - creatorBefore).to.equal(e("0.50625"));
      expect(await staking.dailySpotBonusPool()).to.equal(e("0.50625"));
      expect(await token.balanceOf(await staking.getAddress())).to.equal(e(5)); // only the DAO pool left
    });

    it("cannot be claimed twice or by someone else", async function () {
      const { owner, u, staking } = await deploy();
      const [alice, bob] = u;
      await join(staking, alice, owner, 100);
      await pass(10 * DAY + 60);
      await expect(staking.connect(bob).claimOrder(1)).to.be.revertedWith("Not your order");
      await staking.connect(alice).claimOrder(1);
      await expect(staking.connect(alice).claimOrder(1)).to.be.revertedWith("Already claimed");
    });

    it("a $10 package can be claimed (order claims are exempt from the $10 minimum)", async function () {
      const { owner, u, staking } = await deploy();
      const [alice] = u;
      await join(staking, alice, owner, 10);
      await pass(10 * DAY + 60);
      await expect(staking.connect(alice).claimOrder(1)).to.emit(staking, "OrderClaimed");
    });

    it("minting reward tokens lowers the token rate (no USDT behind them)", async function () {
      const { owner, u, token, staking } = await deploy();
      const [alice] = u;
      await join(staking, alice, owner, 100);
      expect(await token.rateInUSDT()).to.equal(e(1));
      await pass(10 * DAY + 60);
      await staking.connect(alice).claimOrder(1);
      expect(await token.rateInUSDT()).to.be.lt(e(1));
    });
  });

  describe("level income (on the claimed ROI)", function () {
    it("pays levels 2.. as a % of the claimed ROI, nothing at stake time", async function () {
      const { owner, u, staking } = await deploy();
      const [u0, u1, u2, u3, u4] = u;
      await join(staking, u0, owner, 100);
      await join(staking, u1, u0, 100);
      await join(staking, u2, u1, 100);
      await join(staking, u3, u2, 100);
      await join(staking, u4, u3, 100);

      for (const x of [u0, u1, u2]) {
        expect((await staking.bonusInfos(x.address)).levelGains).to.equal(0n); // none at stake time
      }

      await pass(11 * DAY);
      await staking.connect(u4).claimOrder(5); // roi = 10.125

      const roi = e("10.125");
      expect((await staking.bonusInfos(u3.address)).levelGains).to.equal(0n); // level 1 is direct only
      expect((await staking.bonusInfos(u2.address)).levelGains).to.equal((roi * 300n) / 10000n); // 3%
      expect((await staking.bonusInfos(u1.address)).levelGains).to.equal((roi * 150n) / 10000n); // 1.5%
      expect((await staking.bonusInfos(u0.address)).levelGains).to.equal((roi * 150n) / 10000n); // 1.5%
    });

    it("skips an upline whose last package is under $50", async function () {
      const { owner, u, staking } = await deploy();
      const [u0, u1, u2, u3, u4] = u;
      await join(staking, u0, owner, 100);
      await join(staking, u1, u0, 100);
      await join(staking, u2, u1, 40); // under $50
      await join(staking, u3, u2, 100);
      await join(staking, u4, u3, 100);

      await pass(11 * DAY);
      await staking.connect(u4).claimOrder(5);

      const roi = e("10.125");
      expect((await staking.bonusInfos(u2.address)).levelGains).to.equal(0n);
      expect((await staking.bonusInfos(u1.address)).levelGains).to.equal((roi * 150n) / 10000n);
    });
  });

  describe("cap and claimables", function () {
    it("clamps income to 2x of locked tokens (non-working) and then 3x with 2 directs (working)", async function () {
      const { owner, u, staking } = await deploy();
      const [alice, bob, carol] = u;
      await join(staking, alice, owner, 10); // locked 8.1 -> 2x cap 16.2

      await join(staking, bob, alice, 1000); // direct 50 clamped to the 16.2 room
      expect((await staking.bonusInfos(alice.address)).referralGains).to.equal(e("16.2"));
      expect(await staking.capOf(alice.address)).to.equal(e("16.2"));

      await join(staking, carol, alice, 1000); // 2 directs -> 3x cap 24.3, room 8.1
      expect(await staking.capOf(alice.address)).to.equal(e("24.3"));
      expect((await staking.bonusInfos(alice.address)).referralGains).to.equal(e("24.3"));
    });

    it("income claim mints net 90%, 5% to the creator, 5% to the spot pool; enforces the $10 minimum", async function () {
      const { owner, creatorFee, u, token, staking } = await deploy();
      const [alice, bob] = u;
      await join(staking, alice, owner, 10);
      await join(staking, bob, alice, 1000); // alice referralGains = 16.2

      await expect(staking.connect(u[5]).claimReferralGains()).to.be.revertedWith("Nothing to claim");
      const creatorBefore = await token.balanceOf(creatorFee.address);
      await staking.connect(alice).claimReferralGains();
      expect(await token.balanceOf(alice.address)).to.equal(e("14.58"));
      expect((await token.balanceOf(creatorFee.address)) - creatorBefore).to.equal(e("0.81"));
      expect(await staking.dailySpotBonusPool()).to.equal(e("0.81"));
      expect(await staking.claimableReferralGains(alice.address)).to.equal(0n);

      // below $10: carol's direct from a $100 stake is only 5 tokens
      const { owner: o2, u: u2, staking: s2 } = await deploy();
      await join(s2, u2[0], o2, 100);
      await join(s2, u2[1], u2[0], 100);
      await expect(s2.connect(u2[0]).claimReferralGains()).to.be.revertedWith("Below minimum withdrawal");
    });

    it("earned income stays claimable after claiming the last order shrinks the cap, but new income stops", async function () {
      const { owner, u, token, staking } = await deploy();
      const [alice, bob, carol] = u;
      await join(staking, alice, owner, 100);
      await join(staking, bob, alice, 1000); // alice direct income 50 tokens, unclaimed
      await pass(10 * DAY + 60);
      await staking.connect(alice).claimOrder(1);
      expect(await staking.capOf(alice.address)).to.equal(0n);

      expect(await staking.claimableReferralGains(alice.address)).to.equal(e(50));
      await staking.connect(alice).claimReferralGains();
      expect(await token.balanceOf(alice.address)).to.be.gt(e(81)); // principal + ROI + 45 net

      // cap is now 0, so a new direct credits nothing (alice is still inside her grace window)
      await join(staking, carol, alice, 100);
      expect((await staking.bonusInfos(alice.address)).referralGains).to.equal(e(50));
    });
  });

  describe("rank income", function () {
    it("pays rank income on the first claim only, once per 10 days, even with two matured orders", async function () {
      const { owner, u, staking } = await deploy();
      const [alice, d1, d2, d3] = u;
      await join(staking, alice, owner, 100);
      for (const d of [d1, d2, d3]) await join(staking, d, alice, 1000);
      expect((await staking.userInfos(alice.address)).rank).to.equal(1); // Silver

      await pass(DAY);
      await staking.connect(alice).makeStake(e(100)); // second order, day 1
      await pass(11 * DAY);

      // 3000 business x 12.5% x 4% = 15 USD -> 15 tokens at the $1 rate
      await staking.connect(alice).claimOrder(1);
      expect((await staking.bonusInfos(alice.address)).teamGrowthGains).to.equal(e(15));
      await staking.connect(alice).claimOrder(5); // alice's second order (directs took ids 2-4)
      expect((await staking.bonusInfos(alice.address)).teamGrowthGains).to.equal(e(15)); // not paid again
    });

    it("holds the deck's 11 rank tiers and DAO tier 3 as 3000/4000/6", async function () {
      const { staking } = await deploy();
      expect((await staking.rankTiers(10)).incentiveBp).to.equal(2800);
      expect((await staking.rankTiers(10)).selfStake).to.equal(e(10000));
      expect((await staking.daoTiers(2)).share).to.equal(6);
      expect((await staking.daoTiers(2)).directBusiness).to.equal(e(3000));
    });
  });

  describe("monthly CTO", function () {
    it("splits the Core 1 pool (2% of the month's volume) equally, pays duplicates once, owner-only, 30-day gap", async function () {
      const { owner, u, staking } = await deploy();
      const [a1, a2] = u;
      const d1 = u.slice(2, 7);
      const d2 = u.slice(7, 12);
      await join(staking, a1, owner, 100);
      await join(staking, a2, owner, 100);
      for (const d of d1) await join(staking, d, a1, 1000);
      for (const d of d2) await join(staking, d, a2, 1000);

      await pass(25 * DAY);
      await staking.connect(a1).makeStake(e(100)); // recycle so they can still earn
      await staking.connect(a2).makeStake(e(100));
      await pass(5 * DAY + 3600);

      await expect(staking.connect(a1).distributeCTO([a1.address])).to.be.revertedWithCustomError(
        staking,
        "OwnableUnauthorizedAccount"
      );

      // volume = 100+100 + 10x1000 + 100+100 = 10400; Core 1 pool = 2% = 208; two users -> 104 each
      await staking.connect(owner).distributeCTO([a1.address, a1.address, a2.address, d1[0].address]);
      expect((await staking.bonusInfos(a1.address)).ctoGains).to.equal(e(104));
      expect((await staking.bonusInfos(a2.address)).ctoGains).to.equal(e(104));
      expect((await staking.bonusInfos(d1[0].address)).ctoGains).to.equal(0n);
      expect(await staking.monthVolumeUsd()).to.equal(0n);

      await expect(staking.connect(owner).distributeCTO([a1.address])).to.be.revertedWith("Too soon");
    });
  });

  describe("DAO", function () {
    it("holds the 5% as tokens, credits winners from them, keeps the remainder, and pays claims without minting", async function () {
      const { owner, creatorFee, u, usdt, token, staking } = await deploy();
      const [a1, d] = u;
      await join(staking, a1, owner, 100);
      await join(staking, d, a1, 500); // a1 direct business 500 -> DAO share 1
      expect(await staking.DAO_Amount()).to.equal(e(30)); // 5% of 600, in tokens

      await pass(7 * DAY + 60);
      await expect(staking.connect(a1).distributeDAO()).to.be.revertedWithCustomError(
        staking,
        "OwnableUnauthorizedAccount"
      );

      const reserveBefore = await token.internalReserve();
      const usdtBefore = await usdt.balanceOf(await token.getAddress());
      await staking.connect(owner).distributeDAO();
      expect((await staking.bonusInfos(a1.address)).daoGains).to.equal(e(30));
      expect(await staking.DAO_Amount()).to.equal(0n);
      expect(await token.internalReserve()).to.equal(reserveBefore); // no USDT movement
      expect(await usdt.balanceOf(await token.getAddress())).to.equal(usdtBefore);

      // claim: 30 held tokens -> 27 net to a1, 1.5 creator, 1.5 burned into the spot pool ledger
      const supplyBefore = await token.totalSupply();
      const creatorBefore = await token.balanceOf(creatorFee.address);
      await staking.connect(a1).claimDaoGains();
      expect(await token.balanceOf(a1.address)).to.equal(e(27));
      expect((await token.balanceOf(creatorFee.address)) - creatorBefore).to.equal(e("1.5"));
      expect(await staking.dailySpotBonusPool()).to.equal(e("1.5"));
      expect(await token.totalSupply()).to.equal(supplyBefore - e("1.5"));
    });

    it("keeps the pool for the next run when nobody qualifies", async function () {
      const { owner, u, staking } = await deploy();
      await join(staking, u[0], owner, 100); // no DAO-qualified users
      await pass(7 * DAY + 60);
      await staking.connect(owner).distributeDAO();
      expect(await staking.DAO_Amount()).to.equal(e(5)); // carried over, not lost
    });
  });

  describe("daily spot bonus", function () {
    it("pays the token pool (fed by claim fees) equally to qualifiers, duplicates once", async function () {
      const { owner, u, staking } = await deploy();
      const [alice, bob, carol, dave] = u;
      await join(staking, alice, owner, 100);
      await join(staking, bob, owner, 100);
      await pass(10 * DAY + 60);
      await staking.connect(bob).claimOrder(2); // fills the pool with 5% of 10.125
      expect(await staking.dailySpotBonusPool()).to.equal(e("0.50625"));

      await join(staking, carol, alice, 100); // two directs inside 24h, each >= $50
      await join(staking, dave, alice, 100);
      expect(await staking.qualifiesForSpotBonus(alice.address)).to.equal(true);

      await staking.connect(owner).distributeSpotBonus([alice.address, alice.address, bob.address]);
      expect((await staking.bonusInfos(alice.address)).spotBonusGains).to.equal(e("0.50625"));
      expect((await staking.bonusInfos(bob.address)).spotBonusGains).to.equal(0n);
      expect(await staking.dailySpotBonusPool()).to.equal(0n);
    });
  });

  describe("token contract", function () {
    it("sell burns 100% of the tokens, sends the 15% deduction to the reserve pool, pays 85% to the seller", async function () {
      const { owner, u, usdt, reserve, token, staking } = await deploy();
      const [alice] = u;
      await join(staking, alice, owner, 100);
      await pass(10 * DAY + 60);
      await staking.connect(alice).claimOrder(1);

      const bal = await token.balanceOf(alice.address);
      const rate = await token.rateInUSDT();
      const usdPaid = (bal * rate) / e(1);
      const cut = (usdPaid * 1500n) / 10000n;
      const supplyBefore = await token.totalSupply();
      const poolBefore = await usdt.balanceOf(await reserve.getAddress());
      const usdtBefore = await usdt.balanceOf(alice.address);

      await token.connect(alice).sell(bal);

      expect(await token.balanceOf(alice.address)).to.equal(0n);
      expect(await token.totalSupply()).to.equal(supplyBefore - bal);
      expect((await usdt.balanceOf(await reserve.getAddress())) - poolBefore).to.equal(cut);
      expect((await usdt.balanceOf(alice.address)) - usdtBefore).to.equal(usdPaid - cut);
    });

    it("normal user-to-user transfers still burn 1%", async function () {
      const { owner, u, token, staking } = await deploy();
      const [alice, bob] = u;
      await join(staking, alice, owner, 100);
      await pass(10 * DAY + 60);
      await staking.connect(alice).claimOrder(1);
      const supplyBefore = await token.totalSupply();
      await token.connect(alice).transfer(bob.address, e(10));
      expect(await token.balanceOf(bob.address)).to.equal(e("9.9"));
      expect(await token.totalSupply()).to.equal(supplyBefore - e("0.1"));
    });

    it("only the staking contract can mint, buy or credit the reserve", async function () {
      const { u, token } = await deploy();
      await expect(token.connect(u[0]).mintTo(u[0].address, 1)).to.be.revertedWith("Only staking contract");
      await expect(token.connect(u[0]).pricedBuy(1, u[0].address)).to.be.revertedWith("Only staking contract");
      await expect(token.connect(u[0]).creditReserve(1)).to.be.revertedWith("Only staking contract");
    });
  });
});
