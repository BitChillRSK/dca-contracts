# R34 — Rationalize the DcaManager API before freeze

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 26, GitHub [#70](https://github.com/BitChillRSK/dca-contracts/pull/70). Stack on R31 (PR 25). Land before R32 internal cleanup and R9's ABI/event freeze.

## Objective

Replace duplicated caller-only and per-field schedule getters with canonical struct-based reads, remove redundant caller-supplied routing data, and decide one coherent schedule-mutation surface for the relaunch frontend.

## Background

Users interact through `DcaManager`. The previous ABI exposed full-array getters, caller-only wrappers, arbitrary-user per-field getters, a general zero-sentinel updater, and three specialized mutators. `withdrawTokenAndInterest` also accepted a lending-protocol index even though the validated schedule already stores the route used for its principal; a mismatched argument could withdraw principal from one route and ask another route for interest.

DcaManager has substantially more EIP-170 margin than the Dex handlers, so removals must improve API coherence rather than chase bytes. This is a frontend/product decision and must be settled before R9 and R10 document the final surface.

## Open product decisions

- **Mutation surface:** answered 2026-08-26 — **delete `updateDcaSchedule`.** Keep `depositToken`, `setPurchaseAmount`, and `setPurchasePeriod`. The relaunch frontend uses these intent-specific functions; one-field edits are expected to be substantially more common than combined edits. This removes the zero-sentinel ambiguity and the redundant mutation path without removing user capability. Combined amount+period changes take two transactions.
- **Consumer cutover:** answered 2026-08-26 — **delete all redundant getters.** Off-chain components migrate with the relaunch; there is no live dual-ABI window. Remove every `getMy*` wrapper and every per-field schedule getter. Canonical reads are `getDcaSchedules(user, token)`, `getDcaSchedule(user, token, scheduleIndex)`, `getInterestAccrued(user, token, lendingProtocolIndex)`, and `getAccumulatedRbtcBalance(user, token, lendingProtocolIndex)`.

The redundant `withdrawTokenAndInterest` route argument is assigned for removal; it must be derived from the validated schedule.

## Scope

- [x] Add one canonical single-schedule getter returning `DcaDetails` for `(user, token, scheduleIndex)`; retain the arbitrary-user array getter for enumeration.
- [x] Remove caller-only `getMy*` wrappers where the caller can pass `msg.sender` to the canonical getter.
- [x] Remove arbitrary-user per-field schedule getters once the single-schedule struct getter supplies the same data.
- [x] Retain canonical arbitrary-user accrued-interest and accumulated-rBTC getters; remove their caller-only wrappers if the consumer gate confirms migration.
- [x] Remove `lendingProtocolIndex` from `withdrawTokenAndInterest` and derive it from the schedule after validating index/id.
- [x] Apply the recorded mutation-surface decision without weakening invariant 6: every remaining external schedule mutator is `nonReentrant`.
- [x] Update `IDcaManager`, tests, fuzz wrappers, scripts, and checked-in consumers to the final selectors.
- [x] Record the before/after selector list, DcaManager runtime size, and explicit frontend/backend cutover notes.

Before (R31 head): DcaManager runtime **21,061**. After: **18,433**.

Added:
- `getDcaSchedule(address,address,uint256)` `a0527713`

Removed:
- `getMyAccumulatedRbtcBalance(address,uint256)` `d1569fc3`
- `getMyDcaSchedules(address)` `e4452fc8`
- `getMyInterestAccrued(address,uint256)` `b9dc58f6`
- `getMyScheduleId(address,uint256)` `93b9c381`
- `getMySchedulePurchaseAmount(address,uint256)` `4e76600b`
- `getMySchedulePurchasePeriod(address,uint256)` `4d5f62c1`
- `getMyScheduleTokenBalance(address,uint256)` `b1a883e2`
- `getScheduleId(address,address,uint256)` `69f96caa`
- `getSchedulePurchaseAmount(address,address,uint256)` `45b773c2`
- `getSchedulePurchasePeriod(address,address,uint256)` `c48ae5c2`
- `getScheduleTokenBalance(address,address,uint256)` `1a0873f7`
- `updateDcaSchedule(address,uint256,bytes32,uint256,uint256,uint256)` `256ae40c`
- `withdrawTokenAndInterest(address,uint256,bytes32,uint256,uint256)` `fe600c7b`

Replacement:
- `withdrawTokenAndInterest(address,uint256,bytes32,uint256)` `f4e47616` — route taken from the validated schedule

Event removed with its only emitter: `DcaManager__DcaScheduleUpdated`. Storage layout unchanged.

## Out of scope

- [ ] R32 internal implementation cleanup, R13 registry semantics, R9 events, schedule storage packing, pause, or compound interest.
- [ ] Purchase eligibility, schedule-id generation, fee behavior, handler cash accounting, or batch purchase ABI.
- [ ] Proxies, migration of live schedules, or deploy broadcasts.

## Files likely touched

- `src/DcaManager.sol`
- `src/interfaces/IDcaManager.sol`
- DcaManager unit, fuzz, deployment, and integration tests selected through direct selector usage
- Checked-in scripts or helpers that call removed selectors

## Required tests

```sh
forge test --match-contract DcaConfigurationTest
forge test --match-contract DcaManagerEdgeCasesTest
forge test --match-contract RbtcPurchaseTest
forge test --match-contract RbtcWithdrawalTest
forge build --sizes
make check
make fork-sovryn
make fork-tropykus
```

Assert canonical struct reads for self and arbitrary users, invalid-index behavior, schedule-id validation on every remaining mutator, intent-specific `depositToken` / `setPurchaseAmount` / `setPurchasePeriod` edits, and `withdrawTokenAndInterest` using the schedule's route without caller input. Fork tests add no new fork-specific assertions.

## Success criteria

- [x] One canonical single-schedule getter and one canonical schedule-array getter remain.
- [x] No caller-only getter duplicates an arbitrary-user getter without a recorded consumer reason.
- [x] Interest/rBTC reads have one canonical address-taking form.
- [x] `withdrawTokenAndInterest` cannot target a route different from the schedule's stored route.
- [x] The mutation surface is explicitly decided and contains no accidental zero-sentinel ambiguity.
- [x] Every remaining schedule mutator satisfies invariant 6.
- [x] Targeted, done-gate, and both fork tests pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Removed selectors have canonical replacements and consumer migration notes.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No internal refactor or product behavior is hidden in the ABI pass.

## ABI / deploy / cutover impact

- ABI: intentional DcaManager selector additions/removals. `DcaManager__DcaScheduleUpdated` is removed with `updateDcaSchedule` (it had no other emitter). Remaining events and storage layout are unchanged.
- Scripts: checked-in callers update to the canonical API; no broadcast.
- Cutover: relaunch frontend/backend must migrate atomically with this ABI. There is no live-contract migration because relaunch deployment is fresh. Reads go through `getDcaSchedule` / `getDcaSchedules`. Schedule edits use `depositToken`, `setPurchaseAmount`, and `setPurchasePeriod` (two transactions if both amount and period change). `withdrawTokenAndInterest` no longer takes a lending-protocol index.
