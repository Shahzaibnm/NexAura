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

    uint256 public constant CREATOR_FEE_BP = 500; // 5%
    uint256 public constant DAO_FEE_BP = 500;     // 5%
    uint256 public DAO_Amount;

    uint256 public constant DIRECT_INCOME_BP = 500; // 5%
    uint256 public constant MIN_PACKAGE_FOR_LEVEL_INCOME = 50 * BASE;

    event Staked(uint256 orderId, address indexed user, uint256 packageAmount, uint256 mintedAmount, uint256 timestamp);
    event IncomeCredited(address indexed from, address indexed to, uint256 level, uint256 amount, uint8 incomeType);
    // incomeType: 1 = Direct, 2 = Level, 3 = Rank/TeamGrowth, 4 = CTO

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

    struct RankTier {
        uint256 selfStake;
        uint256 directs;
        uint256 matchBusiness;
        uint256 incentiveBp;
    }

    struct CtoTier {
        uint256 directBusiness;
        uint256 teamBusiness;
        uint256 bonusBp;
    }

    RankTier[8] public rankTiers;
    CtoTier[3] public ctoTiers;

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
        userInfos[_owner].lastStake = MAX_PACKAGE;

        rankTiers[0] = RankTier(50 * BASE, 3, 2500 * BASE, 400);
        rankTiers[1] = RankTier(100 * BASE, 6, 5000 * BASE, 600);
        rankTiers[2] = RankTier(200 * BASE, 9, 7500 * BASE, 800);
        rankTiers[3] = RankTier(300 * BASE, 12, 10000 * BASE, 1000);
        rankTiers[4] = RankTier(500 * BASE, 15, 25000 * BASE, 1200);
        rankTiers[5] = RankTier(700 * BASE, 18, 50000 * BASE, 1400);
        rankTiers[6] = RankTier(900 * BASE, 21, 100000 * BASE, 1500);
        rankTiers[7] = RankTier(1200 * BASE, 25, 200000 * BASE, 2000);

        ctoTiers[0] = CtoTier(5000 * BASE, 10000 * BASE, 200);
        ctoTiers[1] = CtoTier(10000 * BASE, 20000 * BASE, 100);
        ctoTiers[2] = CtoTier(20000 * BASE, 40000 * BASE, 100);
    }

    function setTokenAddress(address _token) external onlyOwner nonReentrant {
        require(_token != address(0), "Invalid token address");
        token = INexauraToken(_token);
    }

    function setFeeAddresses(address _creatorFeeAddress, address _treasuryAddress) external onlyOwner nonReentrant {
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

    function makeStake(uint256 usdAmount) external nonReentrant returns (bool) {
        require(userInfos[msg.sender].joined, "caller not registered");
        require(
            usdAmount >= MIN_PACKAGE &&
                usdAmount <= MAX_PACKAGE &&
                usdAmount % PACKAGE_STEP == 0,
            "Invalid package amount"
        );
        require(usdAmount >= userInfos[msg.sender].lastStake, "Package must not decrease");

        bool isFirstStake = userInfos[msg.sender].stakeOrders.length == 0;

        require(usdToken.transferFrom(msg.sender, address(this), usdAmount), "USDT transfer failed");

        uint256 creatorCut = (usdAmount * CREATOR_FEE_BP) / BP_DENOM;
        uint256 daoCut = (usdAmount * DAO_FEE_BP) / BP_DENOM;
        uint256 mintUsd = usdAmount - creatorCut - daoCut;

        require(usdToken.transfer(creatorFeeAddress, creatorCut), "Creator fee transfer failed");
        DAO_Amount += daoCut;

        require(usdToken.transfer(address(token), mintUsd), "Mint funding transfer failed");
        uint256 mintedAmount = token.pricedBuy(mintUsd, msg.sender);

        allStake++;
        stakeInfos[allStake] = Order({
            ownerAddress: msg.sender,
            orderValue: usdAmount,
            orderTime: block.timestamp,
            isComplete: false
        });
        userInfos[msg.sender].stakeOrders.push(allStake);

        if (isFirstStake) {
            address ref = userInfos[msg.sender].referral;
            if (ref != address(0)) {
                userInfos[ref].directs.push(msg.sender);
                userInfos[ref].directJoinTimes.push(block.timestamp);
            }
            userInfos[msg.sender].harvestTime = block.timestamp;
        }

        userInfos[msg.sender].lastStake = usdAmount;

        _distributeCascade(msg.sender, mintedAmount, usdAmount);
        _updateBusinessToUpline(userInfos[msg.sender].referral, usdAmount);
        _payCtoBonus(msg.sender, mintedAmount);

        emit Staked(allStake, msg.sender, usdAmount, mintedAmount, block.timestamp);

        return true;
    }

    function levelIncomeBp() public pure returns (uint16[21] memory bp) {
        bp = [
            500, 300, 150, 150, 100, 100, 50, 50, 50, 25, 25, 25, 15, 15, 15, 15, 15, 25, 25, 50, 100
        ];
    }

    function _distributeCascade(address staker, uint256 mintedAmount, uint256 packageAmount) internal {
        address upline = userInfos[staker].referral;
        uint16[21] memory bp = levelIncomeBp();

        for (uint256 i; i < 21 && upline != address(0); i++) {
            if (i == 0) {
                uint256 basis = mintedAmount;
                uint256 uplineStake = userInfos[upline].lastStake;
                if (packageAmount > uplineStake) {
                    basis = (mintedAmount * uplineStake) / packageAmount;
                }
                uint256 amt = (basis * DIRECT_INCOME_BP) / BP_DENOM;
                bonusInfos[upline].referralGains += amt;
                emit IncomeCredited(staker, upline, 1, amt, 1);
            } else if (userInfos[upline].lastStake >= MIN_PACKAGE_FOR_LEVEL_INCOME) {
                uint256 amt = (mintedAmount * bp[i]) / BP_DENOM;
                bonusInfos[upline].levelGains += amt;
                emit IncomeCredited(staker, upline, i + 1, amt, 2);
            }
            upline = userInfos[upline].referral;
        }
    }

    function _updateBusinessToUpline(address user, uint256 amount) internal {
        address current = user;
        uint256 counter;
        while (current != address(0)) {
            if (counter == 0) {
                userInfos[current].directBusiness += amount;
            } else {
                userInfos[current].totalTeamBusiness += amount;
            }
            _updateRank(current);
            counter++;
            current = userInfos[current].referral;
        }
    }

    event RankUpdated(address indexed user, uint256 newRank);

    function _updateRank(address user) internal {
        UserInfo storage u = userInfos[user];
        // Combined downline volume, not totalTeamBusiness alone: _updateBusinessToUpline only
        // credits totalTeamBusiness from depth >= 2 (grandchildren and below), so a leader whose
        // volume comes entirely from first-level directs would never clear any matchBusiness gate
        // if only totalTeamBusiness were checked.
        uint256 matchBusiness = u.directBusiness + u.totalTeamBusiness;

        for (uint256 i = 8; i > 0; i--) {
            RankTier storage tier = rankTiers[i - 1];
            if (
                u.lastStake >= tier.selfStake &&
                u.directs.length >= tier.directs &&
                matchBusiness >= tier.matchBusiness
            ) {
                if (uint8(i) > u.rank) {
                    u.rank = uint8(i);
                    emit RankUpdated(user, i);
                }
                return;
            }
        }
    }

    function _payCtoBonus(address staker, uint256 mintedAmount) internal {
        address current = userInfos[staker].referral;
        bool[3] memory filled;
        uint256 filledCount;
        uint256 depth;

        while (current != address(0) && filledCount < 3 && depth < 150) {
            UserInfo storage u = userInfos[current];
            for (uint256 t = 3; t > 0; t--) {
                CtoTier storage tier = ctoTiers[t - 1];
                // Same combined-volume reasoning as _updateRank's matchBusiness: teamBusiness is
                // meant to gate on the ancestor's whole downline, not only the depth->=2 slice.
                if (!filled[t - 1] && u.directBusiness >= tier.directBusiness && (u.directBusiness + u.totalTeamBusiness) >= tier.teamBusiness) {
                    uint256 amt = (mintedAmount * tier.bonusBp) / BP_DENOM;
                    bonusInfos[current].ctoGains += amt;
                    emit IncomeCredited(staker, current, t, amt, 4);
                    filled[t - 1] = true;
                    filledCount++;
                    break;
                }
            }
            current = u.referral;
            depth++;
        }
    }
}
