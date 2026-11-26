# R124 — Kann purchase reentrancy guard

Status: **assigned** · Assigned: yes · Optional/further-review: no

Base: stacked on [R123](./R123-kann-configuration.md) / [#200](https://github.com/BitChillRSK/dca-contracts/pull/200) while it is open; `main` once it merges.

## Objective

Add `nonReentrant` to `batchBuyRbtc` and `batchBuyRbtcAcrossHandlers`, so every external function that writes `s_dcaSchedules` is guarded. The change hardens the contract against callbacks. It does not fix a callback found in the supported release paths.

## Background

- [Kann #18](https://github.com/Kann-Audits/BitChill-Audit/issues/18), I-09: the PoC adds an owner-approved intermediate token whose transfer calls a cooperating contract. That contract has an existing rBTC claim on the same handler and withdraws it during another purchase. The handler's measured output then falls, and part of the new output can go uncredited. An unrelated user's claim cannot be withdrawn this way.
- No such callback exists in the supported release paths.
- Owner decision D5 (#18 I-09), 2026-11-25: add the existing transient guard to both purchase entry points as conditional hardening. On Rootstock the guard costs about 300 gas per batch call (R82's figure, not a new measurement).
- Third of four PRs; see `IMPLEMENTATION_ORDER.md`.

## Open product decisions

**none**

## Scope

- [ ] `batchBuyRbtc` and `batchBuyRbtcAcrossHandlers` carry `nonReentrant` as their first modifier, before `onlySwapper`.
  - `batchBuyRbtcAcrossHandlers` keeps calling the private `_batchBuyRbtc`, so one guarded entry never calls another.
- [ ] Any guarded `DcaManager` function reached during a purchase reverts with `ReentrancyGuardReentrantCall`. This covers a nested purchase through either entry point, and a claim made while the handler measures native or wrapped output.
- [ ] A purchase reached from a callback during a user call reverts with the same error, and the whole user call rolls back. Examples: a deposit pull, a withdrawal payout, a receipt-token transfer.
- [ ] Keep the R118 ordering. `depositToken` and `withdrawToken` still store and log the new balance before their handler call. That order no longer serves a nested purchase. It stays as defense in depth.
- [ ] Remove the purchase exception from the places that state it:
  - `AGENTS.md` invariant 6;
  - `AUDIT_GUIDE.md`;
  - the `DcaManager` contract NatSpec.

  The `IDcaManager` NatSpec of both entry points states the guard.
- [ ] Tests:
  - change the callback tests that expected a nested purchase to succeed so that they expect the refusal and a full rollback;
  - add coverage for a nested purchase and a mid-purchase claim through both entry points;
  - keep ordinary purchases through both entry points passing.

## Out of scope

- [ ] Other #18 and #20 items, #16, #17, #21, #22, #24, #25, #26, and the source-consistency sweep (PR 4).
- [ ] Guards on handlers, `OperationsAdmin`, or `activateProtectedPurchaseWindow`.
- [ ] Removing the R118 ordering, a storage-based guard, or any new error or event.
- [ ] Deployment, consumer code, and consumer pin changes.

## Files likely touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- `test/unit/DepositSwapPopReentrancyTest.t.sol`, `test/unit/LendingShareWithdrawalTest.t.sol`, a new purchase reentrancy test under `test/unit/`
- An empty internal hook in `test/mocks/MockMocProxy.sol` and `test/mocks/MockSwapRouter02.sol`, between taking the input and paying the output. The new test overrides it in subclasses to stand in for the PoC's callback token. The shared mocks read no extra storage, so gas fixtures that purchase through them do not move.
- `AGENTS.md`, `AUDIT_GUIDE.md`, this spec, `docs/relaunch/IMPLEMENTATION_ORDER.md`, `docs/relaunch/README.md`

## Required tests

- Nested purchase:
  - a callback during `batchBuyRbtc` calls `batchBuyRbtc`, and then `batchBuyRbtcAcrossHandlers`;
  - a callback during `batchBuyRbtcAcrossHandlers` does the same.

  Each reverts with `ReentrancyGuardReentrantCall`, and no schedule, share or rBTC book moves.
- Mid-purchase claim:
  - a contract with an existing rBTC claim calls `withdrawAllAccumulatedRbtc` from a callback that runs while the handler measures its output, through each entry point;
  - this runs on a MoC lane, where the output is native rBTC, and on a Dex lane, where it is WRBTC;
  - the purchase reverts and the claim is unchanged.
- Callback during a user call:
  - a purchase from the deposit pull or the withdrawal payout reverts the whole deposit or withdrawal;
  - a purchase from the receipt-token transfer in `withdrawLendingShares` now fails with the guard error instead of `ShareConsumptionMismatch`.
- Ordinary purchases through both entry points still pass.
- `make check` and `make fork-layerbank` before push.

## Success criteria

- [ ] All scope items and required tests pass, with no change from PR 4.
- [ ] Every external function that writes `s_dcaSchedules` carries `nonReentrant`, which grep can check.

## Reviewer checklist

- [ ] `nonReentrant` comes first on both entry points.
- [ ] `batchBuyRbtcAcrossHandlers` calls only the private helper.
- [ ] No callback test was dropped. Each one now asserts the refusal and the rollback.
- [ ] The R118 ordering is unchanged.
- [ ] Extra files follow direct dependencies or failing tests and are named in the PR.

## ABI / deploy / cutover impact

- ABI: none. `ReentrancyGuardReentrantCall` is inherited and already in `DcaManager`'s ABI.
- Behavior:
  - a purchase reached from a callback inside any guarded `DcaManager` call now reverts;
  - a guarded call reached during a purchase also reverts;
  - an ordinary purchase is unchanged apart from the guard's gas.
- Gas: one `TLOAD` and two `TSTORE`s per batch call.
- Consumers: none. The bot sends only top-level purchases, and the guard error is already in the `DcaManager` ABI that consumers decode.
