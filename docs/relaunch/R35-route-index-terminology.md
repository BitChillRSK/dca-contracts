# R35 — Rename DcaManager `lendingProtocolIndex` to `routeIndex`

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 27, GitHub [#71](https://github.com/BitChillRSK/dca-contracts/pull/71). Stack on R34 (PR 26, GitHub [#70](https://github.com/BitChillRSK/dca-contracts/pull/70)). Land before R32 internal cleanup. Inserted after #70 because R13 already made the index a route (idle or lending), but DcaManager still named it as if every handler lent funds.

## Objective

Rename DcaManager's schedule-routing noun from `lendingProtocolIndex` to `routeIndex` so it matches `OperationsAdmin` and remains accurate for idle handlers. No behavior change.

## Background

R13 replaced the string protocol registry with a one-shot route-class registry. An index is an immutable idle-or-lending route/version, not a unique external lender. Idle handlers hold the stablecoin on the contract; they do not lend it out.

`OperationsAdmin` already uses `routeIndex`. `DcaManager` still stores, accepts, and emits `lendingProtocolIndex`, and natspec still says the last `createDcaSchedule` argument is "the lending protocol, if any." That is false for idle schedules and for any future non-lending route. R34 settled the DcaManager function set but left this leftover name on the canonical struct, events, errors, and parameters.

Function selectors that only change a parameter *name* stay the same. The custom error *name* change does change that error's selector. Storage layout is unchanged (same type, same struct slot).

## Open product decisions

**none**

## Scope

- [x] Rename `DcaDetails.lendingProtocolIndex` → `routeIndex`.
- [x] Rename DcaManager / `IDcaManager` parameters, internals, and natspec from `lendingProtocolIndex` / `lendingProtocolIndexes` to `routeIndex` / `routeIndexes`.
- [x] Rename `DcaManager__LendingProtocolIndexMismatch` → `DcaManager__RouteIndexMismatch` (and its `actual` / `expected` arguments).
- [x] Update natspec that still describes the index as "the lending protocol, if any" or "0 if it is not lent." The value is an `OperationsAdmin` route index (idle or lending).
- [x] Update tests that read the struct field, expect the error selector, copy the event ABI, or name locals/helpers after the old noun (`s_lendingProtocolIndex`, `getLendingProtocolIndex`, fuzz handler field, array locals).
- [x] No logic, access-control, cash-accounting, or storage-layout change.

**Keep** (not a DcaManager route noun):

- `LENDING_PROTOCOL` / `EXPECTED_LENDING_PROTOCOL` env vars and `make moc-*` / `fork-*` lane names
- `ITokenLending`, `TokenLending__LendingProtocolDepositFailed` / `…RedeemFailed`
- `isLendingRoute`, `TROPYKUS_INDEX` / `SOVRYN_INDEX` / `IDLE_INDEX` / `LAYERBANK_INDEX`

## Out of scope

- [ ] R32 internal cleanup, R9 event indexing, R10 natspec rewrite beyond the renamed identifiers.
- [ ] OperationsAdmin registry semantics, handler cash accounting, purchase eligibility, or deploy/CI index map.
- [ ] Changing which functions take a route index (R34 already dropped it from `withdrawTokenAndInterest`).

## Files likely touched

- `src/interfaces/IDcaManager.sol`
- `src/DcaManager.sol`
- Tests that compile against the struct field, error, or DcaManager-facing locals: `test/unit/DcaDappTest.t.sol`, `DcaScheduleTest`, `DcaConfigurationTest`, `RbtcPurchaseTest`, `RbtcWithdrawalTest`, `StablecoinLendingTest`, `OperationsAdminTest`, `GettersTest`, `Handler.t.sol`, `Invariants.t.sol`, `HandlerTestHarness.t.sol` and its protocol overrides, idle/LayerBank DcaManager tests, `ComparePurchaseMethods.t.sol`
- Specs that describe the current DcaManager/test noun: this file, `IMPLEMENTATION_ORDER.md`, `README.md`, `R32-internal-cleanup.md`, `R34-dca-manager-abi.md` leftover note, `R22-deploy-ci.md` stack line

The implementer may follow compiler errors from this list.

## Required tests

```sh
forge test --match-contract DcaScheduleTest
forge test --match-contract DcaConfigurationTest
forge test --match-contract RbtcPurchaseTest
forge test --match-contract GettersTest
forge test --match-contract IdleDcaManagerTest
forge test --match-contract LayerBankDcaManagerTest
make check
make fork-sovryn
make fork-tropykus
```

Existing tests must still assert create stores the chosen route on `DcaDetails.routeIndex`, batch buys revert `DcaManager__RouteIndexMismatch` when the swapper supplies a different index, and idle/LayerBank schedules keep their index constants. No new behavior. Fork tests add no new fork-specific assertions.

## Success criteria

- [x] No first-party DcaManager identifier is still named `lendingProtocolIndex` / `lendingProtocolIndexes`.
- [x] `OperationsAdmin` already-`routeIndex` names are unchanged.
- [x] Error rename is the only selector change; storage layout and remaining function selectors are unchanged.
- [x] Tests compile and the assertions above pass.
- [x] Targeted, done-gate, and both fork tests pass.
- [x] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to compiler/test fallout and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: `DcaDetails.routeIndex`; event/error/function *parameter names* on the remaining route-taking DcaManager surface; custom error `DcaManager__RouteIndexMismatch` (new selector). Function selectors that only renamed a parameter are unchanged. Storage layout unchanged.
- Scripts: none.
- Cutover: relaunch frontend/backend must read `routeIndex` from `DcaDetails` and handle `RouteIndexMismatch`. Fresh deployment; no live-contract migration.
