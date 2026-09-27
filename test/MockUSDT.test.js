// test/MockUSDT.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MockUSDT", function () {
  it("mints and transfers with correct balances", async function () {
    const [owner, alice, bob] = await ethers.getSigners();
    const MockUSDT = await ethers.getContractFactory("MockUSDT");
    const usdt = await MockUSDT.deploy();

    await usdt.mint(alice.address, ethers.parseEther("1000"));
    expect(await usdt.balanceOf(alice.address)).to.equal(ethers.parseEther("1000"));

    await usdt.connect(alice).transfer(bob.address, ethers.parseEther("100"));
    expect(await usdt.balanceOf(alice.address)).to.equal(ethers.parseEther("900"));
    expect(await usdt.balanceOf(bob.address)).to.equal(ethers.parseEther("100"));
  });
});
