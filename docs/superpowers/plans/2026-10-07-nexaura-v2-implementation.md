# NEXAURA V2 (token-locked staking) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (recommended here) or superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.
>
> **Owner's working rules (override the skill defaults):** build ONE task (one function or one tight group) at a time and STOP for the owner's OK before starting the next. Do NOT compile or run tests after edits; only when the owner asks. That is why tasks below have no "run test" steps; Task 12 is the test task, run only on request.

**Goal:** Replace the USDT-paying staking system with a token-locked one: stakes mint tokens into the staking contract, ROI/income are minted at claim, level and rank income fire on ROI claims, CTO is a monthly owner-run pool.

**Architecture:** Two new files in the `nexaura-implementation` worktree: `NexauraTokenV2.sol` (copy of `NexauraToken.sol` with a public `sell`, `mintTo`, burn-exempt staking transfers, 15% sell deduction to the reserve) and `NexauraStakingV2.sol` (new order/claim logic; unchanged helpers copied from `NexauraStaking.sol`). The old contracts stay untouched as reference. `ReservePool.sol` is reused as is.

**Tech Stack:** Solidity ^0.8.20, Hardhat (existing `hardhat.config.js`), `contracts/mocks/MockUSDT.sol`.

**Spec:** `docs/superpowers/specs/2026-10-07-nexaura-staking-v2-design.md`

All contract paths below are relative to `worktrees/nexaura-implementation/contracts/`. "Old staking" = `NexauraStaking.sol`, "old token" = `NexauraToken.sol`.

## Global Constraints

- Package: $10 to $1,000 in $10 steps; package must not decrease.
- Stake split of `usdAmount`: 5% creator fee, 5% DAO pool (USDT held), 9% to the reserve pool contract (USDT), 81% minted as tokens to the staking contract and locked.
- Direct income: 5% of the full `usdAmount`, in tokens at the live rate, at stake time.
- ROI: 12.5% of the order's `lockedTokens`, tokens, fixed at 10 days, claimable any time after maturity; order claim returns principal tokens and mints ROI.
- Independent orders, 10-day clock each. A user can earn income while `block.timestamp < lastOrder.startTime + 10 days + 7 days`.
- Cap (tokens): 2x (fewer than 2 directs) or 3x (2+ directs) of the sum of `lockedTokens` over unclaimed orders; every gain type counts towards it.
- Level income: 20 uplines starting at the 2nd ancestor (levels 2 to 21), bp `300,150,150,100,100,50,50,50,25,25,25,15,15,15,15,15,25,25,50,100`, applied to the claimed ROI; upline needs `lastStake >= $50` and must be able to earn.
- Rank income: `combinedBusinessUsd x 12.5% x incentiveBp`, converted to tokens at claim, at most once per 10 days per user.
- CTO: monthly, owner-run, pools Core 1 2% / Core 2 1% / Core 3 1% of the month's stake volume (USD), split equally per tier, a user gets only their highest tier.
- Claim fee 10% (5% creator minted, 5% to spot pool in tokens) on the reward part only; $10 minimum and $3,000/day apply to income claims (USD at live rate).
- Swap (token contract): 15% deduction all to the reserve pool, 100% of sold tokens burned, shortfall pulled from the reserve pool.
- No unstake, no selling in the staking contract.

## Review Focus

1. Reward minting has no USDT behind it, so `rateInUSDT()` (internalReserve / totalSupply) drifts down over time. Expect the rate to fall; nothing here compensates it.
2. Claiming an order shrinks the cap (unclaimed stakes only), so earned-but-unclaimed income above the new cap becomes unclaimable. Claim income before claiming the last order.
3. A user with several matured orders must not collect rank income once per order: `lastRankPay` allows one payment per 10 days.
4. A $10 package locks about $8.10 of tokens; the order claim must not revert on the $10 minimum (order claims are exempt from the minimum).
5. Duplicate addresses in the owner-supplied candidate lists (`distributeCTO`, `distributeSpotBonus`) must not be paid twice.
6. Principal release from the staking contract must not lose 1% to the token's transfer burn.

