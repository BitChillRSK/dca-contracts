# R19 — Per-schedule purchase pause

Status: **not started** · Assigned: no · Optional/further-review: no

PR 39 of the relaunch stack. Stack on R48 (PR 38). Land before R18 packing and R9.

## Objective

Let a user pause and resume purchases for one DCA schedule without withdrawing its funds or deleting it.

## Background

Withdrawal/deletion is an exit, not a pause. A DCA user may want to keep funds in the selected route while temporarily stopping buys. The state belongs to the schedule and must be part of the layout before R18 packs the final struct.

This pause is user-owned and affects purchases only. R48 is the separate governance-owned deposit circuit breaker (`setDepositsPaused`, per `(token, routeIndex)`).

## Open product decisions

**none** — one `setSchedulePaused(..., bool paused)` mutator. Paused schedules may still receive deposits, change amount/period, withdraw, withdraw interest/rBTC, or be deleted.

## Scope

- [ ] Add `paused` to `DcaDetails`, defaulting false on creation.
- [ ] Add a nonReentrant, schedule-id-validated `setSchedulePaused(token, scheduleIndex, scheduleId, paused)` and a canonical event.
- [ ] `buyRbtc` is already gone. `batchBuyRbtc` reverts a named error if any named schedule is paused; no purchase timestamp/balance/handler state changes survive.
- [ ] Repeating the current pause state is an idempotent no-op with no event.
- [ ] Test pause/resume, swapper rejection, stale index/id, unchanged access to every user exit/config path, and swap-pop identity.

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

- [ ] Only the schedule owner can change pause state.
- [ ] A paused schedule cannot be purchased, including through the batcher path.
- [ ] User exits and management remain available.
- [ ] The new field/event are present before R18/R9.
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Invariant 6 covers the new mutator.
- [ ] Batch atomicity and swap-pop identity are tested.
- [ ] No unrelated schedule behavior changes.

## ABI / deploy / cutover impact

- ABI: `DcaDetails` gains `paused`; new setter/event/error.
- Scripts: none; new schedules start active.
- Cutover: frontend and bot must read/filter pause state; frontend issue required.
