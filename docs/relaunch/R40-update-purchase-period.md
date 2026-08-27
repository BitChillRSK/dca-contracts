# R40 — `updatePurchasePeriod` and previous/new event

Status: **not started** · Assigned: no · Optional/further-review: no

**Must land before R9 (ABI freeze).**

## Objective

Rename `setPurchasePeriod` to `updatePurchasePeriod` and emit both the previous period and the new one, so indexers and ops messages can show a change without reconstructing the last log.

## Background

R34 kept intent-specific mutators named `setPurchaseAmount` / `setPurchasePeriod`. This PR revisits **only** the period setter: the useful half is the previous value in the event; `update*` reads as a change, not a first write.

`DcaManager__PurchasePeriodSet` currently indexes `purchasePeriod`. R9 forbids indexing periods. This PR must **not** index previous or new period, so R9 does not have to un-index a brand-new event.

`setPurchaseAmount` stays. Combined amount+period edits remain two transactions.

Decided 2026-08-27: **rename + previous/new**. Do not keep the old selector as an alias (R34: no dual-ABI window).

## Open product decisions

**none**.

## Scope

- [ ] `DcaManager.setPurchasePeriod` → `updatePurchasePeriod`. Same args, same checks, invariant 6 (`nonReentrant`) unchanged.
- [ ] Replace `DcaManager__PurchasePeriodSet(user indexed, scheduleId indexed, purchasePeriod indexed)` with
      `DcaManager__PurchasePeriodUpdated(address indexed user, bytes32 indexed scheduleId, uint256 previousPeriod, uint256 newPeriod)`.
      Do not index `previousPeriod` or `newPeriod`.
- [ ] `IDcaManager` natspec: arguments are the new period; the event carries both.
- [ ] Update tests, fuzz wrappers, and checked-in consumers.

## Out of scope

- [ ] Renaming `setPurchaseAmount` or its event.
- [ ] R9 un-indexing of other events.
- [ ] Packing, pause, or changing how `_validatePurchasePeriod` works.

## Files likely touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- `test/unit/DcaConfigurationTest.t.sol`, `test/unit/DcaScheduleTest.t.sol`, and any other `setPurchasePeriod` call site the compiler lists

## Required tests

Targeted: `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-contract DcaConfigurationTest -vv` (and `DcaScheduleTest`). Then `make check`.

- `updatePurchasePeriod` writes the new period and emits `previousPeriod` equal to the value before the call.
- First change after create: previous is the period passed to `createDcaSchedule`.
- Invalid period / wrong schedule id still revert as today.
- No `setPurchasePeriod` selector remains.

Fork: no new assertions. Still run both fork lanes before push.

## Success criteria

- [ ] Only `updatePurchasePeriod` remains; event has previous and new, neither indexed.
- [ ] Frontend issue opened (`AGENTS.md` **Frontend follow-up**).
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (invariant 6 still on this mutator).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: selector change `setPurchasePeriod` → `updatePurchasePeriod`; event rename and layout change (adds `previousPeriod`, drops `indexed` on the period).
- Scripts: none unless a script called the old setter.
- Cutover: **Frontend follow-up required.** Search `bitChillRSK/front-end` and open or update an issue. The app still has `setPurchasePeriod` from R34. Indexers that decoded `PurchasePeriodSet` must switch.
