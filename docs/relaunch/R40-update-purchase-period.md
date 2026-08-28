# R40 — `updatePurchaseAmount` / `updatePurchasePeriod` and previous/new events

Status: **done** · Assigned: yes (PR 37 / [#87](https://github.com/BitChillRSK/dca-contracts/pull/87)) · Optional/further-review: no

PR 37 of the relaunch stack. Stack on R41 (PR 36). **Must land before R9 (ABI freeze).**

## Objective

Rename `setPurchaseAmount` → `updatePurchaseAmount` and `setPurchasePeriod` → `updatePurchasePeriod`, and have each emit both the previous value and the new one, so indexers and ops messages can show a change without reconstructing the last log.

## Background

R34 kept intent-specific mutators named `setPurchaseAmount` / `setPurchasePeriod`. Both only ever edit a schedule that already exists — the first amount and period are written by `createDcaSchedule` — so `update*` reads correctly and `set*` does not, and in both cases the useful half of the event is the previous value.

`DcaManager__PurchaseAmountSet` and `DcaManager__PurchasePeriodSet` currently index the amount and the period. R9 (invariant 4) forbids indexing amounts and periods. This PR must **not** index previous or new on either event, so R9 does not have to un-index two brand-new events.

Combined amount+period edits remain two transactions (R34 decision; `updateDcaSchedule` stays deleted).

Decided 2026-08-27: rename + previous/new for the period setter. Extended 2026-08-28 (human): apply the identical treatment to the amount setter — the two mutators are symmetric and splitting them across PRs would break the ABI twice and leave one half of the surface reading `set*`. Do not keep the old selectors as aliases (R34: no dual-ABI window).

## Open product decisions

**none**.

## Scope

- [x] `DcaManager.setPurchaseAmount` → `updatePurchaseAmount`. Same args, same checks (`_validatePurchaseAmount` against the schedule's current `tokenBalance`), invariant 6 (`nonReentrant`) unchanged.
- [x] `DcaManager.setPurchasePeriod` → `updatePurchasePeriod`. Same args, same checks (`_validatePurchasePeriod`), invariant 6 (`nonReentrant`) unchanged.
- [x] Replace `DcaManager__PurchaseAmountSet(user indexed, scheduleId indexed, purchaseAmount indexed)` with
      `DcaManager__PurchaseAmountUpdated(address indexed user, bytes32 indexed scheduleId, uint256 previousAmount, uint256 newAmount)`.
      Do not index `previousAmount` or `newAmount`.
- [x] Replace `DcaManager__PurchasePeriodSet(user indexed, scheduleId indexed, purchasePeriod indexed)` with
      `DcaManager__PurchasePeriodUpdated(address indexed user, bytes32 indexed scheduleId, uint256 previousPeriod, uint256 newPeriod)`.
      Do not index `previousPeriod` or `newPeriod`.
- [x] `IDcaManager` natspec: arguments are the new value; each event carries both.
- [x] Update tests, fuzz wrappers, and checked-in consumers.

## Out of scope

- [ ] Reviving `updateDcaSchedule` or any combined amount+period mutator.
- [ ] `DcaManager__TokenMinPurchaseAmountSet` and the other owner-only setters (genuine first writes; R9 handles their indexing).
- [ ] R9 un-indexing of other events.
- [ ] Packing, either pause feature, or changing how `_validatePurchaseAmount` / `_validatePurchasePeriod` work.

## Files likely touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- `test/unit/DcaConfigurationTest.t.sol`, `test/unit/DcaScheduleTest.t.sol`, `test/unit/RbtcPurchaseTest.t.sol`,
  `test/unit/PurchaseUniswapSettingsTest.sol`, `test/ai-generated/unit/DcaManagerEdgeCasesTest.t.sol`,
  `test/ai-generated/fuzz/Handler.t.sol`, and any other call site the compiler lists

## Required tests

Targeted: `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-contract DcaConfigurationTest -vv` (and `DcaScheduleTest`). Then `make check`.

- `updatePurchaseAmount` writes the new amount and emits `previousAmount` equal to the value before the call.
- `updatePurchasePeriod` writes the new period and emits `previousPeriod` equal to the value before the call.
- First change after create: previous is the amount/period passed to `createDcaSchedule`.
- Invalid amount (below the minimum, above the balance) / invalid period / wrong schedule id still revert as today.
- No `setPurchaseAmount` or `setPurchasePeriod` selector remains.

Fork: no new assertions. Still run both fork lanes before push.

## Success criteria

- [x] Only `updatePurchaseAmount` and `updatePurchasePeriod` remain; each event has previous and new, neither indexed.
- [x] Frontend issue opened (`AGENTS.md` **Frontend follow-up**).
- [x] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (invariant 6 still on both mutators; invariant 4 satisfied by the new events).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: selector changes `setPurchaseAmount` → `updatePurchaseAmount` and `setPurchasePeriod` → `updatePurchasePeriod`; both events renamed and re-laid out (adds the previous value, drops `indexed` on the changed value).
- Scripts: none unless a script called one of the old setters.
- Cutover: **Frontend follow-up required.** Search `bitChillRSK/front-end` and open or update an issue. The app still has `setPurchaseAmount` / `setPurchasePeriod` from R34. Indexers that decoded `PurchaseAmountSet` / `PurchasePeriodSet` must switch (`bitchill-monitoring` `abi.json`, and `data-api` if it reads either).
