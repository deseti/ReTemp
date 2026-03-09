# ReTemp Protocol – Contract Addresses

## Network

* Network: Tempo Moderato Testnet
* Chain ID: 42431
* RPC: https://rpc.moderato.tempo.xyz
* Explorer: https://explore.tempo.xyz

---

# Core Contracts

## ReTempRouter

Main router contract handling swaps and invoice payments.

Address
0x9A54F31caEb1e6097f55F9A9D6E211A931C612F6

Functions

* createInvoice()
* payInvoice()
* routeSwap()
* quotePayment()
* registerPool()

---

# Liquidity Pools

## AlphaUSD ↔ BetaUSD

Pool Address
0x5c480582a063689a282637e8fB23a9C300127662

---

## AlphaUSD ↔ ThetaUSD

Pool Address
0x524Ec330c1Ae05E05669664a93310Fe30cB6f10e

---

## AlphaUSD ↔ PathUSD

Pool Address
0x6Ff5BBED78E0CF0e1f42bCB0FE3796924545f173

---

# Tokens (Tempo Testnet)

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

BetaUSD → AlphaUSD → ThetaUSD
BetaUSD → AlphaUSD → PathUSD
ThetaUSD → AlphaUSD → PathUSD

AlphaUSD is used as the hub routing token.

---

# Deployment Summary

Contracts deployed via Foundry script:

script/Deploy.s.sol

Command used:

forge script script/Deploy.s.sol:Deploy 
--rpc-url https://rpc.moderato.tempo.xyz 
--broadcast 
-vvv
