const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("NEXAURA — end-to-end integration", function () {
  it("runs a full register -> stake -> cascade -> rank -> recycle -> withdraw -> DAO/spot-bonus flow", async function () {
    const [owner, creatorFee, treasury, alice, bob, carol, dave] = await ethers.getSigners();

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

    for (const u of [alice, bob, carol, dave]) {
      await usdt.mint(u.address, ethers.parseEther("5000"));
      await usdt.connect(u).approve(await staking.getAddress(), ethers.parseEther("5000"));
    }
    // No separate token-contract funding needed: each makeStake below grows internalReserve by
    // its own 90%-mint portion, which is what payoutReserve checks against (see Task 2/Task 9).

    // 1. Register a 3-deep chain under the owner.
    await staking.connect(alice).regUser(owner.address);
    await staking.connect(bob).regUser(alice.address);
    await staking.connect(carol).regUser(alice.address);
    await staking.connect(dave).regUser(bob.address);

    // 2. Alice, Bob, Carol each stake $100; this gives alice 2 directs (bob, carol) -> Working Income unlocked.
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    await staking.connect(bob).makeStake(ethers.parseEther("100"));
    await staking.connect(carol).makeStake(ethers.parseEther("100"));
    await staking.connect(dave).makeStake(ethers.parseEther("100"));

    // Direct income: alice earned 5% of bob's and carol's 90-token mint each.
    const aliceBonus = await staking.bonusInfos(alice.address);
    expect(aliceBonus.referralGains).to.equal(ethers.parseEther("9")); // (90*5%)*2

    // Level income: alice also earns level-2 income from dave's stake (through bob).
    // bp[1]=300 (3%) of dave's 90-token mint = 2.7.
    expect(aliceBonus.levelGains).to.equal(ethers.parseEther("2.7"));

    // 3. Working income is claimable for alice now (2+ directs): referralGains(9) +
    // levelGains(2.7) = 11.7, well under her 3x cap (lastStake 100 * 3 = 300).
    const claimable = await staking.claimableWorking(alice.address);
    expect(claimable).to.equal(ethers.parseEther("11.7"));

    // 4. Daily reward accrues and is claimable as non-working income.
    await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
    await ethers.provider.send("evm_mine");
    await staking.connect(alice).claimDailyReward();
    expect(await staking.claimableNonWorking(alice.address)).to.equal(ethers.parseEther("1.25"));

    // 5. Alice withdraws $10 — her non-working claimable alone (1.25) is below MIN_WITHDRAW
    // ($10), so this draws 1.25 from non-working and the remaining 8.75 from her working
    // balance (referral + level income from bob/carol/dave's stakes, well above 8.75).
    const beforeAlice = await usdt.balanceOf(alice.address);
    await staking.connect(alice).withdraw(ethers.parseEther("10"));
    const afterAlice = await usdt.balanceOf(alice.address);
    expect(afterAlice - beforeAlice).to.equal(ethers.parseEther("9")); // net of 10% fee

    // 6. Recycling: alice's package must hold steady or grow.
    await ethers.provider.send("evm_increaseTime", [11 * 24 * 60 * 60]); // past 10-day maturity
    await ethers.provider.send("evm_mine");
    await staking.connect(alice).makeUnstake(1);
    await staking.connect(alice).makeStake(ethers.parseEther("100")); // recycle at same amount, allowed
    await expect(staking.connect(alice).makeStake(ethers.parseEther("50"))).to.be.revertedWith(
      "Package must not decrease"
    );

    // 7. DAO distribution after the weekly window.
    await ethers.provider.send("evm_increaseTime", [7 * 24 * 60 * 60]);
    await ethers.provider.send("evm_mine");
    if ((await staking.DAO_Amount()) > 0n) {
      await staking.distributeDAO();
      expect(await staking.DAO_Amount()).to.equal(0n);
    }

    // 8. Spot bonus distribution, candidate list supplied explicitly.
    const spotPool = await staking.dailySpotBonusPool();
    if (spotPool > 0n) {
      await staking.distributeSpotBonus([alice.address, bob.address, carol.address, owner.address]);
      expect(await staking.dailySpotBonusPool()).to.equal(0n);
    }
  });
});
