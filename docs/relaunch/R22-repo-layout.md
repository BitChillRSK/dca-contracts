# R22 — Repo layout preparation

Status: **in review** · Assigned: yes · Optional/further-review: no

PR 11 of R22. Idle handler, LayerBank handler, and deploy/CI index-map work are later PRs.

## Objective

Move protocol-specific sources and their dedicated handler tests into `src/sovryn/`, `src/tropykus-legacy/`, and placeholder folders `src/idle/` and `src/layerbank/`, so later R22 PRs can add idle and LayerBank without renaming Tropykus in place. Behavior, indexes, and who gets deployed stay as they are.

## Background

R22 as a whole makes lending optional (idle at index 0), puts LayerBank at 1, and keeps Sovryn at 2. Tropykus is shutdown: keep the code, do not deploy it on the new admin. Idle is PR 12; LayerBank and the deploy/CI map follow R21 and R16 (PRs 15–16).

This PR is only the folder split (`IMPLEMENTATION_ORDER.md` PR 11). Foundry `src = "src"` already compiles subfolders. `PurchaseMoc` and `PurchaseUniswap` stay in core — they are purchase methods, not lending protocols. Do not create `src/moc-lending/`.

Live deploy scripts still register Tropykus after this PR. Dropping that registration is PR 17; doing it here would break `make moc-tropykus`. The `tropykus-legacy/` name is the signal, not a deploy-script change.

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 11. Implement without asking.

## Scope

- [ ] `git mv` Sovryn handlers and their protocol-specific interfaces into `src/sovryn/`.
- [ ] `git mv` Tropykus handlers and their protocol-specific interfaces into `src/tropykus-legacy/`.
- [ ] Create `src/idle/` and `src/layerbank/` as tracked placeholders (short README only; no Solidity).
- [ ] `git mv` dedicated handler unit tests into `test/ai-generated/unit/sovryn/` and `test/ai-generated/unit/tropykus-legacy/`.
- [ ] Update imports in moved files and every remaining caller (scripts, shared harness, other tests). Use `src/...` remappings for core contracts from subfolders.
- [ ] Update `AGENTS.md` Layout to match the new folders. `src/interfaces/` remains first-party *shared* ABIs; protocol-specific interfaces live next to their handlers.

## Out of scope

- [ ] Idle handler (PR 12), LayerBank handler (PR 15), deploy/constants/harness/CI matrix (PR 17).
- [ ] Changing `TROPYKUS_INDEX` / `SOVRYN_INDEX` / `Protocol` enum / `LENDING_PROTOCOL` env values.
- [ ] Stopping Tropykus (or Dex/USDRIF) registration in `DeployMocSwaps` / `DeployDexSwaps`. Scripts only change import paths.
- [ ] Splitting `DcaDappTest`, deleting `ILendingToken`, or moving `test/mocks/` (`MockKdocToken` / `MockIsusdToken` / `MockKToken` are still used by the shared harness and helper configs).
- [ ] Creating `src/moc-lending/`. Deleting or relocating `PurchaseUniswap`, Dex handlers, or Uniswap interfaces.
- [ ] Behavior, ABI, natspec, or R16 renames.

## Files likely touched

Moves:

- `src/SovrynErc20Handler.sol`, `src/SovrynErc20HandlerDex.sol`, `src/SovrynDocHandlerMoc.sol` → `src/sovryn/`
- `src/interfaces/ISovrynErc20Lending.sol`, `src/interfaces/IiSusdToken.sol` → `src/sovryn/`
- `src/TropykusErc20Handler.sol`, `src/TropykusErc20HandlerDex.sol`, `src/TropykusDocHandlerMoc.sol` → `src/tropykus-legacy/`
- `src/interfaces/ITropykusErc20Lending.sol`, `src/interfaces/IkToken.sol` → `src/tropykus-legacy/`
- `test/ai-generated/unit/Sovryn{DocHandlerMoc,Erc20Handler,Erc20HandlerDex}Test.t.sol` → `test/ai-generated/unit/sovryn/`
- `test/ai-generated/unit/Tropykus{DocHandlerMoc,Erc20Handler,Erc20HandlerDex}Test.t.sol` → `test/ai-generated/unit/tropykus-legacy/`

New:

- `src/idle/README.md`
- `src/layerbank/README.md`

Import-path only (same behavior):

- `script/DeployMocSwaps.s.sol`, `script/DeployDexSwaps.s.sol`, `script/DeployUsdrifHandler.s.sol`
- `test/unit/DcaDappTest.t.sol`, `test/unit/StablecoinLendingTest.t.sol`, `test/unit/OperationsAdminTest.t.sol`, `test/unit/DepositSwapPopReentrancyTest.t.sol`
- `test/unit/deployment/BaseDeploymentTest.t.sol`, `test/unit/deployment/NewHandlerDeploymentTest.t.sol`
- `test/interfaces/ILendingToken.sol`
- `test/ai-generated/unit/{GettersTest,RoleSecurityTest,EdgeCasesTest,DcaManagerEdgeCasesTest}.t.sol`
- `test/ai-generated/fuzz/Invariants.t.sol`

Docs:

- `AGENTS.md`
- `docs/relaunch/README.md`

## Required tests

Behavior is unchanged, so the existing done-gate is the proof:

```
make check
```

Targeted compile after the moves (catches leftover `src/Tropykus*.sol` / `src/Sovryn*.sol` imports):

```
make build
```

Behaviors to assert (no new test file):

- `forge build` succeeds; no first-party import still points at the old handler paths.
- `make moc-tropykus` still constructs Tropykus at index 1.
- `make moc-sovryn` still constructs Sovryn at index 2.
- Dedicated handler tests still run (they moved; Forge discovers them under the new folders).

Fork tests: not required.

## Success criteria

- [ ] Sovryn sources live under `src/sovryn/`; Tropykus sources live under `src/tropykus-legacy/`; `src/idle/` and `src/layerbank/` exist as placeholders with no Solidity.
- [ ] `PurchaseMoc.sol` and `PurchaseUniswap.sol` remain in `src/` (not under a lending folder).
- [ ] `src/interfaces/` no longer holds `IkToken`, `IiSusdToken`, `ITropykusErc20Lending`, or `ISovrynErc20Lending`.
- [ ] No bytecode / ABI / index-map change. Deploy scripts still register Tropykus and Sovryn; they only import from the new paths.
- [ ] Done-gate lanes pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable (`git mv` for the moves).

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: import paths only. No new env vars, no index change, no broadcast.
- Cutover: none. Frontend index map is unchanged until PR 17.
