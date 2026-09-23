# R84 — one registry read for deposit routing

Status: **not started** · Assigned: no · Optional/further-review: no

## Objective

`DcaManager._handlerForDeposit` makes two external calls into `OperationsAdmin`, `getTokenHandler` and
then `areDepositsPaused`, and both read the same packed `TokenRoute` word. Add one view that returns the
whole `TokenRoute` and route deposits through it. This saves about 1,100 Rootstock gas on every
`createDcaSchedule` and `depositToken` under the deploy profile, paid by users. It is the smallest item
from the audit, so it is ordered last.

## Background

Found by the [Rootstock gas audit of `src/`](./ROOTSTOCK-GAS-AUDIT.md). Rootstock has no EIP-2929
account-access pricing either: every `CALL`/`STATICCALL` costs a flat 700, where Cancun charges 100 for
a contract already touched in the transaction. Every `SLOAD` costs 200, where Cancun charges 100 warm
([`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md#account-access-no-eip-2929-either)). A second
call to a contract that is already warm is therefore about 7× dearer on Rootstock than Foundry shows.
R50 packed `handler` and `depositsPaused` into one word, but the manager still pays for two calls to
read it.

Measured with the audit harness on `depositToken` (the patch adds
`getTokenRoute(address,uint256) returns (TokenRoute)` and uses it in `_handlerForDeposit`):

| Profile | Cancun exec | Rootstock (derived) |
|---|---:|---:|
| default | 16,340 → 15,430 (−910) | ≈ −1,610 |
| deploy (`via_ir`) | 15,673 → 15,289 (−384) | ≈ **−1,084** |

The Rootstock figure is the Cancun delta plus the repricing of the removed warm call (+600) and the
removed warm `SLOAD` (+100).

## Open product decisions

**none.** If the human judges ~1,100 user gas per deposit not worth an `OperationsAdmin` ABI addition,
close this item in `IMPLEMENTATION_ORDER.md` with that reason instead of implementing it.

## Scope

- [ ] Add `getTokenRoute(address token, uint256 routeIndex) external view returns (TokenRoute memory)`
      to `IOperationsAdmin` and `OperationsAdmin`, bounded with `toUint32()` like its siblings. Place it
      next to `getTokenHandler`, in the same order in the interface and the implementation.
- [ ] `_handlerForDeposit` makes that single call: revert `DcaManager__TokenNotAccepted` on a zero
      handler and `DcaManager__DepositsPaused` when paused. Keep the same order of checks and errors
      as today.
- [ ] Keep `getTokenHandler` and `areDepositsPaused`, since other paths and consumers read them.
- [ ] Update `docs/relaunch/README.md` Status and `IMPLEMENTATION_ORDER.md`.

## Out of scope

- [ ] Changing `_handler` for non-deposit paths, which need only the handler.
- [ ] Removing or renaming existing `OperationsAdmin` getters.
- [ ] R81 and R82.

## Files likely touched

- `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol`
- `src/DcaManager.sol`
- `OperationsAdmin` and `DcaManager` deposit / pause unit tests

## Required tests

- Unit: `getTokenRoute` returns the assigned handler and pause flag, and a zero handler for an unassigned
  pair. It rejects an index above `uint32` like its siblings.
- Deposits and creates on a paused pair still revert `DcaManager__DepositsPaused`; an unassigned pair
  still reverts `DcaManager__TokenNotAccepted`.
- A Foundry gas figure for `depositToken` (labelled Foundry) plus the Rootstock derivation.
- `make check`, `make check-deploy`; fork lanes per `AGENTS.md`.

## Success criteria

- [ ] Deposit routing makes one registry call; errors and their order are unchanged.
- [ ] Saving stated on both schedules.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: additive. There is one new `OperationsAdmin` view and no existing selector changes.
- Scripts: none.
- Cutover: per `AGENTS.md` **Consumer follow-up**, a new public selector on `OperationsAdmin` needs an
  informational `front-end` issue. No other consumer is affected.
