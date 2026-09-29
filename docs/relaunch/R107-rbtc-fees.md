# R107 — rBTC / WRBTC purchase fees

Status: **not started** · Assigned: yes · Optional/further-review: no · Stack on: R106 ([#172](https://github.com/BitChillRSK/dca-contracts/pull/172))

## Objective

Charge BitChill’s purchase fee in native rBTC on MoC routes and WRBTC on Dex routes,
pushed to the fee collector in the same purchase transaction after buyer credits. The
venue spends the full retrieved stablecoin; `minRbtcOut` stays a bound on gross measured
venue output. No currency toggle.

## Background

Production today peels a stablecoin fee to `s_feeCollector` before MoC / Uniswap spends the
net. That leaves BitChill holding DOC / USDRIF / USDT0 and charges the full fee even when
retrieval or fill is short. Product decision (2026-09-29): hardcode rBTC / WRBTC fees so
treasury income is BTC, converts at the users’ price on arrival, and shares execution
shortfall with buyers. Admin-configurable currency was rejected (dual pipeline forever,
public timing lever). Land before the audit revision freezes.

R87 dropped `PurchaseFees__FeeTransferred` because the stablecoin `Transfer` was enough
telemetry. Native MoC fee payments emit no ERC-20 `Transfer`, so this PR re-adds
`PurchaseFees__FeeTransferred` and emits it on every route (MoC and Dex) for uniform
monitoring. `token` is `address(0)` for native rBTC and the WRBTC address on Dex.

Do **not** credit the collector through `_creditRbtc`: that mixes revenue into the users’
ledger, keeps fee custody on the handler, and needs a withdraw from every leaf. A push
keeps handler rBTC as users’ claims only. Pay the fee **last** — after buyer credits,
`RbtcBought` / batch events, and other handler state writes — so a failing collector call
or WRBTC transfer reverts the whole purchase rather than leaving partial accounting.

## Open product decisions

**none** — decided 2026-09-29: option (2) hardcoded rBTC / WRBTC fees; no toggle; EOA
collector; gross `minRbtcOut`; fee event on every route.

## Scope

- [ ] `PurchaseRbtc.batchBuyRbtc`: retrieve gross → spend full retrieved at venue → allocate
      measured output `Q` as `fee = floor(Q × F / G)` and row credit `floor(Q × nᵢ / G)` where
      `G` is planned gross (`∑ purchaseAmounts`), `F` is the aggregated fee in stablecoin
      units from `_calculateFeeAndNetAmounts`, and `nᵢ` is each row’s planned net. Do **not**
      allocate all of `Q` over net weights and then take another fee.
- [ ] `amountSpent` / `SuccessfulRbtcBatchPurchase.totalStablecoinAmountSpent` report **gross**
      venue input (row share of retrieved / total retrieved). Average price is all-in.
- [ ] Remove stablecoin `_transferFee` from the purchase path. Remove
      `PurchaseRbtc__StablecoinRetrievedBelowFee` (short retrieval spends what it got; fee
      shrinks with `Q`).
- [ ] Keep `_transferFee` on `PurchaseFees` as the payment hook (same place R78 named). Default
      is native rBTC to the collector (`call{value:}` + `FeeTransferred(address(0), …)`), matching
      `_withdrawRbtc`: MoC inherits, Dex overrides.
      - `PurchaseUniswap`: `safeTransfer` WRBTC + `FeeTransferred(address(i_wrbtc), …)`.
      - Zero fee: no-op (no event).
- [ ] Re-add `PurchaseFees__FeeTransferred(address indexed token, address indexed collector, uint256 amount)`.
      Do not index `amount`.
- [ ] `minRbtcOut` continues to bind **gross** measured venue output before the fee peel.
- [ ] Floor dust: `fee + ∑ row credits ≤ Q`; uncredited wei stays on the handler (R69 stands).
- [ ] Update unit / integration tests that assumed a stablecoin fee transfer or
      `StablecoinRetrievedBelowFee`.
- [ ] Consumer cutover issues (bot quotes gross; monitoring fee event; `amountSpent` meaning).
- [ ] Assign this spec; update README Status and `IMPLEMENTATION_ORDER.md`.

## Out of scope

- [ ] Admin-configurable fee currency (rejected).
- [ ] Crediting the collector via `_accumulate` / `_creditRbtc`.
- [ ] Changing fee rate math, BPS, flat / variable paths, or collector setters.
- [ ] Unwrapping WRBTC fees on every Dex purchase (collector unwraps infrequently off-path).
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
- `test/unit/NetRedemptionTest.t.sol`
- `test/mocks/PurchaseFeesHarness.sol`
- `test/ai-generated/unit/PurchaseFeesTest.t.sol`
- `docs/relaunch/R107-rbtc-fees.md`
- `docs/relaunch/README.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
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

- Full retrieval: venue input equals planned gross; buyers credited `floor(Q × nᵢ / G)`;
  collector receives `floor(Q × F / G)` as native rBTC (MoC) or WRBTC (Dex).
- Short retrieval: venue spends retrieved; fee and credits scale with `Q`; no
  `StablecoinRetrievedBelowFee`.
- Zero fee rate: no payment, no `FeeTransferred`.
- Fee payment failure (rejecting collector / failing WRBTC transfer) reverts the whole batch
  including credits and events.
- `minRbtcOut` compares gross `Q` before fee peel; violation rolls back fee and credits.
- Floor dust: `fee + ∑ credits ≤ Q`; last row does not take a remainder of `Q`.
- `amountSpent` is the row’s share of gross retrieved stablecoin.

No new fork-specific assertions required beyond the production fork lanes.

## Success criteria

- [ ] Fee paid last on every successful purchase path (rBTC MoC / WRBTC Dex); stablecoin fee
      transfer gone.
- [ ] Conservation / rounding pinned: `floor(Q×F/G)` + `∑ floor(Q×nᵢ/G) ≤ Q`.
- [ ] Gross `minRbtcOut`; gross `amountSpent` / batch spent totals.
- [ ] `PurchaseFees__FeeTransferred` on MoC (`token=0`) and Dex (`token=WRBTC`).
- [ ] `make check` + both production fork lanes green.
- [ ] Consumer issues opened / updated; URLs in the PR cutover note.
- [ ] Spec assigned; README Status and `IMPLEMENTATION_ORDER.md` updated.
- [ ] Local fee-currency options note remains untracked.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (exact stablecoin consumption on gross
      venue input; rBTC pays the signer for user withdrawals; fee is not user-ledger credit).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.
- [ ] `docs/relaunch/FEE-CURRENCY-OPTIONS.md` (if present locally) is **not** in the diff.

## ABI / deploy / cutover impact

- ABI: remove `PurchaseRbtc__StablecoinRetrievedBelowFee`; add
  `PurchaseFees__FeeTransferred`; `RbtcBought.amountSpent` and batch spent totals change
  meaning (net → gross). No function selector changes on `batchBuyRbtc`.
- Scripts: none required (fee collector address unchanged).
- Cutover:
  - **swapper-bot** — quote Dex / MoC `minRbtcOut` from **gross** stablecoin input (not
    post-fee 99%); update [swapper-bot#6](https://github.com/BitChillRSK/swapper-bot/issues/6).
  - **bitchill-monitoring** — subscribe to `PurchaseFees__FeeTransferred`; stop expecting a
    stablecoin `Transfer` to the collector on purchase; MoC fees are native (`token=0`).
  - **front-end** — fee copy stays “1%”; average price from `amountSpent` is all-in; show fee
    in sats carefully.
  - **data-api** / **metrics-dashboard** — `amountSpent` / batch spent are gross if indexed.
