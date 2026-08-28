# R48 — Per-route deposit pause

Status: **PR [#88](https://github.com/BitChillRSK/dca-contracts/pull/88)** · Assigned: yes · Optional/further-review: no

PR 38 of the relaunch stack. Stack on R40 (PR 37). Land before user schedule pausing, packing, and R9.

## Objective

Give governance a narrow circuit breaker that stops new stablecoin deposits to one `(token, routeIndex)` while leaving purchases, withdrawals, interest withdrawal, and schedule deletion available.

## Background

After R46 the manager cannot redirect to another registry, and R13 assignments cannot be replaced. An incident in one lending market should therefore stop new exposure without freezing exits or unrelated routes. A global pause is too broad; an owner sweep or full protocol pause would violate the custody boundary.

## Open product decisions

**none** — pause deposits per token×route. Existing funds remain fully operable.

## Scope

- [x] Add owner-only `OperationsAdmin` pause state, setter, getter, event, and custom errors for a registered/assigned `(token, routeIndex)`.
- [x] `DcaManager.createDcaSchedule` and `depositToken` check the selected route before any token transfer and revert when deposits are paused.
- [x] Purchases, token/rBTC/interest withdrawals, schedule edits, and deletion do not consult this pause.
- [x] Pausing one token or route does not affect another; unpausing restores deposits.
- [x] Preserve invariant 6 on both schedule-writing entry points.

## Out of scope

- [ ] Pausing purchases (R19 is user-owned per-schedule pause).
- [ ] Freezing withdrawals, replacing handlers/admin, or sweeping funds.
- [ ] A global protocol pause or third-party protocol health oracle.

## Files likely touched

- `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol`
- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- DcaManager configuration/deposit and OperationsAdmin tests

## Required tests

Target route-admin and DcaManager deposit/create suites. Assert checks happen before transfer, only the named pair is blocked, every exit and an already-due purchase still works, then run `make check` and both fork lanes.

## Success criteria

- [x] Governance can stop only new inflows to one assigned route.
- [x] No pause state can block users from exiting or receiving already-purchased rBTC/interest.
- [x] Pause events/errors are ready for the later R9 indexing audit.
- [x] No open product decisions.

## Reviewer checklist

- [x] Matches **Scope**; nothing from **Out of scope**.
- [x] The pause is checked before external cash movement.
- [x] Protocol invariants in `AGENTS.md` still hold.
- [x] Tests in the PR match **Required tests**.

## ABI / deploy / cutover impact

- ABI: new OperationsAdmin setter/getter/event/error and DcaManager pause error. Named `setDepositsPaused` / `areDepositsPaused`, not "intake": R19's user-owned pause is `setSchedulePaused` and stops purchases, so "deposits" and "schedule" already separate the two without a qualifier.
- Scripts: none; routes start unpaused.
- Cutover: frontend/backend must surface a blocked-deposit route without hiding withdrawals. Open/update the frontend issue in this PR.
- **Ops runbook (multi-pair pause):** there is no atomic multi-route form. Closing a token across N routes is N Safe transactions, and `setDepositsPaused` reverts `OperationsAdmin__DepositsPauseUnchanged` on a pair that is already in the requested state. A "pause everything for this token" script must therefore **read `areDepositsPaused` per pair and skip the ones already paused**, or it will fail partway through on the second run of a partially-applied sweep — the likely shape of a depeg response, where one route is closed first and the rest follow. The revert is kept deliberately (it is what makes every emitted event a real transition, which R9 indexing and monitoring alerts rely on); the cost is that the ordering constraint lives in the runbook instead of the contract. Unpausing has the same shape in reverse.
