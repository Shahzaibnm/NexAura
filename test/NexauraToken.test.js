const { expect } = require("chai");
const { ethers } = require("hardhat");

async function deployFixture() {
  const [owner, staking, alice, bob] = await ethers.getSigners();

  const MockUSDT = await ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();

  const NexauraToken = await ethers.getContractFactory("NexauraToken");
  const token = await NexauraToken.deploy(
    owner.address,
    await usdt.getAddress(),
    "Nexaura",
    "NXA"
  );

  await token.connect(owner).setStakingContract(staking.address);

  return { owner, staking, alice, bob, usdt, token };
}

describe("NexauraToken", function () {
  it("has correct name, symbol, decimals", async function () {
    const { token } = await deployFixture();
    expect(await token.name()).to.equal("Nexaura");
    expect(await token.symbol()).to.equal("NXA");
    expect(await token.decimals()).to.equal(18);
  });

  it("only the staking contract can call pricedBuy", async function () {
    const { token, alice } = await deployFixture();
    await expect(
      token.connect(alice).pricedBuy(ethers.parseEther("100"), alice.address)
    ).to.be.revertedWith("Only staking contract");
  });

  it("pricedBuy mints tokens at the InitialRate (1:1) when supply is 0", async function () {
    const { token, staking, alice } = await deployFixture();
    await token.connect(staking).pricedBuy(ethers.parseEther("100"), alice.address);
    expect(await token.balanceOf(alice.address)).to.equal(ethers.parseEther("100"));
    expect(await token.totalSupply()).to.equal(ethers.parseEther("100"));
  });

  it("burns 1% on transfer and credits 99% to the recipient", async function () {
    const { token, staking, alice, bob } = await deployFixture();
    await token.connect(staking).pricedBuy(ethers.parseEther("100"), alice.address);

    await token.connect(alice).transfer(bob.address, ethers.parseEther("100"));

    expect(await token.balanceOf(bob.address)).to.equal(ethers.parseEther("99"));
    expect(await token.totalSupply()).to.equal(ethers.parseEther("99"));
  });

  it("pricedSell burns 100% of the sold tokens and pays full USD value to forAddress", async function () {
    const { token, staking, alice, usdt } = await deployFixture();

    await usdt.mint(await token.getAddress(), ethers.parseEther("1000"));
    await token.connect(staking).pricedBuy(ethers.parseEther("100"), staking.address);

    const before = await usdt.balanceOf(alice.address);
    await token.connect(staking).pricedSell(ethers.parseEther("50"), alice.address);
    const after = await usdt.balanceOf(alice.address);

    expect(await token.totalSupply()).to.equal(ethers.parseEther("50"));
    expect(after - before).to.equal(ethers.parseEther("50")); // rate stayed ~1:1 after the buy
  });

  it("rateInUSDT tracks internalReserve / total supply, following pricedBuy/pricedSell", async function () {
    const { token, staking, alice, usdt } = await deployFixture();
    await token.connect(staking).pricedBuy(ethers.parseEther("100"), alice.address);
    // internalReserve = 100 (from the usdAmount passed to pricedBuy), totalSupply = 100 -> rate 1:1
    expect(await token.rateInUSDT()).to.equal(ethers.parseEther("1"));

    await usdt.mint(await token.getAddress(), ethers.parseEther("1000"));
    await token.connect(staking).pricedBuy(ethers.parseEther("200"), alice.address);
    // internalReserve = 300, totalSupply = 300 -> still 1:1, driven by pricedBuy, not by the
    // 1000 USDT that was separately minted straight into the contract.
    expect(await token.rateInUSDT()).to.equal(ethers.parseEther("1"));
  });

  it("a direct USDT transfer into the contract does not move the rate (inflation-attack regression test)", async function () {
    const { token, staking, alice, usdt } = await deployFixture();
    await token.connect(staking).pricedBuy(ethers.parseEther("100"), alice.address);
    const rateBefore = await token.rateInUSDT();

    // Simulate an attacker donating USDT directly to the token contract, bypassing pricedBuy,
    // to try to move the rate before someone else's mint/sell.
    await usdt.mint(await token.getAddress(), ethers.parseEther("50000"));

    const rateAfter = await token.rateInUSDT();
    expect(rateAfter).to.equal(rateBefore);
  });
});