---

### Task 1: Token V2, copy and public `sell`

**Files:**
- Create: `NexauraTokenV2.sol` (copy of `NexauraToken.sol`)

**Interfaces:**
- Produces: `NexauraTokenV2.sell(uint256 tokenAmount) returns (uint256 netUsd)`; removes `pricedSell`, `payoutReserve`, `payoutReward`, `SELL_LP_BP`.

- [ ] **Step 1:** Copy `NexauraToken.sol` to `NexauraTokenV2.sol` and rename `contract NexauraToken` to `contract NexauraTokenV2`.
- [ ] **Step 2:** Delete `pricedSell`, `payoutReserve`, `payoutReward` and the `SELL_LP_BP` constant. Change the reserve constant to `uint256 public constant SELL_RESERVE_BP = 1500; // 15%, all to the reserve pool`. Keep `pricedBuy`, `creditReserve`, `_coverShortfall`, the constructor (the unused `liquidityPoolAddress` stays so the deploy signature does not change).
- [ ] **Step 3:** Add after `pricedBuy`:

```solidity
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
```

- [ ] **Step 4:** Report to the owner and wait for OK.

### Task 2: Token V2, `mintTo` and burn-exempt staking transfers

**Files:**
- Modify: `NexauraTokenV2.sol`

**Interfaces:**
- Produces: `mintTo(address to, uint256 amount)` (staking only, no reserve change); `transfer` from the staking contract is not burned.

- [ ] **Step 1:** Add next to `creditReserve`:

```solidity
    /// @dev Mints reward tokens (ROI, income, fees) with no USDT behind them, by design.
    function mintTo(address to, uint256 amount) external onlyStaking {
        _mint(to, amount);
    }
```

- [ ] **Step 2:** In `_transferWithBurn`, replace `uint256 burnAmount = (amount * TRANSFER_BURN_BP) / BP_DENOM;` with:

```solidity
        uint256 burnAmount = sender == stakingContract
            ? 0
            : (amount * TRANSFER_BURN_BP) / BP_DENOM;
```

- [ ] **Step 3:** Report and wait for OK.

### Task 3: Staking V2 skeleton (state, structs, events, constructor, register)

**Files:**
- Create: `NexauraStakingV2.sol`

**Interfaces:**
- Produces: all state below, `setTokenAddress`, `regUser`. Later tasks use these names exactly.

- [ ] **Step 1:** Create the file. Copy lines 1-89 of `NexauraStaking.sol` (SPDX, pragma, `Context`, `Ownable`, `IUSDLike`, `ReentrancyGuard`; there the interface block is lines 1-27, rewrite it as below). Replace the token interface with:

```solidity
interface INexauraToken {
    function balanceOf(address account) external view returns (uint256);
    function rateInUSDT() external view returns (uint256);
    function reservePoolAddress() external view returns (address);
    function pricedBuy(uint256 usdAmount, address forAddress) external returns (uint256);
    function mintTo(address to, uint256 amount) external;
    function creditReserve(uint256 usdAmount) external;
    function transfer(address to, uint256 amount) external returns (bool);
}
```

- [ ] **Step 2:** Add the contract header, constants and state:

```solidity
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

    struct RankTier { uint256 selfStake; uint256 directsCount; uint256 teamBusiness; uint256 incentiveBp; }
    struct DaoTier { uint256 directBusiness; uint256 matchingBusiness; uint256 share; uint256 duration; }
    struct CtoTier { uint256 directBusiness; uint256 teamBusiness; uint256 bonusBp; }

    // All gains in TOKENS.
    struct BonusInfo {
        uint256 referralGains; uint256 levelGains; uint256 roiGains; uint256 teamGrowthGains;
        uint256 ctoGains; uint256 spotBonusGains; uint256 daoGains;
        uint256 referralClaimed; uint256 levelClaimed; uint256 roiClaimed; uint256 teamGrowthClaimed;
        uint256 ctoClaimed; uint256 spotBonusClaimed; uint256 daoClaimed;
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
    event IncomeCredited(address indexed from, address indexed to, uint256 amount, uint8 incomeType);
    // incomeType: 1 Direct, 2 Level, 3 ROI, 4 Rank, 5 CTO, 6 Spot Bonus, 7 DAO
    event RankUpdated(address indexed user, uint8 newRank);
    event DaoShareUpdated(address indexed user, uint256 newShare);
    event SpotBonusDistributed(uint256 pool, uint256 qualifiedCount);
    event DaoDistributed(uint256 pool, uint256 totalShares);
    event CtoDistributed(uint256 revenueUsd, uint256 core1, uint256 core2, uint256 core3);
    event Withdrawn(address indexed user, uint256 grossAmount, uint256 netAmount, uint8 gainType);
```

