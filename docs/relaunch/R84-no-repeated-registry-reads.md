# R84 — no repeated registry reads

Status: **implemented, trimmed to the `withdrawTokenAndInterest` fix** · GitHub [#146](https://github.com/BitChillRSK/dca-contracts/pull/146) · Assigned: yes · Optional/further-review: no

**Decision (human, 2026-09-25): ship only the `withdrawTokenAndInterest` handler reuse.** The savings
fall on user paths that run rarely, at about 1% of each call and under a cent. On such paths a change
ships only if it improves the code on its own merits. Reusing the handler `_withdrawToken` just paid
out through passes that test. The `getRouteInfo` view does not: it would add permanent registry surface
that overlaps three existing getters, and it would spread handler resolution across three more
call sites, for about 950 gas a call. The view and the three paths it would have served are therefore
**Out of scope**, as the Open product decisions below already allowed. The Objective and Background
record the original four-path proposal as written.

## Objective

Stop `DcaManager` from reading the same registry fact for the same route twice in one call. The facts
are a route's handler, its deposit pause, and its route class. Rootstock charges every
`OperationsAdmin` call a flat 700 gas, plus 200 for the read behind it, where Foundry charges 100 + 100
for a repeat. A path may still make one call per *distinct* fact it needs.
`withdrawTokenAndInterest` keeps one handler lookup and one route-class lookup. Four user paths are
affected:

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

## Measured

Measured with a one-off harness, `test/gas/R84RegistryReadsGas.t.sol`, that did not ship: it is kept
at [`02884fe`](https://github.com/BitChillRSK/dca-contracts/blob/02884fe88467d9bed7e11306b64d91cf46ea9713/test/gas/R84RegistryReadsGas.t.sol). It ran against the real `OperationsAdmin` and `DcaManager` with a stub lending
handler that moves no tokens, and counted `OperationsAdmin` calls and the storage reads behind them
with `vm.startStateDiffRecording`. The same file was run on the unchanged `src/` for the "before"
column. It was dropped from the PR because it would have been a gas pin on a change that ships for
clarity: its stub implements four handler interfaces and breaks whenever one grows, and its
same-handler assertions pass on the old code too, since only one handler is registered. The behaviour
is already covered by the `withdrawTokenAndInterest` cases in `FullWithdrawalTest`,
`StablecoinLendingTest`, `ProtectedPurchaseWindowTest`, `SchedulePauseTest`, `ScheduleOwnershipTest`,
and, for the idle-route revert, `IdleDcaManagerTest`.

Before the measured call the harness warmed `OperationsAdmin` and the two registry slots the path reads,
through getters that exist on both sides. Cancun then prices every registry call and read the same way
before and after (100 + 100), and the delta converts to Rootstock by repricing only what was removed: a
removed warm call is −600 (700 on Rootstock), a removed warm `SLOAD` −100.

Foundry gas is the whole measured call, including the test's call overhead, which cancels in the delta.

| Path | Profile | Foundry (Cancun) | Δ | Registry calls | Registry `SLOAD`s | Rootstock Δ (derived) |
|---|---|---:|---:|---|---|---:|
| `withdrawTokenAndInterest` | default | 75,798 → 74,409 | −1,389 | 3 → 2 | 3 → 2 | ≈ −2,089 |
| | deploy | 74,698 → 73,504 | −1,194 | 3 → 2 | 3 → 2 | ≈ **−1,894** |

These match the audit harness in Background exactly. The four-path version of this PR measured −1,405 /
−1,168 on the same path. The removed work is the same one call and one `SLOAD`; the ±26 gas difference
comes from the codegen around the other, now-reverted changes.

## Open product decisions

**none.** The `withdrawTokenAndInterest` change is internal. If the human judges roughly 950 user gas
per call not worth an additive `OperationsAdmin` view, ship that change alone and record the
`getRouteInfo` part as closed in `IMPLEMENTATION_ORDER.md`. Taken on 2026-09-25: see the decision under
the Status line.

## Scope

- [x] `_withdrawToken` also returns the `ITokenHandler` it resolved. `withdrawTokenAndInterest` passes
      that handler to `_withdrawInterest` instead of calling `_handler` again. The route-class check
      and its error are unchanged.
- [x] No `OperationsAdmin` change.
- [x] Update `docs/relaunch/README.md` Status and `IMPLEMENTATION_ORDER.md`.

## Out of scope

- [ ] Dropped 2026-09-25: an `OperationsAdmin.getRouteInfo(token, routeIndex)` view returning
      `(TokenRoute, RouteClass)` in one call.
- [ ] Dropped 2026-09-25: routing `_handlerForDeposit` (`createDcaSchedule`, `depositToken`),
      `topUpFromInterest`, and each `withdrawAllAccumulatedInterest` pair through that view. They keep
      their two registry calls, each asking a different question.
- [ ] Dropped 2026-09-25: a committed gas or call-count test. The measurement below is reproducible
      from the harness kept in history; see **Measured**.
- [ ] Changing `_handler` for paths that resolve a route only once (purchase, delete, withdraw, rBTC).
- [ ] Folding `withdrawTokenAndInterest`'s route-class check into `_withdrawToken`. That would add a
      read to plain `withdrawToken`, and it is unmeasured.
- [ ] Removing or renaming existing `OperationsAdmin` getters.
- [ ] R81 and R82.

## Files likely touched

- `src/DcaManager.sol`

## Required tests

- The existing `withdrawTokenAndInterest` tests pass unchanged: principal and interest are withdrawn
  through the schedule's handler, and an idle route still reverts `DcaManager__TokenDoesNotYieldInterest`.
- Foundry gas for `withdrawTokenAndInterest` (labelled Foundry) plus the Rootstock derivation, recorded
  under **Measured** rather than pinned by a committed test.
- `make check`, `make check-deploy`; fork lanes per `AGENTS.md`.

## Success criteria

- [x] `withdrawTokenAndInterest` resolves the handler once and makes two `OperationsAdmin` calls: one
      handler lookup and one route-class lookup.
- [x] Its errors and their order are unchanged.
- [x] No other path and no ABI changes.
- [x] The saving is stated on both schedules.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none. Only the `withdrawTokenAndInterest` change ships.
- Scripts: none.
- Cutover: none.
