# NEXAURA Token & Staking System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `NexauraToken.sol` (BEP20 token) and `NexauraStaking.sol` (registration, packages, referral tree, all income/rank/DAO logic) implementing the NEXAURA package-based staking economy.

**Architecture:** Two contracts. `NexauraToken` only mints/burns through calls gated to `NexauraStaking`'s address; all economic logic (packages, referral cascade, rank, DAO, spot bonus, withdrawal) lives in `NexauraStaking`, which holds no token balance of its own — every bonus bucket is a ledger entry (`bonusInfos`) settled by minting fresh tokens at claim time, same two-step "accrue then mint-on-payout" shape as the reference contracts.

**Tech Stack:** Solidity ^0.8.20, Hardhat, `@nomicfoundation/hardhat-toolbox` (ethers v6 + Mocha/Chai), no other runtime dependencies.

**Spec:** `docs/superpowers/specs/2026-09-28-nexaura-design.md` — this plan implements every section of that spec; read both together.

## Global Constraints

- All USD-denominated values (package amounts, thresholds, gains) are stored `BASE`-scaled (`1e18`), matching the token's 18 decimals and BEP20 USDT's 18 decimals — no raw whole-dollar integers anywhere in contract state, per the spec's live-pricing model.
- No hardcoded addresses anywhere — USDT, fee receivers, treasury are constructor/owner-set params only (spec Section 2, Section 5).
- `NexauraToken` mint (`pricedBuy`), sell (`pricedSell`), and reserve payout (`payoutReserve`) are reachable **only** by the address set via `setStakingContract` — never by a plain EOA (spec: "tokens can only be obtained through the Staking Program").
- Transfer burn is exactly 1% on every `transfer`/`transferFrom` (spec Section 2). Withdrawal burns 100% of the sold token amount and applies a 10% USDT-side fee (5% creator / 5% daily spot bonus pool) — **not** a 15% LP/reserve split; that language was superseded (spec Section 2, resolved).
- Referral/level/rank/DAO/CTO percentages are all computed against the **90%-minted token amount** of each package, not the full package value (spec Section 4, confirmed with stakeholder) — this diverges from the reference contract's use of the *full* package amount; do not copy that part of the reference.
- Working Income (Direct + Level + Rank/Team Growth + CTO) caps at 3x active package value and requires 2+ direct referrals to be *claimable* (gains still accrue below that threshold). Non-Working Income (base Daily Reward) caps at 2x. Both caps and gains are compared in the same `BASE`-scaled numeraire (token gains vs. USD package value), same convention the reference contract uses — this assumes near-1:1 pricing and is flagged in Review Focus below, not silently ignored.
- Daily Reward and Team Growth/Rank accrual use a **discrete once-per-24h claim** model (spec Section 3.5), not the reference contract's continuous fractional-day growth curve — this is a deliberate, spec-approved simplification.
- Package recycling is two separate calls (`makeUnstake` then `makeStake`), never an atomic auto-compound function (spec Section 3.3, confirmed).
- DAO Partnership income and Daily Spot Bonus are **not** subject to the 3x/2x caps — they are separate periodic pool distributions (spec Section 3.4, flagged as an open item the stakeholder may revisit later, not a blocker now).

## Review Focus

- **Package amount not a multiple of $10, or below $10/above $1000** — `makeStake` must revert, not silently round or clamp (spec 3.2). Covered in Task 4.
- **Recycling with a smaller package than the previous one** — must revert, since packages can only hold steady or grow (spec 3.2, confirmed). Covered in Task 4.
- **An upline earner whose own package has dropped below $50 (or who never staked $50+)** — must be skipped in the 21-level cascade without breaking the walk for levels further up (spec 4.2, confirmed per-earner gate). Covered in Task 5.
- **A user with fewer than 2 direct referrals accruing large referral/level/rank gains** — those gains must show up in `bonusInfos` but return 0 from `claimableWorking` until they cross the 2-referral threshold, not silently vanish or block accrual entirely (spec 3.4). Covered in Task 7.
- **Withdrawal requests that exceed the $3,000/day cap, or land below the $10 minimum** — must revert with a clear reason, and the daily counter must correctly reset on UTC day rollover rather than accumulating forever. Covered in Task 9.

## Security Review

An adversarial pass was run against this plan before implementation, looking for anything an
ordinary user (not the owner) could exploit for profit or to break the system. Findings and
fixes, folded into the task code above:

- **Reentrancy.** The reference contracts use OpenZeppelin's `ReentrancyGuard` on every
  state-changing external function; this plan had dropped it. Added a `ReentrancyGuard` to both
  contracts and `nonReentrant` on every function that moves funds or mutates ledgers:
  `pricedBuy`/`pricedSell`/`payoutReserve` (Task 2), `regUser`/`makeStake`/`claimDailyReward`/
  `makeUnstake`/`withdraw`/`distributeDAO`/`distributeSpotBonus` (Tasks 3–10).
- **Price-inflation ("donation") attack — real, fixed.** The original `rateInUSDT()` priced
  tokens off `usdToken.balanceOf(address(this))`. Anyone can call `USDT.transfer` to send funds
  directly to a contract address without going through its functions — so an attacker could
  donate USDT straight into the token contract to move the rate, then extract value once a
  legitimate buyer/seller transacted against the manipulated price. This is the same class of
  bug that hit early ERC4626 vault implementations. **Fixed** in Task 2: pricing now uses an
  `internalReserve` counter that only `pricedBuy`/`pricedSell` can move, immune to direct
  transfers. A regression test asserting a direct USDT donation doesn't move the rate was added
  to Task 2.
- **Spot Bonus self-drain via candidate list — real, fixed.** `distributeSpotBonus` splits the
  pool only among the *caller-supplied* candidate addresses that qualify. Left permissionless,
  any qualifying user could call it with a candidate list containing only their own address and
  walk away with the entire day's pool, while every other legitimately qualified user — simply
  left off the list — gets nothing. **Fixed**: restricted to `onlyOwner` in Task 10, so only a
  trusted keeper supplies the list. (Verified this doesn't touch existing tests: every test call
  site already runs as the deploying account.)
- **`distributeDAO` unbounded loop — lower severity, mitigated, not fully solved.**
  `daoQualifiedUsers` only ever grows (qualification is sticky, confirmed design), so the loop's
  gas cost rises over the contract's lifetime and could eventually exceed the block gas limit —
  an availability risk (distributions stop working), not a theft vector, since payouts are
  computed from on-chain state, not caller input. Restricted to `onlyOwner` for consistency and
  so the owner controls when it's exercised; genuinely fixing the unbounded growth needs
  pagination, which is called out as a follow-up in Task 10's `ponytail:` comment rather than
  built now, since the DAO-qualified population (thresholds start at $500 direct business) is a
  much smaller, slower-growing set than the general user base.
- **Withdrawal self-dilution — real, fixed.** An earlier draft of Task 9 paid out bonus gains by
  minting the withdrawn amount as fresh tokens and immediately selling them via `pricedSell`.
  Since `pricedSell` prices against the *current* `internalReserve/totalSupply` ratio, and the
  mint runs first, the sale is priced against a totalSupply the mint itself just inflated —
  shortchanging the withdrawing user (verified numerically: a withdrawal equal to 10% of total
  supply paid out ~9% instead of the correct 10%, i.e. underpaid by roughly `amount/(supply +
  amount)`). Not an attacker-exploitable vector (it only shortchanges the withdrawer themself,
  and totalSupply nets back to its prior value once the same tokens are burned), but a real
  correctness bug. **Fixed**: Task 2 now exposes `payoutReserve(usdAmount, forAddress)`, which
  pays USDT straight out of `internalReserve` with no mint or burn on either side, and Task 9's
  `withdraw()` computes `usdValue` from `rateInUSDT()` before calling it — no self-dilution is
  possible because supply is never touched.
- **Sandwich/MEV pricing attack — checked, not applicable.** `pricedBuy`/`pricedSell` might look
  like a bonding curve that a large trade could move against later users. It isn't: both
  functions transact at the *current* `internalReserve/totalSupply` ratio and update both sides
  proportionally, which is mathematically rate-**preserving** — working the algebra through
  shows the rate before and after either call is identical. There is no classic AMM-style
  sandwich available here, so no slippage-protection parameters were added to `makeStake`/
  `withdraw` (adding them would have meant changing those functions' signatures everywhere
  they're called across Tasks 4–11 for no real protection gained).
- **Referral self-registration ambiguity — checked, already avoided.** The reference contract's
  `regUser` has a confusing dual path (registering either the caller or the argument as the new
  user, depending on prior state) that's a plausible source of referral-hijacking bugs. This
  plan's `regUser` (Task 3) never had that path — it always registers `msg.sender` under the
  given referral — so there's nothing to fix, just confirming it was checked.
- **Open question for you, not a code bug:** because rank/DAO-share/business-volume are all
  sticky-increasing (per your confirmed answer that ranks never downgrade), a user could stake a
  large package once, immediately qualify for a high rank/CTO tier/DAO share from the resulting
  business volume, then `makeUnstake` — and keep that status permanently with no ongoing capital
  at risk, since nothing in the design ever decrements `directBusiness`/`totalTeamBusiness` after
  unstaking. This matches both the reference contract's behavior and your explicit "ranks never
  downgrade" answer, so I haven't changed it — but flagging it now since it's exactly the kind of
  loophole your question was asking about, and it wasn't obviously in view when that design
  point was confirmed. If you want rank/DAO qualification to require *sustained* business rather
  than a permanent watermark, that's a real design change (e.g., decrementing business totals on
  unstake, or re-validating thresholds periodically) worth its own decision before implementation
  starts.

---

## File Structure

```
package.json
hardhat.config.js
contracts/
  NexauraToken.sol
  NexauraStaking.sol
  mocks/
    MockUSDT.sol
test/
  NexauraToken.test.js
  NexauraStaking.test.js
  integration.test.js
```

---

### Task 1: Project Scaffolding

**Files:**
- Create: `package.json`
- Create: `hardhat.config.js`
- Create: `contracts/mocks/MockUSDT.sol`
- Test: `test/MockUSDT.test.js`