- [ ] **Step 3:** Constructor (deck tables, 11 ranks, DAO tier 3 = 3000/4000/6, CTO unchanged):

```solidity
    constructor(address _owner, address _usdtAddress, address _creatorFeeAddress) Ownable(_owner) {
        require(_usdtAddress != address(0), "Invalid USDT address");
        require(_creatorFeeAddress != address(0), "Invalid creator fee address");
        usdToken = IUSDLike(_usdtAddress);
        creatorFeeAddress = _creatorFeeAddress;

        userInfos[_owner].joined = true;
        userInfos[_owner].lastStake = MAX_PACKAGE; // bootstrap: lets the first user register under the owner
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
```

- [ ] **Step 4:** Copy `setTokenAddress` and `regUser` verbatim from old staking lines 274-289. Leave the contract open (no closing brace yet; each later task appends inside it, and Task 11 adds the closing `}`).
- [ ] **Step 5:** Report and wait for OK.

### Task 4: Internal helpers (business, rank, DAO share, active, cap, conversion)

**Files:**
- Modify: `NexauraStakingV2.sol`

**Interfaces:**
- Produces: `_updateBusinessToUpline(address,uint256)`, `_updateDaoShare(address)`, `_updateRank(address)`, `_canEarn(address) view returns (bool)`, `_unclaimedLockedSum(address)`, `_capOf(address)`, `_totalGains(address)`, `_totalClaimed(address)`, `_capRoom(address)`, `_clampToCapRoom(address,uint256)`, `_toTokenAmount(uint256)`, `_toUsdAmount(uint256)`.

- [ ] **Step 1:** Copy `_updateBusinessToUpline` and `_updateDaoShare` verbatim from old staking lines 372-420.
- [ ] **Step 2:** `_updateRank` with 11 tiers and cumulative self business:

```solidity
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
```

- [ ] **Step 3:** Remaining helpers:

```solidity
    // Income window: 10 days from the newest stake plus the 7-day grace.
    function _canEarn(address user) internal view returns (bool) {
        uint256[] storage orders = userInfos[user].stakeOrders;
        if (orders.length == 0) return false;
        return block.timestamp < stakeInfos[orders[orders.length - 1]].startTime + MATURITY_PERIOD + GRACE_PERIOD;
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
        return b.referralGains + b.levelGains + b.roiGains + b.teamGrowthGains +
            b.ctoGains + b.spotBonusGains + b.daoGains;
    }

    function _totalClaimed(address user) internal view returns (uint256) {
        BonusInfo storage b = bonusInfos[user];
        return b.referralClaimed + b.levelClaimed + b.roiClaimed + b.teamGrowthClaimed +
            b.ctoClaimed + b.spotBonusClaimed + b.daoClaimed;
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
```

- [ ] **Step 4:** Report and wait for OK.

### Task 5: `makeStake`

**Files:**
- Modify: `NexauraStakingV2.sol`

**Interfaces:**
- Consumes: Task 3 state/constants, Task 4 helpers, `token.pricedBuy`, `token.reservePoolAddress`.
- Produces: `makeStake(uint256 usdAmount) returns (bool)`; creates an `Order` with `lockedTokens`.

- [ ] **Step 1:** Add:

