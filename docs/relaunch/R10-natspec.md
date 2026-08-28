# R10 — First-party natspec and comments

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 48 of the relaunch stack. Final item. Stack on R9 (PR 47). ABI, names, handlers, route maps, packing, pauses, and the swapper batcher are already frozen. This PR only documents that surface.

## Objective

Rewrite first-party natspec so explorers and generated docs describe the shipped contracts. Put user-facing documentation on interfaces and use `@inheritdoc` on implementing functions. Do not change behavior, ABI, storage, or local names.

## Background

NatSpec on `src/` is verified with the bytecode for the life of the deployment (`AGENTS.md` **Onchain comments**). It currently mixes leftover names (`ISovrynErc20HandlerDex`, “lending index 0” on the idle handler), duplicated function docs on implementations, `@dev`-only public ABI, and copy-paste (`IPurchaseUniswap.setAmountOutMinimumSafetyCheck` restates the percent setter). R16/R25/R26/R35 already settled the glossary; R9 froze events. This pass must not re-open those.

SwapperBatcher and OperationsAdmin already use `@inheritdoc` on several functions. Match that pattern everywhere an implementation overrides a first-party interface.

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 48. Implement without asking.

## Style (this PR’s contract)

- **Interfaces own the ABI docs.** Every first-party external function, event, error, and user-facing struct/enum has `@notice`. `@param` / `@return` on functions. `@dev` only for constraints a caller or indexer must know (pause blast radius, withdraw-all sentinel, positional pairs, share-event `newShares == getUserShares`).
- **Implementations inherit.** A function that `override`s a first-party interface uses `@inheritdoc IFoo`. Extra `@dev` is allowed only for implementation-only facts (packing dirty-writes, CEI order, balance-delta measurement, WRBTC unwrap). Do not duplicate `@notice`/`@param` already on the interface.
- **No interface to inherit from:** constructors, internals, modifiers, `receive`, `supportsInterface` (OZ), adapter hooks. Document those on the implementation with `@dev` / `@param` / `@return`.
- **`@author BitChill team: Antonio Rodríguez-Ynyesto`** on every first-party contract and interface (DcaManager currently differs).
- **`@param name` without a trailing colon.** Existing `param:` forms are rewritten when the block is touched.
- **No relaunch ticket IDs** in `src/` comments or NatSpec. Durable reason only.
- **Keep durable reasons.** Packing layout, cash-delta vs integrator returns, $1 peg, deposit-pause vs schedule-pause, share round-up solvency, nonce-as-id — rewrite for clarity, do not delete.
- **Do not rename locals** (R38 recorded that this pass does not reach local names). Do not `forge fmt`.

## Scope

- [x] First-party interfaces under `src/interfaces/` plus BitChill-owned protocol interfaces (`IIdleErc20Handler`, `ILayerBankErc20Handler`): complete `@notice`/`@param`/`@return` on the public ABI. Fix stale or copy-paste text (idle is a route class, not “lending index 0”; Uniswap safety-check setter is a config floor, not the swap percent).
- [x] First-party implementations: `@inheritdoc` on interface overrides; contract `@title` + `@notice` that names the real composition (funding base + purchase route); constructors document every parameter including `feeCollector` / `initialOwner` / `uniswapSettings` where missing.
- [x] Stale facts: `IdleDocHandlerMoc` “lending index 0”; `SovrynErc20HandlerDex` “ISovrynErc20HandlerDex interface”; `FeeHandler` `@title TokenHandler`; `src/idle/README.md` still saying index 0 has “no protocol name” and that `DeployMocSwaps` wiring is a later PR.
- [x] Third-party ABI wrappers (`IMocProxy`, `IWRBTC`, `ICoinPairPrice`, `IkToken`, `IiSusdToken`, `ILayerBankPool`, `ILayerBankAToken`): a short first-party `@notice` of how BitChill uses them. Do **not** rewrite vendor function dumps (`ICoinPairPrice`, Compound-copied `IkToken` bodies). `ILayerBankPool` / `ILayerBankAToken` already had that header and were left as-is.
- [x] `IStablecoin` is a mock-facing mintable subset used only from `test/mocks`. Mark it as such; do not present it as a production ABI.
- [x] No selector, event, error, storage, or bytecode change. Prove with `forge inspect` methodIdentifiers and storageLayout on the production contracts before/after.

## Out of scope

