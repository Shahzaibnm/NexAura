// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

interface IUSDLike {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private _status = NOT_ENTERED;

    error ReentrancyGuardReentrantCall();

    modifier nonReentrant() {
        if (_status == ENTERED) revert ReentrancyGuardReentrantCall();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }
}

contract NexauraTokenV2 is Ownable, ReentrancyGuard {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    uint8 private constant _decimals = 18;
    string private _name;
    string private _symbol;

    uint256 public constant TRANSFER_BURN_BP = 100; // 1%
    uint256 public constant SELL_RESERVE_BP = 1500; // 15%, all to the reserve pool
    uint256 public constant BP_DENOM = 10000;
    uint256 public InitialRate = 1e18;

    IUSDLike public usdToken;
    address public stakingContract;
    address public liquidityPoolAddress;
    address public reservePoolAddress;

    // Tracked separately from usdToken.balanceOf(address(this)) so that anyone
    // directly transferring USDT into this contract (a "donation") cannot
    // inflate the rate and profit off later buyers/sellers computing against
    // it — the classic ERC4626-style share-price inflation attack. Only
    // pricedBuy/pricedSell ever move this figure.
    uint256 public internalReserve;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event StakingContractUpdated(address indexed newStakingContract);

    modifier onlyStaking() {
        require(msg.sender == stakingContract, "Only staking contract");
        _;
    }

    constructor(
        address _owner,
        address _usdtAddress,
        string memory tokenName,
        string memory tokenSymbol,
        address _liquidityPoolAddress,
        address _reservePoolAddress
    ) Ownable(_owner) {
        require(_usdtAddress != address(0), "Invalid USDT address");
        require(_liquidityPoolAddress != address(0), "Invalid liquidity pool address");
        require(_reservePoolAddress != address(0), "Invalid reserve pool address");
        usdToken = IUSDLike(_usdtAddress);
        _name = tokenName;
        _symbol = tokenSymbol;
        liquidityPoolAddress = _liquidityPoolAddress;
        reservePoolAddress = _reservePoolAddress;
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
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

    function allowance(address owner_, address spender) public view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address recipient, uint256 amount) public returns (bool) {
        _transferWithBurn(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public returns (bool) {
        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "NexauraToken: transfer amount exceeds allowance");
        unchecked {
            _approve(sender, msg.sender, currentAllowance - amount);
        }
        _transferWithBurn(sender, recipient, amount);
        return true;
    }

    function _transferWithBurn(address sender, address recipient, uint256 amount) internal {
        require(recipient != address(0), "NexauraToken: transfer to the zero address");
        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "NexauraToken: transfer amount exceeds balance");

        uint256 burnAmount = sender == stakingContract
            ? 0
            : (amount * TRANSFER_BURN_BP) / BP_DENOM;
        uint256 sendAmount = amount - burnAmount;

        unchecked {
            _balances[sender] = senderBalance - amount;
        }
        _balances[recipient] += sendAmount;
        _totalSupply -= burnAmount;

        emit Transfer(sender, recipient, sendAmount);
        if (burnAmount > 0) emit Transfer(sender, address(0), burnAmount);
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        require(owner_ != address(0), "NexauraToken: approve from the zero address");
        require(spender != address(0), "NexauraToken: approve to the zero address");
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "NexauraToken: mint to the zero address");
        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "NexauraToken: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
        }
        _totalSupply -= amount;
        emit Transfer(account, address(0), amount);
    }

    /// @dev Priced off `internalReserve`, NOT `usdToken.balanceOf(address(this))` — see the
    /// field's comment. A raw balanceOf-based rate would let anyone donate USDT directly to
    /// this contract to move the rate before a buy/sell they don't control, then profit by
    /// reversing it afterward (inflation attack). internalReserve only moves through
    /// pricedBuy/pricedSell, so an external donation has zero effect on pricing.
    function rateInUSDT() public view returns (uint256) {
        if (_totalSupply > 0) {
            return (internalReserve * (10 ** _decimals)) / _totalSupply;
        }
        return InitialRate;
    }

    function setStakingContract(address _stakingContract) external onlyOwner {
        require(_stakingContract != address(0), "Invalid staking contract");
        stakingContract = _stakingContract;
        emit StakingContractUpdated(_stakingContract);
    }

    /// @dev Mints `usdAmount` worth of tokens (at the live rate) to `forAddress`. Expects the
    /// staking contract to have already transferred `usdAmount` of USDT into this contract in
    /// the same call chain (see Task 4) — internalReserve is credited here, not inferred from
    /// balanceOf, so the two MUST move together or accounting drifts.
    function pricedBuy(uint256 usdAmount, address forAddress)
        external
        onlyStaking
        nonReentrant
        returns (uint256 mintedAmount)
    {
        require(usdAmount > 0, "Amount must be greater than 0");
        uint256 rate = rateInUSDT();
        mintedAmount = (usdAmount * (10 ** _decimals)) / rate;
        internalReserve += usdAmount;
        _mint(forAddress, mintedAmount);
    }

    /// @dev reservePoolAddress is expected to be a ReservePool contract that has approved this
    /// contract as a spender (see ReservePool.approveSpender). When internalReserve alone can't
    /// cover a payout, this pulls the shortfall straight from there via transferFrom instead of
    /// reverting -- reservePoolAddress is the same insurance/reserve wallet pricedSell already
    /// funds with its 10% cut, so it backstops the token contract running short.
    function _coverShortfall(uint256 shortfall, address forAddress) internal {
        require(
            usdToken.transferFrom(reservePoolAddress, forAddress, shortfall),
            "Reserve pool pull failed"
        );
    }

    /// @dev Public swap: burns 100% of the caller's `tokenAmount`, pays the USD value at the
    /// live rate minus a 15% deduction that goes entirely to the reserve pool. If
    /// internalReserve can't cover the payout, the shortfall is pulled from the reserve pool.
    function sell(uint256 tokenAmount) external nonReentrant returns (uint256 netUsd) {
        require(tokenAmount > 0, "Amount must be greater than 0");
        uint256 usdPaid = (tokenAmount * rateInUSDT()) / (10 ** _decimals);

        _burn(msg.sender, tokenAmount);

        uint256 fromReserve = usdPaid > internalReserve ? internalReserve : usdPaid;
        uint256 shortfall = usdPaid - fromReserve;
        internalReserve -= fromReserve;
        if (shortfall > 0) {
            _coverShortfall(shortfall, address(this));
        }

        uint256 reserveCut = (usdPaid * SELL_RESERVE_BP) / BP_DENOM;
        netUsd = usdPaid - reserveCut;

        require(usdToken.transfer(reservePoolAddress, reserveCut), "Reserve transfer failed");
        require(usdToken.transfer(msg.sender, netUsd), "USDT transfer failed");
    }

    /// @dev Mints reward tokens (ROI, income, fees) with no USDT behind them, by design.
    function mintTo(address to, uint256 amount) external onlyStaking {
        _mint(to, amount);
    }

    /// @dev Credits `usdAmount` into internalReserve, backing the token price. Same push-then-credit pattern as pricedBuy: the caller (staking contract) must
    /// have already transferred that USDT into this contract in the same call chain -- this only
    /// updates the internal accounting to match, it never pulls funds itself.
    function creditReserve(uint256 usdAmount) external onlyStaking nonReentrant {
        require(usdAmount > 0, "Amount must be greater than 0");
        internalReserve += usdAmount;
    }
}
