# R19 — Per-schedule purchase pause

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 39 of the relaunch stack. Stack on R48 (PR 38). Land before R18 packing and R9.

## Objective

Let a user pause and resume purchases for one DCA schedule without withdrawing its funds or deleting it.

## Background

Withdrawal/deletion is an exit, not a pause. A DCA user may want to keep funds in the selected route while temporarily stopping buys. The state belongs to the schedule and must be part of the layout before R18 packs the final struct.

This pause is user-owned and affects purchases only. R48 is the separate governance-owned deposit circuit breaker (`setDepositsPaused`, per `(token, routeIndex)`).

## Open product decisions

**none** — one `setSchedulePaused(..., bool paused)` mutator. Paused schedules may still receive deposits, change amount/period, withdraw, withdraw interest/rBTC, or be deleted.

## Scope

- [x] Add `paused` to `DcaDetails`, defaulting false on creation.
- [x] Add a nonReentrant, schedule-id-validated `setSchedulePaused(token, scheduleIndex, scheduleId, paused)` and a canonical event.
- [x] `buyRbtc` is already gone. `batchBuyRbtc` reverts a named error if any named schedule is paused; no purchase timestamp/balance/handler state changes survive.
- [x] Repeating the current pause state is an idempotent no-op with no event.
- [x] Test pause/resume, swapper rejection, stale index/id, unchanged access to every user exit/config path, and swap-pop identity.

## Out of scope

- [ ] Governance deposit pause (R48), global emergency pause, or third-party market pause detection.
- [ ] Automatically unpausing, scheduled pauses, or pausing withdrawals.
- [ ] Storage type narrowing/field reordering (R18).

## Files likely touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- DcaManager schedule/purchase tests and fuzz/invariant handlers

## Required tests

Run DcaSchedule, DcaManager purchase, and invariant suites. A paused row in a length-one and multi-row batch must revert atomically; deposits/config/exits must remain usable. Then `make check` and both fork lanes.

## Success criteria

- [x] Only the schedule owner can change pause state.
- [x] A paused schedule cannot be purchased, including through the batcher path.
- [x] User exits and management remain available.
- [x] The new field/event are present before R18/R9.
- [x] No open product decisions.

## Reviewer checklist

- [x] Matches **Scope**; nothing from **Out of scope**.
- [x] Invariant 6 covers the new mutator.
- [x] Batch atomicity and swap-pop identity are tested.
- [x] No unrelated schedule behavior changes.

## Measured cost, and why R18 follows immediately

The `paused` bool is appended to an unpacked `DcaDetails`, so it takes a seventh slot and
`_rBtcPurchaseChecksEffects` — which copies the whole struct to memory — reads one more cold slot
per batch row. Measured on `RbtcPurchaseTest` against the R48 base:

| Test | Base | R19 | Delta |
|---|---|---|---|
| `testSinglePurchase` | 304,203 | 307,788 | +3,585 |
| `testBatchPurchasesOneUser` (5 rows) | 2,369,851 | 2,446,343 | +76,492 |
| `testSeveralPurchasesWithSeveralSchedules` | 4,553,979 | 4,618,819 | +64,840 |

This lands on the **protocol-paid** purchase path, which `AGENTS.md` invariant 6 singles out as the
one place where a gas win is worth having — and it is roughly the same order as the ~2,300 gas that
invariant refuses to buy by weakening reentrancy protection. It is accepted here only because it is
temporary: R18 (PR 40, the next PR) packs `paused` into the slot holding `purchasePeriod`,
`lastPurchaseTimestamp`, and `routeIndex`, which removes the extra slot read. **The merge order is
load-bearing, not incidental** — shipping R19 without R18 behind it leaves a permanent per-row cost
on every batch the swapper pays for.

## Griefing surface: pause makes an existing batch DoS cheaper

One user pausing their own schedule reverts a batch carrying other users' schedules. The victims
keep their balance and timestamp, so this is a missed tick, not a loss.

This is not a new class. `updatePurchaseAmount` alone already reverts a whole batch identically, via
`DcaManager__PurchaseAmountMismatch`, and so does any withdrawal that drops a row below its purchase
amount. What R19 changes is the **price**: withdrawing or deleting costs the griefer their position,
and an amount edit changes their own DCA, whereas a pause is free, instant, and reversible.

Two consequences worth stating rather than discovering later:

- **The mitigation is entirely off-chain and racy.** The bot filters paused schedules at compose
  time; a pause landing between compose and execution still takes the tick down. Nothing on-chain
  prevents it, and R19 does not try to — per-row skipping would mean partial batches, which the
  batch design deliberately rejects.
- **R42 widens the blast radius.** The swapper batcher (PR 46) bundles several `batchBuyRbtc` calls
  all-or-nothing, so after R42 a single paused row takes down *every venue in the bundle*, not just
  its own token×route. [`R42-swapper-batcher.md`](./R42-swapper-batcher.md) records that atomicity as
  a deliberate trade; R19 raises its cost, so R42 should re-confirm the trade with pause in mind.

## ABI / deploy / cutover impact

- ABI: `DcaDetails` gains `paused`; new setter/event/error.
- Scripts: none; new schedules start active.
- Cutover: frontend and bot must read/filter pause state; frontend issue required.
