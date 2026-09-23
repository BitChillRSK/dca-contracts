# R84 — no repeated registry reads

Status: **not started** · Assigned: no · Optional/further-review: no

## Objective

Stop `DcaManager` from calling `OperationsAdmin` more than once to resolve a single route. Rootstock
charges every one of those calls a flat 700 gas, plus 200 for the read behind it, where Foundry charges
100 + 100 for a repeat. Four user paths are affected:

| Path | Today | Change | Rootstock saving (deploy) |
|---|---|---|---:|
| `withdrawTokenAndInterest` | resolves the handler in `_withdrawToken`, then again for interest | reuse the handler `_withdrawToken` already resolved | **≈ 1,900** |
| `createDcaSchedule` / `depositToken` | `getTokenHandler` + `areDepositsPaused`, both reading one packed word | one `getRouteInfo` call | ≈ 950 |
| `topUpFromInterest` | `isLendingRoute` + `getTokenHandler` | one `getRouteInfo` call | ≈ 950 |
| `withdrawAllAccumulatedInterest` | `getTokenHandler` + `isLendingRoute` per pair | one `getRouteInfo` call per pair | ≈ 940 / pair |

The first row needs no ABI change. The other three share one additive `OperationsAdmin` view.

## Background

Found by the [Rootstock gas audit of `src/`](./ROOTSTOCK-GAS-AUDIT.md). The `withdrawTokenAndInterest`
and interest-path cases were raised in review of #140. Pricing is in
[`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md#account-access-no-eip-2929-either): no EIP-2929
for account access, so a repeat call into a contract already touched in the transaction costs a flat
700, about 7× what Foundry shows. R50 packed `handler` and `depositsPaused` into one word, but the
manager still makes two calls to read it.

Measured with the audit harness on a lending route (stub lending handler). The Rootstock figure is the
Cancun delta plus the repricing of each removed warm call (+600) and each removed warm `SLOAD` (+100).
Each removed call repeats one made earlier in the same transaction, so Cancun prices it warm:

| Path | Profile | Cancun exec | `SLOAD`s | Rootstock (derived) |
|---|---|---:|---:|---:|
| `withdrawTokenAndInterest` (reuse handler) | default | 22,020 → 20,631 | 16 → 15 | ≈ −2,089 |
| | deploy | 21,041 → 19,847 | 14 → 13 | ≈ **−1,894** |
| `depositToken` (`getRouteInfo`) | default | 16,269 → 15,657 | 8 → 8 | ≈ −1,212 |
| | deploy | 15,670 → 15,319 | 7 → 7 | ≈ −951 |
| `topUpFromInterest` (`getRouteInfo`) | default | 20,055 → 19,612 | 14 → 14 | ≈ −1,043 |
| | deploy | 19,319 → 18,968 | 13 → 13 | ≈ −951 |
| `withdrawAllAccumulatedInterest`, one pair | default | 14,642 → 14,217 | 10 → 10 | ≈ −1,025 |
| | deploy | 14,338 → 13,997 | 9 → 9 | ≈ −941 |

For deposits, a view returning only `TokenRoute` measured slightly better (−384 Cancun and one fewer
`SLOAD`, ≈ −1,084 Rootstock under deploy), because deposits do not need the route class. One
`getRouteInfo` view serving all three paths costs deposits about 130 gas more, in exchange for one
selector instead of two. This spec takes the single view.

## Open product decisions

**none.** The `withdrawTokenAndInterest` change is internal. If the human judges roughly 950 user gas
per call not worth an additive `OperationsAdmin` view, ship that change alone and record the
`getRouteInfo` part as closed in `IMPLEMENTATION_ORDER.md`.

## Scope

- [ ] `_withdrawToken` also returns the `ITokenHandler` it resolved. `withdrawTokenAndInterest` passes
      that handler to `_withdrawInterest` instead of calling `_handler` again. The route-class check
      and its error are unchanged.
- [ ] Add `getRouteInfo(address token, uint256 routeIndex) external view returns (TokenRoute memory
      tokenRoute, RouteClass routeClass)` to `IOperationsAdmin` and `OperationsAdmin`, bounded with
      `toUint32()` like its siblings. Place it next to `getTokenHandler`, in the same order in the
      interface and the implementation.
- [ ] Route these three through one `getRouteInfo` call each, keeping today's order of checks, errors,
      and skips:
  - `_handlerForDeposit`: `TokenNotAccepted`, then `DepositsPaused`.
  - `topUpFromInterest`: `TokenDoesNotYieldInterest`, then `TokenNotAccepted`.
  - `withdrawAllAccumulatedInterest`: skip an unassigned pair, then skip an idle route.
- [ ] Keep `getTokenHandler`, `areDepositsPaused`, and `isLendingRoute`, since other paths and consumers
      read them.
- [ ] Update `docs/relaunch/README.md` Status and `IMPLEMENTATION_ORDER.md`.

## Out of scope

- [ ] Changing `_handler` for paths that resolve a route only once (purchase, delete, withdraw, rBTC).
- [ ] Folding `withdrawTokenAndInterest`'s route-class check into `_withdrawToken`. That would add a
      read to plain `withdrawToken`, and it is unmeasured.
- [ ] Removing or renaming existing `OperationsAdmin` getters.
- [ ] R81 and R82.

## Files likely touched

- `src/DcaManager.sol`
- `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol`
- the `OperationsAdmin` and `DcaManager` unit tests for deposits, pauses, top-up, and interest

## Required tests

- Unit: `getRouteInfo` returns the assigned handler, pause flag, and route class. It returns a zero
  handler for an unassigned pair and rejects an index above `uint32` like its siblings.
- Deposit, top-up, and interest-withdrawal behavior is unchanged:
  - a paused pair still reverts `DcaManager__DepositsPaused`;
  - an unassigned pair still reverts `DcaManager__TokenNotAccepted`, or is skipped on the batch path;
  - an idle route still reverts `DcaManager__TokenDoesNotYieldInterest`, or is skipped.
- `withdrawTokenAndInterest` withdraws principal and interest through the same handler as before.
- Foundry gas for each of the four paths (labelled Foundry) plus the Rootstock derivation.
- `make check`, `make check-deploy`; fork lanes per `AGENTS.md`.

## Success criteria

- [ ] None of the four paths calls `OperationsAdmin` more than once per route it resolves.
- [ ] Errors, skips, and their order are unchanged.
- [ ] The saving is stated on both schedules.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: additive, one new `OperationsAdmin` view; no existing selector changes. None if only the
  `withdrawTokenAndInterest` change ships.
- Scripts: none.
- Cutover: per `AGENTS.md` **Consumer follow-up**, a new public selector on `OperationsAdmin` needs an
  informational `front-end` issue. No other consumer is affected.
