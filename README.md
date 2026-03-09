# ReTemp Protocol

**ReTemp** is a Stablecoin Payment Router + DEX Pool designed for a payment-focused blockchain.

---

## Architecture

```
contracts/
├── interfaces/
│   └── IReTempPool.sol     ← Pool interface (swap, getAmountOut, getPrice, getReserves)
├── ReTempPool.sol          ← AMM constant-product liquidity pool
└── ReTempRouter.sol        ← Payment invoice router with swap routing

script/
└── Deploy.s.sol            ← Forge deployment script

test/
└── ReTemp.t.sol            ← Integration tests
```

### Contract Overview

| Contract | Role |
|---|---|
| `ReTempPool` | AMM liquidity pool — stablecoin swaps, x·y=k formula |
| `ReTempRouter` | Invoice creation, payment settlement, routing through the pool |

### Key Parameters

| Parameter | Value | Meaning |
|---|---|---|
| `ROUTER_FEE` | `20` | 0.20% (basis points out of 10,000) |
| Swap fee (pool) | `0.3%` | Applied via `997/1000` multiplier (TODO) |

---

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Node / npm (optional, for linting)

Install Foundry:
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

---

## Getting Started

### 1. Install dependencies

```bash
forge install OpenZeppelin/openzeppelin-contracts
```

### 2. Build

```bash
forge build
```

### 3. Run tests

```bash
forge test -vv
```

### 4. Deploy (local Anvil node)

```bash
# Terminal 1 — start local node
anvil

# Terminal 2 — deploy
cp .env.example .env
# edit .env with your PRIVATE_KEY (use Anvil's first key for local testing)
forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast
```

---

## Implementation Roadmap

The contracts are scaffolded with placeholder logic. Below are the TODOs in priority order.

### ReTempPool

- [ ] `_sqrt()` — Babylonian integer square root for first-deposit shares
- [ ] `addLiquidity()` — geometric mean shares (first deposit) + proportional (subsequent)
- [ ] `removeLiquidity()` — proportional token return when burning shares
- [ ] `getAmountOut()` — constant-product formula `(amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)`
- [ ] `swap()` — pull tokenIn, push tokenOut, call `_updateReserves()`
- [ ] `getPrice()` — `(reserveB * 1e18) / reserveA`
- [ ] `_updateReserves()` — sync with `IERC20.balanceOf`

### ReTempRouter

- [ ] `payInvoice()` — direct transfer path (same token)
- [ ] `payInvoice()` — cross-token path (approve pool, call `pool.swap`)
- [ ] `payInvoice()` — fee deduction & treasury forwarding
- [ ] `routeSwap()` — pull tokenIn → approve → swap → send output
- [ ] `quotePayment()` — reverse quote including router fee
- [ ] Slippage protection (`minAmountOut`) parameter
- [ ] Native ETH support via WETH wrap

---

## License

MIT