- [ ] Behavior, ABI, packing, pause, fee math, route maps, batcher logic.
- [ ] Local variable renames.
- [ ] `forge fmt` of existing files.
- [ ] `script/` runbooks (except a constructor comment that contradicts the current ABI — none expected).
- [ ] `test/` natspec.
- [ ] SPDX / license.
- [ ] Rewriting third-party function-level natspec on vendor ABI copies.
- [ ] Consumer copy (front-end, monitoring). NatSpec is on-chain; no sibling-repo issue unless an ABI field meaning changed — it must not.

## Files likely touched

First-party interfaces:

- `src/interfaces/IDcaManager.sol`
- `src/interfaces/IDcaManagerAccessControl.sol`
- `src/interfaces/IOperationsAdmin.sol`
- `src/interfaces/ITokenHandler.sol`
- `src/interfaces/ITokenLending.sol`
- `src/interfaces/IFeeHandler.sol`
- `src/interfaces/IPurchaseRbtc.sol`
- `src/interfaces/IPurchaseMoc.sol`
- `src/interfaces/IPurchaseUniswap.sol`
- `src/interfaces/ISwapperBatcher.sol`
- `src/idle/IIdleErc20Handler.sol`
- `src/layerbank/ILayerBankErc20Handler.sol`

First-party implementations:

- `src/DcaManager.sol`
- `src/DcaManagerAccessControl.sol`
- `src/OperationsAdmin.sol`
- `src/BitChillOwnable.sol`
- `src/FeeHandler.sol`
- `src/TokenHandler.sol`
- `src/TokenLending.sol`
- `src/LendingErc20Handler.sol`
- `src/StablecoinSource.sol`
- `src/PurchaseRbtc.sol`
- `src/PurchaseMoc.sol`
- `src/PurchaseUniswap.sol`
- `src/SwapperBatcher.sol`
- `src/idle/IdleErc20Handler.sol`
- `src/idle/IdleDocHandlerMoc.sol`
- `src/sovryn/SovrynErc20Handler.sol`
- `src/sovryn/SovrynDocHandlerMoc.sol`
- `src/sovryn/SovrynErc20HandlerDex.sol`
- `src/layerbank/LayerBankErc20Handler.sol`
- `src/layerbank/LayerBankDocHandlerMoc.sol`
- `src/layerbank/LayerBankErc20HandlerDex.sol`
- `src/tropykus-legacy/TropykusErc20Handler.sol`
- `src/tropykus-legacy/TropykusDocHandlerMoc.sol`
- `src/tropykus-legacy/TropykusErc20HandlerDex.sol`

Third-party wrappers (header only) and mock-facing:

- `src/interfaces/IMocProxy.sol`, `IWRBTC.sol`, `ICoinPairPrice.sol`, `IStablecoin.sol`
- `src/sovryn/IiSusdToken.sol`
- `src/tropykus-legacy/IkToken.sol`
- `src/layerbank/ILayerBankPool.sol`, `ILayerBankAToken.sol`

Stale first-party handler note:

- `src/idle/README.md`

## Required tests

No new behavioral tests. Comments do not change bytecode.

1. `forge inspect` `methodIdentifiers` and `storageLayout` for `DcaManager`, `OperationsAdmin`, `SwapperBatcher`, `IdleDocHandlerMoc`, `SovrynDocHandlerMoc`, `SovrynErc20HandlerDex`, `LayerBankDocHandlerMoc`, `LayerBankErc20HandlerDex` — byte-identical to R9 HEAD.
2. Targeted compile: `forge build`.
3. `make check`.
4. Fork: no new assertions. Still run `make fork-sovryn` and `make fork-tropykus` before push.

## Success criteria

- [x] User-facing ABI docs live on first-party interfaces; implementing functions use `@inheritdoc` (plus `@dev` only for implementation-only facts).
- [x] No first-party `src/` comment names a relaunch ticket or a deleted interface.
- [x] Idle is documented as route class / default index 0, not a lending protocol.
- [x] `forge inspect` methodIdentifiers and storageLayout unchanged on the production contracts.
- [x] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable. No local renames, no `forge fmt`.

## ABI / deploy / cutover impact

- ABI: none. NatSpec is not part of the ABI JSON selectors; `forge inspect` must stay identical.
- Scripts: none.
- Cutover: none. Explorers will show the new comments after verification. No consumer issue — no selector, event, or field-meaning change.
