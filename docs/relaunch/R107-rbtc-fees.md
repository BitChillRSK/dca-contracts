# R107 — rBTC / WRBTC purchase fees

Status: **in review** · Assigned: yes · Optional/further-review: no · Stack on: R106 ([#172](https://github.com/BitChillRSK/dca-contracts/pull/172)) · PR: [#173](https://github.com/BitChillRSK/dca-contracts/pull/173)

## Objective

Charge BitChill’s purchase fee in native rBTC on MoC routes and WRBTC on Dex routes.
The venue spends the full retrieved stablecoin; `minRbtcOut` stays a bound on gross measured
venue output. The collector’s floored share is **credited** on the same accumulated-rBTC
books as buyers (`s_accumulatedRbtc`) and withdrawn later through
`withdrawAccumulatedRbtc`. No currency toggle.

## Background

Production today peels a stablecoin fee to `s_feeCollector` before MoC / Uniswap spends the
net. That leaves BitChill holding DOC / USDRIF / USDT0 and charges the full fee even when
retrieval or fill is short. Product decision (2026-09-29): hardcode rBTC / WRBTC fees so
treasury income is BTC, converts at the users’ price on arrival, and shares execution
shortfall with buyers. Admin-configurable currency was rejected (dual pipeline forever,
public timing lever). Land before the audit revision freezes.

A first cut of this PR **pushed** native rBTC (MoC) or WRBTC (Dex) to the collector in the
purchase transaction. That was discarded in-PR (2026-09-30): a push needs a Dex
`_transferFee` override, reverts the whole batch if the collector cannot receive native
rBTC, and is more expensive on the hot path than one extra `_creditRbtc`. The collector is
a **passive EOA** that will not open a BitChill position. Credits to that address are fees;
`PurchaseFees__FeeCredited` versus `PurchaseRbtc__RbtcBought` lets monitoring reconstruct
history even if the same address later bought. Mixing the mapping is therefore acceptable.
The mapping is renamed `s_usersAccumulatedRbtc` → `s_accumulatedRbtc` because it is no
longer users-only.

R87 dropped `PurchaseFees__FeeTransferred` because the stablecoin `Transfer` was enough
telemetry. There is still no ERC-20 `Transfer` on a MoC fee (nothing is pushed), so this PR
emits `PurchaseFees__FeeCredited(collector, rbtcAmount, stablecoinAmount)` on every route.
`rbtcAmount` is the floored share of measured output; `stablecoinAmount` is that same share
of retrieved venue input so off-chain can compute BitChill’s all-in price
(`stablecoinAmount / rbtcAmount`). Dex WRBTC stays on the handler until the collector
withdraws (unwrap then native, same seam as buyers).

Pay the fee **last** — after buyer credits and the batch event — so the collector’s
storage write is the last accounting step. A zero floored `feeRbtc` is a no-op and emits
nothing. A rejecting collector **does not** revert the purchase; it only fails that
address’s later withdraw (`PurchaseRbtc__rBtcWithdrawalFailed`). `setFeeCollector` does not
migrate already-credited balances.

## Open product decisions

**none** — rBTC/WRBTC fees decided 2026-09-29; credit-not-push decided 2026-09-30 in this PR.

## Scope

- [ ] `PurchaseRbtc.batchBuyRbtc`: retrieve gross → spend full retrieved at venue → allocate
      measured output `Q` as `fee = floor(Q × F / G)` and row credit `floor(Q × nᵢ / G)` where
      `G` is `purchaseAmountsSum` (`∑ purchaseAmounts`), `F` is the total fee in stablecoin
      units from `_calculateFeeAndNetWeights`, and `nᵢ` is each row’s net weight. Do **not**
      allocate all of `Q` over net weights and then take another fee.
- [ ] `amountSpent` / `SuccessfulRbtcBatchPurchase.totalStablecoinAmountSpent` report **gross**
      venue input (row share of retrieved / total retrieved). Average price is all-in.
- [ ] Remove stablecoin `_transferFee` from the purchase path. Remove
      `PurchaseRbtc__StablecoinRetrievedBelowFee` (short retrieval spends what it got; fee
      shrinks with `Q`).
- [ ] `_payFee` on `PurchaseRbtc` (no Dex override): `_creditRbtc(collector, feeRbtc)` and
      emit `FeeCredited`. Rename `s_usersAccumulatedRbtc` → `s_accumulatedRbtc`.
- [ ] `PurchaseFees__FeeCredited(address indexed collector, uint256 rbtcAmount, uint256 stablecoinAmount)`.
      Asset is implied by the emitting handler. `stablecoinAmount = retrieved × F / G`.
      Zero `feeRbtc`: no-op, no event.
- [ ] `minRbtcOut` continues to bind **gross** measured venue output before the fee peel.
- [ ] Floor dust: `fee + ∑ row credits ≤ Q`; uncredited wei stays on the handler (R69 stands).
- [ ] Update unit / integration tests that assumed a stablecoin fee transfer, a native/WRBTC
      push, or `StablecoinRetrievedBelowFee`.
- [ ] Consumer cutover issues (bot quotes gross; monitoring `FeeCredited`; `amountSpent` meaning).
- [ ] Assign this spec; update README Status and `IMPLEMENTATION_ORDER.md`.

## Out of scope

- [ ] Admin-configurable fee currency (rejected).
- [ ] Pushing rBTC/WRBTC to the collector in the purchase transaction.
- [ ] Changing fee rate math, BPS, flat / variable paths, or collector setters.
- [ ] Unwrapping WRBTC on every Dex purchase (collector unwraps on withdraw, same as buyers).
- [ ] Deploy broadcast / live addresses.
- [ ] Committing any local product-decision note that is not this assigned spec.

## Files likely touched

- `src/PurchaseRbtc.sol`
- `src/PurchaseFees.sol`
- `src/PurchaseMoc.sol`
- `src/PurchaseUniswap.sol`
- `src/interfaces/IPurchaseRbtc.sol`
- `src/interfaces/IPurchaseFees.sol`
- `test/unit/PurchaseRbtcTest.t.sol`
- `test/unit/DcaDappTest.t.sol`
- `test/unit/NetRedemptionTest.t.sol`
- `test/unit/EventIndexingTest.t.sol`
- `test/unit/BatchMinRbtcOutTest.t.sol`
- `test/unit/PurchaseUniswapExactConsumptionTest.t.sol`
- `test/mocks/PurchaseFeesHarness.sol`
- `test/ai-generated/unit/PurchaseFeesTest.t.sol`
- `test/ai-generated/fuzz/PurchaseRbtcConservationInvariant.t.sol`
- `test/ai-generated/fuzz/LendingPurchaseConservationInvariant.t.sol`
- `test/ai-generated/fuzz/README_INVARIANTS.md`
- `AGENTS.md`
- `docs/relaunch/R107-rbtc-fees.md`
- `docs/relaunch/README.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/CUTOVER_RUNBOOK.md` (collector withdraws per handler; payable receive is for
  withdraw, not every MoC purchase)
- `.gitignore` (keep any local fee-currency decision note untracked)

## Required tests

Executable `src/` change → full gate:

1. Targeted: `forge test --match-path test/unit/PurchaseRbtcTest.t.sol`
2. Targeted: `forge test --match-path test/unit/NetRedemptionTest.t.sol` (Sovryn MoC mocks)
3. Targeted: `forge test --match-path test/ai-generated/unit/PurchaseFeesTest.t.sol`
4. `make check`
5. `make fork-sovryn`
6. `make fork-layerbank`

Behaviors to assert:

- Full retrieval: venue input equals `purchaseAmountsSum`; buyers credited `floor(Q × nᵢ / G)`;
  collector credited `floor(Q × F / G)` on the same books (native rBTC MoC / WRBTC Dex still
  on the handler until withdraw).
- Short retrieval: venue spends retrieved; fee and credits scale with `Q`; no
  `StablecoinRetrievedBelowFee`.
- Zero fee rate: no credit, no `FeeCredited`.
- A rejecting collector does **not** revert the batch; its later withdraw reverts
  `rBtcWithdrawalFailed` and leaves the credit.
- `minRbtcOut` compares gross `Q` before fee peel; violation rolls back fee credit and buyer credits.
- Floor dust: `fee + ∑ credits ≤ Q`; last row does not take a remainder of `Q`.
- `amountSpent` is the row’s share of gross retrieved stablecoin.
- `FeeCredited.stablecoinAmount` is the retrieved share (`retrieved × F / G`), not raw `F`.

No new fork-specific assertions required beyond the production fork lanes.

## Success criteria

- [ ] Fee credited last on every successful purchase path; stablecoin fee transfer gone; no
      Dex `_transferFee` override.
- [ ] Conservation / rounding pinned: `floor(Q×F/G)` + `∑ floor(Q×nᵢ/G) ≤ Q`.
- [ ] Gross `minRbtcOut`; gross `amountSpent` / batch spent totals.
- [ ] `PurchaseFees__FeeCredited` on every successful non-zero-fee purchase (MoC and Dex).
- [ ] `s_accumulatedRbtc` is the only accumulated-rBTC mapping; invariant 13 names it.
- [ ] `make check` + both production fork lanes green.
- [ ] Consumer issues opened / updated; URLs in the PR cutover note.
- [ ] Spec assigned; README Status and `IMPLEMENTATION_ORDER.md` updated.
- [ ] Local fee-currency options note remains untracked.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (exact stablecoin consumption on gross
      venue input; rBTC pays the signer for withdrawals, including the collector’s; collector
      credit is on `s_accumulatedRbtc`).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.
- [ ] `docs/relaunch/FEE-CURRENCY-OPTIONS.md` (if present locally) is **not** in the diff.

## ABI / deploy / cutover impact

- ABI: remove `PurchaseRbtc__StablecoinRetrievedBelowFee`; add
  `PurchaseFees__FeeCredited(address indexed collector, uint256 rbtcAmount, uint256 stablecoinAmount)`;
  do **not** add `FeePaymentFailed`. `RbtcBought.amountSpent` and batch spent totals change
  meaning (net → gross). `SuccessfulRbtcBatchPurchase.totalPurchasedRbtc` is still gross
  measured output and now includes the collector's share, so it generally exceeds
  `∑ RbtcBought.rBtcBought`. No function selector changes on `batchBuyRbtc`.
- Scripts: none required (fee collector address unchanged). The collector is a passive EOA.
  It withdraws per handler through `DcaManager.withdrawAccumulatedRbtc`; Dex unwraps WRBTC
  then pays native. See [`CUTOVER_RUNBOOK.md`](./CUTOVER_RUNBOOK.md).
- Cutover:
  - **swapper-bot** — quote Dex / MoC `minRbtcOut` from **gross** stablecoin input (not
    post-fee 99%); [swapper-bot#15](https://github.com/BitChillRSK/swapper-bot/issues/15).
  - **bitchill-monitoring** — subscribe to `PurchaseFees__FeeCredited` (rBTC + stablecoin
    amounts); stop expecting a stablecoin `Transfer` to the collector on purchase; do not
    watch `PurchaseFees__FeePaymentFailed`. Do not alert on
    `∑ RbtcBought.rBtcBought != SuccessfulRbtcBatchPurchase.totalPurchasedRbtc`: the batch
    total is gross `Q` and includes the collector's share.
    [bitchill-monitoring#27](https://github.com/BitChillRSK/bitchill-monitoring/issues/27).
  - **front-end** — fee copy stays “1%”; average price from `amountSpent` is all-in; show fee
    in sats carefully. Collector withdraw uses the existing accumulated-rBTC path.
  - **data-api** / **metrics-dashboard** — `amountSpent` / batch spent are gross if indexed.
    `totalPurchasedRbtc` includes the collector's share and generally exceeds the sum of
    buyer credits. `FeeCredited.stablecoinAmount` is the fee’s share of retrieved input.
