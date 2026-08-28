# R41 — Reject fee-on-transfer deposits

Status: **done** · Assigned: yes (PR 36) · Optional/further-review: no

PR 36 of the relaunch stack. Stack on R43 (PR 35); behavior builds on R21 (PR 13 / [#54](https://github.com/BitChillRSK/dca-contracts/pull/54)). **Must land before R36 and R9** because the new custom error is ABI and the new Dex stable deployments should inherit the settled fail-closed deposit policy.

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

- [x] `TokenHandler.depositToken`: after measuring `depositedAmount`, revert
      `TokenHandler__DepositAmountMismatch(uint256 requested, uint256 received)` if
      `depositedAmount != depositAmount`. Drop `TokenHandler__ZeroStablecoinReceived`.
- [x] Event still reports received, and only emits on success (so it always equals requested).
- [x] `DcaManager` create / extra-deposit still credit the handler return (now guaranteed equal to the request). Do not add a second check there.
- [x] Rewrite `FeeOnTransferDepositTest`: a FOT `transferFrom` on deposit/create **reverts** and leaves no schedule credit; the user’s wallet is unchanged (full rollback). Keep “another user’s funds untouched.”
- [x] Keep the named insufficient-balance guards on buy/withdraw (R21: they are not FOT defenses).

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
- Over-delivery (`received > requested`) reverts the same error.
- A drop in handler `balanceOf` during `transferFrom` reverts `TokenHandler__DepositAmountMismatch(requested, 0)`, not a panic; other users' funds roll back.
- Withdraw of a 1:1 deposit is unchanged.

Fork: no new assertions. Still run both fork lanes before push.

## Success criteria

- [x] Hop-1 `received != requested` reverts; 1:1 deposits unchanged.
- [x] `TokenHandler__ZeroStablecoinReceived` is gone. `TokenLending__ZeroStablecoinReceived` is a different error on the redeem side and stays.
- [x] FOT tests expect revert, not a short credit.
- [x] No open product decisions.

## Decisions taken while implementing

**Hop-2 coverage kept, moved off the FOT stablecoin (2026-08-28).** The spec left this open ("if hop-2 coverage
is still wanted"). It is: the four Tropykus cases assert that `DcaManager`'s book can sit ahead of the
share-backed underlying, which is what R28's per-user share clamp and `TokenLending__InsufficientShares` exist
for. They are now driven by a 1:1 stablecoin plus `MockKdocToken.setMintShortfallBps`, a market that keeps all
the cash it pulled and mints shares for only part of it. Hop 1 stays fee-free there, so `TokenHandler` never
sees a mismatch and the lag is purely hop 2. That is one knob on an existing mock rather than a new fee-taking
lending mock.

**One stablecoin mock, fee off by default.** `MockFeeOnTransferStablecoin` now starts at `feeBps == 0` — DOC,
USDRIF, and USDT0 are 1:1 — and each test opts into the fee. Turning it on *before* a deposit is the new
fail-closed case; turning it on *after* one landed models a listed token that starts charging, and keeps R21's
"withdraw still works" and R20's "principal falls by the requested amount" coverage alive.

**Three purchase-amount cases dropped.** `test_create_reverts_whenPurchaseAmountGreaterThanReceived`,
`test_create_allowsPurchaseAmountEqualToReceived`, and `test_setPurchaseAmount_reverts_whenGreaterThanReceived`
only existed to check `purchaseAmount` against a FOT-shortened credit. With no short credit they are generic
balance checks already covered by `DcaConfigurationTest` and `DcaManagerEdgeCasesTest`.

**No `vm.recordLogs` assertion for the "no event" bullet.** The deposit reverts, so the whole transaction rolls
back and neither `TokenHandler__TokenDeposited` nor `DcaManager__TokenBalanceUpdated` can be observed. The tests
assert the post-revert state instead: no schedule, no handler credit, no shares, unchanged wallet, and a zero
balance at the token's fee recipient.

**Saturating hop-1 delta (audit follow-up).** A `balanceOf` that falls during `transferFrom` used to underflow the
subtraction and panic. The delta is now `0` when `balanceAfter < balanceBefore`, so that path reverts
`TokenHandler__DepositAmountMismatch(requested, 0)` like a zero receipt. Over-delivery (`received > requested`)
is the same `!=` predicate; both branches now have tests. `MockFeeOnTransferStablecoin` gained `setExtraCredit`
and `setRecipientBurn` knobs for those cases. `createDcaSchedule` natspec no longer says purchase amount is
validated against a credited balance that can differ from the request.

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