```solidity
    function makeStake(uint256 usdAmount) external nonReentrant returns (bool) {
        UserInfo storage u = userInfos[msg.sender];
        require(u.joined, "caller not registered");
        require(
            usdAmount >= MIN_PACKAGE && usdAmount <= MAX_PACKAGE && usdAmount % PACKAGE_STEP == 0,
            "Invalid package amount"
        );
        require(usdAmount >= u.lastStake, "Package must not decrease");

        bool isFirstStake = u.stakeOrders.length == 0;
        require(usdToken.transferFrom(msg.sender, address(this), usdAmount), "USDT transfer failed");

        uint256 creatorCut = (usdAmount * CREATOR_FEE_BP) / BP_DENOM;
        uint256 daoCut = (usdAmount * DAO_FEE_BP) / BP_DENOM;
        uint256 reserveCut = (usdAmount * RESERVE_FEE_BP) / BP_DENOM;
        uint256 mintUsd = usdAmount - creatorCut - daoCut - reserveCut;

        require(usdToken.transfer(creatorFeeAddress, creatorCut), "Creator fee transfer failed");
        require(usdToken.transfer(token.reservePoolAddress(), reserveCut), "Reserve transfer failed");
        DAO_Amount += daoCut;
        require(usdToken.transfer(address(token), mintUsd), "Mint funding transfer failed");
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
            uint256 directAmt = _clampToCapRoom(upline, _toTokenAmount((usdAmount * DIRECT_INCOME_BP) / BP_DENOM));
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
```

- [ ] **Step 2:** Report and wait for OK.

### Task 6: `_distributeLevelIncome`

**Files:**
- Modify: `NexauraStakingV2.sol`

**Interfaces:**
- Produces: `levelIncomeBp()`, `_distributeLevelIncome(address claimer, uint256 roiTokens)`.

- [ ] **Step 1:** Copy `levelIncomeBp` verbatim from old staking lines 561-566, then add:

```solidity
    // Pays levels 2-21 as a % of the ROI the claimer just collected (tokens).
    function _distributeLevelIncome(address claimer, uint256 roiTokens) internal {
        uint16[20] memory bp = levelIncomeBp();
        address upline = userInfos[userInfos[claimer].referral].referral;
        for (uint256 i; i < 20 && upline != address(0); i++) {
            if (userInfos[upline].lastStake >= MIN_PACKAGE_FOR_LEVEL_INCOME && _canEarn(upline)) {
                uint256 amt = _clampToCapRoom(upline, (roiTokens * bp[i]) / BP_DENOM);
                if (amt > 0) {
                    bonusInfos[upline].levelGains += amt;
                    emit IncomeCredited(claimer, upline, amt, 2);
                }
            }
            upline = userInfos[upline].referral;
        }
    }
```

- [ ] **Step 2:** Report and wait for OK.

### Task 7: `_payRankIncome` and `claimOrder`

**Files:**
- Modify: `NexauraStakingV2.sol`

**Interfaces:**
- Consumes: Tasks 4 and 6.
- Produces: `_payRankIncome(address)`, `_checkDailyCap(address,uint256)`, `claimOrder(uint256 orderId)`.

- [ ] **Step 1:** Add:

```solidity
    // Rank income for the claimer's own cycle: 12.5% x combined business (USD) x incentive %.
    // At most once per 10 days so several orders claimed together don't pay it repeatedly.
    function _payRankIncome(address user) internal {
        UserInfo storage u = userInfos[user];
        if (u.rank == 0 || !_canEarn(user)) return;
        if (block.timestamp < u.lastRankPay + MATURITY_PERIOD) return;

        uint256 combinedUsd = u.directBusiness + u.totalTeamBusiness;
        uint256 rankUsd = (((combinedUsd * ROI_BP) / BP_DENOM) * rankTiers[u.rank - 1].incentiveBp) / BP_DENOM;
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
        require(withdrawnToday[user] + usdValue <= MAX_DAILY_WITHDRAW, "Exceeds daily withdrawal cap");
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
```

- [ ] **Step 2:** Report and wait for OK.

### Task 8: Monthly CTO (`_ctoTierOf`, `distributeCTO`)

**Files:**
- Modify: `NexauraStakingV2.sol`

