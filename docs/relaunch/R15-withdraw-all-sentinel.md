# R15 — Withdraw-all sentinel

Status: **in review** · Assigned: yes · Optional/further-review: no

## Objective

Let a user empty a schedule without racing the swapper: `withdrawalAmount == type(uint256).max` means "this schedule's whole `tokenBalance`" as it stands when the transaction runs.

## Background

`withdrawToken` / `withdrawTokenAndInterest` need an exact `withdrawalAmount`. The UI reads `tokenBalance`, then sends the tx; if a purchase lands in between, `DcaManager__WithdrawalAmountExceedsBalance` reverts the withdrawal. `type(uint256).max` resolved against live storage removes the race. `deleteDcaSchedule` already withdraws the whole `tokenBalance` with no amount argument, and rBTC withdrawals already send everything, so neither needs a sentinel.

`type(uint256).max` means **this schedule's principal**, not principal + interest. Interest keeps its own entry points (`withdrawTokenAndInterest`'s interest path, `withdrawAllAccumulatedInterest`).

Related and already landed in PR 8 (R1/R20): Tropykus `withdrawToken` transfers what the redemption produced instead of the requested amount. Nothing left to do there.

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 10. Implement without asking.

## Scope

- [ ] `DcaManager._withdrawToken`: resolve `withdrawalAmount == type(uint256).max` to the schedule's live `tokenBalance` before the zero / exceeds checks. Both existing reverts stay for every other amount.
- [ ] Natspec for the sentinel on `IDcaManager.withdrawToken` / `withdrawTokenAndInterest`.

## Out of scope

- [ ] `if (amount == max) amount = lendingToken.balanceOf(...)` or the user's share mapping inside `withdrawToken` — that would empty every schedule the user has on that protocol in one call.
- [ ] Treating `max` as "principal plus interest" on `withdrawToken`.
- [ ] A sentinel on `deleteDcaSchedule` or on the rBTC withdrawals; they already take everything.
- [ ] R16 renames, R22 folder moves, packing, and any change to how `_withdrawToken` debits the schedule (settled in PR 8).
- [ ] Lending-share dust: burning leftover `s_kTokenBalances` / `s_iSusdBalances` when the user locks nothing on a handler, wiring `withdrawInterest(user, 0)` into `deleteDcaSchedule`, or promising that `withdrawTokenAndInterest` with the sentinel zeroes the share mapping. **Deferred, not fixed** — see **Decision — lending-share dust deferred**.

## Decision — lending-share dust deferred

PR 10 originally bundled a sweep of leftover lending shares when a user locked nothing on a handler. That half is **deferred, not fixed**. The residue that remains is a share balance whose underlying truncates to **under 1 wei of stablecoin**. The four reasons:

1. The sweep recovers nothing. `_redeemInternal` / `_redeemLendingToken` already clamp `kTokenToRedeem` / `iSusdToRedeem` to the user's whole share balance, so a post-R1 interest withdrawal with nothing locked already redeems the position AND zeroes `s_kTokenBalances` / `s_iSusdBalances`. The old `if (total <= locked) return;` early exit only strands shares when `total == 0` — i.e. a balance whose underlying truncates below 1 wei of stablecoin. That is the entire leak.
2. It does not close the accounting hole anyway. Every `Math.Rounding.Up` deduction on withdrawals and batch purchases leaves surplus shares in the handler that belong to no user. The sweep burns exactly `s_<x>Balances[user]`, so that surplus stays stranded regardless.
3. It adds a new failure mode to the exit path. Wiring `withdrawInterest(user, 0)` into `deleteDcaSchedule` makes the delete revert wholesale when the lending market cannot service the redemption. Confirmed by mocking Tropykus `redeem(uint256)` to return a non-zero error code (principal uses `redeemUnderlying`, so it still works): the delete reverts and the user receives nothing, where before this PR they would have received their principal. Same for Sovryn with `burn` reverting. `AGENTS.md` already records Tropykus pausing kDOC mint on 2026-04-27, so a degraded market is live risk.
4. The relaunch bar is minimal churn: new handlers plus minor bugs found in prod. The sentinel is ~8 source lines fixing a real prod race. The sweep is ~107 source lines buying a one-call UX nicety and sub-wei accounting hygiene. That trade does not clear the bar.

## Files likely touched

- `src/DcaManager.sol`
- `src/interfaces/IDcaManager.sol`
- `test/unit/FullWithdrawalTest.t.sol` (new)

## Required tests

New `test/unit/FullWithdrawalTest.t.sol`, run on every lane of the done-gate (all lanes run every test file):

- `make moc-tropykus`, `make moc-sovryn`, `STABLECOIN_TYPE=USDRIF make dex-sovryn`.
- Targeted: `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC forge test --match-contract FullWithdrawalTest -vv` (and the same with `LENDING_PROTOCOL=tropykus`).

Behaviors:

- `withdrawToken(..., type(uint256).max)` empties the schedule and pays the user; `tokenBalance` ends at 0.
- The sentinel resolves against **live** storage: a purchase between the UI read and the withdrawal does not revert the withdrawal.
- `0` still reverts `DcaManager__WithdrawalAmountMustBeGreaterThanZero`; `max` on an already-empty schedule reverts the same way; `tokenBalance + 1` still reverts `DcaManager__WithdrawalAmountExceedsBalance`.
- A `max` withdrawal of schedule A leaves schedule B's `tokenBalance` untouched, and leaves the shares backing B in the handler.
- `withdrawTokenAndInterest` with the sentinel still pays principal + interest in one call (the pre-existing interest path). Do not assert that the user's lending-token mapping is zeroed.

Fork tests: not required.

## Success criteria

- [ ] `withdrawToken(..., type(uint256).max)` withdraws the live `tokenBalance` and zeros that schedule; any other amount above `tokenBalance` still reverts; `0` still reverts.
- [ ] A full withdrawal of schedule A does not touch schedule B's principal or shares.
- [ ] Done-gate lanes pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: no signature changes. `withdrawToken` / `withdrawTokenAndInterest` accept a new sentinel value for an argument that used to revert. Existing events only.
- Scripts: none.
- Cutover: the frontend may send `type(uint256).max` for "withdraw everything in this schedule" instead of reading `tokenBalance` first. Closing a position remains two calls (withdrawal then interest), or one via `withdrawTokenAndInterest` with the sentinel. That combined call still does not promise to burn leftover lending tokens.
- Observable side effect: the zero-amount check now runs after `_validateScheduleId`, so `withdrawToken(token, idx, wrongId, 0)` reverts with the schedule-id error instead of `DcaManager__WithdrawalAmountMustBeGreaterThanZero`.
