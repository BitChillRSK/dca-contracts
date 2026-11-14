# R74 — Calibrate launch economic parameters

Status: **complete** · Assigned: yes · Optional/further-review: no · Order: before the final mainnet
broadcast

The launch matrix was explicitly reviewed and approved instead of inheriting the relaunch script's
placeholder cadence. The supporting business analysis is not part of this public implementation
record; this file records only the configuration that deployment and review must verify.

## Objective

Choose the initial fee, minimum purchase amount, minimum purchase period, and per-token schedule cap.
Keep later changes possible through the existing owner-controlled configuration without adding a new
on-chain capability.

## Decision

The relaunch keeps the original launch-era economic parameters:

- A flat 100-bps purchase fee on every production handler.
- A $25 minimum purchase for each listed stablecoin, expressed in that token's decimals.
- A 7-day minimum purchase period.
- At most 10 schedules per user and token.

Daily cadence and a decreasing fee curve are not launch settings. The contract continues to support
whole-day periods down to its one-day hard floor, so governance can lower the configured minimum later
without a new deployment if a future product decision calls for it.

No existing schedules migrate into the fresh relaunch deployment. After deployment, changing a
manager minimum does not rewrite stored schedules: existing schedules retain their values until edited,
while new schedules and edits must satisfy the then-current minimum.

## Scope

- [x] Restore `MIN_PURCHASE_PERIOD` in `script/Constants.sol` from the one-day placeholder to the
      approved 7-day launch value.
- [x] Assert the canonical seven-handler deployment uses the approved period and 10-schedule cap.
- [x] Keep protocol-level tests for the supported one-day cadence independent of the launch default.
- [x] Record the approved public configuration without publishing internal operating-cost analysis.

## Out of scope

- [ ] Changing the contract-level one-day minimum period floor.
- [ ] Changing the 5% fee-rate safety cap.
- [ ] Adding a fee curve or enabling daily cadence at launch.
- [ ] Changing any public ABI, storage layout, event, or custom error.

## Files touched

- `docs/relaunch/R74-economics-parameters-revisit.md`
- `script/Constants.sol`
- `test/unit/deployment/FinalDeploymentTest.t.sol`
- `test/unit/RbtcPurchaseTest.t.sol`
- `test/unit/SchedulePackingTest.t.sol`

No `src/` file changes.

## Required tests

- `make check`
- `make fork-sovryn`
- `make fork-tropykus`

## Success criteria

- [x] A human approved the launch fee, minimum purchase, cadence, and schedule-cap matrix.
- [x] `DeployFinal` receives the approved 7-day minimum through `script/Constants.sol`.
- [x] The canonical deployment test pins the 7-day period and 10-schedule cap.
- [x] One-day and non-weekly whole-day cadence behavior remains covered independently of the deploy
      default.

## Reviewer checklist

- [ ] The production fee remains flat at 100 bps.
- [ ] DOC and USDRIF retain the 18-decimal $25 minimum and USDT0 retains its 6-decimal equivalent.
- [ ] The launch minimum period is exactly 7 days; the protocol hard floor remains 1 day.
- [ ] The per-user/per-token schedule cap remains 10.
- [ ] No internal economics or benchmark fixtures are included.

## ABI / deploy / cutover impact

- ABI and storage: none.
- Deploy: a fresh `DeployFinal` stack starts with a 7-day minimum purchase period.
- Existing deployments: unchanged unless their owner explicitly calls the existing period setter.
- Consumers: no selector, event, error, token, route, or venue change. The front end already exposes
  weekly and longer cadences.
