# R46 — Pin DcaManager to its OperationsAdmin

Status: **PR [#83](https://github.com/BitChillRSK/dca-contracts/pull/83)** · Assigned: yes · Optional/further-review: no

PR 33 of the relaunch stack. Stack on R45 (PR 32). Must precede handler-registry hardening and R9.

## Objective

Remove `DcaManager.setOperationsAdmin` and make the constructor-supplied `OperationsAdmin` immutable, so governance cannot redirect every live schedule to a replacement route registry.

## Background

R13 made routes add-only: upgrades use new indexes while old schedules keep resolving to the handlers that hold their funds. A mutable whole-registry pointer bypasses that model in one call and can redirect every schedule and swapper check. This is a fresh deployment, so there is no migration value to preserve.

One-shot setters still leave a dangerous deployment state and a permanent selector. Constructor pinning is the smallest complete rule.

## Open product decisions

**none** — remove the setter; constructor-pin an immutable admin. Do not replace it with one-shot mutation.

## Scope

- [x] Change `s_operationsAdmin` to an immutable constructor value and reject a zero/non-contract address.
- [x] Remove `setOperationsAdmin` and `DcaManager__OperationsAdminUpdated` from implementation and interface.
- [x] Keep `getOperationsAdminAddress()` as the canonical read.
- [x] Update tests that exercised owner-only mutation to assert the selector is absent and the constructor value never changes.
- [x] Re-measure DcaManager runtime and storage layout; record the removed storage slot.

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

- [x] No `setOperationsAdmin` selector or update event remains.
- [x] Every handler/swapper lookup uses the immutable constructor admin.
- [x] Deployment rejects an unusable admin address.
- [x] No open product decisions.

## Measured results

`s_operationsAdmin` is now `i_operationsAdmin` (immutable). Constructor reverts `DcaManager__OperationsAdminIsNotAContract` when `code.length == 0` (zero and EOA). `getOperationsAdminAddress()` is unchanged as the read. `setOperationsAdmin(address)` (`0x32742d59`) and `DcaManager__OperationsAdminUpdated` are gone.

**Runtime bytecode (EIP-170 limit 24,576) vs R45:**

| contract | R45 | R46 | delta | margin after |
|---|---|---|---|---|
| `DcaManager` | 16,670 | 16,483 | −187 | 8,093 |
| `OperationsAdmin` | 4,625 | 4,625 | 0 | 19,951 |
| Handlers | unchanged | unchanged | 0 | same as R45 |

Only `DcaManager` changed. Removing the setter and storing the admin in bytecode, not a slot, is the shrink.

**Storage.** Slot `2` was `s_operationsAdmin`. It is gone; every later BitChill variable shifts up one slot. Ownable `_owner` / `_pendingOwner` stay in `0` / `1`. ReentrancyGuard stays in its ERC-7201 namespaced slot. Fresh deployment; nothing to migrate. R18 still packs `DcaDetails` inside `s_dcaSchedules`.

| slot | R45 | R46 |
|---|---|---|
| 0 | `_owner` | `_owner` |
| 1 | `_pendingOwner` | `_pendingOwner` |
| 2 | `s_operationsAdmin` | `s_dcaSchedules` |
| 3 | `s_dcaSchedules` | `s_minPurchasePeriod` |
| 4 | `s_minPurchasePeriod` | `s_maxSchedulesPerToken` |
| 5 | `s_maxSchedulesPerToken` | `s_defaultMinPurchaseAmount` |
| 6 | `s_defaultMinPurchaseAmount` | `s_tokenMinPurchaseAmounts` |
| 7 | `s_tokenMinPurchaseAmounts` | `s_scheduleNonce` |
| 8 | `s_scheduleNonce` | — |

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] R13 add-only/versioned route lifecycle can no longer be bypassed by swapping the registry.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests and storage/selector inspection match **Required tests**.

## ABI / deploy / cutover impact

- ABI: removes `setOperationsAdmin(address)` and `DcaManager__OperationsAdminUpdated`.
- Scripts: constructor input is unchanged; deploy tests assert it is immutable.
- Cutover: frontend follow-up only if a checked-in app exposed this owner-only setter (not expected).
