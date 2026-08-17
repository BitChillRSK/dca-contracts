# R1 / R20 — Integration cash accounting: measured balances, not integrator return values

Status: **assigned** · Assigned: yes (PR 8) · Optional/further-review: no

## Objective

Stop treating a lending protocol's return values and views as cash. After any call that is supposed to move
tokens or native to us (or to the user), the measured balance delta is the amount received; return values are
success/failure only, and rates size share burns and nothing else. This is what makes the Sovryn handlers
survive SIP-0094's 0.1% Perimeter Fee, where `burn` returns GROSS and pays NET.

## Background

Sovryn's SIP-0094 adds a 0.10% exit fee on iToken `burn`. The integrator note is explicit: *return values are
GROSS, payouts are NET.* `SovrynErc20Handler` treats `burn`'s return as DOC received, so once the fee is
enabled every Sovryn path that spends or transfers that number asks for more DOC than the handler holds and
**reverts**: purchases, `withdrawToken`, `deleteDcaSchedule`, `withdrawTokenAndInterest`. Funds are not stolen
(the tx rolls back) but they are stuck until the handler is replaced. `withdrawInterest` does not revert — it
pays the user ~99.9% while the event claims 100%.

R20 is the same class, generalised. We do trust Sovryn, Tropykus, MoC, and Uniswap to hold funds and execute
mint / burn / swap; a year in production is the right baseline. R20 is not "sandbox them." The bar is: if an
integration adds a fee, pauses, or retunes a rate, BitChill must **haircut or revert** — never desync its own
accounting, and never `safeTransfer` more than it holds. Tropykus already measured deltas on mint and redeem,
which is exactly why the same fee would not have frozen those handlers.

Two `assetBalanceOf` / `profitOf` facts, since the current preflight is built on a wrong model: Sovryn's
`assetBalanceOf` is already `iTokenBalance * tokenPrice`, i.e. current underlying with interest included, and
`profitOf` is checkpointed interest — a **subset** of it. Adding them double-counts profit, so the cap is
inflated and effectively never fires. This is the same shape as the Tropykus `getSupplierSnapshotStored` cap
already removed in `89d4f09`: a protocol view used as a redeem ceiling.

Related invariants: `AGENTS.md` 1 (balance-delta cash) and 2 (no view as redeem ceiling) — this spec is the PR
that makes the code match them. Invariant 6 (`nonReentrant` on every schedule mutator) is load-bearing here,
because the clamp fix below writes to `s_dcaSchedules` after an external call.

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no Ask for PR 8. Implement without asking.

## Scope

- [ ] `SovrynErc20Handler._redeemStablecoin(user, amount, rate, recipient)`: measure the **recipient's**
      stablecoin balance before/after `burn` and return that delta. This covers both recipients: the handler
      (purchases, `withdrawToken`) and the user (`withdrawInterest`, where the handler cannot read its own
      delta).
- [ ] `SovrynErc20Handler._batchRedeemStablecoin`: **delete** the `assetBalanceOf + profitOf` preflight and its
      `int256` round-trip. Do not replace it with `assetBalanceOf` alone. Measure the handler's stablecoin
      delta around `burn` and return the net. Over-redeeming now fails inside `burn`, where it belongs.
- [ ] `SovrynErc20Handler.depositToken`: credit `s_iSusdBalances` with the measured iToken `balanceOf` delta
      instead of `mint`'s return value (Tropykus already does this). Keep the zero-mint revert, driven off the
      delta.
- [ ] `PurchaseMoc.batchBuyRbtc`: spend the amount actually redeemed minus the aggregated fee, not the
      precomputed gross. Keep the **planned** net total as the denominator when splitting purchased rBTC
      across buyers, so the per-user weights still sum to exactly 1 and the contract can never credit more
      rBTC than it received. Revert with a named error if the redeemed amount cannot cover the fee.
- [ ] `PurchaseUniswap._swapStablecoinForWrbtc`: return the measured WRBTC `balanceOf` delta rather than
      `exactInput`'s `amountOut`. Keep `amountOutMinimum` exactly as is.
- [ ] `PurchaseUniswap.batchBuyRbtc`: same treatment as `PurchaseMoc`. It already spends the redeem result,
      but it overwrites the planned net total with `redeemed - aggregatedFee` and then divides the per-user
      weights by that smaller number, while `netStablecoinAmountsToSpend[i]` still sums to the planned total —
      so a short redemption credits `purchased * planned / actual`, more WRBTC than the handler received.
      Keep the planned net total as the denominator and carry the actual spend in its own variable. This is
      latent today only because the Sovryn redeem returns gross and the path reverts at the swap instead; the
      net-returning redeem in this PR is what arms it.
- [ ] `TropykusErc20Handler.withdrawToken`: transfer the amount `_redeemStablecoin` actually produced, not the
      requested amount. Sovryn already assigns the redeem result; Tropykus discarded it.
- [ ] `ITokenHandler.withdrawToken` returns `uint256` — the amount actually paid to the user. `TokenHandler`,
      `TropykusErc20Handler`, and `SovrynErc20Handler` all return their real payout.
- [ ] **Clamp desync (the R6 leftover; this PR owns it).** The handlers must stop paying out a number they
      did not receive: `TropykusErc20Handler.withdrawToken` transfers the redeemed amount, and both handlers
      return what they actually paid. `DcaManager._withdrawToken` keeps debiting the **requested** amount and
      writes `tokenBalance` before the call, unchanged. Cash received drives what is transferred, what is
      credited as rBTC, and what events report — it must not drive schedule principal. A redemption fee
      consumes principal that is gone, so crediting the difference back would invent principal the handler no
      longer holds and leave dust that later reverts in `burn`. Purchases already debit the full
      `purchaseAmount` regardless of fees; withdrawals match that.