**Interfaces:**
- Consumes: `monthVolumeUsd`, `ctoRunId`, `lastCtoRun`, `ctoTiers`.
- Produces: `distributeCTO(address[] calldata candidates)` (owner only).

- [ ] **Step 1:** Add (qualification is direct business OR team matching business, per the deck; each candidate counted once per run; a user who cannot earn is skipped so their share is not wasted):

```solidity
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
                uint256 poolTokens = _toTokenAmount((monthVolumeUsd * ctoTiers[t].bonusBp) / BP_DENOM);
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
```

- [ ] **Step 2:** Report and wait for OK.

### Task 9: `distributeDAO`

**Files:**
- Modify: `NexauraStakingV2.sol`

**Interfaces:**
- Consumes: `DAO_Amount` (USDT held), `daoQualifiedUsers`, `token.creditReserve`.
- Produces: `distributeDAO()` (owner only, weekly).

- [ ] **Step 1:** Add. Each winner's share of the USD pool is minted as tokens at claim; the whole USDT pool is then moved into the token's reserve to back them:

```solidity
    // ponytail: iterates every DAO-qualified user; paginate if that set grows large.
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
```

- [ ] **Step 2:** Report and wait for OK.

### Task 10: Daily spot bonus

**Files:**
- Modify: `NexauraStakingV2.sol`

**Interfaces:**
- Produces: `qualifiesForSpotBonus(address) view`, `distributeSpotBonus(address[] calldata)` (owner only, daily). `dailySpotBonusPool` is in tokens.

- [ ] **Step 1:** Copy `qualifiesForSpotBonus` verbatim from old staking lines 729-744. Add (pool already in tokens; duplicates in the list are paid once via `lastCtoRun`-style marking using a local array):

```solidity
    function distributeSpotBonus(address[] calldata candidates) external onlyOwner nonReentrant {
        require(block.timestamp >= lastSpotBonusDistribution + SPOTBONUS_DIST_INTERVAL, "Too soon");

        bool[] memory pay = new bool[](candidates.length);
        uint256 qualifiedCount;
        for (uint256 i; i < candidates.length; i++) {
            bool dup;
            for (uint256 j; j < i; j++) {
                if (candidates[j] == candidates[i]) { dup = true; break; }
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
```

(The pool is only reset when someone qualified, so an empty day does not burn it.)

- [ ] **Step 2:** Report and wait for OK.

### Task 11: Claimable views and income claims

**Files:**
- Modify: `NexauraStakingV2.sol`

**Interfaces:**
- Produces: `claimable(address)`, `claimable{Referral,Level,TeamGrowth,Cto,SpotBonus,Dao}Gains(address)`, `claim{Referral,Level,TeamGrowth,Cto,SpotBonus,Dao}Gains()`, `capOf(address)`. ROI has no claim function (paid inside `claimOrder`).

- [ ] **Step 1:** Add:

```solidity
    function capOf(address user) external view returns (uint256) { return _capOf(user); }

    // Tokens claimable right now across all types: min(totalGains, cap) - claimed.
    function claimable(address user) public view returns (uint256) {
        uint256 total = _totalGains(user);
        uint256 cap = _capOf(user);
        uint256 capped = total > cap ? cap : total;
        uint256 claimed = _totalClaimed(user);
        return capped > claimed ? capped - claimed : 0;
    }

    function _claimableOfType(address user, uint256 gain, uint256 claimedOfType) internal view returns (uint256) {
        uint256 own = gain > claimedOfType ? gain - claimedOfType : 0;
        uint256 room = claimable(user);
        return own > room ? room : own;
    }

    function claimableReferralGains(address u) public view returns (uint256) { BonusInfo storage b = bonusInfos[u]; return _claimableOfType(u, b.referralGains, b.referralClaimed); }
    function claimableLevelGains(address u) public view returns (uint256) { BonusInfo storage b = bonusInfos[u]; return _claimableOfType(u, b.levelGains, b.levelClaimed); }
    function claimableTeamGrowthGains(address u) public view returns (uint256) { BonusInfo storage b = bonusInfos[u]; return _claimableOfType(u, b.teamGrowthGains, b.teamGrowthClaimed); }
    function claimableCtoGains(address u) public view returns (uint256) { BonusInfo storage b = bonusInfos[u]; return _claimableOfType(u, b.ctoGains, b.ctoClaimed); }
    function claimableSpotBonusGains(address u) public view returns (uint256) { BonusInfo storage b = bonusInfos[u]; return _claimableOfType(u, b.spotBonusGains, b.spotBonusClaimed); }
    function claimableDaoGains(address u) public view returns (uint256) { BonusInfo storage b = bonusInfos[u]; return _claimableOfType(u, b.daoGains, b.daoClaimed); }

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

    function claimReferralGains() external nonReentrant { uint256 a = claimableReferralGains(msg.sender); bonusInfos[msg.sender].referralClaimed += a; _claimIncome(msg.sender, a, 1); }
    function claimLevelGains() external nonReentrant { uint256 a = claimableLevelGains(msg.sender); bonusInfos[msg.sender].levelClaimed += a; _claimIncome(msg.sender, a, 2); }
    function claimTeamGrowthGains() external nonReentrant { uint256 a = claimableTeamGrowthGains(msg.sender); bonusInfos[msg.sender].teamGrowthClaimed += a; _claimIncome(msg.sender, a, 4); }
    function claimCtoGains() external nonReentrant { uint256 a = claimableCtoGains(msg.sender); bonusInfos[msg.sender].ctoClaimed += a; _claimIncome(msg.sender, a, 5); }
    function claimSpotBonusGains() external nonReentrant { uint256 a = claimableSpotBonusGains(msg.sender); bonusInfos[msg.sender].spotBonusClaimed += a; _claimIncome(msg.sender, a, 6); }
    function claimDaoGains() external nonReentrant { uint256 a = claimableDaoGains(msg.sender); bonusInfos[msg.sender].daoClaimed += a; _claimIncome(msg.sender, a, 7); }
}
```

(The final `}` closes the contract. Confirm no earlier task left a stray closing brace.)

- [ ] **Step 2:** Report and wait for OK.

### Task 12: Deploy wiring (script only)

**Files:**
- Modify: `scripts/deploy.js` (worktree root, not under `contracts/`)

- [ ] **Step 1:** Open `scripts/deploy.js`; swap the deployed contracts for `NexauraTokenV2` and `NexauraStakingV2` (same constructor arguments as before), keeping the existing wiring order: `token.setStakingContract(staking)`, `staking.setTokenAddress(token)`, and the ReservePool `approveSpender(token)` call so `_coverShortfall` works.
- [ ] **Step 2:** Report and wait for OK.

### Task 13: Tests (only when the owner asks)

**Files:**
- Create: `test/NexauraStakingV2.test.js`, `test/NexauraTokenV2.test.js` (follow the style of `test/NexauraStaking.test.js` and `test/integration.test.js`)

- [ ] **Step 1:** Do not start until asked. When asked, write one test per Review Focus line plus: $100 stake split ($5/$5/$9/$81 and direct income of $5 in tokens), ROI = 12.5% of locked tokens at day 10, level cascade on a claimed ROI, 2x/3x cap clamp, `sell` pulling a shortfall from the reserve pool, `distributeCTO` equal split among Core 1 users.
- [ ] **Step 2:** Run `npx hardhat test` only on the owner's request and report the exact output.

---

## Self-review

- Spec coverage: stake split, direct income, claimOrder (principal + ROI), level on claim, rank on claim, active/grace, token caps, claimables, CTO monthly, DAO reserve funding, swap to reserve, removals of unstake/sell: all mapped to Tasks 1-11. Deck deltas also covered: 11 rank tiers, DAO tier 3 (3000/4000/6), CTO OR rule.
- Names checked across tasks: `_canEarn`, `_clampToCapRoom`, `_toTokenAmount`, `_toUsdAmount`, `lockedTokens`, `startTime`, `roiGains`/`roiClaimed` are used identically everywhere.
