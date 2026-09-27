//SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

//------------------         token interface        -------------------//

interface ERC20In {
    function transfer(address _to, uint256 _amount) external returns (bool);
    function mintReward(address _user, uint256 _amount) external;

    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) external returns (bool);

    function sellSetGox(
        uint256 tokenAmount,
        address toAddress
    ) external returns (bool);

    function buySetGox(uint256 usdAmount) external returns (bool);

    function buySetGox(
        uint256 usdAmount,
        address toAddress
    ) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function rateInUSDT() external view returns (uint256);

    function decimals() external view returns (uint8);
}

interface SetGoxInt {
    struct order {
        address ownerAddress;
        uint256 orderValue;
        uint256 orderGrowth;
        uint256 orderID;
        uint256 orderTime;
        uint256 isMature;
        bool isComplete;
    }

    function stakeInfos(uint256) external view returns (order memory);

    struct userInfo {
        address referral;
        uint256 totalTeam;
        uint256 strongTeam;
        uint256 userLevel;
        uint256 lastStake;
        uint256 forfeitStake;
        uint256 harvestTime;
        bool isNewStake;
        bool joined;
    }

    function userInfos(address) external view returns (userInfo memory);

    struct bonusInfo {
        uint256 referralGains;
        uint256 levelGains;
        uint256 growthGains;
        uint256 teamGrowthGains;
        uint256 leaderGains;
        uint256 developmentGains;
        uint256 teamLevelStake;
        uint256 lapsTeamStake;
        uint256 totalStake;
        uint256 totalUnStake;
        uint256 totalWithdrwan;
        uint256 setgoxBuy;
    }

