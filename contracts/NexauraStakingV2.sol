// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface INexauraToken {
    function balanceOf(address account) external view returns (uint256);
    function rateInUSDT() external view returns (uint256);
    function insurancePoolAddress() external view returns (address);
    function pricedBuy(uint256 usdAmount, address forAddress) external returns (uint256);
    function creditReserve(uint256 usdAmount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
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
    uint256 public constant MAX_PACKAGE = 100000 * BASE;
    uint256 public constant PACKAGE_STEP = 10 * BASE;

    uint256 public constant CREATOR_FEE_BP = 500; // 5%
    uint256 public constant DAO_FEE_BP = 500; // 5%
    uint256 public constant LIQUIDITY_FEE_BP = 900; // 9% USDT reserve share; no liquidity tokens minted
    uint256 public constant DIRECT_INCOME_BP = 500; // 5% of the full stake
    uint256 public constant MIN_PACKAGE_FOR_LEVEL_INCOME = 50 * BASE;

    uint256 public constant ROI_BP = 1250; // 1.25%/day x 10 days
    uint256 public constant ONE_DAY = 1 minutes;
    uint256 public constant MATURITY_PERIOD = 10 minutes;
    uint256 public constant GRACE_PERIOD = 7 minutes;
    uint256 public constant RANK_DAY = MATURITY_PERIOD / 10; // one "day" of rank income
    uint256 public constant RANK_DAILY_BP = 125; // 1.25% of the tier's match amount, per day

    uint256 public constant WORKING_CAP_MULT = 3;
    uint256 public constant NONWORKING_CAP_MULT = 2;
    uint256 public constant MIN_DIRECTS_FOR_WORKING = 2;

    uint256 public constant SPOTBONUS_MIN_PACKAGE = 50 * BASE;
    uint256 public constant SPOTBONUS_DIST_INTERVAL = 1 days;
    uint256 public constant SPOT_TIER1_BP = 3000; // 30% of the pool: users with 1 qualifying direct
    uint256 public constant SPOT_TIER2_BP = 7000; // 70% of the pool: users with 2+ qualifying directs
    uint256 public constant DAO_DIST_INTERVAL = 7 minutes;
    uint256 public constant CTO_DIST_INTERVAL = 15 minutes; // 15 "days" in this contract's 1 day = 1 minute test scale

    uint256 public constant MIN_WITHDRAW = 10 * BASE;
    uint256 public constant MAX_DAILY_WITHDRAW = 3000 * BASE;
    uint256 public constant WITHDRAW_CREATOR_BP = 500; // 5% of the reward
    uint256 public constant WITHDRAW_SPOTBONUS_BP = 500; // 5% of the reward, stays in the token contract

    uint256 public DAO_Amount; // USDT held here for DAO distribution (5% of each stake)
    uint256 public allStake;
    uint256 public monthVolumeUsd; // stake volume since the last CTO run
    uint256 public dailySpotBonusPool; // USDT value, fed by the 5% claim cut
    uint256 public lastSpotBonusDistribution;
    uint256 public spotRunId;
    mapping(uint256 => address[]) internal spotQueue; // run id => users who qualified during that run
    mapping(address => uint256) internal spotQueuedIn; // run id + 1 the user was last queued in (0 = never)
    uint256 public lastDaoDistribution;
    mapping(address => uint256) public capUsedUsd; // USD value of income credited, at credit time
    uint256 public lastCtoDistribution;

    mapping(address => uint256) public lastWithdrawDay;
    mapping(address => uint256) public withdrawnToday;
    mapping(address => uint256) public withdrawalWallet; // USDT moved here by claimAll, paid out by withdrawFromWallet
    mapping(address => bool) public doubleFirstStake; // migrated user whose first stake still counts double
    address[] public ctoQualifiedUsers;
    mapping(address => bool) public isCtoQualified;

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
        uint8 rank; // 0 = none, 1-8
        uint256 daoJoinTime;
        uint256 daoShare;
        uint256 lastRankPay; // rank income accrued up to this time
    }

    struct Order {
        address ownerAddress;
        uint256 usdAmount; // package size used for cap and ROI (doubled on a migrated user's first stake)
        uint256 startTime;
        bool claimed;
        uint256 paidUsd; // what the user actually paid; the principal returned on claim
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

    // Gains and claims are in USDT (18 decimals), except roiGains/roiClaimed which are TOKENS and always equal.
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
    mapping(uint256 => Order) internal stakeInfos;
    mapping(address => BonusInfo) public bonusInfos;
    mapping(uint256 => RankTier) public rankTiers; // index 0 = tier 1
    mapping(uint256 => DaoTier) public daoTiers;
    mapping(uint256 => CtoTier) public ctoTiers;

    address[] public daoQualifiedUsers;
    mapping(address => bool) public isDaoQualified;

    event RegisterUser(address indexed user, address indexed referral);
    event Staked(address indexed user, uint256 orderId, uint256 usdAmount);
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
    event DaoDistributed(uint256 pool, uint256 totalShares);
    event SpotBonusDistributed(uint256 pool, uint256 qualifiedCount);
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
        rankTiers[5] = RankTier(700 * BASE, 16, 50000 * BASE, 1400); // Ruby
        rankTiers[6] = RankTier(900 * BASE, 18, 100000 * BASE, 1600); // Emerald
        rankTiers[7] = RankTier(1200 * BASE, 20, 250000 * BASE, 1800); // Diamond
        rankTiers[8] = RankTier(2500 * BASE, 22, 500000 * BASE, 2000); // Black Diamond
        rankTiers[9] = RankTier(5000 * BASE, 25, 1000000 * BASE, 2500); // Crown Diamond
        rankTiers[10] = RankTier(10000 * BASE, 30, 2500000 * BASE, 2800); // Kohinoor Diamond

        daoTiers[0] = DaoTier(500 * BASE, 1000 * BASE, 1, 10 days);
        daoTiers[1] = DaoTier(1000 * BASE, 2000 * BASE, 2, 20 days);
        daoTiers[2] = DaoTier(3000 * BASE, 4000 * BASE, 6, 30 days);

        ctoTiers[0] = CtoTier(5000 * BASE, 10000 * BASE, 200);
        ctoTiers[1] = CtoTier(10000 * BASE, 20000 * BASE, 100);
        ctoTiers[2] = CtoTier(20000 * BASE, 40000 * BASE, 100);

        lastDaoDistribution = block.timestamp;
        lastCtoDistribution = block.timestamp;
    }

    function setTokenAddress(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        token = INexauraToken(_token);
    }

    // Owner-only import of existing users (wallet + referrer, in referral order so a referrer is
    // registered before its downline). Their first stake counts as a double package (see makeStake).
    // ponytail: wallet + referral only; extend the arrays if balances/ranks must be imported too.
    function migrateUsers(address[] calldata users, address[] calldata referrals) external onlyOwner {
        require(users.length == referrals.length, "Length mismatch");
        for (uint256 i; i < users.length; i++) {
            address user = users[i];
            address referral = referrals[i];
            require(user != address(0) && !userInfos[user].joined, "Bad or already registered user");
            require(userInfos[referral].joined, "Referral not registered");

            userInfos[user].referral = referral;
            userInfos[user].joined = true;
            userInfos[user].daoJoinTime = block.timestamp;
            doubleFirstStake[user] = true;
            emit RegisterUser(user, referral);
        }
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
            _registerCto(current);
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

    // Rank needs: current package >= self, enough directs, and a match -- the strongest leg and
    // all other legs together each >= half of the tier's amount. Ranks only go up.
    function _updateRank(address user) internal {
        UserInfo storage u = userInfos[user];
        (, uint256 strong) = getStrongestLeg(user);
        uint256 others = _legsTotal(user) - strong;
        for (uint256 t = 11; t > u.rank; t--) {
            RankTier storage tier = rankTiers[t - 1];
            if (
                u.lastStake >= tier.selfStake &&
                u.directs.length >= tier.directsCount &&
                strong >= tier.teamBusiness / 2 &&
                others >= tier.teamBusiness / 2
            ) {
                if (u.rank > 0) _settleRankIncome(user); // pay days earned at the old rank
                else u.lastRankPay = block.timestamp; // income starts from the first rank
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

    // Cap (USD) is always based on the user's last stake.
    function _capOf(address user) internal view returns (uint256) {
        uint256[] storage orders = userInfos[user].stakeOrders;
        if (orders.length == 0) return 0;
        uint256 mult = userInfos[user].directs.length >= MIN_DIRECTS_FOR_WORKING
            ? WORKING_CAP_MULT
            : NONWORKING_CAP_MULT;
        return stakeInfos[orders[orders.length - 1]].usdAmount * mult;
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

    // USD left under the cap.
    function _capRoom(address user) internal view returns (uint256) {
        uint256 used = capUsedUsd[user];
        uint256 cap = _capOf(user);
        return used >= cap ? 0 : cap - used;
    }

    // Cuts a token income to the USD room left under the cap and records its USD value (at the
    // live rate now) as used. Every caller credits the returned amount right after.
    function _clampToCapRoom(address user, uint256 amount) internal returns (uint256) {
        uint256 roomUsd = _capRoom(user);
        uint256 usd = _toUsdAmount(amount);
        if (usd > roomUsd) {
            amount = _toTokenAmount(roomUsd);
            usd = roomUsd;
        }
        capUsedUsd[user] += usd;
        return amount;
    }

    // USD-denominated income: cut to the cap room and record it as used.
    function _clampUsd(address user, uint256 usd) internal returns (uint256) {
        uint256 room = _capRoom(user);
        if (usd > room) usd = room;
        capUsedUsd[user] += usd;
        return usd;
    }

    function _toTokenAmount(uint256 usdAmount) internal view returns (uint256) {
        return (usdAmount * BASE) / token.rateInUSDT();
    }

    // If this contract holds fewer tokens than a payout needs, pull the shortfall from the
    // insurance pool (the owner must have approved this contract as a spender there). Transfers
    // into this contract are burn-exempt in the token, so the full shortfall arrives.
    function _ensureTokens(uint256 needed) internal {
        uint256 bal = token.balanceOf(address(this));
        if (bal >= needed) return;
        require(
            token.transferFrom(token.insurancePoolAddress(), address(this), needed - bal),
            "Reserve top-up failed"
        );
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
        // A migrated user's first stake counts as double for package, cap, ROI and direct income;
        // the money moved, the fees and the business volume stay on the real amount.
        uint256 pkg = doubleFirstStake[msg.sender] ? usdAmount * 2 : usdAmount;
        doubleFirstStake[msg.sender] = false;
        require(usdAmount >= u.lastStake, "Package must not decrease");

        bool isFirstStake = u.stakeOrders.length == 0;
        uint256 newDeposit = usdAmount - u.lastStake; // direct income applies to new money only
        require(
            usdToken.transferFrom(msg.sender, address(this), usdAmount),
            "USDT transfer failed"
        );

        {
        uint256 creatorCut = (usdAmount * CREATOR_FEE_BP) / BP_DENOM;
        uint256 daoCut = (usdAmount * DAO_FEE_BP) / BP_DENOM; // full package, recycles included
        uint256 mintUsd = (usdAmount * (BP_DENOM - CREATOR_FEE_BP - DAO_FEE_BP - LIQUIDITY_FEE_BP)) /
            BP_DENOM;
        uint256 reserveUsd = usdAmount - creatorCut - daoCut - mintUsd; // the 9% reserve share

        require(usdToken.transfer(creatorFeeAddress, creatorCut), "Creator USDT transfer failed");
        DAO_Amount += daoCut;
        // 81% of the package backs locked user tokens; the remaining 9% increases the reserve
        // without minting. The DAO's cut stays here as USDT until an eligible distribution.
        require(
            usdToken.transfer(address(token), mintUsd + reserveUsd),
            "Mint funding transfer failed"
        );
        token.pricedBuy(mintUsd, address(this)); // locked here
        token.creditReserve(reserveUsd);
        }

        _settleRankIncome(msg.sender); // days earned under the previous order, before it is replaced
        allStake++;
        stakeInfos[allStake] = Order(msg.sender, pkg, block.timestamp, false, usdAmount);
        u.stakeOrders.push(allStake);
        u.lastStake = pkg;
        u.selfBusiness += newDeposit;
        monthVolumeUsd += newDeposit;

        address upline = u.referral;
        if (isFirstStake && upline != address(0)) {
            userInfos[upline].directs.push(msg.sender);
            userInfos[upline].directJoinTimes.push(block.timestamp);
            _queueSpotQualifier(upline, msg.sender);
        }

        // Direct income: 5% of the new deposit only (first stake in full, a same-size recycle
        // pays nothing, an increase pays on the difference), in USDT.
        if (newDeposit > 0 && upline != address(0) && _canEarn(upline)) {
            uint256 directAmt = _clampUsd(
                upline,
                (((newDeposit * pkg) / usdAmount) * DIRECT_INCOME_BP) / BP_DENOM
            );
            if (directAmt > 0) {
                bonusInfos[upline].referralGains += directAmt;
                emit IncomeCredited(msg.sender, upline, directAmt, 1);
            }
        }

        _updateBusinessToUpline(upline, newDeposit);
        _updateRank(msg.sender);

        emit Staked(msg.sender, allStake, pkg);
        return true;
    }

    function levelIncomeBp() public pure returns (uint16[21] memory) {
        return [
            500, 300, 150, 150, 100, 100, 50, 50, 50, 25, 25,
            25, 15, 15, 15, 15, 15, 25, 25, 50, 100
        ];
    }

    // Pays levels 1-21 (level 1 = first upline, 5%), as a % of the ROI the claimer just collected,
    // valued in USDT at the live rate.
    function _distributeLevelIncome(address claimer, uint256 roiTokens) internal {
        uint256 roiUsd = _toUsdAmount(roiTokens);
        uint16[21] memory bp = levelIncomeBp();
        address upline = userInfos[claimer].referral;

        for (uint256 i; i < 21 && upline != address(0); i++) {
            if (
                userInfos[upline].lastStake >= MIN_PACKAGE_FOR_LEVEL_INCOME &&
                _canEarn(upline)
            ) {
                uint256 amt = _clampUsd(upline, (roiUsd * bp[i]) / BP_DENOM);
                if (amt > 0) {
                    bonusInfos[upline].levelGains += amt;
                    emit IncomeCredited(claimer, upline, amt, 2);
                }
            }
            upline = userInfos[upline].referral;
        }
    }

    // Daily rank income: 1.25% x the tier's match amount x the tier's incentive %, per full day,
    // in USDT. Days stop counting 17 days (10 + 7 grace) after the newest
    // order; the cursor then jumps to now so a later restake never pays the gap.
    function _settleRankIncome(address user) internal {
        UserInfo storage u = userInfos[user];
        uint256[] storage orders = u.stakeOrders;
        if (u.rank == 0 || orders.length == 0) return;

        uint256 end = stakeInfos[orders[orders.length - 1]].startTime + MATURITY_PERIOD + GRACE_PERIOD;
        uint256 to = block.timestamp < end ? block.timestamp : end;
        if (to > u.lastRankPay) {
            uint256 days_ = (to - u.lastRankPay) / RANK_DAY;
            if (days_ > 0) {
                u.lastRankPay += days_ * RANK_DAY;
                RankTier storage tier = rankTiers[u.rank - 1];
                uint256 dailyUsd = (((tier.teamBusiness * RANK_DAILY_BP) / BP_DENOM) *
                    tier.incentiveBp) / BP_DENOM;
                uint256 amt = _clampUsd(user, dailyUsd * days_);
                if (amt > 0) {
                    bonusInfos[user].teamGrowthGains += amt;
                    emit IncomeCredited(user, user, amt, 4);
                }
            }
        }
        if (block.timestamp >= end) u.lastRankPay = block.timestamp;
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

    // Converts the order's USD amount to tokens at the current price and pays that principal
    // plus ROI on it, both from this contract's balance (nothing is minted). A 10% cut (5% creator, 5% spot) applies to the
    // ROI only, not the principal. Exempt from MIN_WITHDRAW and the daily withdrawal cap.
    // Requires a newer stake (recycle) before an order can be released.
    function claimOrder(uint256 orderId) external nonReentrant {
        Order storage o = stakeInfos[orderId];
        require(o.ownerAddress == msg.sender, "Not your order");
        require(!o.claimed, "Already claimed");
        require(block.timestamp >= o.startTime + MATURITY_PERIOD, "Order not mature");
        uint256[] storage orders = userInfos[msg.sender].stakeOrders;
        require(orders[orders.length - 1] > orderId, "Recycle required: buy next package first");

        uint256 principal = _toTokenAmount(o.paidUsd); // only what was really paid comes back
        uint256 roi = _clampToCapRoom(
            msg.sender,
            (_toTokenAmount(o.usdAmount) * ROI_BP) / BP_DENOM // ROI on the package size (doubled when migrated)
        );
        bonusInfos[msg.sender].roiGains += roi;
        bonusInfos[msg.sender].roiClaimed += roi;
        if (roi > 0) {
            emit IncomeCredited(msg.sender, msg.sender, roi, 3);
        }
        o.claimed = true;

        // 10% cut on the ROI only: 5% creator, 5% spot cut (feeds the spot pool, not paid out).
        uint256 creatorCut = (roi * WITHDRAW_CREATOR_BP) / BP_DENOM;
        uint256 spotCut = (roi * WITHDRAW_SPOTBONUS_BP) / BP_DENOM;
        uint256 net = principal + roi - creatorCut - spotCut;
        dailySpotBonusPool += _toUsdAmount(spotCut);
        _ensureTokens(creatorCut + net);
        require(token.transfer(creatorFeeAddress, creatorCut), "Creator transfer failed");
        require(token.transfer(msg.sender, net), "Payout transfer failed");

        if (roi > 0) _distributeLevelIncome(msg.sender, roi);

        emit OrderClaimed(msg.sender, orderId, principal, roi);
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

    // Users join the CTO list the first time they reach tier 1 (business only grows, so a tier is
    // never lost). The tier itself is re-read at distribution time.
    function _registerCto(address user) internal {
        if (!isCtoQualified[user] && _ctoTierOf(user) > 0) {
            isCtoQualified[user] = true;
            ctoQualifiedUsers.push(user);
        }
    }

    // ponytail: iterates every CTO-qualified user; paginate if that set grows large.
    // Anyone can call once per interval. Each tier's pool (tier % of the period's stake volume)
    // is split equally among that tier's qualified users; a user only collects their highest tier.
    function distributeCTO() external nonReentrant {
        require(block.timestamp >= lastCtoDistribution + CTO_DIST_INTERVAL, "Too soon");

        address[] storage list = ctoQualifiedUsers;
        uint8[] memory tierOf = new uint8[](list.length);
        uint256[3] memory counts;
        for (uint256 i; i < list.length; i++) {
            if (!_canEarn(list[i])) continue;
            uint8 t = _ctoTierOf(list[i]);
            if (t == 0) continue;
            tierOf[i] = t;
            counts[t - 1]++;
        }

        uint256[3] memory perUser;
        for (uint256 t; t < 3; t++) {
            if (counts[t] > 0) {
                perUser[t] = ((monthVolumeUsd * ctoTiers[t].bonusBp) / BP_DENOM) / counts[t];
            }
        }
        for (uint256 i; i < list.length; i++) {
            if (tierOf[i] == 0) continue;
            uint256 amt = _clampUsd(list[i], perUser[tierOf[i] - 1]);
            if (amt > 0) {
                bonusInfos[list[i]].ctoGains += amt;
                emit IncomeCredited(list[i], list[i], amt, 5);
            }
        }

        emit CtoDistributed(monthVolumeUsd, counts[0], counts[1], counts[2]);
        monthVolumeUsd = 0;
        lastCtoDistribution = block.timestamp;
    }

    // ponytail: iterates every DAO-qualified user; paginate if that set grows large.
    // The pool is USDT, credited straight to users' gains. The paid USDT moves to the token
    // contract (which pays claims) without touching its reserve. Unallocated USDT carries over.
    function distributeDAO() external nonReentrant {
        require(block.timestamp >= lastDaoDistribution + DAO_DIST_INTERVAL, "Too soon");

        uint256 totalShares;
        for (uint256 i; i < daoQualifiedUsers.length; i++) {
            totalShares += userInfos[daoQualifiedUsers[i]].daoShare;
        }

        uint256 pool = DAO_Amount;
        uint256 paid;
        if (totalShares > 0 && pool > 0) {
            for (uint256 i; i < daoQualifiedUsers.length; i++) {
                address u = daoQualifiedUsers[i];
                uint256 share = userInfos[u].daoShare;
                if (share == 0 || !_canEarn(u)) continue;
                uint256 amt = _clampUsd(u, (pool * share) / totalShares);
                if (amt > 0) {
                    bonusInfos[u].daoGains += amt;
                    paid += amt;
                    emit IncomeCredited(u, u, amt, 7);
                }
            }
        }

        if (paid > 0) {
            require(usdToken.transfer(address(token), paid), "DAO funding transfer failed");
        }
        emit DaoDistributed(pool, totalShares);
        DAO_Amount = pool - paid;
        lastDaoDistribution = block.timestamp;
    }

    // Spot tier: how many directs ($50+) joined since the last distribution, capped at 2.
    // directJoinTimes is chronological, so the scan stops at the first older entry (or after 20).
    function spotTier(address user) public view returns (uint256 count) {
        UserInfo storage u = userInfos[user];
        uint256 len = u.directJoinTimes.length;
        for (uint256 i = len; i > 0 && (len - i) < 20; i--) {
            if (u.directJoinTimes[i - 1] <= lastSpotBonusDistribution) break;
            if (userInfos[u.directs[i - 1]].lastStake >= SPOTBONUS_MIN_PACKAGE && ++count == 2) return 2;
        }
    }

    // Queues the upline for the next spot distribution on their first $50+ direct of the run,
    // so nobody has to supply a list. The tier is worked out at distribution time.
    function _queueSpotQualifier(address upline, address joiner) internal {
        if (userInfos[joiner].lastStake < SPOTBONUS_MIN_PACKAGE || spotQueuedIn[upline] == spotRunId + 1) return;
        spotQueuedIn[upline] = spotRunId + 1;
        spotQueue[spotRunId].push(upline);
    }

    // Anyone can call once per interval. The pool (5% claim cuts, in USDT) is split 30% / 70%
    // between users with 1 / 2+ qualifying directs, equally within each group. An empty group's
    // share, and whatever the caps leave unpaid, stays in the pool.
    function distributeSpotBonus() external nonReentrant {
        require(block.timestamp >= lastSpotBonusDistribution + SPOTBONUS_DIST_INTERVAL, "Too soon");

        address[] storage q = spotQueue[spotRunId];
        uint256[] memory tier = new uint256[](q.length);
        uint256 n1;
        uint256 n2;
        for (uint256 i; i < q.length; i++) {
            if (!_canEarn(q[i])) continue;
            uint256 t = spotTier(q[i]);
            tier[i] = t;
            if (t == 1) n1++;
            else if (t == 2) n2++;
        }

        uint256 pool = dailySpotBonusPool;
        uint256 share1 = n1 > 0 ? ((pool * SPOT_TIER1_BP) / BP_DENOM) / n1 : 0;
        uint256 share2 = n2 > 0 ? ((pool * SPOT_TIER2_BP) / BP_DENOM) / n2 : 0;
        uint256 paid;
        for (uint256 i; i < q.length; i++) {
            if (tier[i] == 0) continue;
            uint256 amt = _clampUsd(q[i], tier[i] == 1 ? share1 : share2);
            if (amt > 0) {
                bonusInfos[q[i]].spotBonusGains += amt;
                paid += amt;
                emit IncomeCredited(q[i], q[i], amt, 6);
            }
        }
        emit SpotBonusDistributed(pool, n1 + n2);
        dailySpotBonusPool = pool - paid;
        delete spotQueue[spotRunId];
        spotRunId++;
        lastSpotBonusDistribution = block.timestamp;
    }

    // Order details for the UI.
    function getOrder(
        uint256 orderId
    )
        external
        view
        returns (address ownerAddress, uint256 usdAmount, uint256 startTime, bool claimed)
    {
        Order storage o = stakeInfos[orderId];
        return (o.ownerAddress, o.usdAmount, o.startTime, o.claimed);
    }

    // A leg is one direct referral; its business (USD) is that direct's own stakes plus
    // everything below them.
    function _legBusiness(address leg) internal view returns (uint256) {
        UserInfo storage l = userInfos[leg];
        return l.selfBusiness + l.directBusiness + l.totalTeamBusiness;
    }

    function _legsTotal(address user) internal view returns (uint256 total) {
        address[] storage directs = userInfos[user].directs;
        for (uint256 i; i < directs.length; i++) total += _legBusiness(directs[i]);
    }

    // Direct with the largest business (USD) and that business.
    function getStrongestLeg(
        address user
    ) public view returns (address strongestLeg, uint256 strongestBusiness) {
        address[] storage directs = userInfos[user].directs;
        for (uint256 i; i < directs.length; i++) {
            uint256 b = _legBusiness(directs[i]);
            if (b > strongestBusiness) {
                strongestBusiness = b;
                strongestLeg = directs[i];
            }
        }
    }

    // Total business (USD) of all legs except the strongest.
    function getTeamsExcludingStrongest(address user) public view returns (uint256) {
        (, uint256 strong) = getStrongestLeg(user);
        return _legsTotal(user) - strong;
    }

    // Per-user package serials: index 0 is the user's first package, 1 the second, and so on.
    function getUserOrderCount(address user) external view returns (uint256) {
        return userInfos[user].stakeOrders.length;
    }

    function getUserOrder(
        address user,
        uint256 index
    )
        external
        view
        returns (uint256 orderId, uint256 usdAmount, uint256 startTime, bool claimed)
    {
        uint256[] storage orders = userInfos[user].stakeOrders;
        require(index < orders.length, "Invalid serial");
        orderId = orders[index];
        Order storage o = stakeInfos[orderId];
        return (orderId, o.usdAmount, o.startTime, o.claimed);
    }

    function capOf(address user) external view returns (uint256) {
        return _capOf(user);
    }

    // USDT claimable right now across all types: totalGains - claimed. The cap is enforced
    // when income is credited (_clampToCapRoom), so earned income stays claimable even after
    // claiming an order shrinks the cap.
    function claimable(address user) public view returns (uint256) {
        uint256 total = _totalGains(user);
        uint256 claimed = _totalClaimed(user);
        return total > claimed ? total - claimed : 0;
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

    event IncomeMovedToWallet(address indexed user, uint256 amount, uint8 gainType);

    // Credit gross USDT value without transferring funds or charging withdrawal fees.
    function _claimFromHeld(address user, uint256 amount, uint8 gainType) internal {
        require(amount > 0, "Nothing to claim");
        withdrawalWallet[user] += amount;
        emit IncomeMovedToWallet(user, amount, gainType);
    }

    // Only actual wallet payouts consume the daily limit and charge fees.
    function _payFromWallet(address user, uint256 amount) internal {
        _checkDailyCap(user, amount);

        uint256 creatorCut = (amount * WITHDRAW_CREATOR_BP) / BP_DENOM;
        uint256 spotCut = (amount * WITHDRAW_SPOTBONUS_BP) / BP_DENOM;
        uint256 net = amount - creatorCut - spotCut;
        dailySpotBonusPool += spotCut;
        // Paid in tokens at the live rate, from this contract's balance (same as claimOrder).
        uint256 creatorTokens = _toTokenAmount(creatorCut);
        uint256 netTokens = _toTokenAmount(net);
        _ensureTokens(creatorTokens + netTokens);
        require(token.transfer(creatorFeeAddress, creatorTokens), "Creator transfer failed");
        require(token.transfer(user, netTokens), "Payout transfer failed");
        emit Withdrawn(user, amount, net, 8);
    }

    function claimReferralGains() external nonReentrant {
        uint256 amount = claimableReferralGains(msg.sender);
        bonusInfos[msg.sender].referralClaimed += amount;
        _claimFromHeld(msg.sender, amount, 1);
    }

    function claimLevelGains() external nonReentrant {
        uint256 amount = claimableLevelGains(msg.sender);
        bonusInfos[msg.sender].levelClaimed += amount;
        _claimFromHeld(msg.sender, amount, 2);
    }

    // Rank income: credits the days earned so far, then claims the whole balance.
    function claimTeamGrowthGains() external nonReentrant {
        _settleRankIncome(msg.sender);
        uint256 amount = claimableTeamGrowthGains(msg.sender);
        bonusInfos[msg.sender].teamGrowthClaimed += amount;
        _claimFromHeld(msg.sender, amount, 4);
    }

    function claimCtoGains() external nonReentrant {
        uint256 amount = claimableCtoGains(msg.sender);
        bonusInfos[msg.sender].ctoClaimed += amount;
        _claimFromHeld(msg.sender, amount, 5);
    }

    function claimSpotBonusGains() external nonReentrant {
        uint256 amount = claimableSpotBonusGains(msg.sender);
        bonusInfos[msg.sender].spotBonusClaimed += amount;
        _claimFromHeld(msg.sender, amount, 6);
    }

    function claimDaoGains() external nonReentrant {
        uint256 amount = claimableDaoGains(msg.sender);
        bonusInfos[msg.sender].daoClaimed += amount;
        _claimFromHeld(msg.sender, amount, 7);
    }

    // Moves every claimable income into the withdrawal wallet in one call. Types are taken in
    // order (referral, level, rank, CTO, spot, DAO); once the claimable room runs out the rest
    // is skipped, so the wallet only ever receives what is claimable.
    function claimAll() external nonReentrant {
        address user = msg.sender;
        _settleRankIncome(user);
        BonusInfo storage b = bonusInfos[user];
        uint256 room = claimable(user);
        uint256 total;
        uint256 t;

        t = _min(b.referralGains - b.referralClaimed, room);
        b.referralClaimed += t; room -= t; total += t;
        t = _min(b.levelGains - b.levelClaimed, room);
        b.levelClaimed += t; room -= t; total += t;
        t = _min(b.teamGrowthGains - b.teamGrowthClaimed, room);
        b.teamGrowthClaimed += t; room -= t; total += t;
        t = _min(b.ctoGains - b.ctoClaimed, room);
        b.ctoClaimed += t; room -= t; total += t;
        t = _min(b.spotBonusGains - b.spotBonusClaimed, room);
        b.spotBonusClaimed += t; room -= t; total += t;
        t = _min(b.daoGains - b.daoClaimed, room);
        b.daoClaimed += t; total += t;

        _claimFromHeld(user, total, 8);
    }

    // Withdraws from the wallet under the usual rules (minimum, daily cap, creator and spot cuts).
    function withdrawFromWallet(uint256 amount) external nonReentrant {
        require(amount > 0 && amount <= withdrawalWallet[msg.sender], "Insufficient wallet balance");
        require(amount >= MIN_WITHDRAW, "Below minimum withdrawal");
        withdrawalWallet[msg.sender] -= amount;
        _payFromWallet(msg.sender, amount);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
