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

**none** — decided 2026-09-02, decisions 1 and 2 revised 2026-09-02 after review (see
**Revision: keep the band** below):

1. ~~Swap-time oracle floor is `s_amountOutMinimumSafetyCheck`.~~ **Revised.** The swap-time floor is
   `s_amountOutMinimumPercent`, deployed loose (97%). `s_amountOutMinimumSafetyCheck` (95%) stays the
   config-only bound on it.
2. ~~Delete `s_amountOutMinimumPercent` and its setter/getter/event.~~ **Revised.** Both words stay,
   packed in one slot. Dex constructors and deploy configs take both fractions, as before this PR.
3. Uniswap `ExactInputParams.amountOutMinimum` is `max(oracleFloor, minRbtcOut)`. `minRbtcOut == 0`
   therefore still hits the oracle floor.
4. Keep `PurchaseRbtc`'s measured-output check. Do not trust the router return. MoC has no router
   min; it still only sees the post-check (and keeps sending `0` until a redemption preview exists).
5. ~~One owner transaction may change the backstop (no two-action speed bump).~~ **Revised.** One
   owner transaction retightens or widens the live floor anywhere inside `[95%, 100%]`. Widening
   *past* 95% keeps the two-transaction speed bump: lower the safety check first. Changing 95% is
   governance; changing 97% is operations.
6. Production Dex still sends a nonzero quote-derived `minRbtcOut` every batch (R51 off-chain gate).
   Do not add an on-chain nonzero Dex requirement.

## Revision: keep the band (2026-09-02, post-review)

The first implementation collapsed both fractions into one. Review caught what that costs, and the
argument survived scrutiny: the two words answer **different questions**, and merging them forces the
answer to the operational question down to whatever the emergency question permits.

- *How much slippage is normal-operation tolerable?* Needs to sit just under the worst realistic fill,
  moves with pool conditions, and is checked often. That is `s_amountOutMinimumPercent`.
- *How far may the owner ever widen that in one transaction?* Rare, deliberate, and the thing a
  compromised or mistaken Safe must not be able to cross alone. That is
  `s_amountOutMinimumSafetyCheck`.

With one word, the live floor had to be set at 95% for swaps to clear, so a compromised swapper
sending `minRbtcOut = 1` could extract up to 5%. With the band restored and the floor at 97%, the
same attacker is capped at 3%, and the 95% wall still bounds how far one owner transaction can widen
it. Collapsing also deleted the lower bound entirely — one owner transaction could have set the live
floor to zero.

The R43 framing that motivated the collapse ("widening slippage takes two Safe transactions") was only
ever true *below* the safety check. Inside `[95%, 100%]` it was always one transaction, which is the
whole range R51's evidence actually needs.

**Why 97%.** Measured, not picked. `make probe-dex-quote-floor` at block 9198813
(BTC/USD 78,449.59) against live pools:

| Path | Batch | Fill vs oracle |
|---|---|---|
| LayerBank USDRIF | $25 | 99.34% |
| LayerBank USDRIF | $1,000 | **99.27%** (worst realistic size) |
| LayerBank USDT0 | $25 | 99.90% |
| LayerBank USDT0 | $1,000 | 99.84% |

97% leaves ~227 bps under the worst realistic fill for peg drift, oracle drift, and pool movement
between the bot's quote and inclusion — so a healthy batch never reverts on the floor — while capping
hot-key loss at 3%.

**Batch-size note, recorded for the bot, not the floor.** $100,000 single-batch rows do not clear any
sane floor at this block: USDRIF exhausts pool liquidity (partial fill), and USDT0 fills at 94.86% of
oracle, *below even the 95% wall*. Batch splitting is `swapper-bot`'s job and stays there; no floor
value fixes a batch larger than the pool.

## Scope

- [x] `_getAmountOutMinimum` multiplies by `s_amountOutMinimumPercent`, deployed loose (97%) instead
      of the one-time 99.5% probe value.
- [x] `_purchaseRbtc` on Uniswap takes `minRbtcOut` (or equivalent) and passes
      `max(oracleFloor, minRbtcOut)` into `ExactInputParams`. `PurchaseMoc._purchaseRbtc` ignores
      that argument. `PurchaseRbtc.batchBuyRbtc` forwards the local it already has; do not add a
      new stack slot for it.
