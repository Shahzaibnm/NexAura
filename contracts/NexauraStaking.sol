// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface INexauraToken {
    function balanceOf(address account) external view returns (uint256);
    function rateInUSDT() external view returns (uint256);
    function pricedBuy(uint256 usdAmount, address forAddress) external returns (uint256);
    function pricedSell(uint256 tokenAmount, address forAddress) external returns (uint256);
    function payoutReserve(uint256 usdAmount, address forAddress) external;
}

interface IUSDLike {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
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

contract NexauraStaking is Ownable, ReentrancyGuard {
    INexauraToken public token;
    IUSDLike public usdToken;

    address public creatorFeeAddress;
    address public treasuryAddress;

    uint256 internal constant BASE = 1e18;
    uint256 internal constant BP_DENOM = 10000;

    uint256 public constant MIN_PACKAGE = 10 * BASE;
    uint256 public constant MAX_PACKAGE = 1000 * BASE;
    uint256 public constant PACKAGE_STEP = 10 * BASE;

    uint256 public totalReg;
    uint256 public allStake;

    struct UserInfo {
        address referral;
        address[] directs;
        uint256[] directJoinTimes;
        uint256 lastStake;
        uint256[] stakeOrders;
        uint256 directBusiness;
        uint256 totalTeamBusiness;
        uint256 harvestTime;
        uint8 rank;
        uint256 daoShare;
        uint256 daoDeadline;
        bool joined;
    }

    struct Order {
        address ownerAddress;
        uint256 orderValue;
        uint256 orderTime;
        bool isComplete;
    }

    struct BonusInfo {
        uint256 referralGains;
        uint256 levelGains;
        uint256 teamGrowthGains;
        uint256 ctoGains;
        uint256 growthGains;
        uint256 workingWithdrawn;
        uint256 nonWorkingWithdrawn;
    }

    mapping(address => UserInfo) public userInfos;
    mapping(uint256 => Order) public stakeInfos;
    mapping(address => BonusInfo) public bonusInfos;

    event RegisterUser(address indexed user, address indexed referral);

    constructor(
        address _owner,
        address _usdtAddress,
        address _creatorFeeAddress,
        address _treasuryAddress
    ) Ownable(_owner) {
        require(_usdtAddress != address(0), "Invalid USDT address");
        require(_creatorFeeAddress != address(0) && _treasuryAddress != address(0), "Invalid fee address");
        usdToken = IUSDLike(_usdtAddress);
        creatorFeeAddress = _creatorFeeAddress;
        treasuryAddress = _treasuryAddress;

        userInfos[_owner].joined = true;
        userInfos[_owner].lastStake = MIN_PACKAGE;
    }

    function setTokenAddress(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        token = INexauraToken(_token);
    }

    function setFeeAddresses(address _creatorFeeAddress, address _treasuryAddress) external onlyOwner {
        require(_creatorFeeAddress != address(0) && _treasuryAddress != address(0), "Invalid fee address");
        creatorFeeAddress = _creatorFeeAddress;
        treasuryAddress = _treasuryAddress;
    }

    function regUser(address referral) external nonReentrant returns (bool) {
        _regUser(msg.sender, referral);
        return true;
    }

    function _regUser(address user, address referral) internal {
        require(!userInfos[user].joined, "Already registered");
        require(referral != address(0) && userInfos[referral].joined, "Invalid referral");

        totalReg++;
        userInfos[user].referral = referral;
        userInfos[user].joined = true;

        emit RegisterUser(user, referral);
    }

    function directsOf(address user) external view returns (address[] memory) {
        return userInfos[user].directs;
    }
}