    function bonusInfos(address) external view returns (bonusInfo memory);
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

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

//*******************************************************************//
//------------------        MAIN contract         -------------------//
//*******************************************************************//

contract Setgox_Stack is Ownable(msg.sender) {
    address public tokenAddress;
    address public usdAddress = 0x4aE58BfC16b20bD67755FFD5560e85779D962415;
    address public FeeReciver = 0x9F52C31050bD412DF8581251aCeB0065F693A0F8;
    address public FeeReciver_ = 0x11c1789e70B605a9a4a13D343c9e01c396810A25;
    address public FeeReciver__ = 0x0457Cf4833c20dCd5f99E90d2eF14C2c442aaf37;

    address internal defaultAddress;

    uint256 internal constant MAXGROWTH_DAYS = 70 minutes;
    uint256[] internal growthRate = [10, 10];
    uint256[] internal levelSatke = [400, 150, 100, 50, 50, 50, 50, 50, 50, 50];
    uint256 internal BASE = 10 ** 18;
    uint256 public totalReg;
    address[] public DAO_Users;
    uint256 public DAO_Amount;
    mapping(address => uint256) daoRewardClaimed;
    uint256 public allStake;
    uint256 public distShare;
    uint256 public teamDepth = 150;
    uint256 public redeemRate = 5;
    uint256 public checkpoint;
    uint256 public raisedAmount;
    uint256 disCount;
    bool public boostLevel;

    event regUserEv(address _user, address referralAddress);
    event deposit_Satke(
        uint256 stacke_Id,
        address user,
        uint256 growthRate,
        uint256 amount,
        uint256 timeStamp
    );
    event withdrwal_Stacking(address _user, uint256 amount);
    event income_Ev(
        address from_user,
        address to_user,
        uint256 level,
        uint256 payAmount,
        uint256 types
    );
    event forfeit_Ev(uint256 stacke_Id);

    mapping(address => uint256) internal asDefault;
    mapping(address => address) internal asLeader;

    /* 

    //=============Type of Bonus =================//
    Stake Bonus         = 1
    Referral Bonus      = 2
    Level Bonus         = 3
    Team Stake Bonus    = 4
    Leader Bonus        = 5
    Development Bonus   = 6

    */

    struct userInfo {
        address referral;
        address[] directs;
        uint256 totalTeam;
        uint256 strongTeam;
        uint256 userLevel;
        uint256 lastStake;
        uint256 forfeitStake;
        uint256 harvestTime;
        uint256[] stakeOrders;
        bool isNewStake;
        uint256 totalTeamBusiness;
        uint256 directBusiness;
        bool joined;
    }

    struct order {
        address ownerAddress;
        uint256 orderValue;
        uint256 orderGrowth;
        uint256 orderID;
        uint256 orderTime;
        uint256 isMature;
        bool isComplete;
    }

    struct bonusInfo {
        uint256 referralGains;
        uint256 levelGains;
        uint256 growthGains;
        uint256 teamGrowthGains;
        uint256 leaderGains;
        uint256 developmentGains;
        uint256 teamLevelStake;
        uint256 lapsTeamStake;
        uint256 totalStake;
        uint256 totalUnStake;
        uint256 totalWithdrwan;
        uint256 setgoxBuy;
    }

    address[] public usersRankOne;
    address[] public usersRankTwo;
    address[] public usersRankThree;
    mapping(address => bool) public isRankOne;
    mapping(address => bool) public isRankTwo;
    mapping(address => bool) public isRankThree;
    mapping(address => bool) onceAchived;
    mapping(address => bool) twiceAchived;
    mapping(address => bool) thriceAchived;
    mapping(address => uint256) public claimedRankRewardOne;
    mapping(address => uint256) public claimedRankRewardTwo;
    mapping(address => uint256) public claimedRankRewardThree;
    mapping(address => mapping(uint256 => bool)) public fundsSent;
    uint256 public usersCountRankOne;
    uint256 public usersCountRankTwo;
    uint256 public usersCountRankThree;

    mapping(address => userInfo) public userInfos;
    mapping(uint256 => order) public stakeInfos;
    mapping(address => bonusInfo) public bonusInfos;

    constructor(address _owner) {
        defaultAddress = _owner;
        userInfos[_owner].lastStake = 1;
        userInfos[_owner].joined = true;
        checkpoint = block.timestamp;
    }

    function regUser(address referral) public returns (bool) {
        if (userInfos[msg.sender].joined) {
            // other register
            _resUser(referral, msg.sender);
        } else {
            // Self registeration
            _resUser(msg.sender, referral);
        }

        return true;
    }

    function _resUser(address user, address referral) internal {
        require(
            !userInfos[user].joined && referral != address(0),
            "Already Registered"
        );
        require(
            userInfos[referral].lastStake > 0 && referral != address(0),
            "Invalid referral"
        );

        totalReg++;
        userInfos[user].referral = referral;
        userInfos[user].joined = true;
        userInfos[user].userLevel = 1;
        emit regUserEv(user, referral);
    }

    function buyToken(uint256 usdAmount) external returns (bool) {
        uint256 remainBuy = userInfos[msg.sender].lastStake -
            bonusInfos[msg.sender].setgoxBuy;
        require(
            userInfos[msg.sender].stakeOrders.length > 0 &&
                remainBuy >= usdAmount &&
                usdAmount != 0,
            "Invalid Amount"
        );
        bonusInfos[msg.sender].setgoxBuy += usdAmount;
        usdAmount = usdAmount * BASE;

        // take payment.
        ERC20In(usdAddress).transferFrom(msg.sender, address(this), usdAmount);

        // give token
        ERC20In(usdAddress).approve(tokenAddress, usdAmount);
        ERC20In(tokenAddress).buySetGox(usdAmount, msg.sender);

        return true;
    }

    function makeStake(
        uint256 amount,
        address userAddress
    ) public returns (bool) {
        validateUser(userAddress);
        stakeUpdate(userAddress);

        address ref = userInfos[userAddress].referral;
        uint256 nextOrd = userInfos[userAddress].stakeOrders.length;
        uint256 lastAmt = userInfos[userAddress].lastStake;

        uint256 rate = growthRate[0];
        raisedAmount += amount * BASE;

        if (nextOrd > 0) {
            (
                uint256 activeOrd,
                uint256 lastOrder,
                uint256 unlockOrd,
                ,

            ) = matureOrder(userAddress);
            require(activeOrd < 10, "limit exceeded");

            if (activeOrd > 0) {
                _forfeitOrder(userAddress, lastOrder, 0);
                (activeOrd, , unlockOrd, , ) = matureOrder(userAddress);
            }

            if (unlockOrd != 0) {
                stakeInfos[unlockOrd].isMature = 1;
            }

            require(
                stakeInfos[userInfos[userAddress].stakeOrders[nextOrd - 1]]
                    .orderTime +
                    10 minutes <
                    block.timestamp,
                "Next Order after 24 H"
            );

            if (lastAmt == amount) rate = userUpdate(userAddress);
        } else {
            userInfos[ref].directs.push(userAddress);
            userInfos[userAddress].harvestTime = block.timestamp;
        }

        require(
            amount % 10 == 0 && amount >= 10 && lastAmt <= amount,
            "Invalid Stake Amount"
        );

        // Stake order is making
        allStake++;

        order memory newOrder = order(
            userAddress,
            amount,
            rate,
            allStake,
            block.timestamp,
            0,
            false
        );
        stakeInfos[newOrder.orderID] = newOrder;

        emit deposit_Satke(
            newOrder.orderID,
            userAddress,
            rate,
            amount * BASE,
            block.timestamp
        );

        rate = bonusInfos[msg.sender].teamLevelStake;
        uint256 setgoxAmount = getPrice(amount * BASE);

        if (lastAmt == 0 && rate > 0 && activeUser(msg.sender)) {
            nextOrd = (((amount * BASE) * redeemRate) / 100);
            if (balance(tokenAddress, msg.sender) >= setgoxAmount)
                nextOrd = nextOrd * 2;

            rate = rate > nextOrd ? nextOrd : rate;

            bonusInfos[msg.sender].teamGrowthGains += rate;
            bonusInfos[msg.sender].teamLevelStake -= rate;
            emit income_Ev(userAddress, msg.sender, 0, rate, 4);
        } else delete rate;

        _distLevel(userAddress, amount * BASE, lastAmt);
        _leaderDist(userAddress, amount * BASE);

        if (amount > lastAmt) userInfos[userAddress].lastStake = amount;

        userInfos[userAddress].stakeOrders.push(newOrder.orderID);
        bonusInfos[userAddress].totalStake += amount;

        _transferFrom(amount * BASE, setgoxAmount);
        _updateBusinessToUpline(userInfos[userAddress].referral, amount);

        return true;
    }

    function _updateBusinessToUpline(address user, uint256 amount) internal {
        address current = user;
        uint256 counter = 0;
        while (current != address(0)) {
            if (counter == 0) {
                userInfos[current].directBusiness += amount * BASE;
                counter++;
            } else {
                userInfos[current].totalTeamBusiness += amount * BASE;
            }

            if (
                userInfos[current].directBusiness >= 5000 * BASE &&
                userInfos[current].totalTeamBusiness >= 25000 * BASE &&
                userInfos[current].directs.length >= 5
            ) {
                isRankOne[current] = true;
                if (!onceAchived[current]) {
                    usersCountRankOne++;
                    onceAchived[current] = true;
                    usersRankOne.push(current);
                }
            }
            if (
                userInfos[current].directBusiness >= 10000 * BASE &&
                userInfos[current].totalTeamBusiness >= 50000 * BASE &&
                userInfos[current].directs.length >= 10
            ) {
                if (isRankOne[current]) {
                    isRankOne[current] = false;
                }
                isRankTwo[current] = true;

                if (!twiceAchived[current]) {
                    usersCountRankTwo++;
                    twiceAchived[current] = true;
                    usersRankTwo.push(current);
                    usersCountRankOne--;
                }
            }

            if (
                userInfos[current].directBusiness >= 25000 * BASE &&
                userInfos[current].totalTeamBusiness >= 100000 * BASE &&
                userInfos[current].directs.length >= 25
            ) {
                isRankThree[current] = true;
                if (isRankOne[current]) {
                    isRankOne[current] = false;
                }
                if (isRankTwo[current]) {
                    isRankTwo[current] = false;
                }
                if (!thriceAchived[current]) {
                    usersCountRankThree++;
                    thriceAchived[current] = true;
                    usersRankThree.push(current);
                    usersCountRankTwo--;
                }
            }
            current = userInfos[current].referral;
        }
    }

    function makeUnstake(uint256 amount) public returns (bool) {
        validateUser(msg.sender);
        require(amount >= 1, "Invalid Amount");
        (
            ,
            ,
            ,
            uint256 lastOrder,
            ,
            uint256 mhOrder,
            uint256 avGain,
            uint256 ordValue,
            uint256 ordGrowth,
            uint256 teamGrowth,
            uint256 lapsReward
        ) = unStakePotential(msg.sender);

        // team stake update

        _stakeUpdate(msg.sender, teamGrowth, lapsReward);
        _forfeitOrder(msg.sender, lastOrder, ordValue);

        // Stake order update
        if (mhOrder > 0) {
            if (!stakeInfos[mhOrder].isComplete) {
                stakeInfos[mhOrder].isComplete = true;
                bonusInfos[msg.sender].totalUnStake += ordValue;
            } else {
                amount -= ordValue;
                delete ordValue;
            }

            if (ordGrowth > 0) {
                bonusInfos[msg.sender].growthGains += ordGrowth;
                emit income_Ev(msg.sender, msg.sender, mhOrder, ordGrowth, 1);
            }
        }

        if (amount == 0) return true;

        // total withdrwal potantial
        uint256 totalGain = (avGain + ordGrowth + teamGrowth);
        require(amount >= ordValue, "Order Value less then withdrawal");

        amount = (amount * BASE);
        ordValue = (ordValue * BASE);

        require(
            amount <= (totalGain + ordValue) && (totalGain + ordValue) != 0,
            "Invalid Unstake Amount"
        );

        uint256 withdrawn = asDefault[msg.sender] > 1
            ? asDefault[msg.sender] * amount - ordValue
            : amount - ordValue;

        if (withdrawn > 0) {
            bonusInfos[msg.sender].totalWithdrwan += withdrawn;

            withdrawn = getPrice(withdrawn);

            ERC20In(tokenAddress).approve(tokenAddress, withdrawn);
            ERC20In(tokenAddress).sellSetGox(withdrawn, msg.sender);
        }

        // deposit amount transfer
        if (ordValue > 0) _transfer(msg.sender, getPrice(ordValue));

        emit withdrwal_Stacking(msg.sender, amount);
        userUpdate(msg.sender);

        return true;
    }

    function userSelfUpdate(address user) public returns (bool) {
        userUpdate(user);
        stakeUpdate(user);

        return true;
    }

    function userUpdate(address user) internal returns (uint256 orderRate) {
        (
            ,
            uint256 level,
            uint256 sLeg,
            uint256 tTeam,
            uint256 grwRate
        ) = userLiveStatus(user);

        teamUpdate(user, level, sLeg, tTeam);

        orderRate = grwRate > 1 ? growthRate[1] : growthRate[0];
    }

    function teamUpdate(
        address user,
        uint256 level,
        uint256 sLeg,
        uint256 tTeam
    ) internal {
        if (userInfos[user].userLevel < level)
            userInfos[user].userLevel = level;
        if (userInfos[user].strongTeam < sLeg)
            userInfos[user].strongTeam = sLeg;
        if (userInfos[user].totalTeam < tTeam)
            userInfos[user].totalTeam = tTeam;
    }

    function rankQualify(
        address user
    )
        public
        view
        returns (
            uint256 directs,
            uint256 level,
            uint256 strongTeam,
            uint256 totalTeam,
            uint256 fLevel
        )
    {
        (directs, level, strongTeam, totalTeam, ) = userLiveStatus(user);

        if (defValidate(user))
            return (directs, 23, strongTeam, totalTeam, fLevel);

        if (
            userInfos[user].stakeOrders.length > 0 &&
            level < 10 &&
            block.timestamp <
                (stakeInfos[userInfos[user].stakeOrders[0]].orderTime +
                    7 minutes)
        ) fLevel = 10;
        if (boostLevel) fLevel = 21;
    }

    function userLiveStatus(
        address user
    )
        public
        view
        returns (
            uint256 directs,
            uint256 level,
            uint256 strongLeg,
            uint256 totalTeam,
            uint256 growthVol
        )
    {
        uint256 directPh;
        uint256 lastAmount = userInfos[user].lastStake;
        address[] memory ref = userInfos[user].directs;

        level = userInfos[user].userLevel;
        directs = ref.length;

        for (uint256 i; i < ref.length; i++) {
            uint256 refTeam = userInfos[ref[i]].totalTeam;
            totalTeam += (refTeam + 1);

            if (strongLeg < refTeam) strongLeg = (refTeam + 1);
            if (growthVol < 2 && userInfos[ref[i]].lastStake >= lastAmount)
                growthVol++;

            // level Qualification
            if (level < 5 && ref.length >= 5) {
                directPh += bonusInfos[ref[i]].totalStake;
                if (directPh >= 500) level = 5;
            }
        }

        if (level >= 5 && level < 23 && directs >= 10) {
            level = levelCount(
                directs,
                ((totalTeam < strongLeg) ? 0 : (totalTeam - strongLeg))
            );
        }
    }

    function stakeUpdate(address user) internal returns (uint256 userTPR) {
        uint256 frozenRew;
        uint256 lapsReward;
        uint256 orderID;

        (userTPR, , orderID, , frozenRew, lapsReward) = _stakeGrowth(
            user,
            0,
            0,
            false
        );

        _stakeUpdate(user, frozenRew, lapsReward);
        if (orderID > 0) _forfeitOrder(user, orderID, 0);
    }

    function _stakeUpdate(
        address user,
        uint256 frozenRew,
        uint256 lapsReward
    ) internal {
        if (frozenRew > 0) {
            bonusInfos[user].teamGrowthGains += frozenRew;
            emit income_Ev(user, user, 0, frozenRew, 4);
        }

        // lasp profit is credited
        if (lapsReward > 0) bonusInfos[user].lapsTeamStake += lapsReward;
        if ((lapsReward + frozenRew) > 0)
            bonusInfos[user].teamLevelStake -= (lapsReward + frozenRew);

        userInfos[user].harvestTime = block.timestamp;
    }

    function _forfeitOrder(
        address user,
        uint256 OrderId,
        uint256 orderVol
    ) internal {
        if (OrderId != 0) {
            if (orderVol == 0) orderVol = stakeInfos[OrderId].orderValue;
            uint256 totalGain = limitGains(user);

            if (
                totalGain >=
                (((userInfos[user].forfeitStake + orderVol) * 3) * BASE)
            ) {
                userInfos[user].forfeitStake += orderVol;
                bonusInfos[user].totalUnStake += orderVol;
                stakeInfos[OrderId].isComplete = true;
                userInfos[user].isNewStake = true;

                emit forfeit_Ev(OrderId);
            }
        }
    }

    function levelCount(
        uint256 directs,
        uint256 OLeg
    ) internal pure returns (uint256 level) {
        if (OLeg >= 1000 && directs >= 20)
            return 23;
            // Black Diamond or development bonus
        else if (OLeg >= 300 && directs >= 20)
            return 22;
            // Diamond or leader Bonus
        else if (OLeg >= 200 && directs >= 20)
            return 21;
            // platinum
        else if (OLeg >= 50 && directs >= 10)
            return 10;
            // gold
        else return 5; // silver
    }

    //---------------------Gas Optimization Call-----------------------------//

    function validateUser(address user) internal view {
        require(userInfos[user].joined, "caller not registered");
    }

    function authValidate(address user) internal view returns (bool) {
        require(user == defaultAddress, "is not auth");
        return (user == defaultAddress);
    }

    function defValidate(address user) internal view returns (bool) {
        return (asDefault[user] != 0);
    }

    function leaderValidate(address user) internal view returns (bool) {
        return (asLeader[user] == user);
    }

    function stakeGrowth(
        uint256 stake_Order
    ) public view returns (uint256 orderGrowth) {
        (, , , orderGrowth, , ) = _stakeGrowth(
            stakeInfos[stake_Order].ownerAddress,
            stake_Order,
            0,
            false
        );
    }

    function _stakeGrowth(
        address user,
        uint256 stake_Order,
        uint256 userLimit,
        bool callType
    )
        internal
        view
        returns (
            uint256 totalTPR,
            uint256 growthTPR,
            uint256 orderID,
            uint256 orderGrowth,
            uint256 teamGrowth,
            uint256 teamLaps
        )
    {
        if (userLimit != 0 && stake_Order != 0)
            (totalTPR, growthTPR) = _getRemainTPR(user, userLimit);
        else
            (totalTPR, growthTPR, stake_Order) = totalRemainTPR(user, callType);

        uint256 growthVol;
        uint256 current;

        uint256 maxD = MAXGROWTH_DAYS;
        uint256 _d = maxD / 7;

        if (
            stakeInfos[stake_Order].orderGrowth != 0 &&
            growthTPR != 0 &&
            stake_Order != 0 &&
            !stakeInfos[stake_Order].isComplete
        ) {
            orderID = stake_Order;
            current = (block.timestamp - stakeInfos[orderID].orderTime);

            growthVol = stakeInfos[orderID].orderValue * BASE;

            stake_Order = (growthVol * stakeInfos[orderID].orderGrowth) / 1000;

            current = (current > maxD ? maxD : current) / _d;

            orderGrowth = (stake_Order * current);

            orderGrowth = orderGrowth > growthTPR ? growthTPR : orderGrowth;

            growthTPR -= orderGrowth;
            totalTPR -= orderGrowth;
        }

        current = teamGrowthTime(user, growthTPR);

        if (current > 0) {
            growthVol = bonusInfos[user].teamLevelStake;

            stake_Order = (growthVol * 5) / 1000;

            stake_Order = (stake_Order / _d);

            teamGrowth = (current * stake_Order);

            teamGrowth = teamGrowth > growthVol ? growthVol : teamGrowth;

            if (teamGrowth > growthTPR) {
                teamLaps += (teamGrowth - growthTPR);
                teamGrowth = growthTPR;
            }

            totalTPR -= teamGrowth;

            if (growthTPR > totalTPR) growthTPR = totalTPR;
        }
    }

    function teamGrowthTime(
        address user,
        uint256 totalTPR
    ) public view returns (uint256 growthTime) {
        if (defValidate(user) || totalTPR == 0) {
            growthTime = (block.timestamp - userInfos[user].harvestTime);
        } else {
            // order id
            uint256 lsTime = userInfos[user].stakeOrders[
                userInfos[user].stakeOrders.length - 1
            ];

            lsTime = stakeInfos[lsTime].orderTime + MAXGROWTH_DAYS;

            lsTime = lsTime > block.timestamp ? block.timestamp : lsTime;

            if (totalTPR != 0 && lsTime > userInfos[user].harvestTime) {
                growthTime = (lsTime - userInfos[user].harvestTime);
            }
        }
    }

    function matureOrder(
        address _user
    )
        public
        view
        returns (
            uint256 activeOrder,
            uint256 lastOrder,
            uint256 unlock_Order,
            uint256 mature_Order,
            uint256 activeLimit
        )
    {
        uint256 StakeOrd;
        uint256 stakeLen = userInfos[_user].stakeOrders.length;
        uint256 maxGrowth = MAXGROWTH_DAYS;

        if (stakeLen > 0) {
            for (uint256 i = stakeLen; i > 0; i--) {
                StakeOrd = userInfos[_user].stakeOrders[i - 1];

                order memory stakeInfo = stakeInfos[StakeOrd];

                if (!stakeInfo.isComplete) {
                    activeOrder++;

                    lastOrder = StakeOrd;
                    if (
                        stakeInfo.orderGrowth == 0 ||
                        ((stakeInfo.orderTime + maxGrowth) > block.timestamp)
                    ) activeLimit += stakeInfo.orderValue;
                    if (
                        stakeInfo.orderGrowth != 0 &&
                        stakeInfo.isMature == 0 &&
                        ((stakeInfo.orderTime + (5 minutes)) < block.timestamp)
                    ) unlock_Order = StakeOrd;
                    if (
                        stakeInfo.orderGrowth != 0 &&
                        stakeInfo.isMature == 1 &&
                        ((stakeInfo.orderTime + maxGrowth) < block.timestamp)
                    ) mature_Order = StakeOrd;
                }

                if ((stakeLen - i) == 15) break;
            }
        }
        // default user limit
        if (defValidate(_user)) activeLimit = stakeInfos[0].orderValue;
    }

    function userStakeView(
        address user,
        uint256 stakeCount
    ) public view returns (uint256 totalCount, order memory stakeInfo) {
        totalCount = userInfos[user].stakeOrders.length;
        if (totalCount > 0 && totalCount > stakeCount)
            stakeInfo = stakeInfos[userInfos[user].stakeOrders[stakeCount]];
    }

    function levelDist() public pure returns (uint8[21] memory levelPer) {
        levelPer = [
            250,
            100,
            50,
            50,
            50,
            25,
            25,
            25,
            15,
            15,
            15,
            10,
            10,
            10,
            10,
            10,
            10,
            15,
            15,
            15,
            25
        ];
    }

    function activeUser(address _user) public view returns (bool active) {
        if (defValidate(_user)) return true;
        else {
            uint256 StOrd = userInfos[_user].stakeOrders.length;

            if (StOrd > 0) {
                StOrd = userInfos[_user].stakeOrders[StOrd - 1];
                if (
                    (stakeInfos[StOrd].orderTime + MAXGROWTH_DAYS) >
                    block.timestamp
                ) return true;
            }
        }
    }

    function directUser(
        address userAddress
    ) public view returns (address[] memory referrals) {
        return referrals = userInfos[userAddress].directs;
    }

    function totalGains(address _user) public view returns (uint256 total) {
        return
            total = (bonusInfos[_user].referralGains +
                bonusInfos[_user].levelGains +
                bonusInfos[_user].growthGains +
                bonusInfos[_user].teamGrowthGains +
                bonusInfos[_user].leaderGains +
                bonusInfos[_user].developmentGains);
    }

    function limitGains(address _user) internal view returns (uint256 total) {
        return
            total = (bonusInfos[_user].referralGains +
                bonusInfos[_user].levelGains +
                bonusInfos[_user].growthGains +
                bonusInfos[_user].teamGrowthGains);
    }

    function avUnStake(address user) public view returns (uint256 avGh) {
        (
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 tog,
            uint256 ov,
            uint256 og,
            uint256 tg,

        ) = unStakePotential(user);

        return avGh = (tog + tg + og + (ov * BASE));
    }

    function unStakePotential(
        address _user
    )
        public
        view
        returns (
            uint256 remainLimit,
            uint256 growthLimit,
            uint256 active_Order,
            uint256 lastOrder,
            uint256 unlock_Order,
            uint256 mature_Order,
            uint256 totGain,
            uint256 OrderValue,
            uint256 orderGrowth,
            uint256 teamGrowth,
            uint256 teamLaps
        )
    {
        totGain = totalGains(_user);

        totGain = totGain - bonusInfos[_user].totalWithdrwan;

        (
            active_Order,
            lastOrder,
            unlock_Order,
            mature_Order,
            remainLimit
        ) = matureOrder(_user);
        (
            remainLimit,
            growthLimit,
            ,
            orderGrowth,
            teamGrowth,
            teamLaps
        ) = _stakeGrowth(_user, mature_Order, remainLimit * BASE, true);

        if (mature_Order != 0 && stakeInfos[mature_Order].orderGrowth > 0) {
            OrderValue = stakeInfos[mature_Order].orderValue;
        }
    }

    function totalRemainTPR(
        address userAddress,
        bool isMatureOrd
    )
        public
        view
        returns (uint256 totalTPR, uint256 growthTPR, uint256 forfietOrder)
    {
        uint256 matureOrd;

        (, forfietOrder, , matureOrd, totalTPR) = matureOrder(userAddress);

        if (isMatureOrd) forfietOrder = matureOrd;

        (totalTPR, growthTPR) = _getRemainTPR(userAddress, totalTPR * BASE);
    }

    function _getRemainTPR(
        address userAddress,
        uint256 userLimit
    ) internal view returns (uint256 totalTPR, uint256 growthTPR) {
        uint256 fixTpr = userInfos[userAddress].forfeitStake * BASE;

        if ((userLimit + fixTpr) > 0) {
            uint256 totEran = limitGains(userAddress);
            uint256 growthEarn = bonusInfos[userAddress].growthGains;
            // growth limit debited by all growth eran
            growthTPR = (userLimit * 2) > growthEarn
                ? (userLimit * 2) - growthEarn
                : 0;
            // total limit debited by all total eran
            userLimit += fixTpr;
            totalTPR = (userLimit * 3) > totEran
                ? ((userLimit * 3) - totEran)
                : 0;
        }

        if (growthTPR > totalTPR) growthTPR = totalTPR;
    }

    //---------------------Inconme distribution-----------------------------

    function _distLevel(
        address _user,
        uint256 amount,
        uint256 lastStake
    ) internal {
        uint8[21] memory persent = levelDist();
        uint256[] memory lsPersent = levelSatke;

        address usr = userInfos[_user].referral;

        uint256 teamStake = userInfos[_user].isNewStake
            ? amount
            : (amount - (lastStake * BASE));
        uint256 stakePer;

        for (uint256 i; i < 21; i++) {
            if (usr == address(0)) break;

            // stake growth update
            uint256 useTPR = stakeUpdate(usr);

            (
                ,
                uint256 lev,
                uint256 sLeg,
                uint256 tTeam,
                uint256 flev
            ) = rankQualify(usr);

            if (lastStake == 0) {
                if (userInfos[usr].totalTeam < tTeam)
                    teamUpdate(usr, lev, sLeg, tTeam);
            }

            if ((useTPR > 0 || defValidate(usr)) && (lev > i || flev > i)) {
                if (i < lsPersent.length)
                    stakePer = (teamStake * lsPersent[i]) / 1000;
                else delete stakePer;

                uint256 tokanAmt = ((amount * persent[i]) / 10000);

                if (i == 0) {
                    uint256 ls = userInfos[usr].lastStake;
                    if (amount > (ls * BASE))
                        tokanAmt = (((ls * BASE) * persent[i]) / 10000);
                    bonusInfos[usr].referralGains += tokanAmt;
                    lev = 2;
                } else {
                    bonusInfos[usr].levelGains += tokanAmt;
                    lev = 3;
                }

                if (stakePer != 0) {
                    bonusInfos[usr].teamLevelStake += stakePer;
                    emit income_Ev(_user, usr, i + 1, stakePer, 4);
                }
                emit income_Ev(_user, usr, i + 1, tokanAmt, lev);
            }

            usr = userInfos[usr].referral;
        }

        if (userInfos[_user].isNewStake) userInfos[_user].isNewStake = false;
    }

    function _leaderDist(address _user, uint256 amount) internal {
        uint256 payAmt = ((amount * 50) / 10000);
        uint256 persent = 25;

        address[6] memory ledAdd;
        address[3] memory devAdd;

        (ledAdd, devAdd) = findLeaderUser(userInfos[_user].referral);

        for (uint256 i; i < ledAdd.length; i++) {
            address ledUsr = ledAdd[i];
            address devUsr;
            if (i < 3) devUsr = devAdd[i];

            if (ledUsr == address(0) && devUsr == address(0)) break;
            // leader bonus distibution
            if (ledUsr != address(0) && activeUser(ledUsr)) {
                if (i > 0) payAmt = ((amount * 10) / 10000);
                bonusInfos[ledUsr].leaderGains += payAmt;
                emit income_Ev(_user, ledUsr, i + 1, payAmt, 5);
            }
            // Development bonus distibution
            if (devUsr != address(0) && activeUser(devUsr)) {
                if (i == 1) persent = 15;
                else if (i == 2) persent = 10;

                uint256 devAmt = ((amount * persent) / 10000);
                bonusInfos[devUsr].developmentGains += devAmt;
                emit income_Ev(_user, devUsr, i + 1, devAmt, 6);
            }
        }
    }

    function findLeaderUser(
        address userAddress
    ) public view returns (address[6] memory ledAdd, address[3] memory devAdd) {
        uint256 count;
        uint256 breakCall = teamDepth;
        uint256 l;
        uint256 d;

        while ((l != 6) || (d != 3)) {
            if (userAddress == address(0) || count == breakCall) break;

            bool ledQlf;
            bool devQlf;
            uint256 other;

            count++;
            if (
                (defValidate(userAddress) ||
                    (leaderValidate(userAddress)) ||
                    (userInfos[userAddress].directs.length >= 20))
            ) {
                delete other;

                if (userInfos[userAddress].userLevel == 23) {
                    devQlf = true;
                    ledQlf = true;
                } else if (userInfos[userAddress].userLevel >= 22) {
                    ledQlf = true;
                } else
                    other = (userInfos[userAddress].totalTeam -
                        userInfos[userAddress].strongTeam);

                if ((l < 6 && ledQlf) || other >= 300) {
                    ledAdd[l] = (userAddress);
                    l++;
                }

                if ((d < 3 && devQlf) || other >= 1000) {
                    devAdd[d] = (userAddress);
                    d++;
                }
            }

            userAddress = userInfos[userAddress].referral;
        }
    }

    // --------------------- old data fetch ------------------------------//

    bool isContractMerged;

    function fetchOrderData(
        address contractAdd,
        uint256 orderId
    ) internal returns (uint256 Ids) {
        SetGoxInt.order memory orderData = SetGoxInt(contractAdd).stakeInfos(
            orderId
        );

        if (stakeInfos[orderId].orderTime == 0) {
            Ids = orderData.orderID;

            stakeInfos[orderId] = order(
                orderData.ownerAddress,
                orderData.orderValue,
                orderData.orderGrowth,
                orderData.orderID,
                orderData.orderTime,
                orderData.isMature,
                orderData.isComplete
            );

            emit deposit_Satke(
                orderData.orderID,
                orderData.ownerAddress,
                orderData.orderGrowth,
                orderData.orderValue * BASE,
                orderData.orderTime
            );

            if (orderId < 5)
                asDefault[orderData.ownerAddress] = (orderId == 1 ? 2 : 1);

            if (orderId != 0)
                userInfos[orderData.ownerAddress].stakeOrders.push(orderId);

            if (userInfos[orderData.ownerAddress].joined != true) {
                fetchUserData(contractAdd, orderData.ownerAddress);
                fetchRewardrData(contractAdd, orderData.ownerAddress);
            }
        } else delete Ids;
    }

    function fetchUserData(address contractAdd, address user) internal {
        SetGoxInt.userInfo memory userData = SetGoxInt(contractAdd).userInfos(
            user
        );

        if (userData.referral != address(0))
            userInfos[userData.referral].directs.push(user);

        totalReg++;
        userInfos[user].referral = userData.referral;
        userInfos[user].totalTeam = userData.totalTeam;
        userInfos[user].strongTeam = userData.strongTeam;
        userInfos[user].userLevel = userData.userLevel;
        userInfos[user].lastStake = userData.lastStake;
        userInfos[user].forfeitStake = userData.forfeitStake;
        userInfos[user].harvestTime = userData.harvestTime;
        userInfos[user].joined = userData.joined;
        emit regUserEv(user, userData.referral);

        // As leader
        if (asDefault[user] == 0 && userData.userLevel > 21)
            asLeader[user] = user;
    }

    function fetchRewardrData(address contractAdd, address user) internal {
        SetGoxInt.bonusInfo memory bonusData = SetGoxInt(contractAdd)
            .bonusInfos(user);

        bonusInfos[user].referralGains = bonusData.referralGains;
        bonusInfos[user].levelGains = bonusData.levelGains;
        bonusInfos[user].growthGains = bonusData.growthGains;
        bonusInfos[user].teamGrowthGains = bonusData.teamGrowthGains;
        bonusInfos[user].leaderGains = bonusData.leaderGains;
        bonusInfos[user].developmentGains = bonusData.developmentGains;
        bonusInfos[user].teamLevelStake =
            bonusData.teamLevelStake + bonusData.lapsTeamStake;
        bonusInfos[user].totalStake = bonusData.totalStake;
        bonusInfos[user].totalUnStake = bonusData.totalUnStake;
        bonusInfos[user].totalWithdrwan = bonusData.totalWithdrwan;
        bonusInfos[user].setgoxBuy = bonusData.setgoxBuy;
    }

    function distributeRankRewards() external {
        require(block.timestamp >= checkpoint + 30 minutes, "wait for 30 days");
        uint256 rankOnePool = (raisedAmount * 2) / 100;
        uint256 rankTwoPool = (raisedAmount * 1) / 100;
        uint256 rankThreePool = (raisedAmount * 1) / 100;

        uint256 rankOneShare = 0;
        uint256 rankTwoShare = 0;
        uint256 rankThreeShare = 0;

        if (usersCountRankOne > 0 && rankOnePool > 0) {
            rankOneShare = rankOnePool / usersCountRankOne;
        }

        if (usersCountRankTwo > 0 && rankTwoPool > 0) {
            rankTwoShare = rankTwoPool / usersCountRankTwo;
        }

        if (usersCountRankThree > 0 && rankThreePool > 0) {
            rankThreeShare = rankThreePool / usersCountRankThree;
        }

        // Distribute Rank One
        for (uint256 i = 0; i < usersRankOne.length; i++) {
            address user = usersRankOne[i];
            if (isRankOne[user] && !fundsSent[user][disCount]) {
                ERC20In(tokenAddress).mintReward(user, rankOneShare);
                claimedRankRewardOne[msg.sender] += rankOneShare;
                fundsSent[user][disCount] = true;
            }
        }

        // Distribute Rank Two
        for (uint256 i = 0; i < usersRankTwo.length; i++) {
            address user = usersRankTwo[i];
            if (isRankTwo[user] && !fundsSent[user][disCount]) {
                ERC20In(tokenAddress).mintReward(user, rankTwoShare);
                claimedRankRewardTwo[msg.sender] += rankTwoShare;
                fundsSent[user][disCount] = true;
            }
        }

        // Distribute Rank Three
        for (uint256 i = 0; i < usersRankThree.length; i++) {
            address user = usersRankThree[i];
            if (isRankThree[user] && !fundsSent[user][disCount]) {
                ERC20In(tokenAddress).mintReward(user, rankThreeShare);
                claimedRankRewardThree[msg.sender] += rankThreeShare;
                fundsSent[user][disCount] = true;
            }
        }
        checkpoint = block.timestamp;
        raisedAmount = 0;
        disCount++;
    }

    function getRankShares(
        address _user
    )
        public
        view
        returns (
            uint256 rankOneShare,
            uint256 rankTwoShare,
            uint256 rankThreeShare
        )
    {
        uint256 rankOnePool = (raisedAmount * 2) / 100;
        uint256 rankTwoPool = (raisedAmount * 1) / 100;
        uint256 rankThreePool = (raisedAmount * 1) / 100;

        if (usersCountRankOne > 0 && isRankOne[_user]) {
            rankOneShare = rankOnePool / usersCountRankOne;
        }

        if (usersCountRankTwo > 0 && isRankTwo[_user]) {
            rankTwoShare = rankTwoPool / usersCountRankTwo;
        }

        if (usersCountRankThree > 0 && isRankTwo[_user]) {
            rankThreeShare = rankThreePool / usersCountRankThree;
        }

        return (rankOneShare, rankTwoShare, rankThreeShare);
    }

    //---------------------Transfer Function-----------------------------//
    function _transferFrom(
        uint256 _amount,
        uint256 setgoxAmount
    ) internal returns (bool) {
        uint256 beforBal = balance(tokenAddress, address(this));

        if (balance(tokenAddress, msg.sender) >= setgoxAmount) {
            ERC20In(tokenAddress).transferFrom(
                msg.sender,
                address(this),
                setgoxAmount
            );
        } else {
            ERC20In(usdAddress).transferFrom(
                msg.sender,
                address(this),
                _amount
            );
            ERC20In(usdAddress).approve(tokenAddress, _amount);
            ERC20In(tokenAddress).buySetGox(_amount);
        }
        uint256 afterBal = balance(tokenAddress, address(this));

        _amount = afterBal - beforBal;
        raisedAmount += _amount;
        uint256 _feeamount = (_amount * 3) / 100;

        _transfer(FeeReciver, (_feeamount * 44444) / 100000);
        _transfer(FeeReciver, (_feeamount * 22222) / 100000);
        _transfer(FeeReciver_, (_feeamount * 16665) / 100000);
        _transfer(FeeReciver__, (_feeamount * 16665) / 100000);
        uint256 daoFee = (_amount * 150) / 10000;
        DAO_Amount += daoFee;

        return true;
    }

    function distributeReward() public {
        uint256 sharePerUser = DAO_Amount / DAO_Users.length;
        for (uint256 i = 0; i < DAO_Users.length; i++) {
            _transfer(DAO_Users[i], sharePerUser);
            daoRewardClaimed[DAO_Users[i]] += sharePerUser;
        }
        DAO_Amount = 0;
    }

    function DAO_Vote() public {
        ERC20In(usdAddress).transferFrom(
            msg.sender,
            tokenAddress,
            10000 * BASE
        );
        DAO_Users.push(msg.sender);
    }

    function setTokenAddress(address _tokenAddress) public onlyOwner {
        tokenAddress = _tokenAddress;
    }

    function _transfer(address _to, uint256 _amount) internal returns (bool) {
        ERC20In(tokenAddress).transfer(_to, _amount);
        return true;
    }

    function balance(
        address token,
        address user
    ) internal view returns (uint256) {
        return ERC20In(token).balanceOf(user);
    }

    function getPrice(uint256 _amount) public view returns (uint256) {
        return (((10 ** 18) * _amount) / ERC20In(tokenAddress).rateInUSDT());
    }
}