- [x] ~~Remove the 99.5% storage word, its setter/getter/event, and the constructor argument.~~
      **Revised:** keep both words, both setters, both getters, both events, all three errors, and
      both constructor arguments. `_validateSlippageSettings` enforces
      `safetyCheck <= percent <= 100%`. The ABI is therefore unchanged from mainnet-current — only
      the *meaning* of `minRbtcOut` at the router and the *deploy default* for the percent change.
- [x] Update Dex deploy helpers, leaf constructors, and `DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT`
      (retained; retuned 99.5% -> 97%).
- [x] ~~R33's "safety cannot exceed percent" tests go away with the percent.~~ **Revised:** they
      stay, and gain the cases this PR introduces — a `minRbtcOut` above the floor is what the router
      enforces; a `minRbtcOut` below the floor is inert on a successful swap; the owner can retighten
      the floor without moving the wall; the wall bounds how far one owner transaction can widen.
- [x] Record optimized Dex runtime sizes. Do not change `foundry.toml`.
- [x] Update swapper-bot / monitoring / front-end issues in the same turn: the slippage ABI is
      unchanged, the deploy default floor moves 99.5% -> 97%, Dex operational tightness is
      `minRbtcOut`, and a too-tight `minRbtcOut` now reverts in the router rather than raising
      `PurchaseRbtc__BelowSwapperMinimum`.

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

- Oracle floor at the percent default (97%) matches `_getAmountOutMinimum` for 18-decimal and
  6-decimal stables (reuse R43 scaling).
- `minRbtcOut == 0` on Dex: router min equals the oracle floor; measured check is inert.
- `minRbtcOut` above the floor: Uniswap reverts (or the measured check reverts) if output is between
  the floor and `minRbtcOut`; a fill at or above `minRbtcOut` succeeds.
- `minRbtcOut` below the floor: a successful swap still cannot pay less than the oracle floor.
- Owner `setAmountOutMinimumPercent` updates the swap-time floor; cannot exceed 100%; cannot be set
  below the safety check in one transaction; widening past it takes two transactions in order.
- Owner `setAmountOutMinimumSafetyCheck` cannot be raised above the active floor.
- Retightening the floor does not move the wall, and the swap follows the new floor immediately.
- MoC `minRbtcOut` behavior unchanged (including `0`).
- R51 rollback tests still hold when the Uniswap floor is the safety check.

Then `make check`, `make fork-sovryn`, `make fork-tropykus`, `make fork-dex-path`, and — because
this PR changes the number the router enforces — `SWAP_TYPE=dexSwaps STABLECOIN_TYPE=USDRIF make
fork-layerbank` against live Uniswap pools, plus `make probe-dex-quote-floor` to re-derive the
percent. The mock-router lanes cannot show whether a live pool clears the floor.

## Success criteria

- [x] No caller value can loosen the configured oracle floor.
- [x] Dex operational tightness is `minRbtcOut`; the Safe is not on that path in normal operation.
- [x] The live floor is deployed loose enough that a healthy batch never reverts on it, and the 95%
      wall still bounds how far one owner transaction can widen it.
- [x] Invariant 1 unchanged; both venues still compare measured cash in `PurchaseRbtc`.
- [x] Optimized Dex runtimes stay under EIP-170; PR records the figures.
- [x] Consumer issues updated in the same turn.
- [x] No open contract product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are named in the PR.
- [ ] No unrelated refactors.

## ABI / deploy / cutover impact

- **ABI:** unchanged from mainnet-current. Both setters, both getters, both events, all three
  errors, and both constructor arguments stay exactly as deployed. `_purchaseRbtc` is internal.
  DcaManager selectors unchanged.
- **Deploy:** two constructor fractions, as before. `DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT` moves
  99.5% -> 97%; `DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK` stays 95%. No two-step cutover.
- **Behaviour that does change:** the router now enforces `max(floor, minRbtcOut)`, so a `minRbtcOut`
  the swap cannot fill reverts inside SwapRouter02 (`Too little received`) instead of surfacing
  `PurchaseRbtc__BelowSwapperMinimum(received, min)`. On the Dex path that custom error is now
  unreachable; it still fires on MoC. Consumers that parse it must handle the router string.
- **Consumers:** `swapper-bot#6` (router-side revert, 97% floor, batch splitting),
  `bitchill-monitoring#10` (the custom error stops firing on Dex), `front-end#22` (no ABI change
  after all). `data-api` / metrics: none.
