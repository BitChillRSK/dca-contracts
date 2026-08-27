# R43 — Dex path review (peg, slippage, MEV)

Status: **not started** · Assigned: no · Optional/further-review: no

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

- [ ] Written review in the PR body: peg, min-out formula, unused safety-check, path encoding, oracle `isValid` / freshness, router deadline absence, Rootstock MEV. Point at line-level `PurchaseUniswap` / `IPurchaseUniswap`.
- [ ] Implement the recorded decisions. Minimum if the peg is kept: scale `stablecoinAmountToSpend` to 18 decimals (or the oracle’s decimals) before dividing by `currentPrice`, using the purchase token’s `decimals()`. Test with a 6-decimal mock (USDT0 shape) and an 18-decimal mock (USDRIF shape).
- [ ] Either use `s_amountOutMinimumSafetyCheck` in the swap math, document it as a config-only floor (natspec), or delete it (ABI — allowed in this PR, before R9).
- [ ] Keep invariant 1: measured WRBTC delta is cash; `amountOutMinimum` is a revert bound only.
- [ ] Re-measure Dex handler runtime vs EIP-170.

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

- [ ] PR body records decisions 1–3.
- [ ] 6-decimal and 18-decimal stables both produce a min-out in WRBTC wei that matches the $1 (or recorded) assumption.
- [ ] Safety-check is used, documented as config-only, or removed.
- [ ] Invariant 1 unchanged; Dex handlers still under EIP-170.
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] The $1 peg is an explicit recorded choice, not an accidental unit mix-up.
- [ ] USDT0 cannot ship on the old formula.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: possible (safety-check removal, new errors, natspec-only if the formula stays). Must precede R9.
- Scripts: only if constructor args change.
- Cutover: owner still sets percent (and safety, if kept). Frontend follow-up only if a setter/event disappears. Swapper bot may need to know min-out is tighter or decimal-correct — mention in the PR, no bot code here.
