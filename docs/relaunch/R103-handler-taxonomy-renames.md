# R103 — Handler taxonomy: contract and registry renames

Status: **in progress** · Assigned: yes · Optional/further-review: no · Stack on: R102 ([#168](https://github.com/BitChillRSK/dca-contracts/pull/168))

## Objective

Make `*Handler` mean only fund custody/execution units in the `TokenHandler` lineage. Strip redundant
`Erc20` from protocol bases and Dex leaves, rename the fee mixin off `*Handler`, and shorten the
OpsAdmin registry to `getHandler` / `assignHandler` so the public vocabulary matches.

## Background

Post-R102 naming review. BitChill’s deployed leaf for a `(token, route)` holds funds, optionally
lends, and buys rBTC. That unit is correctly a **Handler**. Mixins that only price fees or run the
purchase pipeline are not. Historical `*Erc20Handler` names contrasted Doc leaves with a generic
ERC20 base; every handler’s stablecoin is already an ERC20, and `TokenHandler` already says so.

`PurchaseRbtc` / `PurchaseMoc` / `PurchaseUniswap` stay — they are purchase-route mixins, not
registry handlers. `*DocHandlerMoc` stays — Doc and MoC are load-bearing.

Registry assignment is **add-only** (reassignment reverts). The verb remains `assign*`, not `set*`.
`set*` is reserved for overwriteable config (R104).

This PR is rename-only: no behavior, packing, or purchase-path logic changes. Identifier and NatSpec
polish that is not a contract/file/event/error rename ships in [R104](./R104-identifier-and-natspec-polish.md).

## Open product decisions

1. **Fee mixin name** — **answered 2026-09-28: `PurchaseFees`**.

   Was `PurchaseFees` / `IPurchaseFees` / `PurchaseFees__*` / `FeeConfig`. Chosen name:

   | Piece | Name |
   |-------|------|
   | Contract / file | `PurchaseFees` / `PurchaseFees.sol` |
   | Interface | `IPurchaseFees` |
   | Events / errors | `PurchaseFees__*` |
   | Constructor bag | `FeeConfig` |
   | Keep | `FeeSettings` |

   Rejected: `FeeLogic` (proxy-implementation baggage), `FeeManager` (second `*Manager` layer next to
   `DcaManager`), bare `Fees`, `FeeCalculator`, `FeeModule`. `PurchaseFees` lives on the purchase
   branch (R92), is not a Handler, and reads as the fee facet next to `PurchaseRbtc` / venue leaves.

   Ownership / storage layout stay as after R92 / R94 (`BitChillOwnable` remains on this mixin). Only
   the type and ABI prefix names change.

## Scope

Once the fee name is answered, implement:

- [x] **Rule in `AGENTS.md` layout:** `*Handler` = `TokenHandler` lineage (fund custody/execution).
      Fee mixin and `Purchase*` are not Handlers. Update the inheritance diagram names.
- [x] Strip `Erc20` from protocol bases and Dex leaves (files, contracts, interfaces, error prefixes):

  | Current | New |
  |---------|-----|
  | `IdleErc20Handler` | `IdleHandler` |
  | `IdleErc20HandlerDex` | `IdleHandlerDex` |
  | `SovrynErc20Handler` | `SovrynHandler` |
  | `SovrynErc20HandlerDex` | `SovrynHandlerDex` |
  | `LayerBankErc20Handler` | `LayerBankHandler` |
  | `LayerBankErc20HandlerDex` | `LayerBankHandlerDex` |
  | `ILayerBankErc20Handler` / `LayerBankErc20Handler__*` | `ILayerBankHandler` / `LayerBankHandler__*` |
  | `TropykusErc20Handler` | `TropykusHandler` |
  | `TropykusErc20HandlerDex` | `TropykusHandlerDex` |
  | `ITropykusErc20Handler` / `TropykusErc20Handler__*` | `ITropykusHandler` / `TropykusHandler__*` |

- [x] Keep `TokenHandler`, `LendingHandler`, `ITokenHandler`, `ILendingHandler`, and all `*DocHandlerMoc`.
- [x] Keep `PurchaseRbtc`, `PurchaseMoc`, `PurchaseUniswap` and their interfaces.
- [x] Rename fee mixin to `PurchaseFees` (files, contract, interface, events, errors, `FeeHandlerConfig` → `FeeConfig`).
- [x] OpsAdmin registry: `getTokenHandler` → `getHandler`, `assignTokenHandler` → `assignHandler`,
      event `OperationsAdmin__TokenHandlerAssigned` → `OperationsAdmin__HandlerAssigned`.
- [x] Keep `OperationsAdmin__ContractIsNotTokenHandler` — it names the `ITokenHandler` ERC-165 check,
      and `TokenHandler` remains the funding-base type.
- [x] Update `script/`, `test/`, `AGENTS.md`, and first-party READMEs under `src/*/README.md` that
      hardcode the old contract or path names. Prefer `git mv` for file renames.
- [ ] Consumer follow-up issues for every renamed selector, event, and custom error (at least
      front-end, bitchill-monitoring; swapper-bot / data-api if they call the registry getters).

## Out of scope

- [ ] Variable renames (`i_wrbtc`, locals, …) — [R104](./R104-identifier-and-natspec-polish.md).
- [ ] Function renames other than `getHandler` / `assignHandler` — R104 (`set*`, interest order,
      `withdrawAccumulatedRbtc`, oracle, fee collector).
- [ ] NatSpec / comment trim beyond what a rename forces — R104.
- [ ] Renaming the Handler family to Adapter/Strategy/Vault — closed; keep Handler for fund units.
- [ ] Behavior, packing, fees math, purchase path, pause, route maps.
- [ ] Moving `BitChillOwnable` off the fee mixin (R94 closed).

## Files likely touched

Contract / interface renames (and their tests / scripts by follow):

- `src/FeeHandler.sol` → `src/PurchaseFees.sol`; `src/interfaces/IFeeHandler.sol` → `IPurchaseFees.sol`
- `src/idle/IdleErc20Handler.sol` → `IdleHandler.sol`, `IdleErc20HandlerDex.sol` → `IdleHandlerDex.sol`,
  `IdleDocHandlerMoc.sol` (fee config type only)
- `src/sovryn/SovrynErc20Handler.sol` → `SovrynHandler.sol`, `SovrynErc20HandlerDex.sol` →
  `SovrynHandlerDex.sol`, `SovrynDocHandlerMoc.sol` (fee config type only)
- `src/layerbank/LayerBankErc20Handler.sol` → `LayerBankHandler.sol`,
  `LayerBankErc20HandlerDex.sol` → `LayerBankHandlerDex.sol`, `LayerBankDocHandlerMoc.sol`,
  `ILayerBankErc20Handler.sol` → `ILayerBankHandler.sol`, `README.md`
- `src/tropykus-legacy/TropykusErc20Handler.sol` → `TropykusHandler.sol`,
  `TropykusErc20HandlerDex.sol` → `TropykusHandlerDex.sol`, `TropykusDocHandlerMoc.sol`,
  `ITropykusErc20Handler.sol` → `ITropykusHandler.sol`
- `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol`
- `src/PurchaseRbtc.sol`, `PurchaseMoc.sol`, `PurchaseUniswap.sol` (fee config type only)
- `src/DcaManager.sol` (call sites of `getTokenHandler` / `assignTokenHandler`)
- `AGENTS.md`, `script/**`, matching `test/**`

## Required tests

Rename-only; behavior unchanged. Full executable gate:

1. `make check`
2. `make fork-sovryn` and `make fork-layerbank` (need `RSK_MAINNET_RPC_URL`) before push
3. Document exact commands in the PR
4. No new behavioral assertions required beyond updating call sites / artifact names

## Success criteria

- [x] Open fee-name decision answered and applied consistently (type, file, events, errors, config struct).
- [x] No `Erc20Handler` / `Erc20HandlerDex` identifiers remain in first-party `src/` (except historical
      docs under `docs/relaunch/` that record past PRs).
- [x] OpsAdmin exposes `getHandler` / `assignHandler` / `HandlerAssigned`; `ContractIsNotTokenHandler` kept.
- [x] `Purchase*` and `*DocHandlerMoc` names unchanged.
- [x] `make check` + both forks green; consumer issues filed and linked in the PR.
- [ ] `docs/relaunch/README.md` Status points at this PR; next unassigned prompt is `Start with R104`.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope** (especially no R104 identifier polish).
- [ ] Protocol invariants unchanged.
- [ ] Fee mixin still sits on the purchase branch with `BitChillOwnable` (R92 / R94).
- [ ] Files beyond this list are direct fallout and named in the PR.
- [ ] No unrelated refactors.

## ABI / deploy / cutover impact

- ABI: yes — renamed contracts, error/event prefixes, OpsAdmin selectors and `HandlerAssigned` topic,
  fee mixin selectors/topics/errors, leaf artifact names.
- Scripts: update every deploy / helper that constructs or names the old types.
- Cutover: consumer issues required (front-end registry calls; monitoring ABI regen for events/errors;
  any bot that calls `getHandler`).
