# NEXAURA Token & Staking System — Design Spec

Source material: `NEXAURA PPT.pdf` (13 slides), reference contracts `setgoxToken.sol` /
`setgoxStaking.sol` (style/pattern reference only — numbers and several mechanics
differ, confirmed with stakeholder).

## 1. Goal

Two new Solidity contracts implementing NEXAURA's package-based staking/MLM token
economy:

- `NexauraToken.sol` — BEP20 token, mint/burn only reachable through the staking
  contract.
- `NexauraStaking.sol` — registration, packages, referral tree, all income
  distribution, DAO, rank, and withdrawal logic.

Both are new contracts. The reference pair is reused only for proven mechanical
patterns (level-cascade walk, 3x/2x TPR cap math, team-growth pooling, leader/dev
tree walk, unstake/stake as separate calls) — every constant, table, and several
mechanics (transfer burn, sell deduction, mint-only-via-staking, DAO weighted
shares, spot bonus, 8-tier rank ladder, 3-tier CTO bonus) are NEXAURA-specific and
not present in the reference.

## 2. Token Contract (`NexauraToken.sol`)

- BEP20, 18 decimals, name/symbol TBD by stakeholder at deploy time.
- Constructor: `(address owner, address usdtAddress)`. No hardcoded addresses —
  fee receiver and treasury addresses are all constructor/owner-set params,
  not literals.
- `setStakingContract(address)` (owner-only, one-time or owner-changeable): the
  only address permitted to call mint-triggering and sell-triggering functions.
  Regular EOAs cannot buy or sell tokens directly through this contract — matches
  "Users cannot purchase tokens through Swap; tokens can only be obtained through
  the Staking Program."
- `transfer` / `transferFrom` (P2P): 1% of the transferred amount is burned, 99%
  credited to the recipient. Applies to all transfers, including between regular
  users.
- `pricedBuy(usdAmount, forAddress)` (staking-contract-only): pulls USDT, mints
  tokens to `forAddress` at the live rate. Only ever called by
  `NexauraStaking.makeStake`.
- `pricedSell(tokenAmount, forAddress)` (staking-contract-only): computes USDT
  value at the live rate, burns 100% of the sold token amount, pays the full
  USDT-equivalent to `forAddress`. Does **not** apply any deduction itself —
  the withdrawal fee split (Section 3.6) is calculated and applied by the
  staking contract after receiving the full USDT amount. (Resolved: the
  deck's "15% sale deduction, 5% LP/10% reserve" language and the separate
  "10% withdrawal fee, 5% creator/5% spot bonus" language describe the same
  action — withdrawal *is* the sale. The 10%/5%/5% figures are authoritative;
  the 15%/LP/reserve figures do not apply.)
- `rateInUSDT()`: live pool-ratio pricing, identical formula to the reference —
  `pooledUSDT * 10**decimals / totalSupply`, falling back to `InitialRate` (1.00
  USDT) when `totalSupply == 0`.
- `mintReward(user, amount)` (staking-contract-only): used for rank-pool / DAO
  payouts that aren't tied to a specific sell, same as reference.

## 3. Staking Contract — Core Flow

### 3.1 Registration

`regUser(referral)` — unchanged from reference pattern: self-registration
requires an existing, already-joined referral; one-time and immutable.

### 3.2 Making a package (`makeStake`)

- Amount: multiple of $10, `$10 <= amount <= $1000`, and `amount >= user's last
  package amount` (recycling can hold steady or grow, never shrink — confirmed).
- Split: 5% creator fee, 5% into the global DAO pool, 90% minted to the staker
  at the live rate via `pricedBuy`.
- Creates an `order` struct (ownerAddress, orderValue, orderTime, isMature,
  isComplete) — same shape as the reference.
- First-ever stake: registers the user under `referral.directs[]`, starts
  `harvestTime`.
