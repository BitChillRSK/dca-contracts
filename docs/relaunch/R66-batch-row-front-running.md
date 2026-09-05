# R66 — A batch row can be reverted or definanced from under it before the tick lands

Status: **not started** · Assigned: no · Optional/further-review: no

## Objective

A batch row is checked against a schedule's *current* on-chain state, but the swapper composed the
batch against a snapshot that can be one block stale. Close the gap so that one row's owner — acting
either by accident or adversarially, in a transaction that lands after the bot's query and before the
bot's transaction — can neither revert every other row in the same batch nor silently weaken the
slippage bound every row in the batch relies on.

## Background

Found during review of [R64](./R64-batch-calldata-and-schedule-keying.md) (PR
[#119](https://github.com/BitChillRSK/dca-contracts/pull/119)), while checking whether removing the
per-row staleness guard changed anything about slippage. It did — see the second finding below — but
the underlying front-runnable-batch-row hazard is older than R64 and older than this relaunch plan. It
is documented here as its own item rather than folded into #119, so that PR stays scoped to the
calldata/keying redesign it was opened to test.

`_batchBuyRbtc` ([`DcaManager.sol:513`](../../src/DcaManager.sol#L513)) validates and debits every row
of one handler's batch before calling the handler once. Any revert inside
`_rBtcPurchaseChecksEffects` ([`DcaManager.sol:661`](../../src/DcaManager.sol#L661)) unwinds every
prior row's debit in the same batch, and `batchBuyRbtcAcrossHandlers`
([`DcaManager.sol:272`](../../src/DcaManager.sol#L272)) loops `_batchBuyRbtc` with no per-handler
isolation, so one handler's revert also unwinds every earlier handler's batch in the same call. A
schedule's owner controls several state transitions that flip that function from success to revert,
and can fire one in the block before the swapper's transaction lands:

| Owner action, front-run into the tick | Reverts via |
|---|---|
| `setSchedulePaused(token, id, true)` | `DcaManager__SchedulePaused` |
| `withdrawToken` below the row's `purchaseAmount` | `DcaManager__ScheduleBalanceNotEnoughForPurchase` |
| `deleteDcaSchedule` | `DcaManager__InexistentSchedule` |
| `updatePurchasePeriod` pushing the next-due date forward | `DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed` |
| `updatePurchaseAmount` down, shrinking the batch's total input | `PurchaseRbtc__BelowSwapperMinimum` (aggregate `minRbtcOut` no longer clears) |

A sixth transition does not revert, and is the sharper problem:

| Owner action | Consequence |
|---|---|
| `updatePurchaseAmount` **up** | The row spends more than the swapper quoted, but `batch.minRbtcOut` is forwarded unchanged (`DcaManager.sol:535`) as an **absolute** rBTC figure. It was sized against the old, smaller input, so it no longer represents the tolerance the swapper intended for the new, larger one. The purchase can complete inside a materially worse execution price than quoted and still clear the stale absolute minimum. |

The first five rows are not novel to this batch design: they exist in the pre-relaunch live protocol
today, and none of them requires an adversary — any user pausing, withdrawing, or editing a schedule
in the same block as a scheduled tick reverts every other user's purchase in that batch by accident.
That is a liveness bug on its own. The sixth is a genuine slippage-protection gap: R64 replaced a
staleness guard that reverted a stale row (`PurchaseAmountMismatch`, pre-R64) with nothing that
constrains a purchase-amount increase, and the PR's claim that "nothing about slippage depended on
the removed guard" is too strong given this case.

Confirmed by reproduction during the R64 review (not committed to this branch): doubling a schedule's
purchase amount before the tick let the purchase complete at a materially worse rate than the fresh
quote while still clearing a `minRbtcOut` sized for the smaller, pre-edit amount; halving it reverted
the whole batch under the same pending minimum.

## Open product decisions

**Yes — the human should confirm the direction before implementation, not just the existence of the
bug.** Three candidate mechanisms, not mutually exclusive:

1. **Skip a bad row instead of reverting the batch.** Restructure `_rBtcPurchaseChecksEffects` (checks
   already precede effects, so this is a return-a-reason-code refactor, not a reordering) so
   `_batchBuyRbtc` can drop one un-purchasable row, compact the survivors, and emit a
   `DcaManager__PurchaseRowSkipped(token, scheduleId, reason)` event, reverting only when nothing in
   the batch survives. This removes the accidental-liveness failure (rows 1–4 above) entirely: a
   stranger's edit can no longer cost every other user their purchase that day.
2. **Bind the slippage floor to the amount actually spent, not an absolute quoted figure.**
   Change `minRbtcOut` semantics from an absolute rBTC amount to a minimum rate (rBTC wei per
   stablecoin unit, 18-decimal-scaled), applied by the handler to whatever it actually spends:
   `rate * totalStablecoinAmountToSpend / 1e18`. This is structurally identical to the existing oracle
   floor in `_getAmountOutLowerBound` ([`PurchaseUniswap.sol:365`](../../src/PurchaseUniswap.sol#L365)),
   which is already rate-shaped and already composes with the caller value as `max(...)`
   ([`PurchaseUniswap.sol:311`](../../src/PurchaseUniswap.sol#L311)) — so the two bounds continue to
   compose exactly as they do today. Do not scale the current absolute value by
   `actualInput / plannedInput` instead: `FeeHandler`'s fee rate is interpolated between
   `s_minFeeRate` and `s_maxFeeRate` across purchase-amount bounds
   ([`FeeHandler.sol:29`](../../src/FeeHandler.sol#L29)), so net spend is not proportional to gross
   input and a gross-proportional scale would be quietly inexact. A rate applied to the handler's own
   measured net spend has no such error.
3. **Pack the swapper's expected amount into the batch row and drop a row that no longer matches.**
   Even with (1) and (2), an inflated row is not a slippage problem anymore, but it is still a *size*
   problem: it can push the batch's aggregate input through a pool's depth and fail the *oracle* floor
   for the whole batch, which happens after row selection and so cannot be caught by skipping alone.
   Change `Batch.scheduleIds` (`uint64[]`) to something like `bytes32[] rows` packing
   `(uint64 scheduleId, uint96 expectedPurchaseAmount)`, and drop (skip, per (1)) a row whose expected
   amount no longer matches the schedule's stored one. A `uint64` array element already occupies a
   full 32-byte ABI word, so packing a `uint96` alongside it costs only the zero→non-zero calldata
   bytes — roughly 110 gas/row on Rootstock pricing, not a second word. This is an ABI change to
   `Batch` and to the off-chain swapper bot that builds it.

Also open: whether `batchBuyRbtcAcrossHandlers` should isolate one handler's revert from the others
(a genuine venue failure on route A currently blocks route B too). This is a separate question from
the per-row hazard above, needs a try/catch around an external call, and the current all-or-nothing
behavior is documented as deliberate at
[`IDcaManager.sol:327`](../../src/interfaces/IDcaManager.sol#L327) — raise it to the human rather than
deciding it silently inside this item.

## Scope

- [ ] Whatever subset of (1)/(2)/(3) above the human approves.
- [ ] Update `Batch` NatSpec and any invariant list in `AGENTS.md` that describes today's
      all-or-nothing row behavior.
- [ ] Consumer follow-up: swapper-bot (batch composition and any new skipped-row event), monitoring
      (alert shape if `DcaManager__PurchaseRowSkipped` is added), and any repo that encodes `Batch` if
      its shape changes under (3).

## Out of scope

- [ ] Cross-handler isolation in `batchBuyRbtcAcrossHandlers` — raise as a separate open question to
      the human; do not fold a try/catch redesign into this item without an explicit decision.
- [ ] Any change to the MoC route (no pool, no rate-based floor to apply — see
      [`IDcaManager.sol:53`](../../src/interfaces/IDcaManager.sol#L53)) beyond what (1) already gives
      it for free.
- [ ] Re-opening R64's keying/calldata decision. This item assumes R64's shipped shape
      (`mapping(address token => mapping(uint64 scheduleId => DcaSchedule))`) as its baseline.

## Files likely touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- `src/PurchaseRbtc.sol`, `src/interfaces/IPurchaseRbtc.sol`
- `src/PurchaseUniswap.sol` (if the rate-based floor composition changes), `src/PurchaseMoc.sol`
- Every test/fuzz caller that constructs `IDcaManager.Batch` or calls the handler ABI directly

## Required tests

- A schedule paused, withdrawn-from, deleted, or amount-decreased in the block before the tick no
  longer reverts any other row in the same batch (once (1) ships).
- A schedule's purchase amount increased in the block before the tick either drops that row (once (3)
  ships) or is bound by a floor that reflects the amount actually spent, not the stale quoted one
  (once (2) ships) — reproduce the doubling scenario from this item's Background and assert the
  post-fix behavior.
- The oracle floor and the caller-supplied floor continue to compose as `max(...)` and remain
  independently testable, per R51's existing test shape.
- `batchBuyRbtcAcrossHandlers` behavior for a skipped-to-empty single-handler batch (does it skip that
  handler or revert the whole call — decide and test).

## Success criteria

- [ ] No schedule owner's own state change — benign or adversarial — can prevent any other schedule's
      purchase in the same tick.
- [ ] The slippage bound applied to a purchase reflects the amount actually spent on that purchase,
      not a snapshot taken before an intervening edit.
- [ ] No open product decisions remain unresolved in this file once implementation starts.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] `AGENTS.md` invariants updated if this changes documented all-or-nothing batch behavior.
- [ ] Consumer issues opened/updated for every affected repo in the same turn as the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: depends on which of (1)/(2)/(3) is approved. (1) adds an event. (2) changes `minRbtcOut`
  semantics without changing its type (still `uint256`, still the final `Batch` field) but is a
  behavior change every consumer computing it must know about. (3) changes `Batch.scheduleIds` from
  `uint64[]` to a packed `bytes32[]`, which changes both DcaManager purchase selectors.
- Scripts: none expected.
- Cutover: the swapper bot must change how it composes a batch under (2) and, if approved, (3). Open
  or update `swapper-bot#7` (already carries R64-era context) and any monitoring issue that decodes
  `minRbtcOut` or the batch row shape.