- [ ] `DcaManager.deleteDcaSchedule`: emit the amount the handler actually paid in
      `DcaManager__DcaScheduleDeleted`. The schedule is already gone, so there is no balance to correct — only
      the event must stop overstating.
- [ ] Drop `profitOf` from `IiSusdToken` and `TokenLending__UnderlyingRedeemAmountExceedsBalance` from
      `ITokenLending`; both die with the preflight.

## Out of scope

- [ ] Anything else in `PurchaseUniswap`. The swap path is brought in line with the balance-delta rule and its
      batch split is corrected because this PR arms that bug; the Dex handlers are otherwise untouched and are
      not deployed this relaunch (`R22`).
- [ ] R15's `type(uint256).max` withdraw sentinel and lending-share dust sweep. This PR settles net redemption
      first; R15 follows.
- [ ] Rebuilding deposit accounting around a measured `transferFrom`. DOC and USDRIF are not fee-on-transfer.
      Do not add that trust assumption.
- [ ] Fee-model changes, event re-indexing (R9), storage packing (R18), pause (R19), folder moves (R22).
- [ ] Any ops action on live handlers. The cutover (buffer drain, then repointing `OperationsAdmin`) is
      operational and belongs to the cutover checklist, not to this PR.

## Files likely touched

- `src/SovrynErc20Handler.sol`
- `src/TropykusErc20Handler.sol`
- `src/TokenHandler.sol`
- `src/PurchaseMoc.sol`
- `src/PurchaseUniswap.sol`
- `src/DcaManager.sol`
- `src/interfaces/ITokenHandler.sol`
- `src/interfaces/ITokenLending.sol`
- `src/interfaces/IiSusdToken.sol`
- `src/interfaces/IPurchaseRbtc.sol` (one new error for the fee-exceeds-redeemed case)
- `test/mocks/MockIsusdToken.sol` (settable exit fee: gross return, net payout)
- `test/ai-generated/unit/SovrynErc20HandlerTest.t.sol` (the preflight test goes with the preflight)
- new targeted test file for net-redemption behaviour

## Required tests

- `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn forge test --match-path <new test file>` — the targeted lane.
- Done-gate: `make check`.
- Fork tests: **not required**. The mock exit fee reproduces gross-return/net-payout deterministically; a fork
  cannot, because the Perimeter Fee is not enabled on mainnet yet.

Behaviours to assert, with the mock's exit fee **enabled** (returns gross, pays net):

- `buyRbtc` and `batchBuyRbtc` on Sovryn+MoC succeed, and spend the net amount rather than reverting.
- Sum of per-user accumulated rBTC credited by a batch is never greater than the rBTC the handler received,
  on both the MoC and the Uniswap batch paths.
- `withdrawToken` pays the user the net amount, while the schedule's `tokenBalance` drops by exactly what was
  requested. The fee is not credited back as phantom principal.
- `deleteDcaSchedule` succeeds and its event reports the amount actually paid.
- `withdrawInterest` pays net and emits net.
- With the exit fee at **0** (fail-open, or pre-activation), every one of the above is 1:1 with the requested
  amount — no silent haircut appears where there is no fee.
- Tropykus paths behave identically before and after this PR, except `withdrawToken` now transfers the
  redeemed amount.
- After a withdrawal reduced by the exit fee, the schedule's remaining balance is exactly what was not
  requested, and that remainder is still withdrawable.

## Success criteria

- [ ] No first-party path credits, transfers, or spends a Sovryn / Tropykus / MoC / Uniswap **return value**
      as cash.
- [ ] No protocol view is used as a ceiling on how much stablecoin a redemption will produce.
- [ ] Sovryn `_batchRedeemStablecoin` has no `assetBalanceOf` / `profitOf` preflight; an over-redeem fails
      inside `burn`.
- [ ] Purchases, `withdrawToken`, `deleteDcaSchedule`, and `withdrawTokenAndInterest` all succeed against a
      mock that returns gross and pays net, and all move the net amount.
- [ ] The same tests with the fee at 0 stay exactly 1:1.
- [ ] `DcaManager.tokenBalance` decreases by the requested amount; no cash-received figure is ever written
      back onto a schedule.
- [ ] Tropykus behaviour is unchanged except that `withdrawToken` transfers the redeemed amount.
- [ ] `make check` passes.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] No batch path divides per-user weights by anything other than the planned net total they sum to.
- [ ] `AGENTS.md` invariants 1 and 2 now hold in code, and 3-7 are unchanged.
- [ ] Every state write that happens after an external call reads storage at that point; no stale memory copy
      is written back.
- [ ] Tests in the PR match **Required tests**, including the fee=0 parity cases.
- [ ] Files beyond the list above are direct dependencies and are named in the PR.

## ABI / deploy / cutover impact

- **ABI:** `ITokenHandler.withdrawToken` now returns `uint256`. Additive for callers that ignore it; the
  4-byte selector is unchanged. One new error on `IPurchaseRbtc`. `TokenLending__UnderlyingRedeemAmountExceedsBalance`
  is removed. No event topic changes (that is R9).
- **Scripts:** none.
- **Cutover:** the live Sovryn handler still cannot be patched. Drain it with a subsidised buffer *before*
  repointing `OperationsAdmin` at a new handler, and only once every Sovryn schedule is empty and rBTC is
  claimed. Frontend must know that interest withdrawals on the old handler haircut ~0.1%. None of this is an
  instruction to execute here.