- Triggers the full income cascade (Section 4) up the referral chain.
- Updates `directBusiness` / `totalTeamBusiness` up the entire upline chain
  (reused from reference's `_updateBusinessToUpline`), which also drives DAO and
  rank qualification checks.

### 3.3 Maturity, recycling, grace period

- `MAXGROWTH_DAYS = 10 days`. An order matures 10 days after `orderTime`.
- 7-day grace period after maturity: total accrual window per order = 17 days
  from `orderTime`.
- If not recycled within that window, eligible income/reward accrual for that
  order stops (accrual gated off `isMature`/`isComplete`/elapsed-time, mirroring
  the reference's growth-accrual gating). Principal forfeiture logic (3x-cap
  exceeded triggers `_forfeitOrder`) is retained as-is from the reference.
- Recycling is **two separate transactions** — `makeUnstake` then `makeStake`
  again — not an atomic auto-compound call (confirmed: "how it's in the other
  contract").
- `makeUnstake(amount)`: computes growth/team/laps gains via an
  `unStakePotential`-style view, settles them into `bonusInfo`, marks the order
  complete, pays out earned value above principal (via `pricedSell`), subject to
  the 3x/2x caps below.

### 3.4 Income caps

- **Working Income cap = 3x** active package value. Counts: Direct Income,
  Level Generation Income, Team Growth/Rank Income, CTO/Fractional Partnership
  Income. Requires **2+ direct referrals** to be claimable at all — gains below
  that threshold still accrue into `bonusInfo` but aren't included in claimable
  balance until the referral requirement is met.
- **Non-Working Income cap = 2x** active package value. Counts: base Daily
  Reward (1.25%/day self-stake growth) and Daily Spot Bonus.
- DAO Partnership Income is a separate periodic pool distribution (Section 4.4),
  **not** counted against either cap in this design — flagged as an open item
  the stakeholder may want to revisit.
- Cap math reuses the reference's `_getRemainTPR` shape:
  `totalTPR = userLimit*3 - totalEarned`, `growthTPR = userLimit*2 -
  growthEarned`, recalibrated to the new day-length and rate constants.

### 3.5 Daily Reward (1.25%/day)

- Per the deck's explicit "claimed once every 24 hours" language, this is
  implemented as a **discrete daily accrual** (1.25% of the active order value
  credited per elapsed 24h period since last harvest/claim), **not** the
  reference contract's continuous fractional partial-day growth curve. This is
  a deliberate simplification versus the reference's `_stakeGrowth` model.
- Claimable via a `claimDailyReward()` function, gated to once per 24h per user
  (`harvestTime` tracking, same field as reference).

### 3.6 Withdrawal

- Minimum $10, maximum $3,000 per user per day (new: `mapping(address =>
  (uint256 day, uint256 withdrawnToday))`, tracked and reset per UTC day — the
  reference has no equivalent daily cap).
- 10% fee on every withdrawal: 5% to Creator Fee address, 5% into the
  `dailySpotBonusPool` (confirmed).
- Payout converts token-denominated gains to USDT via `pricedSell` at the live
  rate.

## 4. Income Distribution

All per-stake buckets (4.1–4.3, 4.6) are calculated as percentages of the 90%
minted amount on each `makeStake`, cascaded up the referral chain in one pass
(reused shape from the reference's `_distLevel` + `_leaderDist`). These are
**not** deducted from the staker's own tokens — they are parallel bonus
obligations credited into each upline earner's `bonusInfo` balance, minted as
new supply and paid out later when that earner claims/withdraws (same two-step
"accrue now, mint-on-payout" mechanism the reference contract uses via
`mintReward`/`sellSetGox`, not an immediate transfer out of the staker's
balance).

### 4.1 Direct Income — 5%

Level-0 special case in the cascade: the staker's direct upline gets `minted *
5%`, capped to the referrer's own `lastStake` if the new stake is larger (same
cap logic as reference).

### 4.2 Level Generation Income — 18% across 21 levels

Fixed basis-point table (`uint16[21]`), sums to 18%:

| Level | % | Level | % | Level | % |
|---|---|---|---|---|---|
| 1 | 5% | 8 | 0.5% | 15 | 0.15% |
| 2 | 3% | 9 | 0.5% | 16 | 0.15% |
| 3 | 1.5% | 10 | 0.25% | 17 | 0.15% |
| 4 | 1.5% | 11 | 0.25% | 18 | 0.25% |
| 5 | 1% | 12 | 0.25% | 19 | 0.25% |
| 6 | 1% | 13 | 0.15% | 20 | 0.5% |
| 7 | 0.5% | 14 | 0.15% | 21 | 1% |

**Gate:** at every level of the 21-level walk, that specific earner only
receives their slice if their own active package is $50+ (confirmed: per-earner
gate, not staker-only). An earner below $50 is skipped; income does not pass
through to the next level on their behalf, it is simply not paid (matches
reference's per-level independent check pattern).

### 4.3 Team Growth / Rank Income — 20%, daily against Match Business

**Match Business** = `totalTeamBusiness` — the full compound of the strong leg
plus every other leg combined, i.e. the sum of all downline business with no
leg excluded and no subtraction (confirmed explicitly: "compound of strong leg
business with other leg, no minus" — this is *not* the reference contract's
`OLeg` formula, which excludes the strongest leg; that formula does not apply
here).

8-tier rank table, qualification requires meeting Self, Direct, and Match
Business thresholds simultaneously:

| Rank | Self ($) | Direct | Match Business ($) | Incentive % | Daily formula |
|---|---|---|---|---|---|
| Starter | 50 | 3 | 2,500 | 4% | 1.25% × MB × 4% |
| Booster | 100 | 6 | 5,000 | 6% | 1.25% × MB × 6% |
| Builder | 200 | 9 | 7,500 | 8% | 1.25% × MB × 8% |
| Accelerator | 300 | 12 | 10,000 | 10% | 1.25% × MB × 10% |
| Multiplier | 500 | 15 | 25,000 | 12% | 1.25% × MB × 12% |
| Elite | 700 | 18 | 50,000 | 14% | 1.25% × MB × 14% |
| Legend | 900 | 21 | 100,000 | 15% | 1.25% × MB × 15% |
| Legend Prime | 1,200 | 25 | 200,000 | 20% | 1.25% × MB × 20% |

(Daily formula verified arithmetically against the deck's table — e.g. Starter:
1.25% × 2,500 = 31.25, × 4% = 1.25/day; Legend Prime: 1.25% × 200,000 = 2,500,
× 20% = 500/day — matches deck exactly.)

- Rank is **sticky-upgrade-only**: achieving a higher rank clears/replaces the
  lower rank membership; ranks never downgrade on volume dips (inferred from
  reference's rank-exclusivity pattern — flagged as an assumption, not
  explicitly stated in the deck).
- Daily accrual credited into `teamGrowthGains`, same mechanism as reference's
  `teamLevelStake`/`_stakeGrowth` team-growth math, with the incentive%
  sourced from the 8-tier table instead of a flat rate.

### 4.4 DAO Partnership Income — 5% globally, weighted overridable shares

- Qualification window is **per-tier, not a single shared window**, each
  clocked from the member's own `daoJoinTime` (set once, at their own first
  stake — "joining with their package"; a member who never stakes their own
  package never starts this clock, regardless of how much business flows to
  them from downline activity). Tier thresholds (either condition qualifies —
  OR, not AND) and each tier's own deadline:

| Direct Business ($) | OR Matching Business ($) | Share | Deadline (from own join) |
|---|---|---|---|
| 500 | 1,000 | 1 | 10 days |
| 1,000 | 2,000 | 2 | 20 days |
| 2,500 | 4,000 | 5 | 30 days |

- The three tiers qualify **independently**, not sequentially (confirmed):
  missing Share 1's 10-day deadline forfeits Share 1 forever, but does not
  block Share 2 or Share 5 if their own (longer) thresholds are cleared
  within their own (longer) windows.
- Shares **override**, not stack: reaching Share-2 thresholds replaces a
  Share-1 membership; reaching Share-5 replaces Share-2 (confirmed).
- 5% of every package's 90%-mint value accumulates into a global `DAO_Amount`
  pool (same accumulation pattern as reference's `daoFee`).
- **Weekly**, an owner/keeper-callable distribution function splits
  `DAO_Amount` proportionally by `userShare / totalSharesOutstanding` across all
  currently-qualified users (weighted, not equal-per-head — confirmed, this
  differs from the reference's flat equal-split `distributeReward`). Pool resets
  to 0 after each distribution.

### 4.5 Daily Spot Bonus — 5% of global daily withdrawal deductions

- Funding: 5% of every withdrawal's 10% fee (Section 3.6) accumulates into
  `dailySpotBonusPool`.
- Qualification: 2+ direct referrals gained within the same rolling 24h window,
  each having purchased a $50+ package.
- Distribution: once per 24h, an owner/keeper-callable function splits that
  day's accumulated `dailySpotBonusPool` among that day's qualifying users
  (equal split — deck doesn't specify weighting here, so equal-per-qualifier is
  assumed as the simplest reading). Pool resets after each distribution.

### 4.6 Fractional Partnership / CTO Bonus — 4%, 3 tiers

Tree-walk pattern reused from reference's `findLeaderUser`/`_leaderDist`: walk
upline, find qualifying leaders by Direct Business AND Team Business thresholds
(both required, per the deck's table), pay CTO Bonus% of the minted stake
amount to each qualifying tier found (first match up the chain per tier, same
exclusivity-by-tier logic as reference's leader/dev address arrays):

| Rank | Direct Business ($) | Team Business ($) | CTO Bonus % |
|---|---|---|---|
| 1st | 5,000 | 10,000 | 2% |
| 2nd | 10,000 | 20,000 | 1% |
| 3rd | 20,000 | 40,000 | 1% |

## 5. Admin / Owner Functions

- `setTokenAddress` (staking contract, owner-only) — same as reference.
- `setStakingContract` (token contract, owner-only) — new, replaces reference's
  hardcoded-whitelist-in-constructor approach since we're avoiding hardcoded
  addresses.
- `setFeeAddresses` (creator, treasury) — constructor + owner-only setters, no
  hardcoded literals (confirmed: constructor params, not hardcoded).
- `distributeDAO()` — owner/keeper, weekly cadence (not enforced on-chain by a
  timer beyond an optional `require(block.timestamp >= lastDaoDist + 7 days)`
  guard, mirroring the reference's `checkpoint` pattern).
- `distributeSpotBonus()` — owner/keeper, daily cadence, same guard pattern.

## 6. Explicit Assumptions / Open Items

These were either directly confirmed by the stakeholder or are the best
available reading of an underspecified slide — listed here so they're easy to
revisit if wrong:

1. **DAO income not included in the 3x/2x caps** — deck doesn't say either way;
   flagged for stakeholder to confirm before implementation locks in.
2. **Rank never downgrades** — inferred from reference pattern, not explicit in
   the deck.
3. **Spot Bonus split equally among qualifiers** — deck doesn't specify
   weighting for this bucket (unlike DAO, which is explicitly weighted).
4. **CTO tier qualification requires both Direct AND Team Business thresholds**
   — read directly from the table's column structure, high confidence.
5. Token `name`/`symbol` and exact fee-receiver role assignments (which address
   is "Creator Fee" vs "Treasury") are placeholders pending stakeholder input
   at implementation time — passed as constructor params either way, so this
   doesn't block the spec.

## 7. Testing Considerations

- Unit coverage per income bucket in isolation (direct, 21-level, rank/team
  growth, DAO weighted split, spot bonus, CTO) using fixed referral-tree
  fixtures.
- Cap enforcement: verify 3x/2x ceilings correctly stop further crediting and
  that the 2-referral Working Income gate withholds claimability without losing
  the underlying accrual.
- Recycling window: verify accrual stops correctly after 17 days (10 + 7) if
  not recycled, and that a smaller recycle amount is rejected.
- Token burn math: 1% transfer burn, and 100% burn of sold tokens on
  withdrawal (with the 10% USDT-side fee, 5/5 split, applied in the staking
  contract), verified against total-supply deltas.
- Live pricing: rate moves correctly as pool USDT/supply changes across
  buy/sell/mint/burn sequences.
