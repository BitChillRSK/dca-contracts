# R36 — LayerBank dex stables (USDRIF + USDT0)

Status: **not started** · Assigned: no · Optional/further-review: no

PR 34 of the relaunch stack. Stack on R40 (PR 33).

**Blocked on [R43](./R43-dex-path-review.md):** `PurchaseUniswap._getAmountOutMinimum` treats stablecoin units as 18-decimal USD against the MoC BTC/USD oracle. USDT0 is 6 decimals. Do not implement this PR on the unscaled formula.

## Objective

Ship `LayerBankErc20HandlerDex` (LayerBank lending + Uniswap V3 purchases) and deploy it for
**both** dex stables LayerBank lists: USDRIF (replacing Tropykus) and USDT0 (new). One handler
contract, two constructor configs. This is the replacement R37 needs before it can retire Tropykus
from every live path.

## Background

The relaunch dropped Tropykus from the production MoC map (R22, PR 29 / [#73](https://github.com/BitChillRSK/dca-contracts/pull/73)),
but Tropykus is still live on the **dex** map. `DeployUsdrifHandler` deploys a `TropykusErc20HandlerDex`
bound to `kUsdrifTokenAddress` and registers it at `TROPYKUS_INDEX`; `DeployDexSwaps`' live branch does
the same for the dex map's Tropykus arm. So "Tropykus is never deployed again" is not yet true.

Two reasons the USDRIF move matters beyond tidiness:

- Tropykus paused kDOC mint between blocks 8739512 and 8740674 (deposits revert with kToken error `C2`;
  see the fork-tests bullet in `AGENTS.md`). A fresh Tropykus deploy risks shipping a handler whose
  deposits revert. **Confirm on a mainnet fork whether kUSDRIF is paused too** — the DOC pause is
  measured, the USDRIF status is not.
- LayerBank supports USDRIF, so there is a working alternative. R22 listed "LayerBank Uniswap / USDRIF"
  as explicitly out of scope; this spec is that deferred item, plus the USDT0 twin that was not in
  the original deferral.

`src/layerbank/` currently has only `LayerBankErc20Handler` (abstract) and `LayerBankDocHandlerMoc`.
The dex pairing does not exist. `SovrynErc20HandlerDex` is the exact model to copy: it is
`SovrynErc20Handler, PurchaseUniswap` with a constructor that forwards to both parents and adds no
logic of its own. `LayerBankErc20Handler` already extends `LendingErc20Handler`, so the dex handler
inherits share accounting, the withdraw clamp, and interest for free. The contract is token-agnostic:
USDRIF and USDT0 are two deployments of that same bytecode, not two contracts.

This lands before R9 and R10 deliberately. R9 must freeze and test the event surface against the final
shipped lending-handler set, including both deployments of `LayerBankErc20HandlerDex`; R10 must document
that final handler and deploy surface instead of requiring this PR to imitate a natspec pass that already
closed.

### USDT0 is config, with one real catch (6 decimals)

USDT0 is an ERC20 stable swapped on Uniswap, same as USDRIF. Same Pool as LayerBank DOC
(`0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9`); look up the USDT0 aToken the way R22 looked up
lRooDOC (`UNDERLYING_ASSET_ADDRESS()` must be USDT0, not rUSDT).

| | USDRIF | USDT0 |
|---|---|---|
| Mainnet token | `0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37` | `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` |
| Decimals | 18 | **6** |
| Already in the repo | yes (`STABLECOIN_TYPE=USDRIF`, `UsdrifHelperConfig`) | no |
| LayerBank | listed (aToken to look up) | listed (aToken to look up) |
| Tropykus / Sovryn / MoC | Tropykus today; Sovryn and MoC do not list it | none of them; new BitChill listing |

Do **not** reuse the rUSDT hop address (`0xAf368c91793CB22739386DFCbBb2F1A9e4bCBeBf` on mainnet) as
if it were USDT0. rUSDT is a different token and is already the USDRIF (and DOC) Uniswap intermediate.

`MIN_PURCHASE_AMOUNT` (`25 ether`), `FEE_PURCHASE_LOWER_BOUND` (`1000 ether`), and
`FEE_PURCHASE_UPPER_BOUND` (`100_000 ether`) are 18-decimal DOC/USDRIF units. Passing them into a
USDT0 handler makes the min purchase ~25 trillion USDT0 and puts every real purchase at the max fee
band. Fee bounds are per-handler constructor args (`FeeSettings`); the min is `DcaManager.setTokenMinPurchaseAmount`.
Both must be set in **USDT0 atomic units** on the USDT0 deploy path. Do not read them from those
`Constants.sol` DOC values. The **swap** min-out is a separate 18-decimal bug — R43 owns that; this
PR only consumes the reviewed `PurchaseUniswap`.

Local Anvil mocks may stay 18-decimal (USDRIF already does). The live/mainnet config and a deploy
test must still prove the USDT0 handler was constructed with 6-decimal bounds and that
`setTokenMinPurchaseAmount` was called. Prefer a 6-decimal mock on the `STABLECOIN_TYPE=USDT0` lane
if that is cheap; do not silently run USDT0 tests against 18-decimal amounts and call it coverage.

## Open product decisions

Ask the human before implementing:

1. **Which dex-map index does LayerBank take?** The dex `OperationsAdmin` is a separate instance from
   the MoC one, so it does not have to match `LAYERBANK_INDEX = 1` — but matching it is far less
   confusing for ops and the frontend. Recommend `1`. Route classes are add-only and schedules store
   `routeIndex` forever, so this cannot be changed after a live deploy. USDRIF and USDT0 share that
   index (different tokens, two handler instances).
   R38 now follows R36, so that PR will consume the final dex-map topology rather than asking this gate
   early. Whether the live dex map keeps a DOC/Sovryn arm (decision 2) determines whether its mixed-grid
   example is immediately reachable; the zipped API remains durable even if the first map is simpler.
2. **Does the dex map keep a Sovryn arm alongside LayerBank, or does LayerBank replace it?**
   `DeployDexSwaps` currently deploys both Tropykus and Sovryn on live networks. Sovryn lists neither
   USDRIF nor USDT0; a remaining Sovryn arm is a DOC-dex question, not a USDT0 question.
3. **Is kUSDRIF mint currently paused on Tropykus mainnet?** If yes, say so in the PR — it changes
   the urgency of R37 from cleanup to a live defect.
4. **USDT0 min purchase and fee bounds.** Recommend the same *token-unit* amounts as DOC: min
   purchase `25e6`, fee lower `1000e6`, fee upper `100_000e6`. Confirm or give different numbers.
   USDT0 in this PR is already decided; this gate is only the 6-decimal magnitudes.

Look up the USDT0 Uniswap path (direct WRBTC vs hop, fee tiers) from live SwapRouter02 pools. That is
not a product gate. If no liquid WRBTC route exists, stop and ask rather than guessing a path.

## Scope

- [ ] `src/layerbank/LayerBankErc20HandlerDex.sol` — `LayerBankErc20Handler, PurchaseUniswap`,
      constructor-only, mirroring `SovrynErc20HandlerDex`. No new logic. One contract for both tokens.
- [ ] Helper config — LayerBank aToken + Uniswap settings per dex stable. Extend `DexHelperConfig` /
      `UsdrifHelperConfig` rather than copying a third helper. Mainnet USDRIF: lRooUSDRIF (look up).
      Mainnet USDT0: token `0x779Ded0c9e1022225f8E0630b35a9b54bE713736`, aToken look-up on the same
      Pool as lRooDOC; `address(0)` on testnet if LayerBank USDT0/USDRIF is mainnet-only, matching
      how `MocHelperConfig` handles `layerbankATokenAddress`. Keep `kUsdrifTokenAddress` until R37
      removes it. `STABLECOIN_TYPE=USDT0` is a first-class env value.
- [ ] Deploy — two `LayerBankErc20HandlerDex` instances (USDRIF and USDT0), each registered at the
      index from decision 1. Prefer generalizing `DeployUsdrifHandler` into a dex-stable add-on that
      keys off `STABLECOIN_TYPE` over a second copy-paste script. Carry over R22's live-broadcast
      gate: a real RSK RPC without `REAL_DEPLOYMENT=true` reports `FORK`, and `FORK` must revert
      rather than bind a live aToken with a test `feeCollector` and the 2% test fee cap.
- [ ] USDT0 6-decimal config on the live/mainnet path: `FeeSettings` lower/upper bounds in 6-decimal
      units (decision 4); `dcaManager.setTokenMinPurchaseAmount(usdt0, min)` after the handler is
      registered. Do not pass `MIN_PURCHASE_AMOUNT` / `FEE_PURCHASE_*` from `Constants.sol`.
- [ ] `DeployDexSwaps` — register the LayerBank dex route and deploy the USDRIF and USDT0 handlers
      on the live branch.
- [ ] `Makefile` / harness — a `dex-layerbank` lane; `DcaDappTest` must stop skipping
      `isDexSwaps && isLayerbank` (it currently does, via the R22 "dex is tropykus/sovryn only" guard).
      Treat USDT0 like USDRIF for skip logic: dex yes, MoC no, Sovryn no. The current
      `isDexSwaps && !isUSDRIF` guard must not skip USDT0.
- [ ] CI — add `dex-layerbank` with `STABLECOIN_TYPE=USDRIF` **and** `STABLECOIN_TYPE=USDT0` to the
      matrix and to `make check` / `make ci`.
- [ ] Pin looked-up aToken addresses and Uniswap paths in the PR body (same bar as R22's live DOC
      table). Constructor must still revert `LayerBankErc20Handler__UnderlyingMismatch` if the aToken
      underlying is not the stablecoin being configured.

## Out of scope

- [ ] Retiring Tropykus, the `script/tropykus-legacy/` folder, and moving `TROPYKUS_INDEX` — that is R37.
- [ ] LayerBank DOC on the dex path. Idle USDT0. USDT0 on MoC.
- [ ] R43 slippage/oracle redesign (consume it; do not redo it).
- [ ] Merkl / LAB / harvest, or any external reward integration (see `EXTERNAL_REWARDS.md`).
- [ ] `stablecoinRecipient` on LayerBank redeem.
- [ ] Any `ITokenLending` event/error ABI rename.
- [ ] `--broadcast` or live-chain interaction.
- [ ] Treating rUSDT as USDT0, or changing the existing USDRIF/DOC hop through rUSDT.

## Files likely touched

- `src/layerbank/LayerBankErc20HandlerDex.sol` (new)
- `script/UsdrifHelperConfig.s.sol`, `script/DexHelperConfig.s.sol`, `script/DeployUsdrifHandler.s.sol`,
  `script/DeployDexSwaps.s.sol` (generalize rather than add a USDT0-only twin if that stays smaller)
- `script/Constants.sol` (dex-map index constant, if decision 1 needs one; USDT0 address / 6-decimal
  fee-bound constants if they would otherwise be magic numbers)
- `test/unit/DcaDappTest.t.sol` (dex/layerbank lane guard + USDT0 skip logic), `Makefile`,
  `.github/workflows/test.yml`
- `test/ai-generated/unit/layerbank/` (dedicated dex handler tests; USDT0 6-decimal deploy assertions)

## Required tests

```
SWAP_TYPE=dexSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=USDRIF make dex
STABLECOIN_TYPE=USDRIF make dex-layerbank
STABLECOIN_TYPE=USDT0 make dex-layerbank
make check
```

Assert:

- Deposit → aToken scaled shares → Uniswap purchase → rBTC accrual → withdraw, on the USDRIF
  dex-layerbank lane **and** the USDT0 dex-layerbank lane.
- The round-up solvency property R22 established for the MoC lane also holds here: virtual scaled
  books stay `<=` handler `scaledBalanceOf` after odd-amount redeems against Aave-like round-nearest
  burns. The test must fail if `_stablecoinToShares` were flipped to `Rounding.Down`. Run it on at
  least one of the two dex stables (the handler is shared).
- `DeployUsdrifHandler.run()` (or the generalized dex-stable script) reverts on `FORK` without
  `REAL_DEPLOYMENT=true` (mirror `test_run_revertsOnForkWithoutRealDeployment`).
- USDT0 live/mainnet config: fee lower/upper bounds and `getTokenMinPurchaseAmount` match decision 4
  (6-decimal units), not `25 ether` / `1000 ether` / `100_000 ether`.
- The Sovryn dex lane is unchanged. MoC + USDT0 still skips.

Fork: adds a fork-specific assertion only if decision 3 turns up a live kUSDRIF pause. Still run
`make fork-sovryn` and `make fork-tropykus` before push. A LayerBank USDT0/`UNDERLYING` probe on
`make fork-sovryn` (tip) is welcome if cheap, same skip-if-no-code pattern as the DOC probe.

## Success criteria

- [ ] USDRIF DCA works end-to-end on a LayerBank-backed dex handler with no Tropykus contract involved.
- [ ] USDT0 DCA works end-to-end on a second deployment of the same `LayerBankErc20HandlerDex`.
- [ ] `DeployUsdrifHandler` (or its generalized successor) no longer constructs `TropykusErc20HandlerDex`.
- [ ] `dex-layerbank` is green locally and in CI for `STABLECOIN_TYPE=USDRIF` and `STABLECOIN_TYPE=USDT0`.
- [ ] USDT0 min purchase and fee bounds are 6-decimal (decision 4), asserted by a test.
- [ ] The live-broadcast gate is asserted by a test, not only documented.
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold — in particular #1 (balance-delta cash) and #2
      (no view as redeem ceiling) on the new redeem path.
- [ ] `LayerBankErc20HandlerDex` adds no logic beyond the constructor, like `SovrynErc20HandlerDex`.
- [ ] USDT0 does not receive DOC/USDRIF 18-decimal `Constants.sol` min/fee values.
- [ ] Tests in the PR match **Required tests**.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: new handler contract; no change to shared interfaces. R9 follows this PR and must confirm its share
  event is emitted from `LendingErc20Handler` on both dex stables before the event surface freezes.
- Scripts: `DeployUsdrifHandler` / `DeployDexSwaps` (and helper config) change which handler the live
  dex path deploys, and add a USDT0 registration.
- Cutover: the USDRIF dex route index and its lending backend both change; USDT0 is a new listed
  token. Ops and the frontend need the new index, that USDRIF yield now comes from LayerBank not
  Tropykus, and that USDT0 exists at all. An illiquid LayerBank reserve aborts the whole
  `batchBuyRbtc` (live Aave `withdraw` reverts on insufficient aToken cash) — drop the row, do not
  retry as a partial batch.
- **Frontend follow-up required** (`AGENTS.md` **Frontend follow-up**). New token + remapped USDRIF
  venue. Open or update an issue on `bitChillRSK/front-end` in the same turn as the contracts PR.
