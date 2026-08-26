# R32 — Clean up final DcaManager and lending internals

Status: **not started** · Assigned: yes · Optional/further-review: no

PR 28. Stack on R35 (PR 27). This is the last behavior-preserving Solidity cleanup before R22 deploy/CI freezes the final harness shape.

## Objective

Remove redundant memory copies, locked-principal loops, handler lookups, and identical exchange-rate overrides after the public API and operations registry have reached their final relaunch shape.

## Background

`DcaManager` interest withdrawal and interest views independently copy and sum the same schedule array. Bulk interest withdrawal resolves a handler before calling a helper that validates and resolves it again. Sovryn and LayerBank implement identical `_exchangeRate()` and `_viewExchangeRate()` functions, while only Tropykus needs separate mutating/stored-rate hooks.

R13 already removes protocol-name fetching and installs the direct lending-route query because that change is inseparable from its registry design. R34 deleted `updateDcaSchedule` (the previous whole-struct write-back) and settled the remaining DcaManager functions. R35 renamed the leftover `lendingProtocolIndex` field/args to `routeIndex`. Implement this PR against those final surfaces rather than cleaning up code that R34 deleted.

## Open product decisions

**none**

## Scope

- [ ] Extract one storage-array helper that sums locked principal for `(user, token, routeIndex)` and use it from both interest withdrawal and accrued-interest views.
- [ ] Let bulk interest withdrawal pass an already-resolved handler into the internal withdrawal path instead of looking it up twice.
- [ ] Give `LendingErc20Handler._exchangeRate()` a default implementation that calls `_viewExchangeRate()`. Remove identical Sovryn/LayerBank overrides; Tropykus retains both because `exchangeRateCurrent()` mutates while `exchangeRateStored()` is a view.
- [ ] Preserve all external selectors, events, errors, storage slots, cash measurement, and schedule accounting left by R35.

## Out of scope

- [ ] R34 ABI decisions, schedule-struct packing, pause, compound interest, fee changes, or handler registry changes.
- [ ] Assembly, unchecked-loop changes, calldata rewrites, or gas-driven removal of `nonReentrant` from schedule mutators.
- [ ] Protocol adapter behavior or new shared inheritance layers.

## Files likely touched

- `src/DcaManager.sol`
- `src/LendingErc20Handler.sol`
- `src/sovryn/SovrynErc20Handler.sol`
- `src/layerbank/LayerBankErc20Handler.sol`
- `src/tropykus-legacy/TropykusErc20Handler.sol` only if an explicit override annotation must change
- Focused DcaManager and lending-base tests affected by the helper seams

## Required tests

```sh
forge test --match-contract DcaConfigurationTest
forge test --match-contract StablecoinLendingTest
forge test --match-contract LendingErc20HandlerRedeemTest
forge build --sizes
make check
make fork-sovryn
make fork-tropykus
```

Add or retain tests proving mixed-route locked-principal sums, idle-index rejection for interest, bulk-withdraw skip behavior, and distinct Tropykus current/stored rate calls. Fork tests add no new fork-specific assertions.

## Success criteria

- [ ] One locked-principal summation implementation exists.
- [ ] Bulk interest withdrawal does not resolve the same handler twice.
- [ ] R13's direct lending-route check remains unchanged; no protocol-name registry or lookup is reintroduced.
- [ ] Only adapters with genuinely different mutating/view rates override both hooks.
- [ ] ABI, storage layout, events, errors, and behavior match the R35 base.
- [ ] Targeted, done-gate, and both fork tests pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests demonstrate semantic equivalence rather than only compilation.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No product or ABI decision is hidden in the cleanup.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none.
- Cutover: none; fresh relaunch deployment.
