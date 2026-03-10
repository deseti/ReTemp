# ReTemp Protocol – Contract Addresses

## Network

* Network: Tempo Moderato Testnet
* Chain ID: 42431
* RPC: https://rpc.moderato.tempo.xyz
* Explorer: https://explore.tempo.xyz

---

# Core Contracts

## ReTempRouter ✅ ACTIVE (tested on-chain)

Main router contract — `swapDirect` architecture (no approve bug).

Address
0x148ACa4DF102E7E4F94C8eFDF3A1710E41AFc093

Functions

* routeSwap(address tokenIn, address tokenOut, uint256 amountIn)
* createInvoice(address token, uint256 amount)
* payInvoice(uint256 invoiceId, address paymentToken)
* quotePayment(uint256 invoiceId, address paymentToken)
* registerPool(address tokenA, address tokenB, address pool)
* getPool(address tokenA, address tokenB)

---

# Liquidity Pools ✅ ACTIVE (reserves confirmed on-chain)

## AlphaUSD ↔ BetaUSD

Pool Address
0x857F4F2dEF1a6A2C4c417ae2c5bb1A62F1A0950C

Reserves: 8,000,000,000,000 / 8,000,000,000,000

---

## AlphaUSD ↔ ThetaUSD

Pool Address
0x86ca17F2fe550E8B245cB23967343bc5C8DCfab9

Reserves: 8,000,000,000,000 / 8,000,000,000,000

---

## AlphaUSD ↔ PathUSD

Pool Address
0x23b549AbaE9003ceBD95ac4fFe2BC948E7DcBfEd

Reserves: 8,000,000,000,000 / 8,000,000,000,000

---

# Tokens (Tempo Testnet — TIP-20)

## AlphaUSD (Hub Token)

0x20C0000000000000000000000000000000000001

## BetaUSD

0x20C0000000000000000000000000000000000002

## ThetaUSD

0x20C0000000000000000000000000000000000003

## PathUSD

0x20C0000000000000000000000000000000000000

---

# Treasury

Protocol fee receiver (0.2%)

Address
0x75b0b8EFb946e2892Bc650311D28DEFfbe015Ea9

---

# Routing Topology

BetaUSD  → AlphaUSD (direct)
ThetaUSD → AlphaUSD (direct)
PathUSD  → AlphaUSD (direct)
BetaUSD  → AlphaUSD → ThetaUSD (2-hop)
BetaUSD  → AlphaUSD → PathUSD  (2-hop)
ThetaUSD → AlphaUSD → PathUSD  (2-hop)

AlphaUSD is the hub routing token for all 2-hop swaps.

---

# DEPRECATED Contracts (do not use)

| Contract | Old Address | Reason |
|---|---|---|
| Router (old) | 0x9A54F31caEb1e6097f55F9A9D6E211A931C612F6 | forceApprove double-fee bug on TIP-20 |
| poolAlphaBeta (old) | 0x5c480582a063689a282637e8fB23a9C300127662 | No swapDirect — not compatible with new router |
| poolAlphaTheta (old) | 0x524Ec330c1Ae05E05669664a93310Fe30cB6f10e | No swapDirect — not compatible with new router |
| poolAlphaPath (old) | 0x6Ff5BBED78E0CF0e1f42bCB0FE3796924545f173 | No swapDirect — not compatible with new router |

---

# Deployment

Contracts deployed: 2026-03-09
Script: script/Deploy.s.sol

forge script script/Deploy.s.sol:Deploy
--rpc-url https://rpc.moderato.tempo.xyz
--private-key <PK>
--broadcast --slow
--gas-estimate-multiplier 1000
--chain 42431

On-chain tests: script/test-onchain.ps1
