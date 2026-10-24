// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITokenLike {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

abstract contract Ownable is Context {
    address private _owner;

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _transferOwnership(initialOwner);
    }

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) revert OwnableUnauthorizedAccount(_msgSender());
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

/// @dev Holds Nexaura tokens (the sell deduction) as a reserve. Funding is just a plain token
/// transfer into this contract's own address -- no deposit function needed. It never pushes
/// funds on its own; the owner approves a spender to pull up to a set amount via transferFrom.
contract InsurancePool is Ownable {
    ITokenLike public token;

    event SpenderApproved(address indexed spender, uint256 amount);

    constructor(address _owner) Ownable(_owner) {}

    // Set after deployment: the token needs this contract's address in its constructor.
    function setTokenAddress(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        token = ITokenLike(_token);
    }

    /// @dev Sets (or replaces) how much `spender` may pull from this contract via transferFrom.
    /// Re-approving to a new amount follows the standard ERC20 approve semantics (this overwrites
    /// the prior allowance, it does not add to it).
    function approveSpender(address spender, uint256 amount) external onlyOwner {
        require(spender != address(0), "Invalid spender");
        require(token.approve(spender, amount), "Approve failed");
        emit SpenderApproved(spender, amount);
    }

    function balance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
