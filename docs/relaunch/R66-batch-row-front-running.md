# R66 — A batch row can be reverted or definanced from under it before the tick lands

Status: **assigned** · Assigned: yes · Optional/further-review: no

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

## Decided (2026-09-05)

All three candidate mechanisms ship together, plus a scope correction on MoC. Recorded here before any
Solidity changed, per the repo's spec-before-code rule.

1. **Skip a bad row instead of reverting the batch.** `_rBtcPurchaseChecksEffects` splits into a
   check-only pass and an effects pass. `_batchBuyRbtc` runs checks for every row before writing
   anything: an ineligible row (deleted, paused, balance short, period not elapsed) or an
   expected-amount mismatch (mechanism 3) is skipped and reported via
   `DcaManager__PurchaseRowSkipped(token, scheduleId, reason)`; only rows that pass every check get
   their storage effects applied and are forwarded to the handler. Storage remains the sole authority
   for the buyer and the amount actually spent — skipping never substitutes a caller-supplied value for
   either. A row naming a schedule of a different route (`RouteIndexMismatch`) is not owner-triggered —
   no setter can move a schedule's route — so it stays a hard revert of the whole batch: that is a
   swapper-side composition error, not a front-run to tolerate.

   If every row in a submitted batch is skipped, `_batchBuyRbtc` emits the skip events and returns
   without calling the handler, in both `batchBuyRbtc` and each element of
   `batchBuyRbtcAcrossHandlers` — a genuinely empty *input* array (`batch.scheduleIds`/`rows` of length
   zero) still reverts `DcaManager__EmptyBatchPurchaseArrays`, since that is malformed swapper input,
   not a filtered-down live batch. This also answers the "Required tests" question below:
   `batchBuyRbtcAcrossHandlers` does not revert the whole call when one handler's batch empties out; it
   simply continues to the next handler, because the emptied batch no longer reverts on its own.

