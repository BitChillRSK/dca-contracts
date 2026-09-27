# R92 — FeeHandler ownership move

Status: **in progress** · Assigned: yes · Optional/further-review: no

## Objective

Move `FeeHandler` off `TokenHandler` so fees are owned only on the purchase branch
(`PurchaseRbtc` ← `PurchaseMoc` / `PurchaseUniswap`). Keep every concrete leaf constructor ABI
unchanged. Solve the default-profile (`via_ir = false`) Dex stack-too-deep that blocked the R90
prototype so `make check` stays on legacy codegen.

## Background

Fees are charged only on purchases. `TokenHandler` is the deposit/withdraw base; inheriting
`FeeHandler` there is a diagram lie and forces every funding-base test harness to thread fee args
that funding does not use. R30 already put `FeeHandler` on `PurchaseRbtc` as well (diamond). R90
prototyped dropping it from `TokenHandler` and routing fee constructor args through
`PurchaseMoc` / `PurchaseUniswap`:

| Check | R90 prototype result |
|---|---|
| Storage layout (IdleDoc / SovrynDoc under default; Idle Dex under `deploy`) | Identical vs then-base |
| `[profile.deploy]` (`via_ir`) | Dex leaves compile |
| `[profile.default]` (`via_ir = false`) | **`IdleErc20HandlerDex` stack-too-deep** at the leaf constructor |
| Concrete leaf constructor ABIs | Unchanged |

