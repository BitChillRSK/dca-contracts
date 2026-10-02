# Invariant Testing Guide

## Overview

Stateful fuzz coverage for BitChill lives in three suites under this folder, two of which run under
both a flat and the launch variable fee configuration. Every contract name matches
`--match-contract InvariantTest` (the `make invariants` / `make invariants-sovryn` lane), so naming a
new suite `…InvariantTest` is enough to pick it up with no Makefile change.

| Contract | What it targets | What it deliberately does **not** cover |
|---|---|---|
| `InvariantTest` | Production `DcaManager` + production lending adapters (`TropykusHandler` / `SovrynHandler`) behind **purchase wrappers** that reimplement `batchBuyRbtc` | Production `PurchaseRbtc` allocation, rBTC solvency, MoC / Uniswap venues |
| `PurchaseRbtcConservationInvariantTest` / `PurchaseRbtcVariableFeeConservationInvariantTest` | Production `PurchaseRbtc` through `PurchaseRbtcHarness` (venue + retrieval overridden); flat and launch-variable fees | Lending share books, `DcaManager`, a real venue |
| `LendingPurchaseConservationInvariantTest` / `LendingPurchaseVariableFeeConservationInvariantTest` | Production `SovrynDocHandlerMoc` (lending + `PurchaseMoc` / `PurchaseRbtc`) with `MockIToken` + `MockMocProxy`; flat and launch-variable fees | Full `DcaManager` schedule lifecycle (the fuzz actor is the `dcaManager`) |

The main suite's wrappers exist so deposit / withdraw / pause / top-up / schedule edits can run against
real lending accounting without standing up MoC. They credit rBTC without a matching cash move, so any
rBTC solvency check there would be false by construction. That is why rBTC conservation lives in the
other two suites instead.

## Running

```bash
# Default lane (Tropykus wrappers) + the conservation suites
make invariants

# CI lane (Sovryn wrappers) + the conservation suites
make invariants-sovryn

# The main suite alone
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-contract '^InvariantTest$' -j 1
```

`LENDING_PROTOCOL` only affects `InvariantTest`'s lending wrapper. The conservation suites build
their own fixtures and ignore the env.

## What each suite actually proves

### `InvariantTest` (lending + schedule surface)

1. **Stablecoin conservation** — sum of schedule `tokenBalance` values must not exceed the lending
   protocol's stablecoin value of BitChill's receipt shares by more than **100 wei** (rounding /
   interest operations).
2. **No idle stablecoin on the handler** — after every action the handler's ERC-20 balance is zero
   (funds are in lending or burned by the purchase simulation).
3. **Exchange-rate monotonicity** — Tropykus `exchangeRateCurrent() >= exchangeRateStored()`;
   Sovryn `tokenPrice() > 0` (the mock has no stored previous rate to compare).
4. **Virtual shares ≤ receipt shares** — sum of `getUserShares` never exceeds the handler's
   kToken / iSUSD balance.
5. **Schedule sanity** — live schedules keep `purchaseAmount >= MIN_PURCHASE_AMOUNT`,
   `purchasePeriod >= MIN_PURCHASE_PERIOD`, and a non-zero `scheduleId`.
6. **Paused schedules never purchase** — a schedule the ghost holds as paused keeps an unchanged
   `cadenceAnchor` (only a purchase writes that field).

Coverage guards (deterministic, not fuzzed) pin that create / pause / buy / top-up actions can still
reach the chain: `test_invariantHandlerCreatesScheduleAtSelectedRoute`,
`test_invariantHandlerPausesAndRecordsGhost`, `test_invariantHandlerBuysRbtcThroughDcaManager`,
`test_invariantHandlerTopsUpFromInterest`. `afterInvariant` refuses a vacuous pause run when pauses
were attempted on live schedules.

**Not claimed here:** rBTC solvency, production purchase allocation, or “user interest only
increases.” Interest accrual is exercised by the conservation check and the exchange-rate check;
share burns on withdraw / purchase are allowed and expected.

### `PurchaseRbtcConservationInvariantTest` / `PurchaseRbtcVariableFeeConservationInvariantTest`

Shared handler and invariants; two fee configurations. Flat: 100 bps equal rates. Variable: launch
band (100/20 bps, 250-token lower bound). Fuzz actions include `batchBuyRbtc`, buyer/collector
`withdrawAccumulatedRbtc`, and `rotateFeeCollector` (buyer overlap allowed). Claimables are summed
uniquely across buyers and every address that has been collector so overlap does not double-count.

1. **Credits stay in the floored band** — unique claimables + withdrawn ≤ measured venue output,
   and that total plus under-one-wei-per-row slack (k = rows + fee floors leave at most k − 1 wei)
   ≥ measured output.
2. **Books never exceed handler balance** — unique claimable rBTC ≤ `address(harness).balance`.

### `LendingPurchaseConservationInvariantTest` / `LendingPurchaseVariableFeeConservationInvariantTest`

Same flat + launch-variable split and collector rotate/withdraw surface, on `SovrynDocHandlerMoc`.

1. **Native rBTC conservation** — MoC-paid rBTC (measured as handler balance gains)
   equals remaining handler balance plus measured withdrawals. Collector fees stay on the
   handler until withdrawn. Length-1 batches can leave one wei of floor dust on the handler.
2. **Virtual shares ≤ receipt shares** — same lending-book bound as the main suite, on the real
   `SovrynDocHandlerMoc` leaf while purchases redeem through MoC.
3. **No idle stablecoin on the handler** — DOC sits in iSUSD or is consumed by MoC. Purchase fees are native rBTC.

Actions are restricted to `depositToken` / `buyRbtc` / `withdrawAccumulatedRbtc` /
`rotateFeeCollector` via `targetContract` + `targetSelector` (so inherited `Test.failed()` and
deployed mocks are not fuzzed). Production calls are not try/caught: empty cases return early, and
`fail_on_revert` surfaces real handler regressions.

## Adding an invariant

Do not assert that an unsigned value is non-negative under a solvency or monotonicity name: it is true
by construction and proves nothing.
