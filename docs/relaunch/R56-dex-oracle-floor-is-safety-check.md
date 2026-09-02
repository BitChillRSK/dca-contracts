# R56 — Dex oracle floor is the safety check; the bot sets tightness

Status: **not started** · Assigned: [#107](https://github.com/BitChillRSK/dca-contracts/pull/107) · Optional/further-review: no

Planning lives in GitHub [#105](https://github.com/BitChillRSK/dca-contracts/pull/105). Implement in a
later `Start with R56` PR stacked on [#104](https://github.com/BitChillRSK/dca-contracts/pull/104).
Gated on R51 / [#103](https://github.com/BitChillRSK/dca-contracts/pull/103) (`minRbtcOut`) and R52 /
[#104](https://github.com/BitChillRSK/dca-contracts/pull/104) (current `PurchaseUniswap`).

## Objective

Make the swapper's per-batch `minRbtcOut` the operational Dex fill bound, and use
`s_amountOutMinimumSafetyCheck` (deploy default 95%) as the only on-chain oracle floor. Remove
`s_amountOutMinimumPercent` from swap math and from the handler ABI. A quote-aware bot can tighten
after seeing the pool; the Safe is no longer in that loop. A compromised or zero `minRbtcOut` still
cannot clear less than the safety-check fraction of live MoC BTC/USD.

## Background

R43 kept an on-chain oracle floor and documented `s_amountOutMinimumSafetyCheck` as **config-only**:
it bounds the owner setter for `s_amountOutMinimumPercent` and never enters `_getAmountOutMinimum`.
Widening slippage therefore took two Safe transactions. R51 added `minRbtcOut` so a quote can
tighten, but not loosen, that floor, and explicitly left `_getAmountOutMinimum` and the 99.5% / 95%
defaults out of PR 103.

That leaves 99.5% as the number Uniswap actually enforces. It was a one-time probe, only the
multisig can change it, and it is too tight for live LP fees (R51's fork table: LayerBank USDRIF
misses 99.5% by 16–23 bps). The bot cannot add margin after a quote. The 95% safety check is the
value that was always meant as "more room" — a loss ceiling, not weekly policy.

R51's threat model is unchanged: `minRbtcOut == 0` is legal (MoC; a compromised key can send `1`).
The governance floor must still bind. This PR moves that floor from the 99.5% storage percent onto
the 95% safety check and lets `minRbtcOut` be the operational number.

The $1 listed-stable peg, execution-time `isValid`, decimal scaling, and measured-WRBTC credits stay
exactly as R43/R51.

## Open product decisions

**none** — decided 2026-09-02:

1. Swap-time oracle floor is `s_amountOutMinimumSafetyCheck` (keep the name; it is now the live
   fraction, not a setter-only bound).
2. Delete `s_amountOutMinimumPercent`, `setAmountOutMinimumPercent`, `getAmountOutMinimumPercent`,
   and `PurchaseUniswap_AmountOutMinimumPercentUpdated` from `IPurchaseUniswap` / `PurchaseUniswap`.
   Dex constructors and deploy configs take one remaining percent argument: the safety check.
3. Uniswap `ExactInputParams.amountOutMinimum` is `max(oracleFloor, minRbtcOut)`. `minRbtcOut == 0`
   therefore still hits the oracle floor.
4. Keep `PurchaseRbtc`'s measured-output check. Do not trust the router return. MoC has no router
   min; it still only sees the post-check (and keeps sending `0` until a redemption preview exists).
5. One owner transaction may change the backstop (no two-action speed bump). Changing 95% is
   governance, not a weekly knob.
6. Production Dex still sends a nonzero quote-derived `minRbtcOut` every batch (R51 off-chain gate).
   Do not add an on-chain nonzero Dex requirement.

## Scope

- [ ] `_getAmountOutMinimum` multiplies by `s_amountOutMinimumSafetyCheck` instead of
      `s_amountOutMinimumPercent`.
- [ ] `_purchaseRbtc` on Uniswap takes `minRbtcOut` (or equivalent) and passes
      `max(oracleFloor, minRbtcOut)` into `ExactInputParams`. `PurchaseMoc._purchaseRbtc` ignores
      that argument. `PurchaseRbtc.batchBuyRbtc` forwards the local it already has; do not add a
      new stack slot for it.
- [ ] Remove the 99.5% storage word, its setter/getter/event, and the constructor argument. Keep
      `setAmountOutMinimumSafetyCheck` / `getAmountOutMinimumSafetyCheck` / the safety-check event.
      `_validateSlippageSettings` only enforces `safetyCheck <= 100%`.
- [ ] Update Dex deploy helpers, leaf constructors, `DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT` call sites
      (delete the constant if nothing remains), and tests that set or assert the old percent.
- [ ] R33's "safety cannot exceed percent" tests go away with the percent. Replace with: owner can
      lower/raise the safety check within `<= 100%`; swap min-out tracks that value; a `minRbtcOut`
      above the floor is what the router enforces; a `minRbtcOut` below the floor is inert on a
      successful swap.
- [ ] Record optimized Dex runtime sizes. Do not change `foundry.toml`.
- [ ] Update swapper-bot / monitoring / front-end issues in the same turn: percent setter gone;
      Dex operational tightness is `minRbtcOut`; on-chain floor is the safety-check getter.

## Out of scope

- [ ] DcaManager `Batch` shape or `minRbtcOut` units (R51).
- [ ] Path allowlisting (R52).
- [ ] Changing the $1 peg, oracle `isValid` check, decimal scaling, or adding a deadline.
- [ ] A mandatory on-chain nonzero Dex minimum, MoC quote formula, or on-chain Uniswap quoter.
- [ ] Re-locking cutover as two Safe executions that copy percent onto safety check (R51 runbook).
      Deploy/cutover sets the single backstop once.
- [ ] Optimizer / via-IR / solx (R53–R55).
- [ ] Schedule top-up (R54).
- [ ] Closing the DOC Dex `DeployDexSwaps` hole ([R57](./R57-close-doc-dex-deploy-hole.md)).

## Files likely touched

- `src/interfaces/IPurchaseUniswap.sol`, `src/PurchaseUniswap.sol`
- `src/PurchaseRbtc.sol`, `src/PurchaseMoc.sol` (virtual `_purchaseRbtc` signature only)
- Dex leaves' constructors: `src/sovryn/SovrynErc20HandlerDex.sol`,
  `src/layerbank/LayerBankErc20HandlerDex.sol`,
  `src/tropykus-legacy/TropykusErc20HandlerDex.sol`
- `script/Constants.sol`, `script/DexHelperConfig.s.sol`, `script/UsdrifHelperConfig.s.sol`,
  Dex deploy scripts that pass both percents
- `test/unit/PurchaseUniswapSettingsTest.sol`, `test/unit/PurchaseUniswapMinOutTest.t.sol`,
  `test/unit/PurchaseRbtcTest.t.sol`, Dex handler constructor tests, `ZeroTokenPurchaseUniswap`
  if its constructor lists both percents

## Required tests

- Oracle floor at the safety-check default (95%) matches `_getAmountOutMinimum` for 18-decimal and
  6-decimal stables (reuse R43 scaling).
- `minRbtcOut == 0` on Dex: router min equals the oracle floor; measured check is inert.
- `minRbtcOut` above the floor: Uniswap reverts (or the measured check reverts) if output is between
  the floor and `minRbtcOut`; a fill at or above `minRbtcOut` succeeds.
- `minRbtcOut` below the floor: a successful swap still cannot pay less than the oracle floor.
- Owner `setAmountOutMinimumSafetyCheck` updates the swap-time floor; cannot exceed 100%.
- Removed percent setter/getter/event are gone (`forge inspect` / compile).
- MoC `minRbtcOut` behavior unchanged (including `0`).
- R51 rollback tests still hold when the Uniswap floor is the safety check.

Then `make check`, `make fork-sovryn`, `make fork-tropykus`, and `make fork-dex-path`.

## Success criteria

- [ ] No caller value can loosen the safety-check oracle floor.
- [ ] Dex operational tightness is `minRbtcOut`; the Safe is not on that path.
- [ ] `s_amountOutMinimumPercent` is gone from ABI and storage.
- [ ] Invariant 1 unchanged; both venues still compare measured cash in `PurchaseRbtc`.
- [ ] Optimized Dex runtimes stay under EIP-170; PR records the figures.
- [ ] Consumer issues updated in the same turn.
- [ ] No open contract product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are named in the PR.
- [ ] No unrelated refactors.

## ABI / deploy / cutover impact

- **ABI:** Dex handler constructors drop `amountOutMinimumPercent`. `IPurchaseUniswap` loses
  `setAmountOutMinimumPercent`, `getAmountOutMinimumPercent`, and
  `PurchaseUniswap_AmountOutMinimumPercentUpdated`. Safety-check setter/getter/event remain.
  `_purchaseRbtc` is internal. DcaManager selectors unchanged.
- **Deploy:** one constructor percent (the backstop). No two-step cutover that copies 99.5% onto 95%.
- **Consumers:** `front-end#22` if it calls the percent setter or embeds the old constructor.
  `swapper-bot#6` already owns `minRbtcOut`; confirm it no longer assumes a 99.5% router floor.
  `bitchill-monitoring#10` if it decodes the removed event. `data-api` / metrics: none unless they
  label the old percent.
