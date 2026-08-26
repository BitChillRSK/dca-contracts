# R36 — LayerBank USDRIF dex handler

Status: **not started** · Assigned: no · Optional/further-review: no

## Objective

Ship `LayerBankErc20HandlerDex` (LayerBank lending + Uniswap V3 purchases) and move the live USDRIF
dex deploy off Tropykus onto it, so USDRIF DCA has a lending backend that is actually operating.
This is the replacement that R37 needs before it can retire Tropykus from every live path.

## Background

The relaunch dropped Tropykus from the production MoC map (R22, PR 29 / [#73](https://github.com/BitChillRSK/dca-contracts/pull/73)),
but Tropykus is still live on the **dex** map. `DeployUsdrifHandler` deploys a `TropykusErc20HandlerDex`
bound to `kUsdrifTokenAddress` and registers it at `TROPYKUS_INDEX`; `DeployDexSwaps`' live branch does
the same for the dex map's Tropykus arm. So "Tropykus is never deployed again" is not yet true.

Two reasons this matters beyond tidiness:

- Tropykus paused kDOC mint between blocks 8739512 and 8740674 (deposits revert with kToken error `C2`;
  see the fork-tests bullet in `AGENTS.md`). A fresh Tropykus deploy risks shipping a handler whose
  deposits revert. **Confirm on a mainnet fork whether kUSDRIF is paused too** — the DOC pause is
  measured, the USDRIF status is not.
- LayerBank supports USDRIF, so there is a working alternative. R22 listed "LayerBank Uniswap / USDRIF"
  as explicitly out of scope; this spec is that deferred item.

`src/layerbank/` currently has only `LayerBankErc20Handler` (abstract) and `LayerBankDocHandlerMoc`.
The dex pairing does not exist. `SovrynErc20HandlerDex` is the exact model to copy: it is
`SovrynErc20Handler, PurchaseUniswap` with a constructor that forwards to both parents and adds no
logic of its own. `LayerBankErc20Handler` already extends `LendingErc20Handler`, so the dex handler
inherits share accounting, the withdraw clamp, and interest for free.

This lands after the ABI-freeze PRs (R9 event indexing, R10 natspec). That is deliberate and cheap:
R9's `TokenLending__UserSharesUpdated` is emitted from the shared `LendingErc20Handler` base, so the
new handler inherits it without an ABI re-freeze. This PR must write its own natspec in the R10 style
rather than assume a later sweep will cover it.

## Open product decisions

Ask the human before implementing:

1. **Which dex-map index does LayerBank take?** The dex `OperationsAdmin` is a separate instance from
   the MoC one, so it does not have to match `LAYERBANK_INDEX = 1` — but matching it is far less
   confusing for ops and the frontend. Recommend `1`. Route classes are add-only and schedules store
   `routeIndex` forever, so this cannot be changed after a live deploy.
2. **Does the dex map keep a Sovryn arm alongside LayerBank, or does LayerBank replace it?**
   `DeployDexSwaps` currently deploys both Tropykus and Sovryn on live networks.
3. **Is kUSDRIF mint currently paused on Tropykus mainnet?** If yes, say so in the PR — it changes
   the urgency of R37 from cleanup to a live defect.

## Scope

- [ ] `src/layerbank/LayerBankErc20HandlerDex.sol` — `LayerBankErc20Handler, PurchaseUniswap`,
      constructor-only, mirroring `SovrynErc20HandlerDex`. No new logic.
- [ ] `UsdrifHelperConfig` — a LayerBank USDRIF aToken address (mainnet lRooUSDRIF; `address(0)` on
      testnet if LayerBank USDRIF is mainnet-only, matching how `MocHelperConfig` handles
      `layerbankATokenAddress`). Keep `kUsdrifTokenAddress` until R37 removes it.
- [ ] `DeployUsdrifHandler` — deploy the LayerBank dex handler instead of `TropykusErc20HandlerDex`,
      registered at the index chosen in decision 1. Carry over R22's live-broadcast gate: a real RSK
      RPC without `REAL_DEPLOYMENT=true` reports `FORK`, and `FORK` must revert rather than bind a
      live aToken with a test `feeCollector` and the 2% test fee cap.
- [ ] `DeployDexSwaps` — register the LayerBank dex route and deploy the handler on the live branch.
- [ ] `Makefile` / harness — a `dex-layerbank` lane; `DcaDappTest` must stop skipping
      `isDexSwaps && isLayerbank` (it currently does, via the R22 "dex is tropykus/sovryn only" guard).
- [ ] CI — add `dex-layerbank` with `STABLECOIN_TYPE=USDRIF` to the matrix and to `make check` / `make ci`.

## Out of scope

- [ ] Retiring Tropykus, the `script/tropykus-legacy/` folder, and moving `TROPYKUS_INDEX` — that is R37.
- [ ] LayerBank DOC on the dex path (this item is USDRIF).
- [ ] Merkl / LAB / harvest, or any external reward integration (see `EXTERNAL_REWARDS.md`).
- [ ] `stablecoinRecipient` on LayerBank redeem.
- [ ] Any `ITokenLending` event/error ABI rename.
- [ ] `--broadcast` or live-chain interaction.

## Files likely touched

- `src/layerbank/LayerBankErc20HandlerDex.sol` (new)
- `script/UsdrifHelperConfig.s.sol`, `script/DeployUsdrifHandler.s.sol`, `script/DeployDexSwaps.s.sol`
- `script/Constants.sol` (dex-map index constant, if decision 1 needs one)
- `test/unit/DcaDappTest.t.sol` (dex/layerbank lane guard), `Makefile`, `.github/workflows/test.yml`
- `test/ai-generated/unit/layerbank/` (new dedicated dex handler tests)

## Required tests

```
SWAP_TYPE=dexSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=USDRIF make dex
STABLECOIN_TYPE=USDRIF make dex-layerbank
make check
```

Assert:

- Deposit → aToken scaled shares → Uniswap purchase → rBTC accrual → withdraw, on the USDRIF dex lane.
- The round-up solvency property R22 established for the MoC lane also holds here: virtual scaled books
  stay `<=` handler `scaledBalanceOf` after odd-amount redeems against Aave-like round-nearest burns.
  The test must fail if `_stablecoinToShares` were flipped to `Rounding.Down`.
- `DeployUsdrifHandler.run()` reverts on `FORK` without `REAL_DEPLOYMENT=true` (mirror
  `test_run_revertsOnForkWithoutRealDeployment`).
- The Sovryn dex lane is unchanged.

Fork: adds a fork-specific assertion only if decision 3 turns up a live kUSDRIF pause. Still run
`make fork-sovryn` and `make fork-tropykus` before push.

## Success criteria

- [ ] USDRIF DCA works end-to-end on a LayerBank-backed dex handler with no Tropykus contract involved.
- [ ] `DeployUsdrifHandler` no longer constructs `TropykusErc20HandlerDex`.
- [ ] `dex-layerbank` is green locally and in CI.
- [ ] The live-broadcast gate is asserted by a test, not only documented.
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold — in particular #1 (balance-delta cash) and #2
      (no view as redeem ceiling) on the new redeem path.
- [ ] `LayerBankErc20HandlerDex` adds no logic beyond the constructor, like `SovrynErc20HandlerDex`.
- [ ] Tests in the PR match **Required tests**.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: new handler contract; no change to shared interfaces. Confirm the R9 share event is inherited
  from `LendingErc20Handler` and actually emitted on the new path.
- Scripts: `DeployUsdrifHandler` and `DeployDexSwaps` change which handler the live dex path deploys.
- Cutover: the USDRIF dex route index and its lending backend both change. Ops and the frontend need
  the new index and the fact that USDRIF yield now comes from LayerBank, not Tropykus. An illiquid
  LayerBank USDRIF reserve aborts the whole `batchBuyRbtc` (live Aave `withdraw` reverts on
  insufficient aToken cash) — drop the row, do not retry as a partial batch.
