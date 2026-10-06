// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface INexauraToken {
    function balanceOf(address account) external view returns (uint256);
    function rateInUSDT() external view returns (uint256);
    function reservePoolAddress() external view returns (address);
    function pricedBuy(uint256 usdAmount, address forAddress) external returns (uint256);
    function mintTo(address to, uint256 amount) external;
    function creditReserve(uint256 usdAmount) external;
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUSDLike {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
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

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

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
        if (owner() != _msgSender())
            revert OwnableUnauthorizedAccount(_msgSender());
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

contract NexauraStakingV2 is Ownable, ReentrancyGuard {
    INexauraToken public token;
    IUSDLike public usdToken;
    address public creatorFeeAddress;

    uint256 internal constant BASE = 1e18;
    uint256 internal constant BP_DENOM = 10000;

    uint256 public constant MIN_PACKAGE = 10 * BASE;
    uint256 public constant MAX_PACKAGE = 1000 * BASE;
    uint256 public constant PACKAGE_STEP = 10 * BASE;

    uint256 public constant CREATOR_FEE_BP = 500; // 5%
    uint256 public constant DAO_FEE_BP = 500; // 5%
    uint256 public constant RESERVE_FEE_BP = 900; // 9% (10% of the 90%)
    uint256 public constant DIRECT_INCOME_BP = 500; // 5% of the full stake
    uint256 public constant MIN_PACKAGE_FOR_LEVEL_INCOME = 50 * BASE;

    uint256 public constant ROI_BP = 1250; // 1.25%/day x 10 days
    uint256 public constant ONE_DAY = 1 days;
    uint256 public constant MATURITY_PERIOD = 10 days;
    uint256 public constant GRACE_PERIOD = 7 days;

    uint256 public constant WORKING_CAP_MULT = 3;
    uint256 public constant NONWORKING_CAP_MULT = 2;
    uint256 public constant MIN_DIRECTS_FOR_WORKING = 2;

    uint256 public constant SPOTBONUS_MIN_PACKAGE = 50 * BASE;
    uint256 public constant SPOTBONUS_DIST_INTERVAL = 1 days;
    uint256 public constant DAO_DIST_INTERVAL = 7 days;
    uint256 public constant CTO_DIST_INTERVAL = 30 days;

    uint256 public constant MIN_WITHDRAW = 10 * BASE;
    uint256 public constant MAX_DAILY_WITHDRAW = 3000 * BASE;
    uint256 public constant WITHDRAW_CREATOR_BP = 500; // 5% of the reward
    uint256 public constant WITHDRAW_SPOTBONUS_BP = 500; // 5% of the reward

    uint256 public DAO_Amount; // USDT held, forwarded to the token reserve at distributeDAO
    uint256 public allStake;
    uint256 public dailySpotBonusPool; // TOKENS, fed by the 5% claim cut
    uint256 public monthVolumeUsd; // stake volume since the last CTO run
    uint256 public ctoRunId;
    uint256 public lastSpotBonusDistribution;
    uint256 public lastDaoDistribution;
    uint256 public lastCtoDistribution;

    mapping(address => uint256) public lastWithdrawDay;
    mapping(address => uint256) public withdrawnToday;
    mapping(address => uint256) public lastCtoRun; // dedupe guard for candidate lists

    struct UserInfo {
        address referral;
        bool joined;
        uint256 lastStake; // USD of the newest stake
        uint256 selfBusiness; // USD, cumulative own stakes (rank "self" column)
        uint256[] stakeOrders;
        address[] directs;
        uint256[] directJoinTimes;
        uint256 directBusiness; // USD
        uint256 totalTeamBusiness; // USD
        uint8 rank; // 0 = none, 1-11
        uint256 daoJoinTime;
        uint256 daoShare;
        uint256 lastRankPay;
    }

    struct Order {
        address ownerAddress;
        uint256 usdAmount;
        uint256 lockedTokens;
        uint256 startTime;
        bool claimed;
    }

    struct RankTier {
        uint256 selfStake;
        uint256 directsCount;
        uint256 teamBusiness;
        uint256 incentiveBp;
    }

    struct DaoTier {
        uint256 directBusiness;
        uint256 matchingBusiness;
        uint256 share;
        uint256 duration;
    }

    struct CtoTier {
        uint256 directBusiness;
        uint256 teamBusiness;
        uint256 bonusBp;
    }

    // All gains in TOKENS.
    struct BonusInfo {
        uint256 referralGains;
        uint256 levelGains;
        uint256 roiGains;
        uint256 teamGrowthGains;
        uint256 ctoGains;
        uint256 spotBonusGains;
        uint256 daoGains;
        uint256 referralClaimed;
        uint256 levelClaimed;
        uint256 roiClaimed;
        uint256 teamGrowthClaimed;
        uint256 ctoClaimed;
        uint256 spotBonusClaimed;
        uint256 daoClaimed;
    }

    mapping(address => UserInfo) public userInfos;
    mapping(uint256 => Order) public stakeInfos;
    mapping(address => BonusInfo) public bonusInfos;
    mapping(uint256 => RankTier) public rankTiers; // index 0 = tier 1
    mapping(uint256 => DaoTier) public daoTiers;
    mapping(uint256 => CtoTier) public ctoTiers;

    address[] public daoQualifiedUsers;
    mapping(address => bool) public isDaoQualified;

    event RegisterUser(address indexed user, address indexed referral);
    event Staked(address indexed user, uint256 orderId, uint256 usdAmount, uint256 lockedTokens);
    event OrderClaimed(address indexed user, uint256 orderId, uint256 principal, uint256 roi);
    event IncomeCredited(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint8 incomeType
    );
    // incomeType: 1 Direct, 2 Level, 3 ROI, 4 Rank, 5 CTO, 6 Spot Bonus, 7 DAO
    event RankUpdated(address indexed user, uint8 newRank);
    event DaoShareUpdated(address indexed user, uint256 newShare);
    event SpotBonusDistributed(uint256 pool, uint256 qualifiedCount);
    event DaoDistributed(uint256 pool, uint256 totalShares);
    event CtoDistributed(uint256 revenueUsd, uint256 core1, uint256 core2, uint256 core3);
    event Withdrawn(
        address indexed user,
        uint256 grossAmount,
        uint256 netAmount,
        uint8 gainType
    );

    constructor(
        address _owner,
        address _usdtAddress,
        address _creatorFeeAddress
    ) Ownable(_owner) {
        require(_usdtAddress != address(0), "Invalid USDT address");
        require(_creatorFeeAddress != address(0), "Invalid creator fee address");
        usdToken = IUSDLike(_usdtAddress);
        creatorFeeAddress = _creatorFeeAddress;

        // Bootstrap: lets the first real user register under the owner.
        userInfos[_owner].joined = true;
        userInfos[_owner].lastStake = MAX_PACKAGE;
        userInfos[_owner].daoJoinTime = block.timestamp;

        rankTiers[0] = RankTier(50 * BASE, 3, 2500 * BASE, 400); // Silver
        rankTiers[1] = RankTier(100 * BASE, 6, 5000 * BASE, 600); // Gold
        rankTiers[2] = RankTier(200 * BASE, 9, 7500 * BASE, 800); // Pearl
        rankTiers[3] = RankTier(300 * BASE, 12, 10000 * BASE, 1000); // Platinum
        rankTiers[4] = RankTier(500 * BASE, 15, 25000 * BASE, 1200); // Sapphire
        rankTiers[5] = RankTier(700 * BASE, 18, 50000 * BASE, 1400); // Ruby
        rankTiers[6] = RankTier(900 * BASE, 25, 100000 * BASE, 1600); // Emerald
        rankTiers[7] = RankTier(1200 * BASE, 30, 250000 * BASE, 1800); // Diamond
        rankTiers[8] = RankTier(2500 * BASE, 35, 500000 * BASE, 2000); // Black Diamond
        rankTiers[9] = RankTier(5000 * BASE, 40, 1000000 * BASE, 2500); // Crown Diamond
        rankTiers[10] = RankTier(10000 * BASE, 60, 2500000 * BASE, 2800); // Kohinoor Diamond

        daoTiers[0] = DaoTier(500 * BASE, 1000 * BASE, 1, 10 days);
        daoTiers[1] = DaoTier(1000 * BASE, 2000 * BASE, 2, 20 days);
        daoTiers[2] = DaoTier(3000 * BASE, 4000 * BASE, 6, 30 days);

        ctoTiers[0] = CtoTier(5000 * BASE, 10000 * BASE, 200);
        ctoTiers[1] = CtoTier(10000 * BASE, 20000 * BASE, 100);
        ctoTiers[2] = CtoTier(20000 * BASE, 40000 * BASE, 100);

        lastSpotBonusDistribution = block.timestamp;
        lastDaoDistribution = block.timestamp;
        lastCtoDistribution = block.timestamp;
    }

    function setTokenAddress(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        token = INexauraToken(_token);
    }

    function regUser(address referral) external nonReentrant returns (bool) {
        require(!userInfos[msg.sender].joined, "Already registered");
        require(userInfos[referral].lastStake > 0, "Referral has not staked yet");

        userInfos[msg.sender].referral = referral;
        userInfos[msg.sender].joined = true;
        userInfos[msg.sender].daoJoinTime = block.timestamp; // each DAO tier's window starts counting from right here

        emit RegisterUser(msg.sender, referral);
        return true;
    }

    // Credits usdAmount as directBusiness to the staker's immediate referral, and as
    // totalTeamBusiness to every ancestor above that -- then re-checks each ancestor's rank
    // against the new totals. Called on every stake (not just first), so a user's business (and
    // rank) keeps growing with every recycle their downline does too.
    function _updateBusinessToUpline(address user, uint256 amount) internal {
        address current = user;
        uint256 depth;
        while (current != address(0)) {
            if (depth == 0) {
                userInfos[current].directBusiness += amount;
            } else {
                userInfos[current].totalTeamBusiness += amount;
            }
            _updateRank(current);
            _updateDaoShare(current);
            depth++;
            current = userInfos[current].referral;
        }
    }

    // Each DAO tier is an independent qualification path with its OWN deadline, measured from
    // the user's own daoJoinTime (set at registration) -- not a single flat window shared by all
    // tiers. Missing a tier's own deadline forfeits that tier forever, but does NOT forfeit a
    // higher tier whose (longer) window is still open. Share is OVERRIDDEN (not added) as higher
    // tiers qualify, and once earned it's permanent -- DAO membership never expires or downgrades.
    function _updateDaoShare(address user) internal {
        UserInfo storage u = userInfos[user];
        if (u.daoJoinTime == 0) return; // not registered yet

        uint256 combined = u.directBusiness + u.totalTeamBusiness;

        for (uint256 i = 3; i > 0; i--) {
            DaoTier storage tier = daoTiers[i - 1];
            if (tier.share <= u.daoShare) continue; // already hold this tier or better
            if (block.timestamp > u.daoJoinTime + tier.duration) continue; // this tier's window closed
            if (
                u.directBusiness >= tier.directBusiness ||
                combined >= tier.matchingBusiness
            ) {
                if (!isDaoQualified[user]) {
                    isDaoQualified[user] = true;
                    daoQualifiedUsers.push(user);
                }
                u.daoShare = tier.share;
                emit DaoShareUpdated(user, tier.share);
                break; // highest still-open, still-qualifying tier found
            }
        }
    }

    function _updateRank(address user) internal {
        UserInfo storage u = userInfos[user];
        uint256 combined = u.directBusiness + u.totalTeamBusiness;
        for (uint256 t = 11; t > u.rank; t--) {
            RankTier storage tier = rankTiers[t - 1];
            if (
                u.selfBusiness >= tier.selfStake &&
                u.directs.length >= tier.directsCount &&
                combined >= tier.teamBusiness
            ) {
                u.rank = uint8(t);
                emit RankUpdated(user, uint8(t));
                break;
            }
        }
    }

    // Income window: 10 days from the newest stake plus the 7-day grace.
    function _canEarn(address user) internal view returns (bool) {
        uint256[] storage orders = userInfos[user].stakeOrders;
        if (orders.length == 0) return false;
        return
            block.timestamp <
            stakeInfos[orders[orders.length - 1]].startTime + MATURITY_PERIOD + GRACE_PERIOD;
    }

    function _unclaimedLockedSum(address user) internal view returns (uint256 sum) {
        uint256[] storage orders = userInfos[user].stakeOrders;
        for (uint256 i; i < orders.length; i++) {
            Order storage o = stakeInfos[orders[i]];
            if (!o.claimed) sum += o.lockedTokens;
        }
    }

    function _capOf(address user) internal view returns (uint256) {
        uint256 mult = userInfos[user].directs.length >= MIN_DIRECTS_FOR_WORKING
            ? WORKING_CAP_MULT
            : NONWORKING_CAP_MULT;
        return _unclaimedLockedSum(user) * mult;
    }

    function _totalGains(address user) internal view returns (uint256) {
        BonusInfo storage b = bonusInfos[user];
        return
            b.referralGains +
            b.levelGains +
            b.roiGains +
            b.teamGrowthGains +
            b.ctoGains +
            b.spotBonusGains +
            b.daoGains;
    }

    function _totalClaimed(address user) internal view returns (uint256) {
        BonusInfo storage b = bonusInfos[user];
        return
            b.referralClaimed +
            b.levelClaimed +
            b.roiClaimed +
            b.teamGrowthClaimed +
            b.ctoClaimed +
            b.spotBonusClaimed +
            b.daoClaimed;
    }

    function _capRoom(address user) internal view returns (uint256) {
        uint256 total = _totalGains(user);
        uint256 cap = _capOf(user);
        return total >= cap ? 0 : cap - total;
    }

    function _clampToCapRoom(address user, uint256 amount) internal view returns (uint256) {
        uint256 room = _capRoom(user);
        return amount > room ? room : amount;
    }

    function _toTokenAmount(uint256 usdAmount) internal view returns (uint256) {
        return (usdAmount * BASE) / token.rateInUSDT();
    }

    function _toUsdAmount(uint256 tokenAmount) internal view returns (uint256) {
        return (tokenAmount * token.rateInUSDT()) / BASE;
    }

    function makeStake(uint256 usdAmount) external nonReentrant returns (bool) {
        UserInfo storage u = userInfos[msg.sender];
        require(u.joined, "caller not registered");
        require(
            usdAmount >= MIN_PACKAGE &&
                usdAmount <= MAX_PACKAGE &&
                usdAmount % PACKAGE_STEP == 0,
            "Invalid package amount"
        );
        require(usdAmount >= u.lastStake, "Package must not decrease");

        bool isFirstStake = u.stakeOrders.length == 0;
        require(
            usdToken.transferFrom(msg.sender, address(this), usdAmount),
            "USDT transfer failed"
        );

        uint256 creatorCut = (usdAmount * CREATOR_FEE_BP) / BP_DENOM;
        uint256 daoCut = (usdAmount * DAO_FEE_BP) / BP_DENOM;
        uint256 reserveCut = (usdAmount * RESERVE_FEE_BP) / BP_DENOM;
        uint256 mintUsd = usdAmount - creatorCut - daoCut - reserveCut;

        require(
            usdToken.transfer(creatorFeeAddress, creatorCut),
            "Creator fee transfer failed"
        );
        require(
            usdToken.transfer(token.reservePoolAddress(), reserveCut),
            "Reserve transfer failed"
        );
        DAO_Amount += daoCut;
        require(
            usdToken.transfer(address(token), mintUsd),
            "Mint funding transfer failed"
        );
        uint256 locked = token.pricedBuy(mintUsd, address(this)); // locked in this contract

        allStake++;
        stakeInfos[allStake] = Order(msg.sender, usdAmount, locked, block.timestamp, false);
        u.stakeOrders.push(allStake);
        u.lastStake = usdAmount;
        u.selfBusiness += usdAmount;
        monthVolumeUsd += usdAmount;

        address upline = u.referral;
        if (isFirstStake && upline != address(0)) {
            userInfos[upline].directs.push(msg.sender);
            userInfos[upline].directJoinTimes.push(block.timestamp);
        }

        // Direct income: 5% of the FULL stake, as tokens at the live rate.
        if (upline != address(0) && _canEarn(upline)) {
            uint256 directAmt = _clampToCapRoom(
                upline,
                _toTokenAmount((usdAmount * DIRECT_INCOME_BP) / BP_DENOM)
            );
            if (directAmt > 0) {
                bonusInfos[upline].referralGains += directAmt;
                emit IncomeCredited(msg.sender, upline, directAmt, 1);
            }
        }

        _updateBusinessToUpline(upline, usdAmount);
        _updateRank(msg.sender);

        emit Staked(msg.sender, allStake, usdAmount, locked);
        return true;
    }

    function levelIncomeBp() public pure returns (uint16[20] memory) {
        return [
            300, 150, 150, 100, 100, 50, 50, 50, 25, 25,
            25, 15, 15, 15, 15, 15, 25, 25, 50, 100
        ];
    }

    // Pays levels 2-21 as a % of the ROI the claimer just collected (tokens).
    function _distributeLevelIncome(address claimer, uint256 roiTokens) internal {
        uint16[20] memory bp = levelIncomeBp();
        // Start at the 2nd ancestor -- the immediate referral already got Direct Income.
        address upline = userInfos[userInfos[claimer].referral].referral;

        for (uint256 i; i < 20 && upline != address(0); i++) {
            if (
                userInfos[upline].lastStake >= MIN_PACKAGE_FOR_LEVEL_INCOME &&
                _canEarn(upline)
            ) {
                uint256 amt = _clampToCapRoom(upline, (roiTokens * bp[i]) / BP_DENOM);
                if (amt > 0) {
                    bonusInfos[upline].levelGains += amt;
                    emit IncomeCredited(claimer, upline, amt, 2);
                }
            }
            upline = userInfos[upline].referral;
        }
    }

    // Rank income for the claimer's own cycle: 12.5% x combined business (USD) x incentive %.
    // At most once per 10 days so several orders claimed together don't pay it repeatedly.
    function _payRankIncome(address user) internal {
        UserInfo storage u = userInfos[user];
        if (u.rank == 0 || !_canEarn(user)) return;
        if (block.timestamp < u.lastRankPay + MATURITY_PERIOD) return;

        uint256 combinedUsd = u.directBusiness + u.totalTeamBusiness;
        uint256 rankUsd = (((combinedUsd * ROI_BP) / BP_DENOM) *
            rankTiers[u.rank - 1].incentiveBp) / BP_DENOM;
        uint256 amt = _clampToCapRoom(user, _toTokenAmount(rankUsd));
        u.lastRankPay = block.timestamp;
        if (amt > 0) {
            bonusInfos[user].teamGrowthGains += amt;
            emit IncomeCredited(user, user, amt, 4);
        }
    }

    function _checkDailyCap(address user, uint256 usdValue) internal {
        uint256 today = block.timestamp / ONE_DAY;
        if (lastWithdrawDay[user] != today) {
            lastWithdrawDay[user] = today;
            withdrawnToday[user] = 0;
        }
        require(
            withdrawnToday[user] + usdValue <= MAX_DAILY_WITHDRAW,
            "Exceeds daily withdrawal cap"
        );
        withdrawnToday[user] += usdValue;
    }

    // Returns principal tokens + ROI. ROI is minted; a 10% fee is taken from the ROI only.
    // Exempt from MIN_WITHDRAW (a $10 package locks ~$8.10 of tokens).
    function claimOrder(uint256 orderId) external nonReentrant {
        Order storage o = stakeInfos[orderId];
        require(o.ownerAddress == msg.sender, "Not your order");
        require(!o.claimed, "Already claimed");
        require(block.timestamp >= o.startTime + MATURITY_PERIOD, "Order not mature");

        // Cap room is read while this order still counts as unclaimed.
        uint256 roi = _clampToCapRoom(msg.sender, (o.lockedTokens * ROI_BP) / BP_DENOM);
        bonusInfos[msg.sender].roiGains += roi;
        bonusInfos[msg.sender].roiClaimed += roi;
        if (roi > 0) {
            emit IncomeCredited(msg.sender, msg.sender, roi, 3);
            _payRankIncome(msg.sender); // before the order is marked claimed, so the cap still has room
        }
        o.claimed = true;

        uint256 creatorCut = (roi * WITHDRAW_CREATOR_BP) / BP_DENOM;
        uint256 spotCut = (roi * WITHDRAW_SPOTBONUS_BP) / BP_DENOM;
        uint256 netRoi = roi - creatorCut - spotCut;
        dailySpotBonusPool += spotCut;
        if (creatorCut > 0) token.mintTo(creatorFeeAddress, creatorCut);
        if (netRoi > 0) token.mintTo(msg.sender, netRoi);
        require(token.transfer(msg.sender, o.lockedTokens), "Principal transfer failed");

        _checkDailyCap(msg.sender, _toUsdAmount(o.lockedTokens + netRoi));
        if (roi > 0) _distributeLevelIncome(msg.sender, roi);

        emit OrderClaimed(msg.sender, orderId, o.lockedTokens, roi);
    }

    // Highest CTO tier the user qualifies for: direct business OR team matching business.
    function _ctoTierOf(address user) internal view returns (uint8) {
        UserInfo storage u = userInfos[user];
        uint256 combined = u.directBusiness + u.totalTeamBusiness;
        for (uint256 t = 3; t > 0; t--) {
            CtoTier storage tier = ctoTiers[t - 1];
            if (u.directBusiness >= tier.directBusiness || combined >= tier.teamBusiness) {
                return uint8(t);
            }
        }
        return 0;
    }

    // ponytail: owner supplies the candidate list (no on-chain registry of all users);
    // add an indexer-fed list or pagination if the qualified set grows large.
    // Each tier's pool (tier % of the month's stake volume) is split equally among that tier's
    // qualified users; a user only collects their highest tier. Duplicates are paid once.
    function distributeCTO(address[] calldata candidates) external onlyOwner nonReentrant {
        require(block.timestamp >= lastCtoDistribution + CTO_DIST_INTERVAL, "Too soon");
        ctoRunId++;

        uint8[] memory tierOf = new uint8[](candidates.length);
        uint256[3] memory counts;
        for (uint256 i; i < candidates.length; i++) {
            address c = candidates[i];
            if (lastCtoRun[c] == ctoRunId || !_canEarn(c)) continue;
            uint8 t = _ctoTierOf(c);
            if (t == 0) continue;
            lastCtoRun[c] = ctoRunId;
            tierOf[i] = t;
            counts[t - 1]++;
        }

        uint256[3] memory perUser;
        for (uint256 t; t < 3; t++) {
            if (counts[t] > 0) {
                uint256 poolTokens = _toTokenAmount(
                    (monthVolumeUsd * ctoTiers[t].bonusBp) / BP_DENOM
                );
                perUser[t] = poolTokens / counts[t];
            }
        }
        for (uint256 i; i < candidates.length; i++) {
            if (tierOf[i] == 0) continue;
            uint256 amt = _clampToCapRoom(candidates[i], perUser[tierOf[i] - 1]);
            if (amt > 0) {
                bonusInfos[candidates[i]].ctoGains += amt;
                emit IncomeCredited(candidates[i], candidates[i], amt, 5);
            }
        }

        emit CtoDistributed(monthVolumeUsd, counts[0], counts[1], counts[2]);
        monthVolumeUsd = 0;
        lastCtoDistribution = block.timestamp;
    }

    // ponytail: iterates every DAO-qualified user; paginate if that set grows large.
    // Winners' shares are credited as tokens (minted at claim); the whole USDT pool then moves
    // into the token's reserve to back them.
    function distributeDAO() external onlyOwner nonReentrant {
        require(block.timestamp >= lastDaoDistribution + DAO_DIST_INTERVAL, "Too soon");

        uint256 totalShares;
        for (uint256 i; i < daoQualifiedUsers.length; i++) {
            totalShares += userInfos[daoQualifiedUsers[i]].daoShare;
        }

        uint256 pool = DAO_Amount;
        if (totalShares > 0 && pool > 0) {
            for (uint256 i; i < daoQualifiedUsers.length; i++) {
                address u = daoQualifiedUsers[i];
                uint256 share = userInfos[u].daoShare;
                if (share == 0 || !_canEarn(u)) continue;
                uint256 payoutUsd = (pool * share) / totalShares;
                if (payoutUsd == 0) continue;
                uint256 amt = _clampToCapRoom(u, _toTokenAmount(payoutUsd));
                if (amt > 0) {
                    bonusInfos[u].daoGains += amt;
                    emit IncomeCredited(u, u, amt, 7);
                }
            }
        }

        if (pool > 0) {
            require(usdToken.transfer(address(token), pool), "Reserve funding failed");
            token.creditReserve(pool);
        }
        emit DaoDistributed(pool, totalShares);
        DAO_Amount = 0;
        lastDaoDistribution = block.timestamp;
    }

    // 2+ directs whose OWN first stake landed within the last 24h, each at $50+. Looks back at
    // most 20 of the most recent directs (directJoinTimes is appended in chronological order, so
    // once an entry is older than 24h everything before it is too -- safe to stop there).
    function qualifiesForSpotBonus(address user) public view returns (bool) {
        UserInfo storage u = userInfos[user];
        uint256[] storage times = u.directJoinTimes;
        address[] storage directs = u.directs;
        uint256 len = times.length;
        uint256 count;

        for (uint256 i = len; i > 0 && (len - i) < 20; i--) {
            if (block.timestamp - times[i - 1] > 1 days) break;
            if (userInfos[directs[i - 1]].lastStake >= SPOTBONUS_MIN_PACKAGE) {
                count++;
                if (count >= 2) return true;
            }
        }
        return false;
    }

    // ponytail: iterates only the caller-supplied candidate list; the owner (or an indexer)
    // supplies today's plausible qualifiers. The pool is in tokens and only resets when someone
    // qualified, so an empty day does not burn it. Duplicate addresses are paid once.
    function distributeSpotBonus(
        address[] calldata candidates
    ) external onlyOwner nonReentrant {
        require(
            block.timestamp >= lastSpotBonusDistribution + SPOTBONUS_DIST_INTERVAL,
            "Too soon"
        );

        bool[] memory pay = new bool[](candidates.length);
        uint256 qualifiedCount;
        for (uint256 i; i < candidates.length; i++) {
            bool dup;
            for (uint256 j; j < i; j++) {
                if (candidates[j] == candidates[i]) {
                    dup = true;
                    break;
                }
            }
            if (!dup && qualifiesForSpotBonus(candidates[i]) && _canEarn(candidates[i])) {
                pay[i] = true;
                qualifiedCount++;
            }
        }

        uint256 pool = dailySpotBonusPool;
        if (qualifiedCount > 0 && pool > 0) {
            uint256 share = pool / qualifiedCount;
            for (uint256 i; i < candidates.length; i++) {
                if (!pay[i]) continue;
                uint256 amt = _clampToCapRoom(candidates[i], share);
                if (amt > 0) {
                    bonusInfos[candidates[i]].spotBonusGains += amt;
                    emit IncomeCredited(candidates[i], candidates[i], amt, 6);
                }
            }
            dailySpotBonusPool = 0;
        }

        emit SpotBonusDistributed(pool, qualifiedCount);
        lastSpotBonusDistribution = block.timestamp;
    }

    function capOf(address user) external view returns (uint256) {
        return _capOf(user);
    }

    // Tokens claimable right now across all types: min(totalGains, cap) - claimed.
    function claimable(address user) public view returns (uint256) {
        uint256 total = _totalGains(user);
        uint256 cap = _capOf(user);
        uint256 capped = total > cap ? cap : total;
        uint256 claimed = _totalClaimed(user);
        return capped > claimed ? capped - claimed : 0;
    }

    function _claimableOfType(
        address user,
        uint256 gain,
        uint256 claimedOfType
    ) internal view returns (uint256) {
        uint256 own = gain > claimedOfType ? gain - claimedOfType : 0;
        uint256 room = claimable(user);
        return own > room ? room : own;
    }

    function claimableReferralGains(address u) public view returns (uint256) {
        BonusInfo storage b = bonusInfos[u];
        return _claimableOfType(u, b.referralGains, b.referralClaimed);
    }

    function claimableLevelGains(address u) public view returns (uint256) {
        BonusInfo storage b = bonusInfos[u];
        return _claimableOfType(u, b.levelGains, b.levelClaimed);
    }

    function claimableTeamGrowthGains(address u) public view returns (uint256) {
        BonusInfo storage b = bonusInfos[u];
        return _claimableOfType(u, b.teamGrowthGains, b.teamGrowthClaimed);
    }

    function claimableCtoGains(address u) public view returns (uint256) {
        BonusInfo storage b = bonusInfos[u];
        return _claimableOfType(u, b.ctoGains, b.ctoClaimed);
    }

    function claimableSpotBonusGains(address u) public view returns (uint256) {
        BonusInfo storage b = bonusInfos[u];
        return _claimableOfType(u, b.spotBonusGains, b.spotBonusClaimed);
    }

    function claimableDaoGains(address u) public view returns (uint256) {
        BonusInfo storage b = bonusInfos[u];
        return _claimableOfType(u, b.daoGains, b.daoClaimed);
    }

    // Mints the net amount to the user; 5% creator is minted, 5% goes to the spot-bonus pool.
    function _claimIncome(address user, uint256 amount, uint8 gainType) internal {
        require(amount > 0, "Nothing to claim");
        uint256 usdValue = _toUsdAmount(amount);
        require(usdValue >= MIN_WITHDRAW, "Below minimum withdrawal");
        _checkDailyCap(user, usdValue);

        uint256 creatorCut = (amount * WITHDRAW_CREATOR_BP) / BP_DENOM;
        uint256 spotCut = (amount * WITHDRAW_SPOTBONUS_BP) / BP_DENOM;
        uint256 net = amount - creatorCut - spotCut;
        dailySpotBonusPool += spotCut;
        token.mintTo(creatorFeeAddress, creatorCut);
        token.mintTo(user, net);
        emit Withdrawn(user, amount, net, gainType);
    }

    function claimReferralGains() external nonReentrant {
        uint256 amount = claimableReferralGains(msg.sender);
        bonusInfos[msg.sender].referralClaimed += amount;
        _claimIncome(msg.sender, amount, 1);
    }

    function claimLevelGains() external nonReentrant {
        uint256 amount = claimableLevelGains(msg.sender);
        bonusInfos[msg.sender].levelClaimed += amount;
        _claimIncome(msg.sender, amount, 2);
    }

    function claimTeamGrowthGains() external nonReentrant {
        uint256 amount = claimableTeamGrowthGains(msg.sender);
        bonusInfos[msg.sender].teamGrowthClaimed += amount;
        _claimIncome(msg.sender, amount, 4);
    }

    function claimCtoGains() external nonReentrant {
        uint256 amount = claimableCtoGains(msg.sender);
        bonusInfos[msg.sender].ctoClaimed += amount;
        _claimIncome(msg.sender, amount, 5);
    }

    function claimSpotBonusGains() external nonReentrant {
        uint256 amount = claimableSpotBonusGains(msg.sender);
        bonusInfos[msg.sender].spotBonusClaimed += amount;
        _claimIncome(msg.sender, amount, 6);
    }

    function claimDaoGains() external nonReentrant {
        uint256 amount = claimableDaoGains(msg.sender);
        bonusInfos[msg.sender].daoClaimed += amount;
        _claimIncome(msg.sender, amount, 7);
    }
}
