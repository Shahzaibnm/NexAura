const { expect } = require("chai");
const { ethers } = require("hardhat");

async function deployFixture() {
  const [owner, spender, alice] = await ethers.getSigners();

  const MockUSDT = await ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();

  const InsurancePool = await ethers.getContractFactory("InsurancePool");
  const reserve = await InsurancePool.deploy(owner.address, await usdt.getAddress());

  return { owner, spender, alice, usdt, reserve };
}

describe("InsurancePool", function () {
  it("sets the owner and USDT address at construction", async function () {
    const { owner, usdt, reserve } = await deployFixture();
    expect(await reserve.owner()).to.equal(owner.address);
    expect(await reserve.usdToken()).to.equal(await usdt.getAddress());
  });

  it("funding is just a plain USDT transfer, no deposit function needed", async function () {
    const { usdt, reserve } = await deployFixture();
    await usdt.mint(await reserve.getAddress(), ethers.parseEther("500"));
    expect(await reserve.balance()).to.equal(ethers.parseEther("500"));
  });

  it("only the owner can approve a spender", async function () {
    const { spender, reserve } = await deployFixture();
    await expect(
      reserve.connect(spender).approveSpender(spender.address, ethers.parseEther("100"))
    ).to.be.revertedWithCustomError(reserve, "OwnableUnauthorizedAccount");
  });

  it("approveSpender grants a transferFrom allowance to the spender", async function () {
    const { owner, spender, usdt, reserve } = await deployFixture();
    await reserve.connect(owner).approveSpender(spender.address, ethers.parseEther("300"));
    expect(await usdt.allowance(await reserve.getAddress(), spender.address)).to.equal(
      ethers.parseEther("300")
    );
  });

  it("re-approving overwrites the prior allowance rather than adding to it", async function () {
    const { owner, spender, usdt, reserve } = await deployFixture();
    await reserve.connect(owner).approveSpender(spender.address, ethers.parseEther("300"));
    await reserve.connect(owner).approveSpender(spender.address, ethers.parseEther("50"));
    expect(await usdt.allowance(await reserve.getAddress(), spender.address)).to.equal(
      ethers.parseEther("50")
    );
  });

  it("an approved spender can pull funds via transferFrom, an unapproved one cannot", async function () {
    const { owner, spender, alice, usdt, reserve } = await deployFixture();
    await usdt.mint(await reserve.getAddress(), ethers.parseEther("500"));
    await reserve.connect(owner).approveSpender(spender.address, ethers.parseEther("300"));

    await usdt.connect(spender).transferFrom(await reserve.getAddress(), alice.address, ethers.parseEther("200"));
    expect(await usdt.balanceOf(alice.address)).to.equal(ethers.parseEther("200"));
    expect(await reserve.balance()).to.equal(ethers.parseEther("300"));

    await expect(
      usdt.connect(alice).transferFrom(await reserve.getAddress(), alice.address, ethers.parseEther("1"))
    ).to.be.reverted;
  });

  it("ownership can be transferred, and only by the current owner", async function () {
    const { owner, spender, alice, reserve } = await deployFixture();
    await expect(reserve.connect(alice).transferOwnership(alice.address)).to.be.revertedWithCustomError(
      reserve,
      "OwnableUnauthorizedAccount"
    );

    await reserve.connect(owner).transferOwnership(spender.address);
    expect(await reserve.owner()).to.equal(spender.address);
  });
});