The human approved the move for diagram cleanup (2026-09-27) and deferred it to this PR so the
stack break is fixed here, not by making day-to-day `make check` depend on via-IR for Dex leaves.
See [R90](./R90-final-optimization-decisions.md#feehandler-ownership-move-prototype).

## Open product decisions

**none** — approved under R90 (2026-09-27): implement the FeeHandler ownership move; solve
default-profile Dex stack-too-deep without adopting via-IR for `make check`.

## Scope

- [ ] Remove `FeeHandler` from `TokenHandler`'s inheritance and constructor. `TokenHandler` keeps
      `DcaManagerAccessControl` + `StablecoinSource` only (plus `ERC165` / `ITokenHandler`).
- [ ] Give `PurchaseRbtc` a constructor that initializes `FeeHandler`. Route fee args through
      `PurchaseMoc` and `PurchaseUniswap` (not through `IdleErc20Handler` / `LendingErc20Handler`).
- [ ] Slim `IdleErc20Handler`, `LendingErc20Handler`, and every protocol adapter constructor: drop
      fee parameters. Leaves keep the same public constructor parameter lists and pass fee args into
      the purchase base instead of the funding base.
- [ ] Solve default-profile Dex stack-too-deep without enabling `via_ir` on `[profile.default]`.
      Preferred lever: pack fee constructor inputs into one memory struct for the purchase-base call
      so the Dex leaf constructor passes fewer stack slots into `PurchaseUniswap`; extract
      constructor body work only if still needed. Do not accept option (a) from R90 (via-IR for
      day-to-day Dex `make check`).
- [ ] Update NatSpec / `AGENTS.md` layout: fees belong on the purchase branch; `TokenHandler` no
      longer "owns FeeHandler".
- [ ] Update abstract-base test harnesses that construct `IdleErc20Handler` / `LendingErc20Handler` /
      protocol adapters without a purchase leaf so they compile (drop fee args there). Leaves and
      deploy scripts stay ABI-stable — `script/` should not need constructor-shape edits.
- [ ] Prove concrete constructor ABIs / method identifiers unchanged on every production leaf.
- [ ] Record storage layout vs the R91 parent for IdleDoc, SovrynDoc, and Idle Dex under both
      profiles. Prefer identity (R90 prototype). If a lending leaf shifts slots because FeeHandler
      leaves the funding-first C3 prefix, document the exact before/after and keep going: these
      contracts are not proxies and have not deployed. Do not invent a second FeeHandler inheritance
      on the funding side just to freeze slots.
- [ ] Full executable gate: `make check`, `make check-deploy`, `make fork-sovryn`, `make fork-tropykus`.

## Out of scope

- [ ] Changing any concrete leaf constructor parameter list, external selector, event, or error.
- [ ] Enabling `via_ir` on `[profile.default]` / day-to-day `make check`.
- [ ] Fee math, fee ABI surface, or collector behaviour changes.
- [ ] Folding `IdleErc20Handler` into `TokenHandler` (rejected under R90).
- [ ] `forge fmt` (R91).
- [ ] Deploy broadcasts or consumer-repo implementations.

## Files likely touched

- `src/TokenHandler.sol`
- `src/PurchaseRbtc.sol`
- `src/PurchaseMoc.sol`
- `src/PurchaseUniswap.sol`
- `src/FeeHandler.sol` (NatSpec only, and optionally a fee-constructor struct if that is the stack fix)
- `src/interfaces/IFeeHandler.sol` (only if the fee-constructor struct lives on the interface)
- `src/idle/IdleErc20Handler.sol`
- `src/LendingErc20Handler.sol`
- `src/idle/IdleDocHandlerMoc.sol`, `src/idle/IdleErc20HandlerDex.sol`
- `src/sovryn/SovrynErc20Handler.sol`, `src/sovryn/SovrynDocHandlerMoc.sol`, `src/sovryn/SovrynErc20HandlerDex.sol`
- `src/layerbank/LayerBankErc20Handler.sol`, `src/layerbank/LayerBankDocHandlerMoc.sol`, `src/layerbank/LayerBankErc20HandlerDex.sol`
- `src/tropykus-legacy/TropykusErc20Handler.sol`, `src/tropykus-legacy/TropykusDocHandlerMoc.sol`, `src/tropykus-legacy/TropykusErc20HandlerDex.sol`
- Abstract-base / reversed-inheritance / handler harness tests that construct funding bases without a
  purchase leaf (follow compile errors from the list above)
- `AGENTS.md` (layout: FeeHandler on purchase branch only)
- `docs/relaunch/R92-feehandler-ownership.md`, `docs/relaunch/README.md`,
  `docs/relaunch/R90-final-optimization-decisions.md` (point the deferred row at this PR once open)

## Required tests

Executable change → full local gate:

```text
make check
make check-deploy
make fork-sovryn
make fork-tropykus
```

Also before push:

1. `forge inspect <leaf> methodIdentifiers` (or constructor ABI) identical vs R91 parent for every
   production MoC and Dex leaf (including Tropykus leaves that still compile).
2. `forge inspect <leaf> storageLayout` recorded vs parent for `IdleDocHandlerMoc`,
   `SovrynDocHandlerMoc`, and `IdleErc20HandlerDex` under default and `FOUNDRY_PROFILE=deploy`.
3. Confirm `[profile.default]` compiles `IdleErc20HandlerDex` / `SovrynErc20HandlerDex` /
   `LayerBankErc20HandlerDex` (the R90 failure mode).
4. Fee behaviour unchanged: existing fee unit tests and a purchase path that pays a non-zero fee
   still pass; owner after construction is still `initialOwner`.

Forks add no R92-specific live-state assertion; they are the Makefile gate.

## Success criteria

- [ ] `TokenHandler` does not inherit or construct `FeeHandler`.
- [ ] `FeeHandler` is initialized only through `PurchaseRbtc` (via `PurchaseMoc` / `PurchaseUniswap`).
- [ ] Every concrete leaf constructor ABI / method-id set matches the R91 parent.
- [ ] `[profile.default]` compiles all Dex leaves (no stack-too-deep); `via_ir` stays false there.
- [ ] `make check`, `make check-deploy`, `make fork-sovryn`, and `make fork-tropykus` pass.
- [ ] Storage layout vs parent is recorded; any slot shift is explained in the PR (pre-deploy only).
- [ ] `AGENTS.md` layout no longer says TokenHandler owns FeeHandler.
- [ ] No consumer-visible selector / event / error change; no consumer issue required.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Default profile still `via_ir = false`; Dex leaves compile under it.
- [ ] Concrete constructor ABIs unchanged; scripts untouched unless a compile error proves otherwise.
- [ ] Tests match **Required tests**; files beyond this list are named in the PR.
- [ ] No fee-math or fee-ABI behaviour change mixed in.

## ABI / deploy / cutover impact

- ABI: none on concrete leaves (constructor and external selectors unchanged). Abstract-base
  constructors may slim; those are not deployed.
- Scripts: expected none. Concrete constructor ABI preservation is a success criterion.
- Storage: prefer identity with R91; any shift is pre-deploy only and must be listed in the PR.
- Cutover: none. No consumer issue.
