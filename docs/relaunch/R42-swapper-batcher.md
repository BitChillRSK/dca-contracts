# R42 — Swapper batcher (one tx, many `batchBuyRbtc`)

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 46 of the relaunch stack. GitHub [#98](https://github.com/BitChillRSK/dca-contracts/pull/98). Stack on R38 (PR 45). Lands **before** R9/R10 so the event/ABI review and final natspec pass see every first-party contract that ships. It does not change `DcaManager`’s surface. Cutover: [swapper-bot#6](https://github.com/BitChillRSK/swapper-bot/issues/6).

## Objective

Add a thin contract that the swapper allowlist can call once per cron tick to run several `DcaManager.batchBuyRbtc` calls (one per token×route handler) in a single transaction.

## Background

`batchBuyRbtc` already requires every row to share one `token` and one `routeIndex`. After idle + LayerBank + Sovryn + USDRIF/USDT0 dex, a tick is several of those calls. Ethereum/Rootstock still has one top-level call per tx, so the bot cannot bundle them without an intermediate contract or a `multicall` on `DcaManager`.

Do **not** add `multicall` to `DcaManager`. A dedicated batcher:

- leaves the manager ABI unchanged for the subsequent freeze;
- is `addSwapper`’d on `OperationsAdmin` (`DcaManager.onlySwapper` already keys off that allowlist);
- holds no user funds;
- can be replaced without touching handlers.

R36/R37 land first so the batcher tests and cutover notes can use the final production route set rather
than describing handlers that have not been wired yet.

**Atomicity.** One revert rolls back every venue in the bundle. Today a failed LayerBank batch does not roll back Sovryn. That isolation is operationally useful (an illiquid reserve aborts one handler, not the tick). Bundling trades isolation for one tx. That is the product choice this spec records, not an accident.

Decided 2026-08-27: **ship the batcher** as a relaunch item, not optional-late.

## Open product decisions

**none** — decided 2026-08-27: calls are all-or-nothing, with no `try/catch`; the bot EOA remains allowlisted as a break-glass/single-handler retry path alongside the batcher.

**Re-confirmed against R19 (2026-08-28).** A paused row still reverts its own `batchBuyRbtc`, and
because the batcher has no `try/catch`, that revert now rolls back every other venue in the same
transaction. `testPausedScheduleInSecondGroupRollsBackTheFirst` pins that blast radius. Partial
bundles would reintroduce the partial-failure accounting this design exists to avoid: some
handlers purchased, others not, from a single receipt the bot cannot split. The off-chain pause
filter remains the only mitigation and still races the pause; the allowlisted bot EOA is the
per-handler retry when a bundle reverts. Keep all-or-nothing. See
[`R19-schedule-pause.md`](./R19-schedule-pause.md).

## Scope

- [x] `src/SwapperBatcher.sol` (name may vary): immutable `dcaManager`, no token custody, no `receive` that holds rBTC.
- [x] One external function `batchBuyRbtcGroups` that takes an array of `batchBuyRbtc` argument groups (token, routeIndex, parallel buyer/index/id/amount arrays) and forwards each group to `DcaManager.batchBuyRbtc`. Named differently from the inner call so the compose cannot be confused with one token×route group after the ABI freeze. Empty top-level array reverts. Per-group empty/length checks stay on `DcaManager`.
- [x] `onlySwapper` on the batcher, reading the **same** `OperationsAdmin.isSwapper` list `DcaManager` uses (pinned from `dcaManager.getOperationsAdminAddress()` at construction). Review follow-up: without the outer check, a random EOA can consume one due schedule and revert the bot's atomic bundle. This is not a second mapping. The batcher **is** `msg.sender` on the inner calls, so it must still be `addSwapper`’d, and the bot EOA must stay on the list to call the batcher.
- [x] Add-on `script/DeploySwapperBatcher.s.sol` (local/test). Live `addSwapper` is ops, not this PR’s broadcast.
- [x] Tests: two handlers (e.g. idle DOC + Sovryn DOC, or two route indexes on one admin) succeed in one `batcher` call; a revert in the second group rolls back the first; an address that is not a swapper cannot use the batcher to purchase (DcaManager revert) unless the batcher itself is allowlisted in the test fixture.

## Out of scope

- [ ] `multicall` / `delegatecall` on `DcaManager`.
- [ ] Changing `batchBuyRbtc` to accept mixed tokens or routes.
- [ ] Telegram / monitoring. Per-user amounts already live in `PurchaseRbtc__RbtcBought`.
- [ ] Removing the bot EOA from the allowlist.
- [ ] `--broadcast`.

## Files likely touched

- `src/SwapperBatcher.sol` (new), matching interface if you split one
- `script/DeploySwapperBatcher.s.sol` (new)
- New unit test under `test/unit/`
- `AGENTS.md` layout one-liner if a new `src/` file needs it

## Required tests

Targeted new test file, then `make check`.

- One batcher tx, two `batchBuyRbtc` groups, two handlers: both purchase.
- Second group reverts (e.g. empty buyers if decision 1 is all-or-nothing): first group’s schedule `lastPurchaseTimestamp` / balances unchanged.
- Batcher not on the allowlist: revert `DcaManager__UnauthorizedSwapper`. Caller not on the allowlist: revert `SwapperBatcher__UnauthorizedSwapper`.
- Fork: no new assertions. Still run both fork lanes before push.

## Success criteria

- [x] Cron can drive every due handler in one tx through the batcher.
- [x] Failure policy matches decision 1, tested.
- [x] No DcaManager selector/event/error change.
- [x] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Batcher cannot withdraw user funds or rBTC.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: new contract only. DcaManager frozen surface unchanged.
- Scripts: local deploy add-on. Ops `addSwapper(batcher)` after deploy (document, do not broadcast).
- Cutover: swapper bot points at the batcher. **Frontend follow-up:** none unless the UI ever sent `batchBuyRbtc` (it should not). Monitoring already sees the same handler events.
