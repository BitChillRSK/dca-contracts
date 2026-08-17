# R15 — Withdraw-all sentinel and lending-share dust

Status: **in review** · Assigned: yes · Optional/further-review: no

## Objective

Let a user empty a schedule without racing the swapper (`withdrawalAmount == type(uint256).max` means "this schedule's whole `tokenBalance`"), and stop leftover lending shares from staying mapped to a user who has nothing locked on that handler any more.

## Background

Two different leftovers. They share files; they are not the same bug.

**1. Schedule accounting.** `withdrawToken` / `withdrawTokenAndInterest` need an exact `withdrawalAmount`. The UI reads `tokenBalance`, then sends the tx; if a purchase lands in between, `DcaManager__WithdrawalAmountExceedsBalance` reverts the withdrawal. `type(uint256).max` resolved against live storage removes the race. `deleteDcaSchedule` already withdraws the whole `tokenBalance` with no amount argument, and rBTC withdrawals already send everything, so neither needs a sentinel.

**2. Lending-share dust.** Handler lending balances (`s_kTokenBalances`, `s_iSusdBalances`) are pooled per user + token + protocol, not per schedule. Stablecoin → shares rounds up (`Math.Rounding.Up`); shares → stablecoin truncates. So after the last withdrawal a user can hold shares that convert to **0** stablecoin. `withdrawInterest` then hits `if (totalInLending <= locked) return;` and those shares stay mapped to that user forever — the handler never lets go of them and the user has no call that will.

The fix is to burn *shares*, not a stablecoin amount converted back into shares: when the user locks nothing on that handler, burn the whole remaining share balance, pay out whatever underlying actually arrives (may be 0 or 1 wei), and zero the mapping. Both handlers' existing redeem helpers revert when the payout is 0 (`TropykusErc20Lending__ZeroStablecoinRedeemed`, `SovrynErc20Lending__RedeemUnderlyingFailed`), which is right for a real redemption and wrong for a dust sweep, so the sweep needs its own path.

`type(uint256).max` means **this schedule's principal**, not principal + interest. Interest keeps its own entry points.

Related and already landed in PR 8 (R1/R20): Tropykus `withdrawToken` transfers what the redemption produced instead of the requested amount. Nothing left to do there.

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 10. Implement without asking.

## Scope

- [ ] `DcaManager._withdrawToken`: resolve `withdrawalAmount == type(uint256).max` to the schedule's live `tokenBalance` before the zero / exceeds checks. Both existing reverts stay for every other amount.
- [ ] `DcaManager.deleteDcaSchedule`: after the principal withdrawal, if the caller locks nothing else on that token + `lendingProtocolIndex`, sweep the handler's remaining shares. Skip silently when the protocol index yields no interest (an idle handler must still be deletable).
- [ ] `TropykusErc20Handler.withdrawInterest` / `SovrynErc20Handler.withdrawInterest`: when `stablecoinLockedInDcaSchedules == 0` and the user holds shares, burn **all** of them, transfer whatever underlying arrived, and zero the user's share balance. A 0 payout must not revert.
- [ ] Natspec for the sentinel on `IDcaManager.withdrawToken` / `withdrawTokenAndInterest`, and for the sweep on `ITokenLending.withdrawInterest`.

## Out of scope

- [ ] `if (amount == max) amount = lendingToken.balanceOf(...)` or the user's share mapping inside `withdrawToken` — that would empty every schedule the user has on that protocol in one call.
- [ ] Treating `max` as "principal plus interest" on `withdrawToken`.
- [ ] Sweeping shares on a principal-only `withdrawToken` while other schedules still lock funds on that handler.
- [ ] A sentinel on `deleteDcaSchedule` or on the rBTC withdrawals; they already take everything.
- [ ] New external ABI: the sweep reuses `withdrawInterest(user, 0)`.
- [ ] R16 renames, R22 folder moves, packing, and any change to how `_withdrawToken` debits the schedule (settled in PR 8).

## Files likely touched

- `src/DcaManager.sol`
- `src/interfaces/IDcaManager.sol`
- `src/TropykusErc20Handler.sol`
- `src/SovrynErc20Handler.sol`
- `src/interfaces/ITokenLending.sol`
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
- Deleting the last schedule for a user + token + protocol leaves `getUsersLendingTokenBalance(user) == 0`.
- Deleting one of several schedules does **not** zero the user's share balance.
- `withdrawAllAccumulatedInterest` after a full principal withdrawal leaves `getUsersLendingTokenBalance(user) == 0`.
- A share balance whose underlying truncates to 0 is still swept (no revert, mapping zeroed).

Fork tests: not required.

## Success criteria

- [ ] `withdrawToken(..., type(uint256).max)` withdraws the live `tokenBalance` and zeros that schedule; any other amount above `tokenBalance` still reverts; `0` still reverts.
- [ ] After the last schedule for a user + token + protocol is deleted, the handler's share accounting for that user is 0.
- [ ] After a full principal withdrawal plus an interest withdrawal, the handler's share accounting for that user is 0.
- [ ] A full withdrawal of schedule A does not touch schedule B's principal or shares.
- [ ] A sweep that redeems 0 underlying does not revert.
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
- Cutover: the frontend may send `type(uint256).max` for "withdraw everything in this schedule" instead of reading `tokenBalance` first. Closing a position is now one call (`deleteDcaSchedule`, or `withdrawTokenAndInterest` with the sentinel) rather than a withdrawal followed by a remembered interest call.