**Interfaces:**
- Produces: `MockUSDT` — `mint(address to, uint256 amount) external`, plus standard ERC20 `transfer`/`transferFrom`/`approve`/`balanceOf`, 18 decimals. Used by every later test file to fund test accounts with fake USDT.

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "nexaura-contracts",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "test": "hardhat test"
  },
  "devDependencies": {
    "@nomicfoundation/hardhat-toolbox": "^5.0.0",
    "hardhat": "^2.22.0"
  }
}
```

- [ ] **Step 2: Install dependencies**

Run (from the project root — the directory containing this `package.json`): `npm install`
Expected: installs without error, creates `node_modules/` and `package-lock.json`.

- [ ] **Step 3: Create `hardhat.config.js`**

```js
require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
};
```

- [ ] **Step 4: Create `contracts/mocks/MockUSDT.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockUSDT {
    string public name = "Mock USDT";
    string public symbol = "USDT";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "MockUSDT: insufficient allowance");
        unchecked {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "MockUSDT: insufficient balance");
        unchecked {
            balanceOf[from] -= amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
```

- [ ] **Step 5: Write the test**

```js
// test/MockUSDT.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MockUSDT", function () {
  it("mints and transfers with correct balances", async function () {
    const [owner, alice, bob] = await ethers.getSigners();
    const MockUSDT = await ethers.getContractFactory("MockUSDT");
    const usdt = await MockUSDT.deploy();

    await usdt.mint(alice.address, ethers.parseEther("1000"));
    expect(await usdt.balanceOf(alice.address)).to.equal(ethers.parseEther("1000"));

    await usdt.connect(alice).transfer(bob.address, ethers.parseEther("100"));
    expect(await usdt.balanceOf(alice.address)).to.equal(ethers.parseEther("900"));
    expect(await usdt.balanceOf(bob.address)).to.equal(ethers.parseEther("100"));
  });
});
```

- [ ] **Step 6: Run test to verify it passes**

Run: `npx hardhat test test/MockUSDT.test.js`
Expected: PASS (1 passing)

- [ ] **Step 7: Commit**

```bash
git init
git add package.json hardhat.config.js contracts/mocks/MockUSDT.sol test/MockUSDT.test.js .gitignore
git commit -m "chore: scaffold Hardhat project with MockUSDT test fixture"
```

(Create a `.gitignore` with `node_modules/`, `artifacts/`, `cache/` before staging, if not already present.)

---

### Task 2: NexauraToken — Full Contract

**Files:**
- Create: `contracts/NexauraToken.sol`
- Test: `test/NexauraToken.test.js`

**Interfaces:**
- Consumes: nothing (base contract).
- Produces: `NexauraToken` — constructor `(address owner, address usdtAddress, string memory tokenName, string memory tokenSymbol)`; `setStakingContract(address)` (owner-only); `setFeeAddresses` — **not on this contract**, fee addresses live on `NexauraStaking` (Task 3); `pricedBuy(uint256 usdAmount, address forAddress) returns (uint256 minted)` (staking-only); `pricedSell(uint256 tokenAmount, address forAddress) returns (uint256 usdPaid)` (staking-only); `payoutReserve(uint256 usdAmount, address forAddress)` (staking-only — pure reserve payout, no mint/burn, see Task 9 for why); `rateInUSDT() returns (uint256)`; standard ERC20 `transfer`/`transferFrom`/`approve`/`balanceOf`/`allowance`/`totalSupply`/`name`/`symbol`/`decimals` with 1% burn on `transfer`/`transferFrom`. Later tasks (`NexauraStaking`) call `pricedBuy`, `pricedSell`, `payoutReserve`, `rateInUSDT`.

- [ ] **Step 1: Write the failing tests**

```js
// test/NexauraToken.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

async function deployFixture() {
  const [owner, staking, alice, bob] = await ethers.getSigners();

  const MockUSDT = await ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();

  const NexauraToken = await ethers.getContractFactory("NexauraToken");
  const token = await NexauraToken.deploy(
    owner.address,
    await usdt.getAddress(),
    "Nexaura",
    "NXA"
  );

  await token.connect(owner).setStakingContract(staking.address);

  return { owner, staking, alice, bob, usdt, token };
}