2. **Bind the slippage floor to the amount actually spent, not an absolute quoted figure.** The `Batch`
   field (and the matching `IPurchaseRbtc.batchBuyRbtc` / `PurchaseRbtc` internals) is renamed
   `minRbtcOut` → `minRbtcOutRate`: rBTC wei per **raw** stablecoin unit (the token's own decimals, not
   USD-normalized), scaled by `1e18`. The shared check in `PurchaseRbtc.batchBuyRbtc` becomes
   `requiredMin = Math.mulDiv(minRbtcOutRate, totalStablecoinAmountToSpend, 1e18, Math.Rounding.Ceil)`
   against the measured `totalPurchasedRbtc`, using the actual post-fee net spend rather than a
   pre-computed absolute figure — this is what closes the staleness gap, since the amount the rate is
   applied to is measured after the current tick's retrieval, not planned before it. Rounding the
   required minimum **up** means the floor is never accidentally weaker than configured. `0` still
   disables the check.

   `minRbtcOutRate` is threaded down into `_purchaseRbtc` (replacing the old absolute `minRbtcOut`
   parameter) so `PurchaseUniswap` derives its own absolute `amountOutMinimum` from the same rate
   against the same actual `stablecoinAmount` it is about to swap, composing with the existing oracle
   floor exactly as today: `max(amountOutLowerBound, Math.mulDiv(minRbtcOutRate, stablecoinAmount, 1e18,
   Ceil))`. A Uniswap purchase that fails this bound now reverts inside the router call with the
   pre-existing Uniswap revert path; the shared post-hoc check in `PurchaseRbtc` is then a redundant
   but harmless second gate for that route, and the *only* gate for MoC (see the scope correction
   below). Both 6-decimal and 18-decimal stablecoins are covered by the same formula — the rate's
   numeric value differs by token, decided off-chain by whoever composes the batch, but the on-chain
   scaling is decimal-agnostic (always `/1e18` against the token's raw units), so `PurchaseRbtc` needs
   no per-token decimals lookup.

3. **Pack the swapper's expected amount into the batch row.** `Batch.scheduleIds` (`uint64[]`) becomes
   `Batch.rows` (`bytes32[]`), each row packing `(uint64 scheduleId, uint96 expectedPurchaseAmount)`
   (scheduleId in the high 64 bits, expectedPurchaseAmount in the low 96, top 96 bits zero). A row whose
   `expectedPurchaseAmount` no longer matches the schedule's stored `purchaseAmount` is skipped under
   mechanism (1) rather than purchased at a size the swapper never saw. This is the piece that stops an
   inflated row from pushing the batch's aggregate input through a pool's depth: mechanism (2) alone
   only bounds price, not size.

**Scope correction — MoC is in scope for the caller-rate check.** The original open-decisions text
excluded "any change to the MoC route" because MoC has no pool and so no rate-shaped *oracle* floor to
compose with. That reasoning does not extend to the caller-supplied `minRbtcOutRate` check itself:
`PurchaseMoc._purchaseRbtc` already ignores `minRbtcOut` entirely today, and the shared check this item
adds lives in `PurchaseRbtc.batchBuyRbtc`, above both routes — applying it uniformly is not a change to
MoC's redemption mechanism, only to whether the caller's floor is enforced on it at all. It should be:
a swapper-composed MoC batch is exactly as exposed to a mid-flight amount increase as a Uniswap one, and
the pre-R66 code already lets a caller pass a nonzero `minRbtcOut` that MoC silently drops. AGENTS.md's
`Batch.minRbtcOut` natspec ("A MoC route has no floor to compose with... leaving no slippage surface for
a floor to guard") is corrected by this PR: MoC has no *oracle* floor, but it is not exempt from the
caller's own floor.

**Deferred — cross-handler isolation.** Whether `batchBuyRbtcAcrossHandlers` should isolate one
handler's revert from the others remains its own open question, raised but not decided here (see **Out
of scope**). This item's skip-based row filtering already removes most of the *pressure* for that
question — a single owner's stale edit no longer forces a revert at all — but a genuine venue failure
(oracle down, router revert) is untouched and still takes down every earlier handler in the same call.

## Decided (2026-09-05, second pass): the funding shortfall closes the same gap

Review of the first pass found that mechanisms (1)–(3) do not actually deliver the guarantee they
claim. Every check they added reads the **schedule**, and a schedule's principal is not the same book
as the funds behind it. A lending handler credits shares rounded down on deposit and debits them
rounded up on spend, so a schedule at its tail — balance exactly one purchase — can want one share more
than its owner holds; and because shares are pooled per buyer rather than per schedule, one schedule's
withdrawal moves what another one's purchase can spend. R43 knew about this and decided to keep it as a
batch revert, on the grounds that the swapper filters the tail before batching. R66's threat model is
exactly what breaks that argument: **the owner reaches this state after the bot's snapshot**, and the
schedule balance, the purchase amount and the due date the manager checks are all still precisely what
was quoted. So one buyer's sub-wei rounding dust reverted every other buyer's purchase in the tick.

**How reachable it is, measured rather than asserted.** Accrued interest covers the rounding by orders
of magnitude — one second of it is worth ~4×10¹³ shares against a gap of one or two — so no user meets
this by accident while their position is earning. It is the *owner* who decides when that cushion goes
away: `withdrawAllAccumulatedInterest` sweeps it to a rounding remainder, and each
withdraw-and-redeposit round trip after that burns one more share (the withdrawal's debit rounds up,
the deposit's mint rounds down) while putting the principal straight back, so the ledger the manager
sees never moves. On the mock lanes that is one call plus zero round trips on LayerBank and four on
Sovryn and Tropykus — all of which a contract owning the schedules does in one transaction ahead of the
tick, for gas and no profit. `test/unit/BatchRowFundingSkipTest.t.sol` runs exactly that sequence.

The schedule-creation variant is **not** reachable: BitChill's off-chain indexer only reads finalized
blocks (12 on Rootstock), so a schedule created in the tick's own block is never in the batch it would
front-run.

**The decision.** A row the handler cannot fund is a **skip**, on the same footing as the five schedule
states already skipped, with a sixth reason `FundingInsufficient`. This supersedes R43's batch-revert
decision for batches. It does **not** clamp, forgive or subsidise the shortfall: the row keeps its
principal, buys nothing, pays no fee and is credited no rBTC, and the owner's exits are unchanged
(withdraw the rest, deposit more, or lower the purchase amount). Clamping stays rejected for the reason
R43 gave and one more: a short row would still carry its original weight through the allocation, so it
would be paid for out of the other buyers' stablecoin.

Three consequences follow, and they are the whole cost of the decision:

1. **The manager cannot know which rows funded until the handler tells it**, because the funds are the
   handler's book, pooled per buyer. So `IPurchaseRbtc.batchBuyRbtc` returns `uint256[] unfundedRows` —
   the ascending indexes of the rows it could not fund, and an empty array in the usual case where it
   funded all of them — and `_batchBuyRbtc` becomes *check every row, call the handler once, then debit
   the rows that funded*. Nothing is written before the call: an optimistic debit would have to be taken
   back, and a dropped row would have consumed a period it never bought in. Handlers filter in place,
   before any fee is charged or anything bought, and pass zero rows over untouched, so no array is ever
   compacted and the indexes line up on both sides.
2. **Both purchase entry points take `nonReentrant`.** Schedule writes now follow a handler call, so the
   exception invariant 6 carved out for the purchase paths is gone. The guard is what keeps an owner
   mutation, or a second purchase, out of the window between the checks and the commit.
3. **A batch's rows must be in strictly increasing schedule-id order** (`DcaManager__BatchRowsNotSorted`,
   naming the row that broke it). With the checks no longer interleaved with the effects, the same
   schedule listed twice would pass twice and buy twice; sorting makes that unrepresentable for one
   comparison per row and gives a batch a canonical order. Skipped rows hold their place in it. This is a
   swapper composition rule, not an owner-triggerable state, so it reverts like the route mismatch does.
   Across `batchBuyRbtcAcrossHandlers` no rule is needed: each inner batch commits before the next one's
   checks run, so a repeat in a later batch reads the updated timestamp and skips as `PeriodNotElapsed`.

Two smaller things fall out of the same pass. Lending now sums each row's own rounded-up share debit
instead of slicing one aggregate figure pro rata, which makes the shares redeemed exactly the shares
taken off the buyers — the old two-stage rounding asked them for slightly more than it burned. And
`TokenLending__InsufficientShares` and `IdleErc20Handler__InsufficientIdleBalance` are removed: the
batch path was the only thrower of either.

**Gas.** `test/gas/R64BatchGasBenchmark.t.sol` design A is `src/DcaManager` on the stub handler; running
it on this branch and on the parent commit gives the operator's bill for one steady-state tick,
execution plus Rootstock calldata, with nothing skipped:

| rows | before | after | Δ | Δ % |
|---:|---:|---:|---:|---:|
| 1 | 30,381 | 36,377 | +5,996 | +19.7% |
| 5 | 88,625 | 93,538 | +4,913 | +5.5% |
| 10 | 167,069 | 173,126 | +6,057 | +3.6% |
| 50 | 794,802 | 810,020 | +15,218 | +1.9% |
| 200 | 3,152,505 | 3,202,077 | +49,572 | +1.6% |

Calldata is unchanged — the `Batch` shape is the same. **5,207 gas of the fixed cost is `nonReentrant`
alone**, measured by removing only that modifier; the rest is ~790 fixed and ~220 a row (the sort
comparison, the commit pass, and the handler's filter pass). Returning the unfunded-row indexes rather
than echoing a per-row answer is what keeps the marginal cost at ~220 instead of ~410 a row. The guard's
5,207 is a cold storage slot written and cleared; OpenZeppelin's `ReentrancyGuardTransient` would make
it ~200 on this Cancun target and would pay off on every user call too, but swapping the protocol's
reentrancy primitive is its own change and is deliberately **not** in this PR.

Reproduce with `forge test --match-path 'test/gas/R64BatchGasBenchmark.t.sol' -vv`, here and on the
parent commit, and read row A.

<details>
<summary>Original candidate framing (superseded by the Decided section above)</summary>

Three candidate mechanisms, not mutually exclusive:

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

</details>

## Scope

- [x] All of (1), (2), and (3) above.
- [x] A row the handler cannot fund from the buyer's own book is skipped rather than reverting the
      batch, with a sixth skip reason `FundingInsufficient`. Supersedes R43's batch-revert decision;
      `docs/relaunch/R43-dex-path-review.md` updated to point here.
- [x] `nonReentrant` on both purchase entry points, and strictly increasing row ids
      (`DcaManager__BatchRowsNotSorted`) — both consequences of committing schedule debits after the
      handler result. Invariant 6 in `AGENTS.md` updated.
- [x] Apply the caller-rate check (2) to the MoC route as well as Uniswap — see the scope correction
      above.
- [x] Update `Batch` NatSpec and invariant 9 in `AGENTS.md`, which stated "a batch row is one
      `uint64` and nothing else" and "do not add a per-row amount back as a staleness guard" — both are
      superseded by mechanism (3)'s packed row. Invariant 8's "its rows are ids" corrected in passing.
- [x] Consumer follow-up: swapper-bot (`Batch.rows` packing, `minRbtcOutRate` semantics, and the new
      skipped-row event), monitoring (alert shape for `DcaManager__PurchaseRowSkipped`), and any repo
      that encodes `Batch` off-chain.

## Out of scope

- [ ] Cross-handler isolation in `batchBuyRbtcAcrossHandlers` — deferred, see above. Keep the loop
      atomic across handlers: a genuine handler-call failure (not a skipped-to-empty batch, which no
      longer reverts) still unwinds every earlier handler in the same `batchBuyRbtcAcrossHandlers` call.
- [ ] Re-opening R64's keying/calldata decision. This item assumes R64's shipped shape
      (`mapping(address token => mapping(uint64 scheduleId => DcaSchedule))`) as its baseline.

## Files likely touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol` — row decode/skip loop, `Batch.rows`,
  `DcaManager__PurchaseRowSkipped`.
- `src/PurchaseRbtc.sol`, `src/interfaces/IPurchaseRbtc.sol` — `minRbtcOut` → `minRbtcOutRate`,
  rate-against-actual-spend check shared by every route.
- `src/PurchaseUniswap.sol`, `src/interfaces/IPurchaseUniswap.sol` — swap-time `amountOutMinimum`
  derived from the same rate against the same actual `stablecoinAmount`.
- `src/PurchaseMoc.sol` — no redemption-mechanism change; confirms it now receives the same shared
  rate check as every other route through `PurchaseRbtc`.
- `src/StablecoinSource.sol`, `src/LendingErc20Handler.sol`, `src/idle/IdleErc20Handler.sol`,
  `src/interfaces/ITokenLending.sol`, `src/idle/IIdleErc20Handler.sol` — the funding hook filters rows
  and reports the ones it dropped; the two shortfall errors it used to throw are removed.
- `AGENTS.md` invariants 6 and 9; `docs/relaunch/R43-dex-path-review.md`.
- Every test/fuzz caller that constructs `IDcaManager.Batch` or calls the handler ABI directly (see the
  file list gathered during implementation for the full set).

## Required tests

- A schedule paused, withdrawn-from, deleted, or amount-decreased in the block before the tick is
  skipped with `DcaManager__PurchaseRowSkipped` and no longer reverts any other row in the same batch.
- A schedule's purchase amount increased in the block before the tick is skipped once its packed
  `expectedPurchaseAmount` no longer matches storage (mechanism 3), reproducing the doubling scenario
  from this item's Background and asserting it is skipped rather than purchased at the stale quote.
- `minRbtcOutRate` bound to actual net spend, tested on both a 6-decimal and an 18-decimal stablecoin.
- The oracle floor and the caller-supplied rate floor continue to compose as `max(...)` on the Uniswap
  route and remain independently testable, per R51's existing test shape.
- The MoC route now enforces a nonzero `minRbtcOutRate` (it previously ignored `minRbtcOut` entirely).
- A batch that skips every row emits every row's skip event, calls no handler, and does not revert;
  `batchBuyRbtcAcrossHandlers` continues to the next handler rather than reverting the whole call in
  that case. A batch submitted with a genuinely empty row array still reverts
  `DcaManager__EmptyBatchPurchaseArrays`.
- A genuine handler-level failure (not a skipped-to-empty batch) still unwinds every earlier handler in
  `batchBuyRbtcAcrossHandlers`, confirming cross-handler atomicity is unchanged.
- A buyer who starves their own funding between the swapper's snapshot and the tick loses that row and
  nobody else's: the bystander buys, the skipped row keeps its balance, timestamp, shares and rBTC, and
  pays no fee. The pre-mutation batch is asserted to work first, so the test cannot pass vacuously.
- `BatchTailScheduleTest`'s R43 pins are flipped, not deleted, as their own header asked: the tail row
  is skipped and a healthy buyer in the same batch still buys. Handler-level shortfall tests on all
  three lending leaves and both idle leaves assert the row is dropped, nothing is redeemed against it,
  and its book is untouched.
- Duplicate and descending rows revert `DcaManager__BatchRowsNotSorted`, including when the offending
  row would have been skipped anyway.

## Success criteria

- [x] No schedule owner's own state change — benign or adversarial — can prevent any other schedule's
      purchase in the same tick.
- [x] The slippage bound applied to a purchase reflects the amount actually spent on that purchase,
      not a snapshot taken before an intervening edit.
- [x] No schedule owner's own state change can prevent another schedule's purchase **through the
      funding book either**, not only through the schedule ledger.
- [x] The batch gas cost of that guarantee is measured against the parent commit and recorded above.
- [x] No open product decisions remain unresolved in this file once implementation starts.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] `AGENTS.md` invariant 9 updated for the packed row and the MoC scope correction, and invariant 6
      for the purchase-path guard.
- [ ] The gas table above reproduces on the reviewer's machine from both revisions.
- [ ] Consumer issues opened/updated for every affected repo in the same turn as the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: `Batch.scheduleIds` (`uint64[]`) → `Batch.rows` (`bytes32[]`, packed `(uint64 scheduleId, uint96
  expectedPurchaseAmount)`); `Batch.minRbtcOut` → `Batch.minRbtcOutRate` (still `uint256`, new units and
  semantics); `IPurchaseRbtc.batchBuyRbtc`'s `minRbtcOut` parameter renamed and reinterpreted the same
  way; new event `DcaManager__PurchaseRowSkipped(address indexed token, uint64 indexed scheduleId,
  uint8 reason)` with a sixth reason `FundingInsufficient`; new error
  `DcaManager__BatchRowsNotSorted(uint64 scheduleId)`. `IPurchaseRbtc.batchBuyRbtc` now returns
  `uint256[] unfundedRows`. `TokenLending__InsufficientShares` and
  `IdleErc20Handler__InsufficientIdleBalance` are removed. Both `batchBuyRbtc` and
  `batchBuyRbtcAcrossHandlers` selectors change.
- Log order: a handler's funding, fee and purchase logs now precede the manager's schedule-debit and
  timestamp logs for the same row, because the manager commits after the handler returns. Anything that
  reads a transaction's logs in order must be checked against that.
- Scripts: none expected.
- Cutover: the swapper bot must change how it composes a batch (pack `expectedPurchaseAmount` per row,
  compute `minRbtcOutRate` instead of an absolute quote-derived figure) and must handle
  `DcaManager__PurchaseRowSkipped` as an expected, non-error outcome rather than a call failure. It must
  additionally **sort each batch's rows by ascending schedule id and send no id twice**, or the batch
  reverts `DcaManager__BatchRowsNotSorted`; a skipped row still has to hold its place in that order.
  Monitoring gains the `FundingInsufficient` reason, loses the two removed errors, and must not depend
  on the previous cross-contract log order. Open or update `swapper-bot#7` (already carries R64-era
  context) and any monitoring issue that decodes `minRbtcOut`/`minRbtcOutRate` or the batch row shape.
