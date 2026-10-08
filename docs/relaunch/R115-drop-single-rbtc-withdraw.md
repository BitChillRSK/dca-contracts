# R115 — Drop the single accumulated-rBTC withdraw

Status: **in progress** · Assigned: yes · Optional/further-review: no · Stack on: R114
([#181](https://github.com/BitChillRSK/dca-contracts/pull/181))

## Objective

Remove `DcaManager.withdrawAccumulatedRbtc(token, routeIndex)`. Callers withdraw accumulated rBTC
only through `withdrawAllAccumulatedRbtc`, including a one-element pair list.

## Background

The single function reverts on an unassigned route and on a zero balance. The batch skips both.
No user surface calls the single function. The front end sweeps with the batch. The fee collector
cashes out with the batch. A one-handler batch costs about 1,500 gas more than the single call
(one extra `CALL`, one `SLOAD`, four calldata words). At the current Rootstock gas price that is
about 4 satoshis. That gap does not justify a second entry point.

`PurchaseRbtc.withdrawAccumulatedRbtc(user)` stays. `DcaManager` still calls it from the batch.

## Open product decisions

**none.** Decided 2026-10-08: remove the single `DcaManager` function. Do not add a front-end
branch that calls it for one handler.

## Scope

- [ ] Delete `DcaManager.withdrawAccumulatedRbtc` and the matching `IDcaManager` declaration.
- [ ] Point tests that called it at `withdrawAllAccumulatedRbtc` with one pair.
- [ ] Drop the duplicate invariant action that only called the removed function.
- [ ] Point the cutover runbook and the R107 collector sentence at the batch function.

## Out of scope

- [ ] `PurchaseRbtc.withdrawAccumulatedRbtc(user)` and every handler override of the pay seam.
- [ ] `withdrawAllAccumulatedRbtc` skip rules, empty-array revert, and length check.
- [ ] A front-end code change in this repo. Consumer follow-up is an issue comment only.
- [ ] Historical specs and published audit reports that name the old selector.
- [ ] The next R-item.

## Files likely touched

- `src/DcaManager.sol`
- `src/interfaces/IDcaManager.sol`
- `docs/relaunch/CUTOVER_RUNBOOK.md`
- `docs/relaunch/R107-rbtc-fees.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/README.md`
- Tests that call `dcaManager.withdrawAccumulatedRbtc`

## Required tests

- One-pair `withdrawAllAccumulatedRbtc` still pays only the signer.
- A paused route and a paused schedule still pay accumulated rBTC through the batch.
- A rejecting contract still reverts `PurchaseRbtc__rBtcWithdrawalFailed` and keeps its credit.
- `make check`, `make fork-sovryn`, and `make fork-layerbank` before push.

## Success criteria

- [ ] `DcaManager` has no `withdrawAccumulatedRbtc`.
- [ ] `withdrawAllAccumulatedRbtc` is unchanged apart from being the only accumulated-rBTC withdraw.
- [ ] Handler `withdrawAccumulatedRbtc(user)` still exists.
- [ ] The runbook tells the collector to call the batch function.
- [ ] Invariants 3, 6, 10, and 13 still hold.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: remove `DcaManager.withdrawAccumulatedRbtc(address,uint256)`.
  `withdrawAllAccumulatedRbtc(address[],uint256[])` is unchanged.
  `PurchaseRbtc.withdrawAccumulatedRbtc(address)` is unchanged.
- Scripts: none.
- Cutover: the collector sweeps with `withdrawAllAccumulatedRbtc`, one pair per live handler.
  Comment on [front-end#30](https://github.com/BitChillRSK/front-end/issues/30): drop the unused
  ABI entry instead of renaming it. Comment on
  [bitchill-monitoring#10](https://github.com/BitChillRSK/bitchill-monitoring/issues/10) and
  [swapper-bot#14](https://github.com/BitChillRSK/swapper-bot/issues/14): regenerate `abi.json`
  without that selector. `data-api` and `metrics-dashboard` do not name it.
