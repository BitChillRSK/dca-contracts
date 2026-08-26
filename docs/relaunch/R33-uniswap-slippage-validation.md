# R33 — Enforce one Uniswap slippage-settings invariant

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 23, GitHub [#67](https://github.com/BitChillRSK/dca-contracts/pull/67). Stack on the post-R30 planning PR (PR 22, GitHub #66). It has no product gate or file overlap with R13, so land it first rather than blocking this independent fix on R13's one-shot migration decision. Keep it separate from R31 selector pruning.

## Objective

Use one validator for Uniswap slippage construction and updates so the safety floor can never exceed the active minimum-output percentage.

## Background

The constructor and `setAmountOutMinimumPercent` enforce:

```text
amountOutMinimumSafetyCheck <= amountOutMinimumPercent <= 100%
```

`setAmountOutMinimumSafetyCheck` checks only the 100% ceiling, so the owner can currently store a safety value above the active percentage. That state is rejected during construction and cannot be reached through the other setter. The safety value is a policy bound for configuration; it does not replace measured WRBTC cash or the router's `amountOutMinimum`.

## Open product decisions

**none** — preserve both existing setters and enforce the already-intended invariant in every path. R31 owns any later selector decision.

## Scope

- [x] Add one internal slippage-settings validator covering the minimum ceiling, safety ceiling, and `minimum >= safety` relation.
- [x] Use it in the constructor, `setAmountOutMinimumPercent`, and `setAmountOutMinimumSafetyCheck`.
- [x] Reuse the existing custom errors unless a new error is necessary to make the failing relation unambiguous; document any error-ABI addition.
- [x] Add a regression where the owner raises safety above the current minimum and state remains unchanged.
- [x] Preserve event ordering and old/new values for successful updates.

## Out of scope

- [ ] Oracle math, price freshness, purchase paths, swap paths, fee policy, or WRBTC cash measurement.
- [ ] Atomic settings setters, selector removal, storage packing, or R31 ABI work.
- [ ] Deployment defaults or live broadcasts.

## Files likely touched

- `src/PurchaseUniswap.sol`
- `src/interfaces/IPurchaseUniswap.sol` only if an error is added or clarified
- `test/unit/PurchaseUniswapSettingsTest.sol`
- Direct Sovryn/Tropykus Dex handler tests if the shared settings suite does not cover construction and both setters

## Required tests

```sh
forge test --match-contract PurchaseUniswapSettingsTest
forge test --match-contract "SovrynErc20HandlerDexTest|TropykusErc20HandlerDexTest"
make check
make fork-sovryn
make fork-tropykus
```

Assert all equality boundaries, both values at 100%, minimum below safety, safety above current minimum, unchanged state on revert, and successful updates in both valid directions. Constructor and setter boundary cases live in the Sovryn/Tropykus Dex handler suites: `PurchaseUniswapSettingsTest` is `onlyDexSwaps` and DcaDappTest skips the USDRIF+Sovryn check/CI lane, so those assertions would not run in `make check`. Fork tests add no new fork-specific assertions.

## Success criteria

- [x] Constructor and both setters share one validation rule.
- [x] No reachable state has `s_amountOutMinimumSafetyCheck > s_amountOutMinimumPercent`.
- [x] Valid settings, events, swap behavior, and measured-cash accounting are unchanged.
- [x] No selector or storage-layout change unless a narrowly justified error addition is recorded.
- [x] Targeted, done-gate, and both fork tests pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests cover the formerly missing update direction.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No slippage-policy expansion is disguised as validation reuse.

## ABI / deploy / cutover impact

- ABI: no function/event/error change. The `minimum >= safety` relation reuses `PurchaseUniswap__AmountOutMinimumPercentTooLow` on construction and both setters.
- Scripts: none.
- Cutover: owner configuration becomes stricter in the one state already rejected at construction.
