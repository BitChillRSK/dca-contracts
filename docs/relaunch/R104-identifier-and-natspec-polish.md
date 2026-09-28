# R104 — Identifier polish and NatSpec trim

Status: **assigned** · Assigned: yes · Optional/further-review: no · Stack on: R103 ([R103-handler-taxonomy-renames.md](./R103-handler-taxonomy-renames.md)) · PR: [#170](https://github.com/BitChillRSK/dca-contracts/pull/170)

## Objective

Finish the post-R102 naming pass: rename awkward public immutables and inconsistent public
functions, clean local grammar, and trim redundant / verbose NatSpec and inline comments so verified
`src/` reads like authored blue-chip code rather than review accretion.

## Background

R103 settles the Handler taxonomy (fund units vs fee mixin vs purchase mixins) and the OpsAdmin
`getHandler` / `assignHandler` pair. This PR does not rename contracts or files. It renames
identifiers inside the post-R103 tree and hardens comments.

Conventions locked in planning (keep in the PR body / `AGENTS.md` only where a durable rule belongs):

- Prefixes: `i_` immutables, `s_` storage — keep.
- Owner setters for overwriteable config: `set*` (not `modify*` / `update*`).
- Registry add-only assignment: `assign*` (already done in R103) — never `setHandler`.
- Handler locals: `handler` (or `lendingHandler` when typed `ILendingHandler`); never
  `tokenHandlerAddress`.
- Public rBTC API casing: `Rbtc` in function names (`batchBuyRbtc`, `minRbtcOut`). Private helpers:
  lowercase `rbtc`. WRBTC immutable: ticker noun `i_wrbtc`.
- Interest: one noun order — `getAccruedInterest` / `quoteAccruedInterest` on the handler and on
  `DcaManager`.
- Product token: `i_stablecoin` (not `i_stableToken` / `i_asset` / `i_underlying`). Lending receipt
  immutables share the short noun form: `i_aToken`, `i_kToken`, `i_iToken` (Sovryn). Vendored
  `IiSusdToken` stays.

## Open product decisions

**none remaining.** Renames through the first Keep list were approved in the naming chat
(2026-09-28). Product override the same day: also rename `i_stableToken` → `i_stablecoin` and
Sovryn `i_iSusd` / `iSusdTokenAddress` → `i_iToken` / `iTokenAddress`. Fee mixin *type* name remains
R103’s gate, not this PR’s.

## Scope

### Public / immutable renames (ABI)

- [x] `PurchaseUniswap.i_wrBtcToken` → `i_wrbtc`; `UniswapSettings.wrBtcToken` → `wrbtc`; locals
      `wrBtcBalanceBefore` → `wrbtcBalanceBefore`.
- [x] `PurchaseUniswap.i_swapRouter02` → `i_swapRouter` (`@notice` may still say SwapRouter02).
- [x] `SovrynHandler.i_iSusdToken` → `i_iSusd` → **`i_iToken`** (parity with `i_aToken` /
      `i_kToken`); ctor `iSusdTokenAddress` → `iTokenAddress`. Leave vendored `IiSusdToken` alone.
- [x] `i_stableToken` → `i_stablecoin`; ctor/locals `stableTokenAddress` / `tokenAddress` (where
      that arg *is* the stablecoin) → `stablecoinAddress`.
- [x] `DcaManager.modifyMinPurchasePeriod` → `setMinPurchasePeriod`.
- [x] `DcaManager.modifyMaxSchedulesPerToken` → `setMaxSchedulesPerToken`.
- [x] `DcaManager.getInterestAccrued` → `getAccruedInterest` (align with `ILendingHandler` /
      `quoteAccruedInterest`).
- [x] `DcaManager.withdrawRbtcFromTokenHandler` → `withdrawAccumulatedRbtc(token, routeIndex)`
      (mirrors `getAccumulatedRbtcBalance` / handler `withdrawAccumulatedRbtc(user)`).
- [x] `IPurchaseUniswap.updateMocOracle` → `setMocOracle`.
- [x] Fee mixin `getFeeCollectorAddress` / `setFeeCollectorAddress` → `getFeeCollector` /
      `setFeeCollector` (post-R103 fee type).

### Locals / private (no ABI)

- [x] `numOfPurchases` / `numOfSchedules` / `numOfPairs` → `purchaseCount` / `scheduleCount` /
      `pairCount` (and matching return names).
- [x] `usersShares` / `usersSharesToRedeem` / `usersPurchasedRbtc` / `usersStablecoinSpent` →
      `userShares` / `sharesToRedeem` / `userRbtc` / `userStablecoinSpent`.
- [x] `tokenHandlerAddress` / redundant typed `tokenHandler` → `handler` (or `lendingHandler`).
- [x] `_rBtcPurchaseChecksEffects` → `_rbtcPurchaseChecksEffects`.

### NatSpec / comments

- [x] Remove `@return The constructor-supplied …` on public immutables (type + `@notice` suffice).
- [x] Remove Fee mixin trailing `//` on `s_feeCollector` / bounds / rates that restate the name
      (keep the packing `@dev`).
- [x] Remove `s_tokenMinPurchaseAmounts // Per-token…`, `// Calculate net amounts`, and “scoped to
      this block because it is dead once…” apologetics in `PurchaseRbtc`.
- [x] Collapse duplicate `memory` `@dev` on `setPurchasePath` / `setPurchasePathAllowed` to one short
      note (or one site + `@inheritdoc`-style silence on the twin).
- [x] Fix inaccurate `i_pool` `@return` on LayerBank if it still claims constructor-supplied aToken.
- [x] Do **not** strip durable invariant `@dev` (packing, exact consumption, oracle floor, protected
      window, schedule-id-as-nonce, leaf lifecycle headers).

### Keep explicitly

- [x] Event / error spellings such as `PurchaseRbtc__rBtcWithdrawn` (ABI churn for monitoring with no
      readability win).
- [x] `i_operationsAdmin`, `i_dcaManager`, `i_mocProxy`, `i_aToken`, `i_kToken`, `i_pool`, and
      domain `s_*` names. Vendored `IiSusdToken` type/file name.
- [x] Long product names: `batchBuyRbtcAcrossHandlers`, protected-window APIs, `topUpFromInterest`,
      `restore*Approval`.

## Out of scope

- [ ] Any contract, file, or fee-mixin *type* rename — R103.
- [ ] OpsAdmin `getHandler` / `assignHandler` — R103.
- [ ] Behavior, gas, packing, purchase-path logic.
- [ ] Rewriting historical relaunch specs’ old names (closed R10 / R21 / … keep the names that
      shipped then). Only this file, `docs/relaunch/README.md` Status, and `AGENTS.md` may name the
      new identifiers in docs.

## Files likely touched

- `src/PurchaseUniswap.sol`, `src/interfaces/IPurchaseUniswap.sol`
- `src/PurchaseRbtc.sol`, `src/interfaces/IPurchaseRbtc.sol`
- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- Fee mixin + `IFee*` (post-R103 paths)
- `src/StablecoinSource.sol`, `src/interfaces/IStablecoinSource.sol`, `src/TokenHandler.sol`
- `src/sovryn/SovrynHandler.sol` (+ Dex / Doc leaves’ ctor param names; not `IiSusdToken.sol`)
- `src/LendingHandler.sol`, `src/idle/IdleHandler.sol`, other call sites of locals
- Matching `test/**`, `script/**` only where they name renamed selectors or immutables
- `AGENTS.md` for the durable `i_stablecoin` layout sentence; `docs/relaunch/README.md` Status

## Required tests

Executable ABI changes → full gate:

1. `make check`
2. `make fork-sovryn` and `make fork-layerbank` before push
3. Consumer issues for every renamed DcaManager / fee / Uniswap / Sovryn getter or setter
4. Document exact commands in the PR

Comment-only hunks do not need a separate metadata-stripped proof if the same PR already runs the
full gate for the ABI renames.

## Success criteria

- [x] Every Scope rename applied; Keep list untouched (except the product override that moved
      `i_stablecoin` / `i_iToken` into Scope).
- [x] No `@return The constructor-supplied` left on first-party public immutables.
- [x] Fee / PurchaseUniswap state-var trailing noise and PurchaseRbtc scope apologetics gone.
- [x] `make check` + both forks green; consumer issues linked in the PR.
- [x] `docs/relaunch/README.md` Status points at this PR; next unassigned prompt returns to cutover
      (`CUTOVER_RUNBOOK.md`) unless a later item is ordered.
- [x] No historical `docs/relaunch/R*.md` (other than this file) rewritten for the new names.

## Reviewer checklist

- [ ] Matches **Scope**; no R103 contract renames sneaked in.
- [ ] Invariants unchanged; NatSpec trim did not delete durable reasons.
- [ ] `set*` used only for overwriteable config; registry stays `assign*`.
- [ ] Files beyond this list are direct fallout and named in the PR.
- [ ] Closed relaunch specs still use the names that shipped then.

## ABI / deploy / cutover impact

- ABI: yes — listed public immutable getters and function selectors.
- Scripts: update any literal that references old immutable or function names.
- Cutover: front-end (DcaManager setters/getters/withdraw), monitoring if it decodes fee collector
  setters or handler immutables (`i_stablecoin`, `i_iToken`, Dex getters), swapper if it reads Dex
  immutables. Open/update sibling issues per `AGENTS.md`.
