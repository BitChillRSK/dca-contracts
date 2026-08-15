# R2 — UTC purchase-period day boundary

Status: **in progress** · Assigned: yes · Optional/further-review: no

## Objective

Treat a schedule as eligible once the UTC calendar day of `lastPurchaseTimestamp + purchasePeriod` has started, and reject a protocol minimum period below one day, so the swapper can run at a fixed UTC time of day.

## Background

Eligibility today requires a full `purchasePeriod` of wall-clock seconds since `lastPurchaseTimestamp`. A first daily buy at 20:00 UTC blocks the next buy until 20:00 the following day.

Missed-period timestamp snap (`6335994`) already landed: after a gap, `lastPurchaseTimestamp` advances by `periodsElapsed * purchasePeriod`, not `1 * period`. **Keep that snap.** First purchase (`lastPurchaseTimestamp == 0`) still stamps `block.timestamp`.

R2 replaces the remaining strict-seconds check. Daily is the highest frequency BitChill will support; the one-day floor is both required by the UTC-day math (a sub-day period would round to 00:00 today and allow an immediate second buy) and the intended product maximum.

## Open product decisions

**none**

## Scope

- [x] In `DcaManager._rBtcPurchaseChecksEffects`, replace the strict `block.timestamp - last < purchasePeriod` check with UTC day-boundary eligibility:

  ```solidity
  uint256 currentDayStart = block.timestamp - (block.timestamp % 1 days);
  uint256 nextPurchaseDayStart =
      lastPurchaseTimestamp + purchasePeriod
      - (lastPurchaseTimestamp + purchasePeriod) % 1 days;
  if (lastPurchaseTimestamp != 0 && currentDayStart < nextPurchaseDayStart) {
      revert DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed(/* time until nextPurchaseDayStart */);
  }
  ```

  Keep the existing error. `timeRemaining` is seconds until `nextPurchaseDayStart` (`nextPurchaseDayStart - block.timestamp`).

- [x] Keep the `6335994` snap, aligned to UTC due days. Floor `periodsElapsed` at 1 so an early UTC-day buy still consumes a slot. If that wall-clock snap still leaves today's UTC day due (multi-period gap after a late-in-day `last`), consume one more period so a second buy the same day reverts:

  ```solidity
  if (lastPurchaseTimestamp == 0) {
      uint256 dayStart = block.timestamp - (block.timestamp % 1 days);
      lastPurchaseTimestamp = dayStart == 0 ? 1 : dayStart; // 0 stays "never purchased"
  } else {
      uint256 periodsElapsed = (block.timestamp - lastPurchaseTimestamp) / purchasePeriod;
      if (periodsElapsed == 0) periodsElapsed = 1;
      lastPurchaseTimestamp += periodsElapsed * purchasePeriod;
      uint256 nextDueTimestamp = lastPurchaseTimestamp + purchasePeriod;
      uint256 nextPurchaseDayStart = nextDueTimestamp - (nextDueTimestamp % 1 days);
      if (currentDayStart >= nextPurchaseDayStart) {
          lastPurchaseTimestamp += purchasePeriod;
      }
  }
  ```

  First purchase stamps 00:00 UTC of that day. Later purchases add whole periods from that midnight so a weekly schedule keeps its weekday after a gap. Floor / extra-period remain as guards. Actual execution time is the purchase transaction's `block.timestamp` (indexer / `PurchaseRbtc__RbtcBought` log), not this field.

- [x] Add modifier `validateMinPurchasePeriod`: revert if `minPurchasePeriod < 1 days`. Apply on `constructor` and `modifyMinPurchasePeriod`. New error on `IDcaManager` (e.g. `DcaManager__MinPurchasePeriodMustBeAtLeastOneDay`). User schedules still cannot go below `s_minPurchasePeriod` (`_validatePurchasePeriod` unchanged in spirit).

## Out of scope

