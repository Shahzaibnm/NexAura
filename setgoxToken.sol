// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

// File: @openzeppelin/contracts/access/Ownable.sol

// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

pragma solidity ^0.8.20;

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * The initial owner is set to the address provided by the deployer. This can
 * later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

// File: @openzeppelin/contracts/utils/ReentrancyGuard.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/ReentrancyGuard.sol)

pragma solidity ^0.8.20;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If EIP-1153 (transient storage) is available on the chain you're deploying at,
 * consider using {ReentrancyGuardTransient} instead.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}

pragma solidity ^0.8.0;

//import "hardhat/console.sol";

interface IBEP20 {
    function transfer(
        address recipient,
        uint256 amount
    ) external returns (bool);

    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function decimals() external view returns (uint8);
}

contract Setgox_Token is IBEP20, Ownable, ReentrancyGuard {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => uint256) private _lastTransactionTime;

    uint256 private _totalSupply;
    uint8 private constant _decimals = 18;
    string private constant _name = "SETGOX TOKEN";
    string private constant _symbol = "STX";
    uint256 private blockTimestampLast;

    uint256 public InitialRate = 1e18; // Initial rate: 1.00 USDT per SetGox (18 decimals)
    uint256 public burnSlippage = 10;

    mapping(address => bool) public whiteLists;
    address private receiverAddress;
    address private sellReceiverAddress;
    address private treasuryAddress =
        0xd65b211220002F7d95Fae52313BaC4f6585Ac971;
    bool public isBuyOn = true;
    IBEP20 private usdToken;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event Minted(
        address indexed user,
        uint256 usdAmount,
        uint256 setgoxReceived,
        uint256 setgoxPrice
    );
    event Burned(
        address indexed user,
        uint256 setgoxAmount,
        uint256 usdReceived,
        uint256 setgoxPrice
    );

    event RateAdjusted(uint256 newRate);

    modifier onlyEOA() {
        require(
            tx.origin == msg.sender || whiteLists[msg.sender],
            "Caller must be EOA"
        );
        _;
    }

    constructor(
        address _owner,
        address _usdtToken,
        address _setgoxStakingContract,
        address _usdContractCoin
    ) Ownable(_owner) {
        require(_usdtToken != address(0), "Invalid USDT address");
        usdToken = IBEP20(_usdtToken);
        receiverAddress = msg.sender;
        sellReceiverAddress = msg.sender;
        usdToken.approve(_setgoxStakingContract, type(uint256).max);
        usdToken.approve(_usdContractCoin, type(uint256).max);
        whiteLists[_setgoxStakingContract] = true;
        whiteLists[_owner] = true;
    }

    function name() public pure returns (string memory) {
        return _name;
    }

    function symbol() public pure returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function allowance(
        address owner,
        address spender
    ) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address recipient, uint256 amount) public returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public returns (bool) {
        _transfer(sender, recipient, amount);
        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(
            currentAllowance >= amount,
            "BEP20: transfer amount exceeds allowance"
        );
        unchecked {
            _approve(sender, msg.sender, currentAllowance - amount);
        }
        return true;
    }

    function whiteList(
        address newaddress,
        bool flag
    ) public onlyOwner nonReentrant onlyEOA returns (bool) {
        whiteLists[newaddress] = flag;
        return true;
    }

    function buySetGox(
        uint256 usdAmount
    ) external nonReentrant onlyEOA returns (bool) {
        mint(usdAmount, msg.sender);
        return true;
    }

    function buySetGox(
        uint256 usdAmount,
        address toAddress
    ) external nonReentrant onlyEOA returns (bool) {
        mint(usdAmount, toAddress);
        return true;
    }

    function mint(
        uint256 usdAmount,
        address forAddress
    ) internal returns (bool) {
        require(whiteLists[msg.sender] || isBuyOn, "SetGox Buy is not open");
        require(
            usdAmount != 0 && usdAmount >= 1e18,
            "Amount must be greater than 1 USDT"
        );

        uint256 balanceBefore = usdToken.balanceOf(address(this));
        uint256 newRate = rateInUSDT();

        // paid from msg sender
        require(
            usdToken.transferFrom(msg.sender, address(this), usdAmount),
            "USDT transfer failed"
        );

        require(
            usdToken.balanceOf(address(this)) == balanceBefore + usdAmount,
            "USDT transfer amount mismatch"
        );

        uint256 mintValue = ((10 ** _decimals) * ((usdAmount * 945) / 1000)) /
            newRate;
        uint256 creatorValue = mintValue / 100;
        blockTimestampLast = block.timestamp;
        // mint always for address
        _mint(forAddress, mintValue - creatorValue);
        _mint(receiverAddress, creatorValue);

        emit Minted(forAddress, usdAmount, mintValue, newRate);

        //for rate event rateInUSDT();

        return true;
    }

    function mintReward(
        address _user,
        uint256 _amount
    ) external nonReentrant onlyEOA {
        require(whiteLists[msg.sender] || isBuyOn, "SetGox Buy is not open");
        _mint(_user, _amount);
    }

    function sellSetGox(
        uint256 tokenAmount
    ) external nonReentrant onlyEOA returns (bool) {
        burn(tokenAmount, msg.sender);
        return true;
    }

    function sellSetGox(
        uint256 tokenAmount,
        address toAddress
    ) external nonReentrant onlyEOA returns (bool) {
        burn(tokenAmount, toAddress);
        return true;
    }

    function burn(uint256 tokenAmount, address forAddress) internal {
        require(
            tokenAmount != 0 && _balances[msg.sender] >= tokenAmount,
            "Insufficient balance"
        );
        uint256 newRate = rateInUSDT();
        uint256 usdAmount = (tokenAmount * newRate) / (10 ** _decimals);
        uint256 slippage = (usdAmount * burnSlippage) / 100;
        uint256 withdrawFee = (usdAmount * 3) / 1000;

        require(
            usdToken.balanceOf(address(this)) >= usdAmount,
            "Insufficient USDT in contract"
        );
        // burn always msg sender
        _burn(msg.sender, tokenAmount);
        // paid for address
        require(
            usdToken.transfer(forAddress, usdAmount - (slippage + withdrawFee)),
            "USDT transfer to user failed"
        );

        blockTimestampLast = block.timestamp;
        if (_totalSupply > 0)
            usdToken.transfer(sellReceiverAddress, slippage / 5);
        else usdToken.transfer(sellReceiverAddress, slippage);
        usdToken.transfer(treasuryAddress, withdrawFee);

        emit Burned(msg.sender, tokenAmount, usdAmount, newRate);
    }

    function getReserves()
        external
        view
        returns (
            uint256 _reserve0,
            uint256 _reserve1,
            uint256 _blockTimestampLast
        )
    {
        _reserve0 = _totalSupply;
        _reserve1 = usdToken.balanceOf(address(this));
        _blockTimestampLast = blockTimestampLast;
    }

    function rateInUSDT() public view returns (uint256) {
        uint256 pooledUsdt = usdToken.balanceOf(address(this));

        if (_totalSupply > 0) {
            return (pooledUsdt * (10 ** _decimals)) / (_totalSupply);
        } else return InitialRate;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        require(recipient != address(0), "BEP20: transfer to the zero address");

        uint256 senderBalance = _balances[sender];
        require(
            senderBalance >= amount,
            "BEP20: transfer amount exceeds balance"
        );

        // debit from sender
        unchecked {
            _balances[sender] = senderBalance - amount;
        }
        // credit recipient
        _balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "BEP20: mint to the zero address");

        _totalSupply += amount;
        _balances[account] += amount;
        //console.log("Total value ",_totalSupply,_balances[account]);
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "BEP20: burn from the zero address");

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "BEP20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
        }
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "BEP20: approve from the zero address");
        require(spender != address(0), "BEP20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}