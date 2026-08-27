# R43 — Dex path review (peg, slippage, MEV)

Status: **PR [#85](https://github.com/BitChillRSK/dca-contracts/pull/85)** · Assigned: yes · Optional/further-review: no

PR 35 of the relaunch stack. Stack on R47 (PR 34). **Must land before R36 and R9 (ABI freeze)** because LayerBank USDRIF/USDT0 Dex consumes this path. R33 only closed the settings-invariant hole; it explicitly left oracle math, price freshness, and `amountOutMinimum` construction out of scope.

## Objective

Re-examine `PurchaseUniswap` now that dex is a production venue, not a Tropykus leftover: record the $1-stable assumption, replace or keep the slippage construction with a written reason, and decide what MEV protection is worth on Rootstock. Implement the conclusions in this PR so R36 does not clone a formula that is wrong for 6-decimal USDT0.

## Background

Dex buys go `stable → WRBTC` on SwapRouter02, then unwrap on withdraw. Cash is already R1/R20: the WRBTC `balanceOf` delta is credited; the router return is ignored. The remaining design is how `amountOutMinimum` is computed.

Today (`PurchaseUniswap._getAmountOutMinimum`):

```solidity
(uint256 currentPrice, bool isValid, ) = s_mocOracle.getPriceInfo();
if (!isValid) revert PurchaseUniswap__OutdatedPrice();
minimumRbtcAmount = (stablecoinAmountToSpend * s_amountOutMinimumPercent) / currentPrice;
```

That encodes three choices at once:

1. **$1 peg.** `stablecoinAmountToSpend` is treated as USD with the same decimals as the MoC BTC/USD price. No stablecoin-specific USD feed. Reasonable for a protocol that only swaps listed 1:1 stables (DOC, USDRIF) and does not take credit risk on the peg beyond “the swap reverts if the pool disagrees.”
2. **Oracle-scaled min-out, not a quoter / TWAP.** Slippage is `percent × (notional USD / BTCUSD)`. Pool impact, hop fees, and a depeg only show up as a revert when the router cannot meet that floor.
3. **`s_amountOutMinimumSafetyCheck` is not used at swap time.** R33 made it a configuration floor for `s_amountOutMinimumPercent`. It does not enter `_getAmountOutMinimum`. The implementer must say whether that is still the intent or dead ABI.

SwapRouter02 `ExactInputParams` has **no `deadline`**. A stale tx can sit in the mempool and execute later at a worse price, bounded only by `amountOutMinimum` and the oracle `isValid` bit at execution (not at signing). Rootstock is not Ethereum-mainnet dense with MEV, but sandwiching a sizeable `exactInput` is still possible if a searcher watches the public mempool.

**USDT0 is 6 decimals.** The current formula is silently 18-decimal. `25e6 * 0.995e18 / btcUsd18` is not “25 dollars of BTC.” R36 cannot ship until this PR either scales by token decimals or records a different min-out design that does. Do not leave that as a comment on R36.

R33 stays: one validator, `safety <= percent <= 100%`. Do not reopen that invariant except to delete `safety` if the review finds it unused on purpose.

R39 lands first so this review measures and reasons about the batch-only purchase path that will actually ship, with the single-buy bytecode already removed.

R39 also hands this review two concrete questions about the surviving batch path, both pre-existing and both documented in [`R39-remove-single-buy.md`](./R39-remove-single-buy.md):

1. **Should `_batchRetrieveStablecoin` clamp a share shortfall instead of reverting?** Because `_stablecoinToShares` rounds up while deposits credit the protocol's floor-rounded mint, spending a schedule's exact remaining balance is short by exactly one share, and the revert inside the per-buyer loop takes down every other buyer in the tick. R39 removed `buyRbtc`, which was the only path that clamped, so there is no longer an operational way to clear a tail schedule other than the user withdrawing. Pinned by `test/unit/BatchTailScheduleTest.t.sol` — flip those tests if the behavior changes. Idle is unaffected.
2. **Should the fee be charged on the planned gross or on the stablecoin actually retrieved?** The batch computes the aggregated fee up front from `purchaseAmounts`, so a short retrieval reduces the user's spend and leaves the fee whole. The removed single path charged on the retrieved amount.

## Open product decisions

**none** — decided 2026-08-27:

1. Keep the listed-stable **$1 assumption plus MoC BTC/USD oracle**. Natspec must say a depeg makes the pool fail the floor and revert; it does not guarantee redemption at $1.
2. Keep an **on-chain oracle floor** and scale stablecoin units correctly. An off-chain quote may tighten bot policy but cannot replace the handler floor.
3. Keep MEV/stale-tx protection at the floor plus bot operations. Do not add a handler deadline that SwapRouter02 does not expose or a private-relay dependency.

Decimals scaling for non-18 stables is required, not optional.

## Scope

- [x] Written review in the PR body: peg, min-out formula, unused safety-check, path encoding, oracle `isValid` / freshness, router deadline absence, Rootstock MEV. Point at line-level `PurchaseUniswap` / `IPurchaseUniswap`.
- [x] Implement the recorded decisions. Minimum if the peg is kept: scale `stablecoinAmountToSpend` to 18 decimals (or the oracle’s decimals) before dividing by `currentPrice`, using the purchase token’s `decimals()`. Test with a 6-decimal mock (USDT0 shape) and an 18-decimal mock (USDRIF shape).
- [x] Either use `s_amountOutMinimumSafetyCheck` in the swap math, document it as a config-only floor (natspec), or delete it (ABI — allowed in this PR, before R9).
- [x] Keep invariant 1: measured WRBTC delta is cash; `amountOutMinimum` is a revert bound only.
- [x] Re-measure Dex handler runtime vs EIP-170.

## Out of scope

- [ ] R33’s settings invariant (already landed), unless deleting `safety`.
- [ ] R36 handler/deploy work. This PR may add a 6-decimal mock; it must not ship `LayerBankErc20HandlerDex`.
- [ ] On-chain Uniswap quoter in the handler (view+swap in one tx is a sandwich magnet unless the floor is independent).
- [ ] MEV-protection networks, Flashbots, or changing the swapper bot in this repo.
- [ ] MoC purchase path.
- [ ] `--broadcast`.

## Files likely touched

- `src/PurchaseUniswap.sol`, `src/interfaces/IPurchaseUniswap.sol`
- `test/unit/PurchaseUniswapSettingsTest.sol` and Dex handler tests
- A 6-decimal stable mock if not already present
- Natspec on the peg and min-out

## Required tests

Targeted: `forge test --match-contract PurchaseUniswapSettingsTest` and the Dex handler suites, including a 6-decimal min-out case that **fails** if the 18-decimal formula is left unchanged.

Then `make check`, `STABLECOIN_TYPE=USDRIF make dex-sovryn` (and `dex-layerbank` only if that lane already exists). Fork: if `RSK_MAINNET_RPC_URL` is set, a probe that the live MoC oracle + a live pool would have met the computed min-out for a small swap is welcome; skip if the pool has no liquidity. Still run `make fork-sovryn` and `make fork-tropykus` before push.

## Success criteria

- [x] PR body records decisions 1–3.
- [x] 6-decimal and 18-decimal stables both produce a min-out in WRBTC wei that matches the $1 (or recorded) assumption.
- [x] Safety-check is used, documented as config-only, or removed.
- [x] Invariant 1 unchanged; Dex handlers still under EIP-170.
- [x] No open product decisions.

## Review outcome

**The formula.** `_getAmountOutMinimum` now lifts the spend into the oracle's units before dividing:

```solidity
minimumRbtcAmount = (stablecoinAmountToSpend * i_stablecoinToUsdScale * s_amountOutMinimumPercent) / currentPrice;
```

`i_stablecoinToUsdScale` is `10 ** (18 - stablecoin decimals)`, read once from `decimals()` in the
`PurchaseUniswap` constructor because the handler's stablecoin is immutable. Above 18 decimals the
constructor reverts `PurchaseUniswap__UnsupportedStablecoinDecimals` rather than round the floor down.
The `decimals()` read sits after `_setPurchasePath`, which already rejects a zero purchase token, so a
reversed `is` list still fails with `PurchaseUniswap__ZeroPurchaseToken` instead of an empty-address call.

At the live oracle price (80,061.57 USD/BTC, `isValid` true, block 9,188,727), $25 of USDT0 asks for
310,699,573,584,930 wei of WRBTC at 99.5%. The old formula asked for 310 wei — a floor that bounded nothing.

**1. Peg.** Kept, and now written into `PurchaseUniswap`'s contract natspec: one unit of a listed stablecoin
is taken to be one USD, priced against MoC BTC/USD. A downward depeg makes the pool fail the floor and the
swap reverts; nothing here redeems a depegged stablecoin at $1, and a persistent depeg is a delisting, not a
purchase-path problem. The oracle's 18 decimals are hardcoded as `USD_DECIMALS`, in the R29 style, and
confirmed against mainnet.

**2. Oracle floor.** Kept on-chain. `isValid` is checked at execution, not at signing, so a transaction that
waits in the mempool is bounded by the oracle of the block that mines it — that is the property that makes an
on-chain floor worth more than an off-chain quote, which would be signed at composition time.

**3. MEV and the missing deadline.** No handler deadline was added. `IV3SwapRouter.ExactInputParams` has no
deadline field, and `SwapRouter02`'s deadline-carrying `multicall` would not help: a deadline the handler
computes from `block.timestamp` inside the executing transaction is tautologically satisfied. Only a
caller-supplied deadline bounds anything, and that would mean a new `batchBuyRbtc` argument — a swapper ABI
change, out of scope here and R42's ground if it is ever wanted. Rootstock's ~30s merge-mined blocks and public
mempool make sandwiching possible but not routine; the loss is bounded by `1 - s_amountOutMinimumPercent`
(0.5% at the default), re-evaluated against a live oracle price at execution. Tightening that percent is the
owner's lever.

**4. Safety check.** Kept and documented as config-only. It bounds `s_amountOutMinimumPercent` and never enters
swap math, so widening slippage tolerance costs two owner transactions — lower the floor, then the percent.
With the owner a Safe (R45) that speed bump is worth its 32 bytes of storage; deleting it would also break the
`getAmountOutMinimumSafetyCheck` / `setAmountOutMinimumSafetyCheck` surface for no behavioral gain.

**5. Path encoding.** Unchanged. `_setPurchasePath` pins hop 0 to `_purchaseToken()` and the last hop to
`i_wrBtcToken`; only the intermediates and fee tiers are owner-set, and a wrong tier reverts rather than
mis-settles, because cash is the measured WRBTC delta and the floor still applies. The live USDRIF path is
USDRIF →(0.05%)→ USDT →(0.3%)→ WRBTC. USDT is 6-decimal, which does not enter the min-out math: only the
input token's decimals and WRBTC's 18 do.

**6. Zero price.** A `currentPrice` of 0 with `isValid` true divides by zero and reverts (panic 0x12). Loud,
not silent, so no extra guard was added for a broken-oracle case that already cannot mis-price a swap.

**Invariant 1** is untouched: `_swapStablecoinForWrbtc` still credits the measured WRBTC balance delta and
still ignores the router's return value. `amountOutMinimum` is a revert bound only.

**Size and gas.** `SovrynErc20HandlerDex` 21,061 → 21,104 runtime bytes (margin 3,515 → 3,472);
`TropykusErc20HandlerDex` 21,317 → 21,360 (margin 3,259 → 3,216). Both far under EIP-170. A batch purchase
costs ~200 more gas (one immutable read and one multiplication), on the protocol-paid path.

## R39 handoff questions

R39 handed this review two questions about the surviving batch path. Both are answered **keep today's
behavior**, and neither is implemented here — they are lending-side behavior, not the Dex path this PR reviews.

1. **Share shortfall: revert, do not clamp.** `_batchRetrieveStablecoin` still reverts
`TokenLending__InsufficientShares` when a schedule spends its exact remaining balance and the rounded-up debit
is one share short. Clamping would make the handler debit fewer shares than the schedule's `purchaseAmounts[i]`
says was spent, diverging the DcaManager balance from the share book for the sake of dust, and it would touch
every lending route rather than the Dex path. The tail is a state the swapper bot must filter before batching,
like a paused schedule; the user's own exit is the withdraw-all sentinel. `BatchTailScheduleTest` keeps its
tests unflipped and its header records that R43 decided this.
2. **Fee on the planned gross, not the retrieval.** `batchBuyRbtc` still computes the aggregated fee from
`purchaseAmounts` before retrieval. The fee band is a function of the purchase the user asked for, the
aggregate is transferred once before the swap, and re-deriving it from the retrieved amount would add a second
pro-rata pass over buyers to the protocol-paid path. A retrieval short enough to matter already reverts
(`PurchaseRbtc__StablecoinRetrievedBelowFee`, or `TokenLending__ZeroStablecoinReceived`).

## Reviewer checklist

- [x] Matches **Scope**; nothing from **Out of scope**.
- [x] The $1 peg is an explicit recorded choice, not an accidental unit mix-up.
- [x] USDT0 cannot ship on the old formula.
- [x] Tests in the PR match **Required tests**.
- [x] Files beyond this list are limited to direct dependencies and are named in the PR.
- [x] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: one new custom error, `PurchaseUniswap__UnsupportedStablecoinDecimals(uint8)`. No selector, event, or
  getter changed; the safety check stayed, so nothing was removed.
- Scripts: no change. Constructor args are unchanged — decimals are read from the token.
- Cutover: owner still sets percent and safety. No frontend follow-up (no user-facing selector moved). The
  swapper bot's off-chain min-out reproduction must scale by the token's decimals for USDT0; issue opened.