- [ ] Fee model, R18 packing, R19 pause, R12/R13/optionals (PR 2 / later PRs).
- [ ] R7 / R11 / R14 (`createDcaSchedule` max check, one-purchase funding, accumulated-rBTC getters).
- [ ] Event reshaping, storage packing, pause.
- [ ] Handler / accounting / SIP-0094 work (R1, R20).
- [ ] `forge fmt` of existing files.
- [ ] Deploy broadcasts or live addresses.
- [ ] `dca-out-contracts`.

## Files likely touched

- `src/DcaManager.sol`
- `src/interfaces/IDcaManager.sol`
- `test/unit/RbtcPurchaseTest.t.sol`
- `test/unit/ModifiersTest.t.sol`
- `docs/relaunch/README.md` (assignment status)

Implementer may follow failing tests into `test/ai-generated/fuzz/Handler.t.sol` (owner `modifyMinPurchasePeriod` currently bounds down to `1 hours`) and other constructor/`modifyMinPurchasePeriod` call sites. Extra files belong in the PR write-up.

## Required tests

Commands (targeted first, then done-gate):

```bash
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus forge test --match-path test/unit/RbtcPurchaseTest.t.sol --match-path test/unit/ModifiersTest.t.sol
# If fuzz handler bound must change:
LENDING_PROTOCOL=tropykus SWAP_TYPE=mocSwaps forge test --match-contract InvariantTest
make check
```

(`forge test` does not take two `--match-path` flags; use `--match-contract RbtcPurchaseTest` / `ModifiersTest`, or one path per invocation.)

Behaviors to assert:

- First buy late in the UTC day → `lastPurchaseTimestamp` is 00:00 UTC of that day (not `block.timestamp`); next buy allowed at 00:00 UTC of the due day.
- Still reverts one second before 00:00 UTC of the due day.
- Same-block / same-day second buy still reverts (`testCannotBuyIfPeriodNotElapsed` keeps passing; update the error's `timeRemaining` to seconds until the due UTC day start).
- Weekly: allowed any time on the due UTC day, not only after the exact second.
- Owner cannot set `minPurchasePeriod` below 1 day (constructor + `modifyMinPurchasePeriod`). `1 days` remains valid.
- Existing `testLastPurchaseTimestampConsistencyWhenScheduleResumed`: gap snap still skips missed slots (not `1 * period`); expected `last` is the latest period whose UTC due day has started.
- Buy allowed by UTC-day but still before `last + period` wall-clock: timestamp advances by **one** period (`periodsElapsed` floor); same-day second buy reverts.
- Gap resume on the UTC start of the third due day (first buy 20:00, warp to day 3 00:00): `last` advances to the **third** period slot; same-day second buy reverts.

Fork tests: not required.

## Success criteria

- [x] Daily and weekly schedules can be executed at a consistent UTC time of day without waiting out a delayed previous run.
- [x] Protocol min cannot be set below 1 day (constructor and owner setter).
- [x] Missed-period snap (`6335994`) still holds; `periodsElapsed` floor of 1 plus a UTC-due-day extra period prevent same-day double-buy after an early UTC-day purchase **and** after a multi-period gap.
- [x] `testCannotBuyIfPeriodNotElapsed` still reverts.
- [x] Targeted tests above pass; `make check` passes.
- [x] Protocol invariants in `AGENTS.md` unchanged.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec does not change them).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies / failing-test fallout and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: new error `DcaManager__MinPurchasePeriodMustBeAtLeastOneDay`. Existing `DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed(uint256 timeRemaining)` kept; `timeRemaining` is now seconds until 00:00 UTC of the due day, not until `last + period` wall-clock. No function or event signature changes.
- Scripts: none. Deploy scripts already pass `MIN_PURCHASE_PERIOD = 1 days`.
- Cutover: swapper may run at a fixed UTC time once the due calendar day has started. `lastPurchaseTimestamp` is the UTC-day grid (first buy's 00:00, then whole periods), not execution time. Indexers should use `PurchaseRbtc__RbtcBought` plus the log's `block.timestamp` for purchase history. Do not include broadcast steps.
