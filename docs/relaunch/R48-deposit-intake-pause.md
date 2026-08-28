# R48 — Per-route deposit intake pause

Status: **assigned** · Assigned: yes · Optional/further-review: no

PR 38 of the relaunch stack. Stack on R40 (PR 37). Land before user schedule pausing, packing, and R9.

## Objective

Give governance a narrow circuit breaker that stops new stablecoin inflows to one `(token, routeIndex)` while leaving purchases, withdrawals, interest withdrawal, and schedule deletion available.

## Background

After R46 the manager cannot redirect to another registry, and R13 assignments cannot be replaced. An incident in one lending market should therefore stop new exposure without freezing exits or unrelated routes. A global pause is too broad; an owner sweep or full protocol pause would violate the custody boundary.

## Open product decisions

**none** — pause deposit intake per token×route. Existing funds remain fully operable.

## Scope

- [x] Add owner-only `OperationsAdmin` pause state, setter, getter, event, and custom errors for a registered/assigned `(token, routeIndex)`.
- [x] `DcaManager.createDcaSchedule` and `depositToken` check the selected route before any token transfer and revert when intake is paused.
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

- ABI: new OperationsAdmin setter/getter/event/error and DcaManager pause error.
- Scripts: none; routes start unpaused.
- Cutover: frontend/backend must surface a blocked-deposit route without hiding withdrawals. Open/update the frontend issue in this PR.
