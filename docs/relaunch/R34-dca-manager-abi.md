# R34 — Rationalize the DcaManager API before freeze

Status: **not started** · Assigned: yes · Optional/further-review: no

PR 26. Stack on R31 (PR 25). Land before R32 internal cleanup and R9's ABI/event freeze.

## Objective

Replace duplicated caller-only and per-field schedule getters with canonical struct-based reads, remove redundant caller-supplied routing data, and decide one coherent schedule-mutation surface for the relaunch frontend.

## Background

Users interact through `DcaManager`, but its current ABI exposes full-array getters, caller-only wrappers, arbitrary-user per-field getters, a general zero-sentinel updater, and three specialized mutators. `withdrawTokenAndInterest` also accepts a lending-protocol index even though the validated schedule already stores the route used for its principal; a mismatched argument can withdraw principal from one route and ask another route for interest.

DcaManager has substantially more EIP-170 margin than the Dex handlers, so removals must improve API coherence rather than chase bytes. This is a frontend/product decision and must be settled before R9 and R10 document the final surface.

## Open product decisions

- **Mutation surface:** retain the three specialized `depositToken` / `setPurchaseAmount` / `setPurchasePeriod` functions alongside `updateDcaSchedule`, or replace them with one explicit atomic update shape that does not use zero as an implicit "unchanged" flag. Recommended: one explicit atomic update plus only wrappers demonstrated necessary by the frontend.
- **Consumer cutover:** confirm the relaunch frontend/backend can migrate from caller-only and per-field getters to the canonical address-taking struct getters in this PR.

The redundant `withdrawTokenAndInterest` route argument is assigned for removal; it must be derived from the validated schedule.

## Scope

- [ ] Add one canonical single-schedule getter returning `DcaDetails` for `(user, token, scheduleIndex)`; retain the arbitrary-user array getter for enumeration.
- [ ] Remove caller-only `getMy*` wrappers where the caller can pass `msg.sender` to the canonical getter.
- [ ] Remove arbitrary-user per-field schedule getters once the single-schedule struct getter supplies the same data.
- [ ] Retain canonical arbitrary-user accrued-interest and accumulated-rBTC getters; remove their caller-only wrappers if the consumer gate confirms migration.
- [ ] Remove `lendingProtocolIndex` from `withdrawTokenAndInterest` and derive it from the schedule after validating index/id.
- [ ] Apply the recorded mutation-surface decision without weakening invariant 6: every remaining external schedule mutator is `nonReentrant`.
- [ ] Update `IDcaManager`, tests, fuzz wrappers, scripts, and checked-in consumers to the final selectors.
- [ ] Record the before/after selector list, DcaManager runtime size, and explicit frontend/backend cutover notes.

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

Assert canonical struct reads for self and arbitrary users, invalid-index behavior, schedule-id validation on every remaining mutator, atomic update behavior selected by the gate, and `withdrawTokenAndInterest` using the schedule's route without caller input. Fork tests add no new fork-specific assertions.

## Success criteria

- [ ] One canonical single-schedule getter and one canonical schedule-array getter remain.
- [ ] No caller-only getter duplicates an arbitrary-user getter without a recorded consumer reason.
- [ ] Interest/rBTC reads have one canonical address-taking form.
- [ ] `withdrawTokenAndInterest` cannot target a route different from the schedule's stored route.
- [ ] The mutation surface is explicitly decided and contains no accidental zero-sentinel ambiguity.
- [ ] Every remaining schedule mutator satisfies invariant 6.
- [ ] Targeted, done-gate, and both fork tests pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Removed selectors have canonical replacements and consumer migration notes.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No internal refactor or product behavior is hidden in the ABI pass.

## ABI / deploy / cutover impact

- ABI: intentional DcaManager selector additions/removals; exact final list is recorded after the two gates are answered. Events and storage layout remain unchanged.
- Scripts: checked-in callers update to the canonical API; no broadcast.
- Cutover: relaunch frontend/backend must migrate atomically with this ABI. There is no live-contract migration because relaunch deployment is fresh.
