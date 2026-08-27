# R41 — Reject fee-on-transfer deposits

Status: **not started** · Assigned: no · Optional/further-review: no

**Must land before R9** (new custom error is ABI). Stack on R21 (PR 13 / [#54](https://github.com/BitChillRSK/dca-contracts/pull/54)).

## Objective

Keep R21’s hop-1 balance-delta measurement, but revert the whole deposit if the handler received anything other than the requested amount. Listed stables are 1:1; a surprise transfer fee must fail closed, not credit a shortfall.

## Background

[R21](./R21-fee-on-transfer-deposits.md) measures `balanceOf(this)` around `transferFrom`, reverts on **zero** received, and otherwise credits whatever arrived. That prevents `DcaManager` from booking more than the handler holds. It also *accepts* a partial FOT haircut: the user gets a smaller `tokenBalance` than they approved.

FOT is not a supported token class (DOC, USDRIF, USDT0). For those tokens `received == requested` always. The shortfall path only exists for a proxy that turns a fee on. Fail-closed is better there: the `transferFrom` rolls back with the rest of the tx, the user is not left with a schedule they did not intend, and hop-2 lending never sees a short deposit.

R21’s measurement stays. This PR tightens the predicate from `received == 0` to `received != requested` (requested is already `> 0` via `_validateDeposit`). Zero-received is then a subset of the new error; delete `TokenHandler__ZeroStablecoinReceived` rather than keep two errors for one check.

Withdrawals stay on the R20 rule (requested amount leaves `tokenBalance`). Do not start measuring the user’s inbound `balanceOf` on withdraw.

Lending hop-2 (a 1:1 stable whose *lending market* pays fewer shares than the stablecoin pulled) is unchanged: hop-1 still matches, then mint uses received. R21 tests that used a FOT *stablecoin* to exercise hop-2 lag will no longer reach mint — rewrite those to a 1:1 mock stable and a fee-taking lending mock if hop-2 coverage is still wanted; the FOT-stablecoin cases become revert tests.

Decided 2026-08-27: **revert on any hop-1 mismatch**.

## Open product decisions

**none**.

## Scope

- [ ] `TokenHandler.depositToken`: after measuring `depositedAmount`, revert
      `TokenHandler__DepositAmountMismatch(uint256 requested, uint256 received)` if
      `depositedAmount != depositAmount`. Drop `TokenHandler__ZeroStablecoinReceived`.
- [ ] Event still reports received, and only emits on success (so it always equals requested).
- [ ] `DcaManager` create / extra-deposit still credit the handler return (now guaranteed equal to the request). Do not add a second check there.
- [ ] Rewrite `FeeOnTransferDepositTest`: a FOT `transferFrom` on deposit/create **reverts** and leaves no schedule credit; the user’s wallet is unchanged (full rollback). Keep “another user’s funds untouched.”
- [ ] Keep the named insufficient-balance guards on buy/withdraw (R21: they are not FOT defenses).

## Out of scope

- [ ] Reverting withdraw when the user received less than sent (still no recipient-side measurement).
- [ ] Supporting FOT as a product.
- [ ] Changing R20 withdraw accounting.
- [ ] Isolating one underfunded buyer inside `batchBuyRbtc`.

## Files likely touched

- `src/TokenHandler.sol`, `src/interfaces/ITokenHandler.sol`
- `test/unit/FeeOnTransferDepositTest.t.sol`
- Any natspec on `DcaManager.depositToken` / `createDcaSchedule` that still says the schedule is credited with whatever arrived if that now only equals the request

## Required tests

```
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC \
  forge test --match-path "test/unit/FeeOnTransferDepositTest.t.sol" -j 1
```

Then `make check`.

- 1:1 deposit still credits the requested amount (existing lanes).
- FOT `transferFrom` on `createDcaSchedule` and `depositToken` reverts `TokenHandler__DepositAmountMismatch`; no `TokenBalanceUpdated` / `TokenDeposited`; user balance restored.
- Zero-received still reverts (same error, `received == 0`).
- Withdraw of a 1:1 deposit is unchanged.

Fork: no new assertions. Still run both fork lanes before push.

## Success criteria

- [ ] Hop-1 `received != requested` reverts; 1:1 deposits unchanged.
- [ ] `TokenHandler__ZeroStablecoinReceived` is gone.
- [ ] FOT tests expect revert, not a short credit.
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Invariant 1 still holds (measure, then require the measured amount equal the request).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: new error `TokenHandler__DepositAmountMismatch(uint256,uint256)`; remove `TokenHandler__ZeroStablecoinReceived()`. No function selector change.
- Scripts: none.
- Cutover: none for the UI (1:1 tokens never hit it). No frontend issue unless the app special-cased the old zero-received error string.