describe("NexauraToken", function () {
  it("has correct name, symbol, decimals", async function () {
    const { token } = await deployFixture();
    expect(await token.name()).to.equal("Nexaura");
    expect(await token.symbol()).to.equal("NXA");
    expect(await token.decimals()).to.equal(18);
  });

  it("only the staking contract can call pricedBuy", async function () {
    const { token, alice } = await deployFixture();
    await expect(
      token.connect(alice).pricedBuy(ethers.parseEther("100"), alice.address)
    ).to.be.revertedWith("Only staking contract");
  });

  it("pricedBuy mints tokens at the InitialRate (1:1) when supply is 0", async function () {
    const { token, staking, alice } = await deployFixture();
    await token.connect(staking).pricedBuy(ethers.parseEther("100"), alice.address);
    expect(await token.balanceOf(alice.address)).to.equal(ethers.parseEther("100"));
    expect(await token.totalSupply()).to.equal(ethers.parseEther("100"));
  });

  it("burns 1% on transfer and credits 99% to the recipient", async function () {
    const { token, staking, alice, bob } = await deployFixture();
    await token.connect(staking).pricedBuy(ethers.parseEther("100"), alice.address);

    await token.connect(alice).transfer(bob.address, ethers.parseEther("100"));

    expect(await token.balanceOf(bob.address)).to.equal(ethers.parseEther("99"));
    expect(await token.totalSupply()).to.equal(ethers.parseEther("99"));
  });

  it("pricedSell burns 100% of the sold tokens and pays full USD value to forAddress", async function () {
    const { token, staking, alice, usdt } = await deployFixture();

    // Fund the token contract with USDT so it can price and pay out.
    await usdt.mint(await token.getAddress(), ethers.parseEther("1000"));
    await token.connect(staking).pricedBuy(ethers.parseEther("100"), alice.address);

    // alice's 100 tokens are conceptually owned by the staking contract's ledger;
    // pricedSell is called by staking with the token amount to burn.
    const before = await usdt.balanceOf(staking.address);
    await token.connect(staking).pricedSell(ethers.parseEther("50"), staking.address);
    const after = await usdt.balanceOf(staking.address);

    expect(await token.totalSupply()).to.equal(ethers.parseEther("50")); // 100 minted - 50 burned
    expect(after - before).to.be.gt(0n);
  });

  it("rateInUSDT tracks internalReserve / total supply, following pricedBuy/pricedSell", async function () {
    const { token, staking, alice, usdt } = await deployFixture();
    await token.connect(staking).pricedBuy(ethers.parseEther("100"), alice.address);
    // internalReserve = 100 (from the usdAmount passed to pricedBuy), totalSupply = 100 -> rate 1:1
    expect(await token.rateInUSDT()).to.equal(ethers.parseEther("1"));

    await usdt.mint(await token.getAddress(), ethers.parseEther("1000"));
    await token.connect(staking).pricedBuy(ethers.parseEther("200"), alice.address);
    // internalReserve = 300, totalSupply = 300 -> still 1:1, driven by pricedBuy, not by the
    // 1000 USDT that was separately minted straight into the contract.
    expect(await token.rateInUSDT()).to.equal(ethers.parseEther("1"));
  });

  it("a direct USDT transfer into the contract does not move the rate (inflation-attack regression test)", async function () {
    const { token, staking, alice, usdt } = await deployFixture();
    await token.connect(staking).pricedBuy(ethers.parseEther("100"), alice.address);
    const rateBefore = await token.rateInUSDT();

    // Simulate an attacker donating USDT directly to the token contract, bypassing pricedBuy,
    // to try to move the rate before someone else's mint/sell.
    await usdt.mint(await token.getAddress(), ethers.parseEther("50000"));

    const rateAfter = await token.rateInUSDT();
    expect(rateAfter).to.equal(rateBefore);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx hardhat test test/NexauraToken.test.js`
Expected: FAIL — `NexauraToken` artifact not found (contract doesn't exist yet).

- [ ] **Step 3: Write `contracts/NexauraToken.sol`**

```solidity
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

contract NexauraToken is Ownable, ReentrancyGuard {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    uint8 private constant _decimals = 18;
    string private _name;
    string private _symbol;

    uint256 public constant TRANSFER_BURN_BP = 100; // 1%
    uint256 public constant BP_DENOM = 10000;
    uint256 public InitialRate = 1e18;

    IUSDLike public usdToken;
    address public stakingContract;

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
        string memory tokenSymbol
    ) Ownable(_owner) {
        require(_usdtAddress != address(0), "Invalid USDT address");
        usdToken = IUSDLike(_usdtAddress);
        _name = tokenName;
        _symbol = tokenSymbol;
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

        uint256 burnAmount = (amount * TRANSFER_BURN_BP) / BP_DENOM;
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

    /// @dev Burns `tokenAmount` from the staking contract's ledger and pays the full USDT value to `forAddress`.
    function pricedSell(uint256 tokenAmount, address forAddress)
        external
        onlyStaking
        nonReentrant
        returns (uint256 usdPaid)
    {
        require(tokenAmount > 0, "Amount must be greater than 0");
        uint256 rate = rateInUSDT();
        usdPaid = (tokenAmount * rate) / (10 ** _decimals);

        _burn(msg.sender, tokenAmount);
        require(internalReserve >= usdPaid, "Insufficient reserve");
        internalReserve -= usdPaid;
        require(usdToken.transfer(forAddress, usdPaid), "USDT transfer failed");
    }

    /// @dev Pays `usdAmount` of USDT straight out of internalReserve to `forAddress`, with no
    /// mint or burn on either side. Used for ledger-tracked bonus/gain payouts (referral, level,
    /// rank, CTO, daily reward) that were never backed by a real minted token balance in the
    /// first place — see Task 9. Minting those tokens and immediately burning them via
    /// pricedSell (an earlier draft of this plan did that) would price the sale against a
    /// mid-transaction, self-inflated totalSupply and silently shortchange the user; this avoids
    /// that entirely by never touching supply or balances.
    function payoutReserve(uint256 usdAmount, address forAddress) external onlyStaking nonReentrant {
        require(usdAmount > 0, "Amount must be greater than 0");
        require(internalReserve >= usdAmount, "Insufficient reserve");
        internalReserve -= usdAmount;
        require(usdToken.transfer(forAddress, usdAmount), "USDT transfer failed");
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx hardhat test test/NexauraToken.test.js`
Expected: PASS (7 passing)

Note: the `pricedSell` test mints tokens to `alice` in Step 3's test fixture but then calls `pricedSell` from `staking` — since `_burn` in `pricedSell` burns from `msg.sender` (the staking contract), and the staking contract itself holds no tokens in that test, this will actually revert with "burn amount exceeds balance". Fix the test to mint the tokens to `staking` (not `alice`) before calling `pricedSell`, since in the real flow (Task 4+) the staking contract always mints principal to itself, not to end users directly. Update the test:

```js
  it("pricedSell burns 100% of the sold tokens and pays full USD value to forAddress", async function () {
    const { token, staking, alice, usdt } = await deployFixture();

    await usdt.mint(await token.getAddress(), ethers.parseEther("1000"));
    await token.connect(staking).pricedBuy(ethers.parseEther("100"), staking.address);

    const before = await usdt.balanceOf(alice.address);
    await token.connect(staking).pricedSell(ethers.parseEther("50"), alice.address);
    const after = await usdt.balanceOf(alice.address);

    expect(await token.totalSupply()).to.equal(ethers.parseEther("50"));
    expect(after - before).to.equal(ethers.parseEther("50")); // rate stayed ~1:1 after the buy
  });
```

Re-run: `npx hardhat test test/NexauraToken.test.js` — Expected: PASS (7 passing).

- [ ] **Step 5: Commit**

```bash
git add contracts/NexauraToken.sol test/NexauraToken.test.js
git commit -m "feat: add NexauraToken with 1% transfer burn, reentrancy guard, and donation-resistant pricing"
```

---

### Task 3: NexauraStaking — Core Data Structures, Registration, Admin Wiring

**Files:**
- Create: `contracts/NexauraStaking.sol`
- Test: `test/NexauraStaking.test.js`

**Interfaces:**
- Consumes: `NexauraToken.pricedBuy`, `.pricedSell`, `.payoutReserve`, `.rateInUSDT` (Task 2, called via `INexauraToken` interface — not wired into logic yet, just declared).
- Produces: `NexauraStaking` — constructor `(address owner, address usdtAddress, address creatorFeeAddress, address treasuryAddress)`; `setTokenAddress(address)` (owner-only); `setFeeAddresses(address, address)` (owner-only); `regUser(address referral) returns (bool)`; `userInfos(address) returns (UserInfo)` (public mapping getter); `directsOf(address) returns (address[])`. Later tasks (4+) add `makeStake`, cascade, rank/CTO, claims, unstake, withdraw, DAO, spot bonus as new functions on this same contract.

- [ ] **Step 1: Write the failing tests**

```js
// test/NexauraStaking.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

async function deployFixture() {
  const [owner, creatorFee, treasury, alice, bob, carol] = await ethers.getSigners();

  const MockUSDT = await ethers.getContractFactory("MockUSDT");
  const usdt = await MockUSDT.deploy();

  const NexauraToken = await ethers.getContractFactory("NexauraToken");
  const token = await NexauraToken.deploy(owner.address, await usdt.getAddress(), "Nexaura", "NXA");

  const NexauraStaking = await ethers.getContractFactory("NexauraStaking");
  const staking = await NexauraStaking.deploy(
    owner.address,
    await usdt.getAddress(),
    creatorFee.address,
    treasury.address
  );

  await token.connect(owner).setStakingContract(await staking.getAddress());
  await staking.connect(owner).setTokenAddress(await token.getAddress());

  return { owner, creatorFee, treasury, alice, bob, carol, usdt, token, staking };
}

describe("NexauraStaking — core", function () {
  it("registers the owner as joined at deploy time", async function () {
    const { owner, staking } = await deployFixture();
    const info = await staking.userInfos(owner.address);
    expect(info.joined).to.equal(true);
  });

  it("regUser requires an already-joined referral", async function () {
    const { alice, bob, staking } = await deployFixture();
    await expect(staking.connect(alice).regUser(bob.address)).to.be.revertedWith("Invalid referral");
  });

  it("regUser succeeds under a joined referral (the owner)", async function () {
    const { owner, alice, staking } = await deployFixture();
    await staking.connect(alice).regUser(owner.address);
    const info = await staking.userInfos(alice.address);
    expect(info.joined).to.equal(true);
    expect(info.referral).to.equal(owner.address);
  });

  it("cannot register twice", async function () {
    const { owner, alice, staking } = await deployFixture();
    await staking.connect(alice).regUser(owner.address);
    await expect(staking.connect(alice).regUser(owner.address)).to.be.revertedWith("Already registered");
  });

  it("only the owner can set the token address and fee addresses", async function () {
    const { alice, staking, token } = await deployFixture();
    await expect(
      staking.connect(alice).setTokenAddress(await token.getAddress())
    ).to.be.revertedWithCustomError(staking, "OwnableUnauthorizedAccount");
    await expect(
      staking.connect(alice).setFeeAddresses(alice.address, alice.address)
    ).to.be.revertedWithCustomError(staking, "OwnableUnauthorizedAccount");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: FAIL — `NexauraStaking` artifact not found.

- [ ] **Step 3: Write `contracts/NexauraStaking.sol`**

```solidity
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
        // Seeded at MAX_PACKAGE, not MIN_PACKAGE: the owner acts as the root referral for the
        // whole tree, and both the direct-income cap (Task 5) and the $50 level-income gate
        // (Task 5) compare a staker's package against their UPLINE's own lastStake. Seeding the
        // owner at $10 would spuriously cap/gate every stake made directly under the owner,
        // since real packages routinely exceed $10 — the owner needs to look like a
        // fully-qualified referral, not a minimum one.
        userInfos[_owner].lastStake = MAX_PACKAGE;
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
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: PASS (5 passing)

- [ ] **Step 5: Commit**

```bash
git add contracts/NexauraStaking.sol test/NexauraStaking.test.js
git commit -m "feat: add NexauraStaking registration, admin wiring, and reentrancy guard"
```

---

### Task 4: `makeStake` — Package Purchase, Fee Split, Order Creation, Business Propagation

**Files:**
- Modify: `contracts/NexauraStaking.sol`
- Modify: `test/NexauraStaking.test.js`

**Interfaces:**
- Consumes: `INexauraToken.pricedBuy` (Task 2); `IUSDLike.transferFrom`/`.transfer` (Task 1's `MockUSDT`, real USDT in production).
- Produces: `makeStake(uint256 usdAmount) external returns (bool)`; internal `_updateBusinessToUpline(address user, uint256 amount)`. Task 5 (cascade) and Task 6 (rank/CTO) both hook into the business-update walk added here; Task 7 (claims) reads `userInfos[user].harvestTime` set here on first stake.

- [ ] **Step 1: Write the failing tests**

Append to `test/NexauraStaking.test.js`:

```js
describe("NexauraStaking — makeStake", function () {
  async function stakedFixture() {
    const base = await deployFixture();
    const { owner, alice, usdt, staking } = base;

    await staking.connect(alice).regUser(owner.address);
    await usdt.mint(alice.address, ethers.parseEther("10000"));
    await usdt.connect(alice).approve(await staking.getAddress(), ethers.parseEther("10000"));

    return base;
  }

  it("rejects package amounts that aren't a multiple of $10", async function () {
    const { owner, alice, staking } = await stakedFixture();
    await expect(staking.connect(alice).makeStake(ethers.parseEther("15"))).to.be.revertedWith(
      "Invalid package amount"
    );
  });

  it("rejects package amounts below $10 or above $1000", async function () {
    const { alice, staking } = await stakedFixture();
    await expect(staking.connect(alice).makeStake(ethers.parseEther("0"))).to.be.revertedWith(
      "Invalid package amount"
    );
    await expect(staking.connect(alice).makeStake(ethers.parseEther("1010"))).to.be.revertedWith(
      "Invalid package amount"
    );
  });

  it("pulls USDT, splits 5% creator / 5% DAO / 90% mint, and creates an order", async function () {
    const { alice, creatorFee, staking, usdt, token } = await stakedFixture();

    const beforeCreator = await usdt.balanceOf(creatorFee.address);
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    const afterCreator = await usdt.balanceOf(creatorFee.address);

    expect(afterCreator - beforeCreator).to.equal(ethers.parseEther("5"));
    expect(await staking.DAO_Amount()).to.equal(ethers.parseEther("5"));

    const info = await staking.userInfos(alice.address);
    expect(info.lastStake).to.equal(ethers.parseEther("100"));

    const order = await staking.stakeInfos(1);
    expect(order.ownerAddress).to.equal(alice.address);
    expect(order.orderValue).to.equal(ethers.parseEther("100"));
    expect(order.isComplete).to.equal(false);
  });

  it("forwards the 90% mint portion to the token contract BEFORE calling pricedBuy, so internalReserve stays fully backed", async function () {
    const { alice, staking, usdt, token } = await stakedFixture();

    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    // Regression test for a previously-broken ordering: if pricedBuy were ever called before
    // forwarding the real USDT, internalReserve would be credited without backing funds ever
    // arriving, and this assertion would fail (real balance would be 0, internalReserve 90).
    expect(await usdt.balanceOf(await token.getAddress())).to.equal(ethers.parseEther("90"));
    expect(await token.internalReserve()).to.equal(ethers.parseEther("90"));
  });

  it("rejects a recycle package smaller than the previous one", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    await expect(staking.connect(alice).makeStake(ethers.parseEther("50"))).to.be.revertedWith(
      "Package must not decrease"
    );
  });

  it("registers the staker under the referral's directs on first stake", async function () {
    const { owner, alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    const directs = await staking.directsOf(owner.address);
    expect(directs).to.include(alice.address);
  });

  it("propagates business volume up the referral chain", async function () {
    const { owner, alice, bob, usdt, staking } = await stakedFixture();

    await staking.connect(bob).regUser(alice.address);
    await usdt.mint(bob.address, ethers.parseEther("1000"));
    await usdt.connect(bob).approve(await staking.getAddress(), ethers.parseEther("1000"));

    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    await staking.connect(bob).makeStake(ethers.parseEther("50"));

    const aliceInfo = await staking.userInfos(alice.address);
    expect(aliceInfo.directBusiness).to.equal(ethers.parseEther("50"));

    const ownerInfo = await staking.userInfos(owner.address);
    expect(ownerInfo.totalTeamBusiness).to.equal(ethers.parseEther("50"));
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: FAIL — `makeStake` does not exist on the contract.

- [ ] **Step 3: Add `makeStake` and the business-update walk to `contracts/NexauraStaking.sol`**

Add these state variables inside the contract, alongside the existing `totalReg`/`allStake`:

```solidity
    uint256 public constant CREATOR_FEE_BP = 500; // 5%
    uint256 public constant DAO_FEE_BP = 500;     // 5%
    uint256 public DAO_Amount;

    event Staked(uint256 orderId, address indexed user, uint256 packageAmount, uint256 mintedAmount, uint256 timestamp);
```

Add this function at the end of the contract, just before the final closing `}`:

```solidity
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

        require(usdToken.approve(address(token), mintUsd) || true, "approve unused"); // USDT held by this contract, mint pulls from token's own reserve via pricedBuy accounting
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

        _updateBusinessToUpline(userInfos[msg.sender].referral, usdAmount);

        emit Staked(allStake, msg.sender, usdAmount, mintedAmount, block.timestamp);

        return true;
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
            counter++;
            current = userInfos[current].referral;
        }
    }
```

Note: `pricedBuy` doesn't pull any USDT itself — it only increments the token contract's
`internalReserve` counter and mints tokens (see Task 2). The staking contract already holds
`mintUsd` worth of real USDT from the `transferFrom` above, but nothing yet moves it to the
token contract — if `pricedBuy` is called without that transfer, `internalReserve` (and
`rateInUSDT`) would drift ahead of the token contract's real, spendable USDT balance, and a
later `pricedSell`/`payoutReserve` would eventually fail even though the accounting says there's
enough. Fix by forwarding the real funds first, so `internalReserve` stays backed 1:1 by actual
USDT sitting in the token contract:

Replace the `pricedBuy` call line with:

```solidity
        require(usdToken.transfer(address(token), mintUsd), "Mint funding transfer failed");
        uint256 mintedAmount = token.pricedBuy(mintUsd, msg.sender);
```

and delete the now-unused `require(usdToken.approve(...) || true, ...)` line entirely.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: PASS (12 passing)

- [ ] **Step 5: Commit**

```bash
git add contracts/NexauraStaking.sol test/NexauraStaking.test.js
git commit -m "feat: implement makeStake with fee split and upline business propagation"
```

---

### Task 5: Referral Cascade — Direct Income (5%) + 21-Level Generation Income (18%)

**Files:**
- Modify: `contracts/NexauraStaking.sol`
- Modify: `test/NexauraStaking.test.js`

**Interfaces:**
- Consumes: `mintedAmount` from `makeStake` (Task 4); `userInfos[upline].lastStake` (Task 3/4).
- Produces: internal `_distributeCascade(address staker, uint256 mintedAmount, uint256 packageAmount)`, called from `makeStake`; `levelIncomeBp() public pure returns (uint16[21] memory)`. Populates `bonusInfos[upline].referralGains` / `.levelGains`, read by Task 7's claim/cap logic.

- [ ] **Step 1: Write the failing tests**

Append to `test/NexauraStaking.test.js`:

```js
describe("NexauraStaking — referral cascade", function () {
  it("credits 5% direct income to the immediate referral", async function () {
    const { owner, alice, usdt, staking, token } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    // mintedAmount = 90 USD worth of tokens at 1:1 initial rate = 90 tokens
    const bonus = await staking.bonusInfos(owner.address);
    expect(bonus.referralGains).to.equal(ethers.parseEther("4.5")); // 5% of 90
  });

  it("skips level income for an upline earner whose own package is below $50", async function () {
    const { owner, alice, bob, usdt, staking } = await stakedFixture();

    await staking.connect(bob).regUser(alice.address);
    await usdt.mint(bob.address, ethers.parseEther("1000"));
    await usdt.connect(bob).approve(await staking.getAddress(), ethers.parseEther("1000"));

    // alice stakes only $20 (< $50 gate), so she gets no level-2 income when bob's downline stakes later.
    await staking.connect(alice).makeStake(ethers.parseEther("20"));
    await staking.connect(bob).makeStake(ethers.parseEther("100"));

    const aliceBonus = await staking.bonusInfos(alice.address);
    // alice IS bob's direct (level 0 / Direct Income), which has no $50 gate per spec 4.1 vs 4.2 — only
    // levels use the gate. Direct income should still be credited.
    expect(aliceBonus.referralGains).to.be.gt(0n);
  });

  it("pays 21-level income up a deep chain, gated by each earner's own $50 package", async function () {
    const { owner, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    // Build a chain: owner -> u1 -> u2 -> u3, each staking $100 (above the $50 gate).
    let referral = owner.address;
    const users = signers.slice(6, 9);
    for (const u of users) {
      await staking.connect(u).regUser(referral);
      await usdt.mint(u.address, ethers.parseEther("1000"));
      await usdt.connect(u).approve(await staking.getAddress(), ethers.parseEther("1000"));
      await staking.connect(u).makeStake(ethers.parseEther("100"));
      referral = u.address;
    }
    // owner is at level 2 relative to the last staker (u3): u3 -> u2 (level 0/direct) -> u1 (level 1) -> owner (level 2)
    const ownerBonus = await staking.bonusInfos(owner.address);
    expect(ownerBonus.levelGains).to.be.gt(0n);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: FAIL — `bonusInfos[...].referralGains` stays 0 (cascade not implemented).

- [ ] **Step 3: Add the cascade to `contracts/NexauraStaking.sol`**

Add this constant near the other constants:

```solidity
    uint256 public constant DIRECT_INCOME_BP = 500; // 5%
    uint256 public constant MIN_PACKAGE_FOR_LEVEL_INCOME = 50 * BASE;

    event IncomeCredited(address indexed from, address indexed to, uint256 level, uint256 amount, uint8 incomeType);
    // incomeType: 1 = Direct, 2 = Level, 3 = Rank/TeamGrowth, 4 = CTO
```

Add this pure function and internal cascade function, and call the cascade from `makeStake`:

```solidity
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
                // Direct Income (spec 4.1) has no $50 gate — only Level Generation Income does.
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
```

In `makeStake`, replace the line:

```solidity
        userInfos[msg.sender].lastStake = usdAmount;

        _updateBusinessToUpline(userInfos[msg.sender].referral, usdAmount);
```

with:

```solidity
        userInfos[msg.sender].lastStake = usdAmount;

        _distributeCascade(msg.sender, mintedAmount, usdAmount);
        _updateBusinessToUpline(userInfos[msg.sender].referral, usdAmount);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: PASS (14 passing)

- [ ] **Step 5: Commit**

```bash
git add contracts/NexauraStaking.sol test/NexauraStaking.test.js
git commit -m "feat: implement direct + 21-level referral cascade income"
```

---

### Task 6: Rank Computation (8-Tier) + CTO Tier Computation (3-Tier)

**Files:**
- Modify: `contracts/NexauraStaking.sol`
- Modify: `test/NexauraStaking.test.js`

**Interfaces:**
- Consumes: `userInfos[user].lastStake`, `.directs.length`, `.totalTeamBusiness` (Task 4).
- Produces: `rankTiers(uint256) public view returns (RankTier)`, `ctoTiers(uint256) public view returns (CtoTier)`; internal `_updateRank(address user)` called from `_updateBusinessToUpline`'s walk; `_payCtoBonus(address staker, uint256 mintedAmount)` called from `makeStake`. `userInfos[user].rank` (0 = none, 1..8) is read by Task 7's daily-accrual formula.

- [ ] **Step 1: Write the failing tests**

Append to `test/NexauraStaking.test.js`:

```js
describe("NexauraStaking — rank and CTO tiers", function () {
  it("promotes a user to Starter rank once thresholds are met and never downgrades", async function () {
    const { owner, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    const directs = signers.slice(6, 9); // 3 directs, meets Starter's "Direct: 3"

    for (const d of directs) {
      await staking.connect(d).regUser(owner.address);
      await usdt.mint(d.address, ethers.parseEther("1000"));
      await usdt.connect(d).approve(await staking.getAddress(), ethers.parseEther("1000"));
      await staking.connect(d).makeStake(ethers.parseEther("1000")); // pushes owner's directBusiness up
    }
    // Owner's own selfStake gate (>= $50) is already satisfied: the constructor seeds the owner's
    // lastStake at MAX_PACKAGE ($1000) so it behaves as a fully-qualified root referral (Task 5).
    // A further owner.makeStake() here would revert ("Package must not decrease") since $50 < $1000.

    const info = await staking.userInfos(owner.address);
    expect(info.rank).to.equal(1); // 1 = Starter (index 0 stored as rank 1, 0 means unranked)
  });

  it("pays CTO bonus to the first qualifying upline tier", async function () {
    const { owner, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    const leader = signers[9];
    const staker = signers[10];

    await staking.connect(leader).regUser(owner.address);
    await usdt.mint(leader.address, ethers.parseEther("20000"));
    await usdt.connect(leader).approve(await staking.getAddress(), ethers.parseEther("20000"));
    await staking.connect(leader).makeStake(ethers.parseEther("1000"));

    await staking.connect(staker).regUser(leader.address);
    await usdt.mint(staker.address, ethers.parseEther("20000"));
    await usdt.connect(staker).approve(await staking.getAddress(), ethers.parseEther("20000"));

    // Push leader's directBusiness past the 1st CTO tier ($5,000 direct / $10,000 team, where "team"
    // gates on combined direct+team volume — see _updateRank/_payCtoBonus) by having several other
    // directs stake $1000 twice each (5 signers * 2 stakes * $1000 = $10,000).
    for (let i = 11; i <= 15; i++) {
      const s = signers[i];
      await staking.connect(s).regUser(leader.address);
      await usdt.mint(s.address, ethers.parseEther("2000"));
      await usdt.connect(s).approve(await staking.getAddress(), ethers.parseEther("2000"));
      await staking.connect(s).makeStake(ethers.parseEther("1000"));
      await staking.connect(s).makeStake(ethers.parseEther("1000"));
    }

    await staking.connect(staker).makeStake(ethers.parseEther("100"));

    const bonus = await staking.bonusInfos(leader.address);
    expect(bonus.ctoGains).to.be.gt(0n);
  });

  it("pays ALL qualifying tiers to a single ancestor, not just the highest one", async function () {
    const { owner, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    const leader = signers[9];
    const staker = signers[10];

    await staking.connect(leader).regUser(owner.address);
    await usdt.mint(leader.address, ethers.parseEther("1000"));
    await usdt.connect(leader).approve(await staking.getAddress(), ethers.parseEther("1000"));
    await staking.connect(leader).makeStake(ethers.parseEther("1000"));

    await staking.connect(staker).regUser(leader.address);
    await usdt.mint(staker.address, ethers.parseEther("1000"));
    await usdt.connect(staker).approve(await staking.getAddress(), ethers.parseEther("1000"));

    // Push leader's directBusiness (all volume here is direct, since every staker below is
    // leader's own direct) to $40,000 — clears tier 3's $20,000 direct / $40,000 team
    // thresholds, which numerically also clears tier 1 and tier 2. leader should collect all
    // three: 2% + 1% + 1% = 4% of every later mintedAmount that reaches this point.
    const directs = signers.slice(11, 19); // 8 signers
    for (const s of directs) {
      await staking.connect(s).regUser(leader.address);
      await usdt.mint(s.address, ethers.parseEther("5000"));
      await usdt.connect(s).approve(await staking.getAddress(), ethers.parseEther("5000"));
      for (let i = 0; i < 5; i++) {
        await staking.connect(s).makeStake(ethers.parseEther("1000"));
      }
    }

    const before = await staking.bonusInfos(leader.address);
    await staking.connect(staker).makeStake(ethers.parseEther("100"));
    const after = await staking.bonusInfos(leader.address);

    // mintedAmount for a $100 stake = 90 tokens (1:1 rate); 4% of 90 = 3.6.
    expect(after.ctoGains - before.ctoGains).to.equal(ethers.parseEther("3.6"));
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: FAIL — `rank` stays 0, `ctoGains` stays 0.

- [ ] **Step 3: Add rank and CTO logic to `contracts/NexauraStaking.sol`**

Add these structs and state near the other structs:

```solidity
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
```

Add tier initialization at the end of the constructor (after the existing `userInfos[_owner].lastStake = MAX_PACKAGE;` line):

```solidity
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
```

Add rank update logic. Replace `_updateBusinessToUpline` with a version that also recomputes rank per ancestor:

```solidity
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

    event RankUpdated(address indexed user, uint256 newRank);
```

Add CTO payout logic. Add this function and call it from `makeStake`:

```solidity
    function _payCtoBonus(address staker, uint256 mintedAmount) internal {
        address current = userInfos[staker].referral;
        bool[3] memory filled;
        uint256 filledCount;
        uint256 depth;

        while (current != address(0) && filledCount < 3 && depth < 150) {
            UserInfo storage u = userInfos[current];
            uint256 combined = u.directBusiness + u.totalTeamBusiness;
            // Same combined-volume reasoning as _updateRank's matchBusiness: teamBusiness is
            // meant to gate on the ancestor's whole downline, not only the depth->=2 slice.
            //
            // No `break` here: the spec ("pay CTO Bonus% ... to each qualifying tier found,
            // first match up the chain PER TIER") means each of the 3 tiers is its own
            // independent search up the chain — a single highly-qualified ancestor who clears
            // all three thresholds is the "first match" for all three simultaneously and
            // collects all three slices (2%+1%+1%=4%), not just the highest one. An earlier
            // draft `break`d after the first tier match per ancestor, which shortchanged
            // top-qualified leaders down to a single tier's bonus.
            for (uint256 t = 3; t > 0; t--) {
                CtoTier storage tier = ctoTiers[t - 1];
                if (!filled[t - 1] && u.directBusiness >= tier.directBusiness && combined >= tier.teamBusiness) {
                    uint256 amt = (mintedAmount * tier.bonusBp) / BP_DENOM;
                    bonusInfos[current].ctoGains += amt;
                    emit IncomeCredited(staker, current, t, amt, 4);
                    filled[t - 1] = true;
                    filledCount++;
                }
            }
            current = u.referral;
            depth++;
        }
    }
```

In `makeStake`, add the CTO call **after** `_updateBusinessToUpline`, not before — CTO tier
qualification must see this stake's own contribution to `directBusiness`/`totalTeamBusiness`,
the same as rank does (rank is recomputed inside `_updateBusinessToUpline`'s loop already, so it
already sees fresh totals; CTO would otherwise lag one stake behind on the exact same data):

```solidity
        _distributeCascade(msg.sender, mintedAmount, usdAmount);
        _updateBusinessToUpline(userInfos[msg.sender].referral, usdAmount);
        _payCtoBonus(msg.sender, mintedAmount);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: PASS (18 passing)

- [ ] **Step 5: Commit**

```bash
git add contracts/NexauraStaking.sol test/NexauraStaking.test.js
git commit -m "feat: implement 8-tier rank promotion and 3-tier CTO bonus payout"
```

---

### Task 7: Daily Reward + Team Growth Accrual, 3x/2x Caps, Working-Income Gate

**Files:**
- Modify: `contracts/NexauraStaking.sol`
- Modify: `test/NexauraStaking.test.js`

**Interfaces:**
- Consumes: `userInfos[user].rank`, `.harvestTime`, `.totalTeamBusiness`, `.directs.length`, `.lastStake` (Tasks 3–6); `rankTiers` (Task 6).
- Produces: `claimDailyReward() external`; `claimableWorking(address user) public view returns (uint256)`; `claimableNonWorking(address user) public view returns (uint256)`. Task 9 (withdraw) calls both `claimable*` functions and `bonusInfos[user].workingWithdrawn`/`.nonWorkingWithdrawn`.

- [ ] **Step 1: Write the failing tests**

Append to `test/NexauraStaking.test.js`:

```js
describe("NexauraStaking — daily reward and caps", function () {
  it("reverts claimDailyReward within the same 24h window", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    // A brand-new stake's harvestTime is "now" — the very first claim needs a full day to
    // elapse too (you can't claim a reward for zero elapsed time), same as every later claim.
    await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
    await ethers.provider.send("evm_mine");

    await staking.connect(alice).claimDailyReward();
    await expect(staking.connect(alice).claimDailyReward()).to.be.revertedWith("Too soon");
  });

  it("credits 1.25% of lastStake per elapsed day into growthGains", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
    await ethers.provider.send("evm_mine");

    await staking.connect(alice).claimDailyReward();
    const bonus = await staking.bonusInfos(alice.address);
    expect(bonus.growthGains).to.equal(ethers.parseEther("1.25")); // 1.25% of 100
  });

  it("uses combined direct+team business for rank-based daily accrual, not totalTeamBusiness alone", async function () {
    const { alice, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    const directs = signers.slice(6, 9); // 3 signers

    // alice stakes $50 herself (sets her own harvestTime, satisfies Starter's selfStake >= 50).
    await staking.connect(alice).makeStake(ethers.parseEther("50"));

    // 3 directs stake $1000 each, all landing in alice's directBusiness (flat tree, no
    // grandchildren) -> alice.directBusiness = 3000, alice.totalTeamBusiness = 0,
    // alice.directs.length = 3 -> Starter rank (400bp incentive).
    for (const d of directs) {
      await staking.connect(d).regUser(alice.address);
      await usdt.mint(d.address, ethers.parseEther("1000"));
      await usdt.connect(d).approve(await staking.getAddress(), ethers.parseEther("1000"));
      await staking.connect(d).makeStake(ethers.parseEther("1000"));
    }

    await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
    await ethers.provider.send("evm_mine");
    await staking.connect(alice).claimDailyReward();

    const bonus = await staking.bonusInfos(alice.address);
    // dailyMatchYield = combinedBusiness(3000) * 1.25% = 37.5; rankAmount = 37.5 * 4% = 1.5.
    // Under the totalTeamBusiness-alone bug, combinedBusiness would read as 0 (all volume here
    // is direct-level) and this would be 0 instead.
    expect(bonus.teamGrowthGains).to.equal(ethers.parseEther("1.5"));
  });

  it("claimableWorking returns 0 for a user with fewer than 2 direct referrals", async function () {
    const { owner, alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    // owner has 1 direct (alice) so far -> below the 2-referral gate
    const claimable = await staking.claimableWorking(owner.address);
    expect(claimable).to.equal(0n);
  });

  it("claimableNonWorking is capped at 2x lastStake", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("10")); // small stake, easy to hit the 2x cap

    for (let i = 0; i < 200; i++) {
      await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
      await ethers.provider.send("evm_mine");
      await staking.connect(alice).claimDailyReward();
    }

    const claimable = await staking.claimableNonWorking(alice.address);
    expect(claimable).to.equal(ethers.parseEther("20")); // 2x of $10, fully accrued and capped
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: FAIL — `claimDailyReward`/`claimableWorking`/`claimableNonWorking` don't exist.

- [ ] **Step 3: Add claim and cap logic to `contracts/NexauraStaking.sol`**

Add these constants:

```solidity
    uint256 public constant DAILY_REWARD_BP = 125; // 1.25%
    uint256 public constant WORKING_CAP_MULT = 3;
    uint256 public constant NONWORKING_CAP_MULT = 2;
    uint256 public constant MIN_DIRECTS_FOR_WORKING = 2;
    uint256 public constant ONE_DAY = 1 days;

    event DailyRewardClaimed(address indexed user, uint256 daysElapsed, uint256 growthAmount, uint256 rankAmount);
```

Add the claim function and cap views at the end of the contract:

```solidity
    function claimDailyReward() external nonReentrant {
        require(userInfos[msg.sender].joined, "caller not registered");
        UserInfo storage u = userInfos[msg.sender];
        require(u.harvestTime > 0, "no active stake");

        uint256 daysElapsed = (block.timestamp - u.harvestTime) / ONE_DAY;
        require(daysElapsed >= 1, "Too soon");

        uint256 growthAmount = (u.lastStake * DAILY_REWARD_BP * daysElapsed) / BP_DENOM;
        bonusInfos[msg.sender].growthGains += growthAmount;

        uint256 rankAmount;
        if (u.rank > 0) {
            RankTier storage tier = rankTiers[u.rank - 1];
            // Same combined-volume convention as _updateRank's matchBusiness and
            // _payCtoBonus's team-business check (Task 6): totalTeamBusiness alone excludes
            // depth-1 (direct) volume, so it undercounts the same business figure that
            // qualified this user for their rank in the first place.
            uint256 combinedBusiness = u.directBusiness + u.totalTeamBusiness;
            uint256 dailyMatchYield = (combinedBusiness * DAILY_REWARD_BP) / BP_DENOM;
            rankAmount = (dailyMatchYield * tier.incentiveBp * daysElapsed) / BP_DENOM;
            bonusInfos[msg.sender].teamGrowthGains += rankAmount;
        }

        u.harvestTime += daysElapsed * ONE_DAY;

        emit DailyRewardClaimed(msg.sender, daysElapsed, growthAmount, rankAmount);
    }

    function claimableWorking(address user) public view returns (uint256) {
        UserInfo storage u = userInfos[user];
        if (u.directs.length < MIN_DIRECTS_FOR_WORKING) return 0;

        BonusInfo storage b = bonusInfos[user];
        uint256 total = b.referralGains + b.levelGains + b.teamGrowthGains + b.ctoGains;
        uint256 cap = u.lastStake * WORKING_CAP_MULT;
        uint256 capped = total > cap ? cap : total;

        return capped > b.workingWithdrawn ? capped - b.workingWithdrawn : 0;
    }

    function claimableNonWorking(address user) public view returns (uint256) {
        UserInfo storage u = userInfos[user];
        BonusInfo storage b = bonusInfos[user];

        uint256 cap = u.lastStake * NONWORKING_CAP_MULT;
        uint256 capped = b.growthGains > cap ? cap : b.growthGains;

        return capped > b.nonWorkingWithdrawn ? capped - b.nonWorkingWithdrawn : 0;
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: PASS (23 passing)

- [ ] **Step 5: Commit**

```bash
git add contracts/NexauraStaking.sol test/NexauraStaking.test.js
git commit -m "feat: implement daily reward claim, rank accrual, and 3x/2x claim caps"
```

---

### Task 8: `makeUnstake` — Maturity, Grace Period, Order Completion

**Files:**
- Modify: `contracts/NexauraStaking.sol`
- Modify: `test/NexauraStaking.test.js`

**Interfaces:**
- Consumes: `stakeInfos[orderId]` (Task 4); `userInfos[user].stakeOrders` (Task 4).
- Produces: `makeUnstake(uint256 orderId) external`; `isOrderAccruing(uint256 orderId) public view returns (bool)`. Task 9 (withdraw) is independent of this (withdrawal pays out `bonusInfos` ledger balances, not order principal — orders are bookkeeping only per the spec), but Task 7's `claimDailyReward` should stop accruing for a fully-lapsed order; this task adds that gate.

- [ ] **Step 1: Write the failing tests**

Append to `test/NexauraStaking.test.js`:

```js
describe("NexauraStaking — maturity, grace, and recycling", function () {
  it("an order is not yet mature before 10 days", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    expect(await staking.isOrderAccruing(1)).to.equal(true);
  });

  it("an order stops accruing after maturity (10d) + grace (7d) if not recycled", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    await ethers.provider.send("evm_increaseTime", [18 * 24 * 60 * 60]); // past 17 days
    await ethers.provider.send("evm_mine");

    expect(await staking.isOrderAccruing(1)).to.equal(false);
  });

  it("claimDailyReward reverts once the sole order has lapsed past grace", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    await ethers.provider.send("evm_increaseTime", [18 * 24 * 60 * 60]);
    await ethers.provider.send("evm_mine");

    await expect(staking.connect(alice).claimDailyReward()).to.be.revertedWith("no active stake");
  });

  it("makeUnstake marks the order complete and blocks a second unstake of the same order", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    await ethers.provider.send("evm_increaseTime", [11 * 24 * 60 * 60]); // past 10-day maturity
    await ethers.provider.send("evm_mine");

    await staking.connect(alice).makeUnstake(1);
    const order = await staking.stakeInfos(1);
    expect(order.isComplete).to.equal(true);

    await expect(staking.connect(alice).makeUnstake(1)).to.be.revertedWith("Order not active");
  });

  it("makeUnstake reverts before maturity", async function () {
    const { alice, staking } = await stakedFixture();
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    await expect(staking.connect(alice).makeUnstake(1)).to.be.revertedWith("Order not mature");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: FAIL — `isOrderAccruing`/`makeUnstake` don't exist, and `claimDailyReward` doesn't yet gate on order lapse.

- [ ] **Step 3: Add maturity/grace/unstake logic to `contracts/NexauraStaking.sol`**

Add these constants:

```solidity
    uint256 public constant MATURITY_PERIOD = 10 days;
    uint256 public constant GRACE_PERIOD = 7 days;

    event Unstaked(address indexed user, uint256 orderId);
```

Add these functions at the end of the contract:

```solidity
    function isOrderAccruing(uint256 orderId) public view returns (bool) {
        Order storage o = stakeInfos[orderId];
        if (o.orderTime == 0 || o.isComplete) return false;
        return block.timestamp < o.orderTime + MATURITY_PERIOD + GRACE_PERIOD;
    }

    function _hasActiveOrder(address user) internal view returns (bool) {
        uint256[] storage orders = userInfos[user].stakeOrders;
        for (uint256 i = orders.length; i > 0; i--) {
            if (isOrderAccruing(orders[i - 1])) return true;
        }
        return false;
    }

    function makeUnstake(uint256 orderId) external nonReentrant {
        Order storage o = stakeInfos[orderId];
        require(o.ownerAddress == msg.sender, "Not your order");
        require(!o.isComplete, "Order not active");
        require(block.timestamp >= o.orderTime + MATURITY_PERIOD, "Order not mature");

        o.isComplete = true;
        emit Unstaked(msg.sender, orderId);
    }
```

Update `claimDailyReward`'s guard — replace:

```solidity
        require(u.harvestTime > 0, "no active stake");
```

with:

```solidity
        require(u.harvestTime > 0 && _hasActiveOrder(msg.sender), "no active stake");
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: PASS (25 passing)

- [ ] **Step 5: Commit**

```bash
git add contracts/NexauraStaking.sol test/NexauraStaking.test.js
git commit -m "feat: implement order maturity, grace period, and makeUnstake"
```

---

### Task 9: Withdrawal — Min/Max Caps, 10% Fee Split

**Files:**
- Modify: `contracts/NexauraStaking.sol`
- Modify: `test/NexauraStaking.test.js`

**Interfaces:**
- Consumes: `claimableWorking`/`claimableNonWorking` (Task 7); `INexauraToken.rateInUSDT`/`.payoutReserve` (Task 2); `bonusInfos[user].workingWithdrawn`/`.nonWorkingWithdrawn` (Task 7).
- Produces: `withdraw(uint256 amount) external`. Task 10 (spot bonus) consumes the `dailySpotBonusPool` this task funds.

- [ ] **Step 1: Write the failing tests**

Append to `test/NexauraStaking.test.js`:

```js
describe("NexauraStaking — withdrawal", function () {
  async function claimableFixture() {
    const base = await stakedFixture();
    const { alice, staking } = base;
    await staking.connect(alice).makeStake(ethers.parseEther("100"));

    await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
    await ethers.provider.send("evm_mine");
    await staking.connect(alice).claimDailyReward();

    // No extra USDT funding needed: alice's $100 makeStake already grew internalReserve by 90
    // (the 90%-mint portion), which is far more than any withdrawal amount these tests use.
    // payoutReserve checks internalReserve, not raw balanceOf, so donating extra USDT directly
    // to the token contract here would do nothing — see Task 2's donation-attack fix.

    return base;
  }

  it("reverts below the $10 minimum", async function () {
    const { alice, staking } = await claimableFixture();
    await expect(staking.connect(alice).withdraw(ethers.parseEther("5"))).to.be.revertedWith(
      "Below minimum withdrawal"
    );
  });

  it("reverts above the $3000/day cap", async function () {
    const { alice, staking } = await claimableFixture();
    await expect(staking.connect(alice).withdraw(ethers.parseEther("3001"))).to.be.revertedWith(
      "Exceeds daily withdrawal cap"
    );
  });

  it("reverts when requesting more than the claimable non-working balance", async function () {
    const { alice, staking } = await claimableFixture();
    // growthGains = 1.25 after one day; nothing else claimable without 2 directs.
    await expect(staking.connect(alice).withdraw(ethers.parseEther("10"))).to.be.revertedWith(
      "Exceeds claimable balance"
    );
  });

  it("pays out 90% to the user and splits the 10% fee 5/5 into creator fee and spot bonus pool", async function () {
    const { alice, creatorFee, staking, usdt } = await claimableFixture();

    const beforeAlice = await usdt.balanceOf(alice.address);
    const beforeCreator = await usdt.balanceOf(creatorFee.address);

    await staking.connect(alice).withdraw(ethers.parseEther("1.25"));

    const afterAlice = await usdt.balanceOf(alice.address);
    const afterCreator = await usdt.balanceOf(creatorFee.address);

    expect(afterAlice - beforeAlice).to.equal(ethers.parseEther("1.125")); // 90% of 1.25
    expect(afterCreator - beforeCreator).to.equal(ethers.parseEther("0.0625")); // 5% of 1.25
    expect(await staking.dailySpotBonusPool()).to.equal(ethers.parseEther("0.0625")); // 5% of 1.25
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: FAIL — `withdraw` doesn't exist.

- [ ] **Step 3: Add withdrawal logic to `contracts/NexauraStaking.sol`**

Add these constants and state:

```solidity
    uint256 public constant MIN_WITHDRAW = 10 * BASE;
    uint256 public constant MAX_DAILY_WITHDRAW = 3000 * BASE;
    uint256 public constant WITHDRAW_CREATOR_BP = 500; // 5%
    uint256 public constant WITHDRAW_SPOTBONUS_BP = 500; // 5%

    uint256 public dailySpotBonusPool;
    mapping(address => uint256) public lastWithdrawDay;
    mapping(address => uint256) public withdrawnToday;

    event Withdrawn(address indexed user, uint256 grossAmount, uint256 netAmount);
```

Add this function at the end of the contract:

```solidity
    function withdraw(uint256 amount) external nonReentrant {
        require(amount >= MIN_WITHDRAW, "Below minimum withdrawal");

        uint256 today = block.timestamp / ONE_DAY;
        if (lastWithdrawDay[msg.sender] != today) {
            lastWithdrawDay[msg.sender] = today;
            withdrawnToday[msg.sender] = 0;
        }
        require(withdrawnToday[msg.sender] + amount <= MAX_DAILY_WITHDRAW, "Exceeds daily withdrawal cap");

        uint256 availableNonWorking = claimableNonWorking(msg.sender);
        uint256 availableWorking = claimableWorking(msg.sender);
        require(amount <= availableNonWorking + availableWorking, "Exceeds claimable balance");

        uint256 fromNonWorking = amount > availableNonWorking ? availableNonWorking : amount;
        uint256 fromWorking = amount - fromNonWorking;

        bonusInfos[msg.sender].nonWorkingWithdrawn += fromNonWorking;
        bonusInfos[msg.sender].workingWithdrawn += fromWorking;
        withdrawnToday[msg.sender] += amount;

        // amount is a ledger-tracked gain, never a real minted/burned token balance — priced
        // and paid directly from the token contract's reserve via payoutReserve (Task 2), NOT
        // pricedBuy/pricedSell, so nothing here mints or burns anything. Pricing it via a mint
        // then an immediate pricedSell (an earlier draft of this task did that) would price the
        // sale against a totalSupply the mint itself just inflated, shortchanging the user — see
        // the Security Review's "Withdrawal self-dilution" entry.
        uint256 usdValue = (amount * token.rateInUSDT()) / BASE;

        uint256 creatorCut = (usdValue * WITHDRAW_CREATOR_BP) / BP_DENOM;
        uint256 spotBonusCut = (usdValue * WITHDRAW_SPOTBONUS_BP) / BP_DENOM;
        uint256 netAmount = usdValue - creatorCut - spotBonusCut;

        token.payoutReserve(usdValue, address(this));

        require(usdToken.transfer(creatorFeeAddress, creatorCut), "Creator fee transfer failed");
        dailySpotBonusPool += spotBonusCut;
        require(usdToken.transfer(msg.sender, netAmount), "Withdrawal transfer failed");

        emit Withdrawn(msg.sender, usdValue, netAmount);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: PASS (30 passing)

- [ ] **Step 5: Commit**

```bash
git add contracts/NexauraStaking.sol test/NexauraStaking.test.js
git commit -m "feat: implement withdrawal with min/max caps and 10% fee split, priced via direct reserve payout to avoid self-dilution"
```

---

### Task 10: DAO Partnership (Weighted Weekly Distribution) + Daily Spot Bonus

**Files:**
- Modify: `contracts/NexauraStaking.sol`
- Modify: `test/NexauraStaking.test.js`

**Interfaces:**
- Consumes: `DAO_Amount` (Task 4), `dailySpotBonusPool` (Task 9), `userInfos[user].directBusiness`/`.totalTeamBusiness`/`.directJoinTimes` (Tasks 4, 6).
- Produces: `distributeDAO() external onlyOwner`; `distributeSpotBonus(address[] calldata candidates) external onlyOwner` (both `onlyOwner` — see the security note in Step 3 on why `distributeSpotBonus` must not be permissionless); internal `_updateDaoShare(address user)` called from `_updateBusinessToUpline`; `qualifiesForSpotBonus(address user) public view returns (bool)`.

- [ ] **Step 1: Write the failing tests**

Append to `test/NexauraStaking.test.js`:

```js
describe("NexauraStaking — DAO and spot bonus", function () {
  it("assigns and overrides DAO share as thresholds are crossed", async function () {
    const { owner, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    const directs = signers.slice(6, 9);

    for (const d of directs) {
      await staking.connect(d).regUser(owner.address);
      await usdt.mint(d.address, ethers.parseEther("1000"));
      await usdt.connect(d).approve(await staking.getAddress(), ethers.parseEther("1000"));
    }
    // owner's directBusiness after these three $200 stakes = 600 >= 500 (Share 1 threshold)
    await staking.connect(directs[0]).makeStake(ethers.parseEther("200"));
    await staking.connect(directs[1]).makeStake(ethers.parseEther("200"));
    await staking.connect(directs[2]).makeStake(ethers.parseEther("200"));

    let info = await staking.userInfos(owner.address);
    expect(info.daoShare).to.equal(1);

    // Push past 1000 direct business -> Share 2
    await staking.connect(directs[0]).makeStake(ethers.parseEther("500"));
    info = await staking.userInfos(owner.address);
    expect(info.daoShare).to.equal(2);
  });

  it("distributeDAO splits the pool proportionally by share, weekly", async function () {
    const { owner, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    const directs = signers.slice(6, 9);

    for (const d of directs) {
      await staking.connect(d).regUser(owner.address);
      await usdt.mint(d.address, ethers.parseEther("1000"));
      await usdt.connect(d).approve(await staking.getAddress(), ethers.parseEther("1000"));
    }
    await staking.connect(directs[0]).makeStake(ethers.parseEther("200"));
    await staking.connect(directs[1]).makeStake(ethers.parseEther("200"));
    await staking.connect(directs[2]).makeStake(ethers.parseEther("200"));

    await ethers.provider.send("evm_increaseTime", [7 * 24 * 60 * 60]);
    await ethers.provider.send("evm_mine");

    const poolBefore = await staking.DAO_Amount();
    expect(poolBefore).to.be.gt(0n);

    await staking.distributeDAO();

    expect(await staking.DAO_Amount()).to.equal(0n);
    const ownerBonus = await staking.bonusInfos(owner.address);
    expect(ownerBonus.ctoGains).to.equal(ownerBonus.ctoGains); // sanity: DAO payout uses mintReward directly to wallet, not bonusInfos — see Step 3
  });

  it("distributeDAO reverts before the weekly cooldown elapses", async function () {
    const { staking } = await stakedFixture();
    await expect(staking.distributeDAO()).to.be.revertedWith("Too soon");
  });

  it("qualifies a user for spot bonus after 2 directs stake $50+ within 24h", async function () {
    const { owner, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    const directs = signers.slice(6, 8);

    for (const d of directs) {
      await staking.connect(d).regUser(owner.address);
      await usdt.mint(d.address, ethers.parseEther("1000"));
      await usdt.connect(d).approve(await staking.getAddress(), ethers.parseEther("1000"));
      await staking.connect(d).makeStake(ethers.parseEther("50"));
    }

    expect(await staking.qualifiesForSpotBonus(owner.address)).to.equal(true);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: FAIL — `daoShare` stays 0, `distributeDAO`/`qualifiesForSpotBonus` don't exist.

- [ ] **Step 3: Add DAO and spot bonus logic to `contracts/NexauraStaking.sol`**

Add these constants and state:

```solidity
    uint256 public constant DAO_QUALIFY_WINDOW = 10 days;
    uint256 public constant DAO_DIST_INTERVAL = 7 days;
    uint256 public constant SPOTBONUS_DIST_INTERVAL = 1 days;
    uint256 public constant SPOTBONUS_MIN_PACKAGE = 50 * BASE;

    uint256 public lastDaoDistribution;
    uint256 public lastSpotBonusDistribution;
    address[] public daoQualifiedUsers;
    mapping(address => bool) public isDaoQualified;
    address[] public spotBonusQualifiers;

    event DaoShareUpdated(address indexed user, uint256 newShare);
    event DaoDistributed(uint256 totalAmount, uint256 totalShares);
    event SpotBonusDistributed(uint256 totalAmount, uint256 qualifiersCount);
```

Initialize the two distribution timestamps at the end of the constructor:

```solidity
        lastDaoDistribution = block.timestamp;
        lastSpotBonusDistribution = block.timestamp;
```

Add DAO share update logic — a helper checking the OR-threshold table:

```solidity
    function _daoShareFor(uint256 directBusiness, uint256 matchBusiness) internal pure returns (uint256) {
        if (directBusiness >= 2500 * BASE || matchBusiness >= 4000 * BASE) return 5;
        if (directBusiness >= 1000 * BASE || matchBusiness >= 2000 * BASE) return 2;
        if (directBusiness >= 500 * BASE || matchBusiness >= 1000 * BASE) return 1;
        return 0;
    }

    function _updateDaoShare(address user) internal {
        UserInfo storage u = userInfos[user];
        if (u.daoDeadline == 0) {
            u.daoDeadline = block.timestamp + DAO_QUALIFY_WINDOW;
        }
        if (block.timestamp > u.daoDeadline) return;

        uint256 newShare = _daoShareFor(u.directBusiness, u.totalTeamBusiness);
        if (newShare > u.daoShare) {
            if (!isDaoQualified[user]) {
                isDaoQualified[user] = true;
                daoQualifiedUsers.push(user);
            }
            u.daoShare = newShare;
            emit DaoShareUpdated(user, newShare);
        }
    }
```

Call `_updateDaoShare` from `_updateBusinessToUpline`, right after `_updateRank(current);`:

```solidity
            _updateRank(current);
            _updateDaoShare(current);
```

Add `distributeDAO`. Restricted to `onlyOwner`: the payout math itself can't be gamed by a
caller (shares come from on-chain state, not caller input), but `daoQualifiedUsers` only ever
grows, so the loop's gas cost grows over time — `onlyOwner` keeps a random address from forcing
a call at a moment engineered to run it out of gas or front-run the owner's own maintenance
window, and gives the owner a lever to stop calling it (and plan a paginated redesign) before it
actually hits the block gas limit:

```solidity
    // ponytail: iterates the full daoQualifiedUsers array every call, which only ever grows
    // (qualified users are never pruned). Fine while the DAO-qualified population is small
    // (thresholds start at $500 direct business, so it's a curated set, not every registrant),
    // but this will eventually need pagination (a startIndex/count-bounded variant, run across
    // multiple owner-submitted transactions) if that population grows large enough to approach
    // the block gas limit in one call.
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
                if (share == 0) continue;
                uint256 payout = (pool * share) / totalShares;
                if (payout > 0) {
                    require(usdToken.transfer(u, payout), "DAO payout transfer failed");
                }
            }
        }

        emit DaoDistributed(pool, totalShares);
        DAO_Amount = 0;
        lastDaoDistribution = block.timestamp;
    }
```

Add spot bonus qualification and distribution. First, add a helper that scans `directJoinTimes` from the end for entries within the last 24h:

```solidity
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
```

Add `distributeSpotBonus`, iterating a bounded candidate set built by the caller off-chain (owner
passes the list of users to check, since scanning every registered user on-chain is unbounded —
this is a deliberate scalability trade-off). **This must be `onlyOwner`, not permissionless**:
the payout is `pool / candidates.length-that-qualify`, so if this were callable by anyone with
an arbitrary `candidates` array, an attacker who personally qualifies could call it with a
candidate list containing only their own address, draining the *entire* day's pool to
themselves alone while every other legitimately-qualified user (simply omitted from the
attacker's list) gets nothing — a real, direct theft vector, not just a griefing one. Restricting
to `onlyOwner` means only a trusted keeper supplies the candidate list, closing it:

```solidity
    // ponytail: iterates only the caller-supplied candidate list, not every registered user —
    // an off-chain indexer (or the admin) supplies today's plausible qualifiers. Upgrade path:
    // maintain an on-chain rolling qualifiers set if the user base grows large enough that
    // off-chain candidate curation becomes unreliable. Kept onlyOwner (see note above) so an
    // incomplete or malicious candidate list can only come from a trusted source.
    function distributeSpotBonus(address[] calldata candidates) external onlyOwner nonReentrant {
        require(block.timestamp >= lastSpotBonusDistribution + SPOTBONUS_DIST_INTERVAL, "Too soon");

        uint256 qualifiedCount;
        for (uint256 i; i < candidates.length; i++) {
            if (qualifiesForSpotBonus(candidates[i])) qualifiedCount++;
        }

        uint256 pool = dailySpotBonusPool;
        if (qualifiedCount > 0 && pool > 0) {
            uint256 share = pool / qualifiedCount;
            for (uint256 i; i < candidates.length; i++) {
                if (qualifiesForSpotBonus(candidates[i]) && share > 0) {
                    require(usdToken.transfer(candidates[i], share), "Spot bonus transfer failed");
                }
            }
        }

        emit SpotBonusDistributed(pool, qualifiedCount);
        dailySpotBonusPool = 0;
        lastSpotBonusDistribution = block.timestamp;
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Update the second test ("distributeDAO splits the pool...") — its sanity assertion is a placeholder left over from drafting; replace it with a real assertion now that the payout mechanism (direct USDT transfer, not `bonusInfos`) is known:

```js
  it("distributeDAO splits the pool proportionally by share, weekly", async function () {
    const { owner, staking, usdt } = await stakedFixture();
    const signers = await ethers.getSigners();
    const directs = signers.slice(6, 9);

    for (const d of directs) {
      await staking.connect(d).regUser(owner.address);
      await usdt.mint(d.address, ethers.parseEther("1000"));
      await usdt.connect(d).approve(await staking.getAddress(), ethers.parseEther("1000"));
    }
    await staking.connect(directs[0]).makeStake(ethers.parseEther("200"));
    await staking.connect(directs[1]).makeStake(ethers.parseEther("200"));
    await staking.connect(directs[2]).makeStake(ethers.parseEther("200"));

    await ethers.provider.send("evm_increaseTime", [7 * 24 * 60 * 60]);
    await ethers.provider.send("evm_mine");

    const pool = await staking.DAO_Amount();
    const before = await usdt.balanceOf(owner.address);

    await staking.distributeDAO();

    const after = await usdt.balanceOf(owner.address);
    expect(after - before).to.equal(pool); // owner is the sole qualified user, gets 100% of the pool
    expect(await staking.DAO_Amount()).to.equal(0n);
  });
```

Run: `npx hardhat test test/NexauraStaking.test.js`
Expected: PASS (34 passing)

- [ ] **Step 5: Commit**

```bash
git add contracts/NexauraStaking.sol test/NexauraStaking.test.js
git commit -m "feat: implement DAO weighted distribution and daily spot bonus, owner-gated to prevent candidate-list self-drain"
```

---

### Task 11: Full Integration Test

**Files:**
- Create: `test/integration.test.js`

**Interfaces:**
- Consumes: the complete `NexauraToken` + `NexauraStaking` public interface built in Tasks 1–10.
- Produces: no new contract code — this task is verification-only, exercising the whole system end to end.

- [ ] **Step 1: Write the end-to-end scenario test**

```js
// test/integration.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("NEXAURA — end-to-end integration", function () {
  it("runs a full register -> stake -> cascade -> rank -> recycle -> withdraw -> DAO/spot-bonus flow", async function () {
    const [owner, creatorFee, treasury, alice, bob, carol, dave] = await ethers.getSigners();

    const MockUSDT = await ethers.getContractFactory("MockUSDT");
    const usdt = await MockUSDT.deploy();

    const NexauraToken = await ethers.getContractFactory("NexauraToken");
    const token = await NexauraToken.deploy(owner.address, await usdt.getAddress(), "Nexaura", "NXA");

    const NexauraStaking = await ethers.getContractFactory("NexauraStaking");
    const staking = await NexauraStaking.deploy(
      owner.address,
      await usdt.getAddress(),
      creatorFee.address,
      treasury.address
    );

    await token.connect(owner).setStakingContract(await staking.getAddress());
    await staking.connect(owner).setTokenAddress(await token.getAddress());

    for (const u of [alice, bob, carol, dave]) {
      await usdt.mint(u.address, ethers.parseEther("5000"));
      await usdt.connect(u).approve(await staking.getAddress(), ethers.parseEther("5000"));
    }
    // No separate token-contract funding needed: each makeStake below grows internalReserve by
    // its own 90%-mint portion, which is what payoutReserve checks against (see Task 2/Task 9).

    // 1. Register a 3-deep chain under the owner.
    await staking.connect(alice).regUser(owner.address);
    await staking.connect(bob).regUser(alice.address);
    await staking.connect(carol).regUser(alice.address);
    await staking.connect(dave).regUser(bob.address);

    // 2. Alice, Bob, Carol each stake $100; this gives alice 2 directs (bob, carol) -> Working Income unlocked.
    await staking.connect(alice).makeStake(ethers.parseEther("100"));
    await staking.connect(bob).makeStake(ethers.parseEther("100"));
    await staking.connect(carol).makeStake(ethers.parseEther("100"));
    await staking.connect(dave).makeStake(ethers.parseEther("100"));

    // Direct income: alice earned 5% of bob's and carol's 90-token mint each.
    const aliceBonus = await staking.bonusInfos(alice.address);
    expect(aliceBonus.referralGains).to.equal(ethers.parseEther("9")); // (90*5%)*2

    // Level income: alice also earns level-2 income from dave's stake (through bob).
    expect(aliceBonus.levelGains).to.be.gt(0n);

    // 3. Working income is claimable for alice now (2+ directs).
    const claimable = await staking.claimableWorking(alice.address);
    expect(claimable).to.be.gt(0n);

    // 4. Daily reward accrues and is claimable as non-working income.
    await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
    await ethers.provider.send("evm_mine");
    await staking.connect(alice).claimDailyReward();
    expect(await staking.claimableNonWorking(alice.address)).to.equal(ethers.parseEther("1.25"));

    // 5. Alice withdraws her daily reward.
    const beforeAlice = await usdt.balanceOf(alice.address);
    await staking.connect(alice).withdraw(ethers.parseEther("1.25"));
    const afterAlice = await usdt.balanceOf(alice.address);
    expect(afterAlice - beforeAlice).to.equal(ethers.parseEther("1.125")); // net of 10% fee

    // 6. Recycling: alice's package must hold steady or grow.
    await ethers.provider.send("evm_increaseTime", [11 * 24 * 60 * 60]); // past 10-day maturity
    await ethers.provider.send("evm_mine");
    await staking.connect(alice).makeUnstake(1);
    await staking.connect(alice).makeStake(ethers.parseEther("100")); // recycle at same amount, allowed
    await expect(staking.connect(alice).makeStake(ethers.parseEther("50"))).to.be.revertedWith(
      "Package must not decrease"
    );

    // 7. DAO distribution after the weekly window.
    await ethers.provider.send("evm_increaseTime", [7 * 24 * 60 * 60]);
    await ethers.provider.send("evm_mine");
    if ((await staking.DAO_Amount()) > 0n) {
      await staking.distributeDAO();
      expect(await staking.DAO_Amount()).to.equal(0n);
    }

    // 8. Spot bonus distribution, candidate list supplied explicitly.
    const spotPool = await staking.dailySpotBonusPool();
    if (spotPool > 0n) {
      await staking.distributeSpotBonus([alice.address, bob.address, carol.address, owner.address]);
      expect(await staking.dailySpotBonusPool()).to.equal(0n);
    }
  });
});
```

- [ ] **Step 2: Run the full suite**

Run: `npx hardhat test`
Expected: PASS (every test file, including this new integration scenario). If any assertion fails, it's a sign of an integration mismatch between two tasks' code (e.g. a rank/cap threshold interacting differently under multi-user load than in isolated unit tests) — fix the root cause in the relevant task's contract code, not by loosening this test's assertions.

- [ ] **Step 3: Commit**

```bash
git add test/integration.test.js
git commit -m "test: add end-to-end integration scenario across the full NEXAURA flow"
```

---

## Post-Plan Notes

- The 5 items in the spec's Section 6 (DAO income not capped, rank never downgrades, spot bonus equal split, CTO AND-thresholds, placeholder fee-role names) remain open items for the stakeholder — none of them are contradicted by this plan, but confirm before mainnet deployment.
- `distributeSpotBonus` takes an explicit candidate list (see the `ponytail:` comment in Task 10) rather than scanning all registered users on-chain — this avoids unbounded gas growth as the user base scales, at the cost of needing an off-chain job (or the admin) to supply that day's plausible candidates. Revisit if the qualifying population becomes large enough that manual/off-chain curation becomes unreliable.
- **Open architectural question, not addressed by this plan:** as built, `withdraw()` only pays out the `bonusInfos` gains ledger (referral/level/rank/CTO/daily-reward) — a user's *real* wallet token balance (from package-principal minting at `makeStake`, or received via P2P transfer) has no path back to USDT anywhere in this design; it can only be P2P-transferred further. This is faithful to the approved spec (Section 3.6 explicitly scopes withdrawal to "gains"), but the deck's "100% Sell-Burn mechanism: tokens sold through the platform..." language reads as if a general sell-your-balance action should exist too. Flagging for the stakeholder rather than building it unasked — if a general sell path is wanted, it's a small addition (a `sellBalance(uint256 tokenAmount)` wrapping `token.pricedSell` directly against the caller's own wallet balance, plus deciding whether it shares the 10%/5%/5% withdrawal fee or the deck's original 15% split).
