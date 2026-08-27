# R46 — Pin DcaManager to its OperationsAdmin

Status: **not started** · Assigned: no · Optional/further-review: no

PR 33 of the relaunch stack. Stack on R45 (PR 32). Must precede handler-registry hardening and R9.

## Objective

Remove `DcaManager.setOperationsAdmin` and make the constructor-supplied `OperationsAdmin` immutable, so governance cannot redirect every live schedule to a replacement route registry.

## Background

R13 made routes add-only: upgrades use new indexes while old schedules keep resolving to the handlers that hold their funds. A mutable whole-registry pointer bypasses that model in one call and can redirect every schedule and swapper check. This is a fresh deployment, so there is no migration value to preserve.

One-shot setters still leave a dangerous deployment state and a permanent selector. Constructor pinning is the smallest complete rule.

## Open product decisions

**none** — remove the setter; constructor-pin an immutable admin. Do not replace it with one-shot mutation.

## Scope

- [ ] Change `s_operationsAdmin` to an immutable constructor value and reject a zero/non-contract address.
- [ ] Remove `setOperationsAdmin` and `DcaManager__OperationsAdminUpdated` from implementation and interface.
- [ ] Keep `getOperationsAdminAddress()` as the canonical read.
- [ ] Update tests that exercised owner-only mutation to assert the selector is absent and the constructor value never changes.
- [ ] Re-measure DcaManager runtime and storage layout; record the removed storage slot.

## Out of scope

- [ ] Changing the add-only route registry or handler assignment rules (R47).
- [ ] Replacing OperationsAdmin through a proxy, indirection, or delegatecall.
- [ ] User-position migration.

## Files likely touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- `test/unit/ModifiersTest.t.sol`, getter and deployment tests

## Required tests

Target DcaManager modifiers/getters/deployment tests, inspect method identifiers and storage layout, then `make check` and both fork lanes.

## Success criteria

- [ ] No `setOperationsAdmin` selector or update event remains.
- [ ] Every handler/swapper lookup uses the immutable constructor admin.
- [ ] Deployment rejects an unusable admin address.
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] R13 add-only/versioned route lifecycle can no longer be bypassed by swapping the registry.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests and storage/selector inspection match **Required tests**.

## ABI / deploy / cutover impact

- ABI: removes `setOperationsAdmin(address)` and `DcaManager__OperationsAdminUpdated`.
- Scripts: constructor input is unchanged; deploy tests assert it is immutable.
- Cutover: frontend follow-up only if a checked-in app exposed this owner-only setter (not expected).
