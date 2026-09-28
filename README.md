# NEXAURA

Solidity contracts (`contracts/`) plus a basic React frontend (`frontend/`) for the NEXAURA
staking system.

> **Before deploying anywhere real:** the final whole-branch review found two unresolved
> Critical bugs (see `docs/superpowers/plans/2026-09-28-nexaura-implementation.md`, bottom of the
> file). Don't deploy to mainnet until those are fixed.

## Contracts

```bash
npm install
npm test                # run the full contract test suite
```

## Local testing (no real funds needed)

```bash
npx hardhat node                                    # terminal 1: local chain
npx hardhat run scripts/deploy.js --network localhost  # terminal 2: deploy + write frontend/src/contracts/*
cd frontend && npm install && npm run dev            # terminal 2 (continued): serve the UI
```

Then in MetaMask, add a network for `http://127.0.0.1:8545`, chain ID `31337`, and import one of
the local node's printed test accounts to have test ETH and (after deploying) test USDT.

## BSC Testnet deploy

1. Copy `.env.example` to `.env` and fill in `PRIVATE_KEY` (a **testnet-only** wallet — never a
   mainnet key). `.env` is gitignored.
2. Fund that wallet with testnet BNB from a faucet (e.g. https://testnet.bnbchain.org/faucet-smart).
3. Deploy:
   ```bash
   npx hardhat run scripts/deploy.js --network bscTestnet
   ```
   This deploys a `MockUSDT` stand-in (BSC testnet has no single canonical USDT), the two NEXAURA
   contracts, wires them together, and writes `frontend/src/contracts/addresses.json` + ABIs.
4. Run the frontend:
   ```bash
   cd frontend && npm install && npm run dev
   ```
5. In MetaMask, switch to BSC Testnet (chain ID 97) — the app will offer to add/switch it for you
   if you're on the wrong network. Use the "Mint" function on the deployed `MockUSDT` contract
   (or extend the deploy script) to get test USDT into any account you want to try staking with.

## Frontend scope

The frontend currently covers registration and staking only:
- Connect wallet (MetaMask), network check/switch.
- Register with a referral address.
- Approve USDT + stake a package.
- Basic status: registered?, last package, USDT balance.

Claiming rewards, withdrawal, recycling, rank/DAO/CTO views, and admin functions are not built
yet — this was scoped as a basic first pass covering the onboarding flow.
