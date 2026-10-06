# NEXAURA Staking V2 — Design

Source: "NEXAURA FINAL PPT 05 Sep 26.pptx" plus the owner's walkthrough (2026-10-07).
New file `NexauraStakingV2.sol` in the `nexaura-implementation` worktree. The existing
`NexauraStaking.sol` stays untouched as a reference. Token and ReservePool are reused, with the
small token change below.

## Stake (`makeStake`)

Package $10–$1,000 in $10 steps; package must not decrease; user must be registered.

| Share of stake | Destination |
|---|---|
| 5% | Creator fee address (USDT) |
| 5% | DAO pool (held in staking contract, distributed later) |
| 9% (10% of the 90%) | Token's liquidity pool address (USDT) |
| 81% (90% of the 90%) | Minted as tokens at the live price, **minted to the staking contract and locked** |

On $100: $5 / $5 / $9 / $81.

- Each stake creates an **independent order**: `usdAmount`, `lockedTokens`, `startTime`, `claimed`.
  Each order has its own 10-day clock. Staking again before day 10 is "recycling" and just
  creates another order.
- **Direct income:** 5% of the full `usdAmount` ($5 on $100), converted to tokens at the live
  price, credited to the direct upline. Gated on the upline being active; clamped to cap room.
- Business volume updates at stake time as today. No level income and no CTO payment at
  stake time. The month's stake volume (USD) is accumulated for the CTO pools.

## Claim (`claimOrder(orderId)`)

- Requires `block.timestamp >= startTime + 10 days` and `!claimed`. Claimable at any time
  after maturity, including after grace ends.
- ROI = 12.5% (1.25% x 10 days) of the order's `lockedTokens`, in tokens, no price conversion,
  for any package amount. ROI is fixed at 10 days: nothing accrues beyond maturity.
- User receives the locked principal tokens (released from the staking contract) plus the ROI
  tokens (**minted at claim**). Order marked `claimed`.
- ROI is clamped to the claimer's remaining cap room.
- After paying out, the same transaction runs:
  1. `_distributeLevelIncome(claimer, roiAmount)`: the 21-level table from the deck, each
     percentage applied to the claimed ROI. Pays active uplines, clamped to their cap room.
  2. Rank income for the claimer: 12.5% x (direct + team business, in tokens) x rank
     incentive %, for that cycle. Replaces the daily `claimDailyReward`.

## Active, grace and caps

- **Active:** the user's last (newest) stake is under 10 days old. Only the last stake is
  checked.
- **Grace:** 7 days after the user's newest order matures; all other income types (direct,
  level, rank, DAO, spot, CTO) still credit.
- **Inactive:** after grace, no income credits until the user stakes again. Principal and ROI
  of existing orders stay claimable.
- **Caps, in tokens:** 2x (non-working) or 3x (working) of the user's **unclaimed** staked
  token amount (sum of `lockedTokens` over orders not yet claimed): cap = 2x (non-working) or
  3x (working) of that sum, for any amount. "Working" keeps the existing contract's
  definition.
- **Business volume** stays tracked in USD (rank thresholds are in dollars); rank income
  converts to tokens at the live price at claim time. Every gain type counts
  towards the cap and is clamped to the room left.
- **Claimables:** every income other than the principal+ROI claim (direct, level, rank, DAO,
  spot, CTO) accrues as a token claimable balance; the user claims it and receives tokens.

## CTO bonus (monthly, owner-run)

- Revenue = total stake volume (USD) of the month, accumulated in `makeStake`.
- Owner runs a distribute function once a month. Pool per tier = tier % x month's revenue:
  Core 1 2%, Core 2 1%, Core 3 1% (thresholds per the deck: direct business or team matching
  business).
- Each tier's pool is split equally among the users qualified for that tier, converted to
  tokens at the live price, **minted** and credited as claimable CTO gains (clamped to cap).
- A user collects **only their highest qualified tier's** pool.
- Example: 5 users at Core 1 share the 2% pool, one fifth each.

## Removed from the staking contract

No `makeUnstake`, no token selling, no sell/burn logic here. Users claim tokens from this
contract, then swap in the token contract at its price.

## Unchanged from current contract

DAO distribution, spot bonus, per-type claim functions, withdrawal minimum/daily cap and
fee rules (the 15% sell deduction and 100% burn live in the token contract's swap). Each income credit is gated on the
recipient being active (or in grace).

## Token contract change

`pricedBuy` currently mints to the staker. V2 needs the staking contract to receive the minted
stake tokens, and to mint ROI/income tokens at claim. Small change: mint to a caller-supplied
recipient, or add a staking-only `mintReward` function. Exact shape decided when that function
is written.

## Open items to settle during implementation

- Whether the $9 USDT liquidity transfer is made by the staking contract directly or via the
  token.
- Exact definition of "working" vs "non-working" user for the 3x/2x cap (keep the current
  definition unless the deck says otherwise).

## Way of working

One function at a time, each confirmed before the next. No compiling or testing until asked.
