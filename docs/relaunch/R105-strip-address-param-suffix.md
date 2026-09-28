# R105 — Strip redundant `Address` from address parameters

Status: **assigned** · Assigned: yes · Optional/further-review: no · Stack on: R104 ([R104-identifier-and-natspec-polish.md](./R104-identifier-and-natspec-polish.md))

## Objective

Strip the redundant `Address` suffix from first-party `address` parameters (constructors and any
matching locals / script helpers that carry the same role noun) so the name is the role. The type
already says address.

## Background

R104 finished public immutable and function polish (`i_stablecoin`, `i_dcaManager`, `i_iToken`, fee
collector drops `Address` from getters/setters). Constructor and script parameter names still say
`stablecoinAddress`, `dcaManagerAddress`, `mocProxyAddress`, and so on. That restates the type and
disagrees with the immutables they initialize (`i_stablecoin`, `i_dcaManager`, `i_mocProxy`).

Ctor argument names are not call selectors; every `new Handler(...)` / deploy-script call site still
needs updating for compile. Named locals that mirror those roles rename with them.

Decided naming (2026-09-28 follow-up to R104):

| Before | After |
|---|---|
| `stablecoinAddress` | `stablecoin` |
| `dcaManagerAddress` | `dcaManager` |
| `operationsAdminAddress` / `adminOpsAddress` | `operationsAdmin` |
| `mocProxyAddress` | `mocProxy` |
| `aTokenAddress` | `aToken` |
| `kTokenAddress` | `kToken` |
| `iTokenAddress` | `iToken` |
| `docTokenAddress` | `docToken` |
| `kDocTokenAddress` | `kToken` (parity with `i_kToken` / `TropykusHandler(kToken)`) |

Already-clean names stay: `feeCollector`, `initialOwner`, and any parameter that is not `address`.
Do not add `Address` back for “clarity.”

## Open product decisions

**none**

## Scope

- [ ] Rename every first-party `address` constructor / function parameter whose name ends in
      `Address` to the role noun (table above and any sibling role such as `wrbtcTokenAddress` →
      `wrbtc`, `swapRouterAddress` → `swapRouter`, `shareTokenAddress` → `shareToken`).
- [ ] Rename matching locals in those bodies, and script / test helpers that declare the same role
      as an `address` parameter or NetworkConfig field feeding a constructor.
- [ ] Update NatSpec `@param` names to match.
- [ ] Update every compile-breaking call site (`new Handler(...)`, deploy scripts, tests).
- [ ] Tropykus DOC leaf: `kDocTokenAddress` → `kToken` (consistent with `i_kToken` and the base
      ctor). `MocHelperConfig.kDocAddress` → `kDoc` (already token-specific without `Token`).
- [ ] Script accessors that only exist to return those roles may drop `Address` too
      (`getStablecoinAddress` → `getStablecoin`, and siblings) so callers stay consistent.

## Out of scope

- [ ] Public immutables / protocol getters (`i_stablecoin`, `i_dcaManager`, …) — R104.
- [ ] Contract / file renames, behavior, gas, packing.
- [ ] Vendored interfaces (`IiSusdToken`, `IkToken`, `ILayerBankAToken`, …).
- [ ] Events and custom errors (including names that contain `Address`, e.g.
      `PurchaseUniswap__InvalidOracleAddress`, `PurchaseFees__FeeCollectorAddressSet`).
- [ ] Rewriting historical relaunch specs (R10, R21, …). Only this file, `docs/relaunch/README.md`
      Status, and `AGENTS.md` if a durable sentence belongs.
- [ ] Consumer issues unless a public ABI name actually changes (it should not — ctor arg names are
      not selectors).

## Files likely touched

- `src/DcaManager.sol`, `src/DcaManagerAccessControl.sol`
- `src/TokenHandler.sol`, `src/StablecoinSource.sol`, `src/LendingHandler.sol`, `src/PurchaseMoc.sol`
- `src/idle/*`, `src/sovryn/*`, `src/layerbank/*`, `src/tropykus-legacy/*` (ctor params + NatSpec)
- Matching `script/**` helper configs and deploy scripts; matching `test/**` locals / constructors
- `docs/relaunch/README.md` Status; `docs/relaunch/IMPLEMENTATION_ORDER.md` row; this spec

## Required tests

Rename-only in `src/` / `script/` / `test/` → full executable gate:

1. `make check`
2. `make fork-sovryn` and `make fork-layerbank` before push
3. No new fork-specific assertions; no consumer issues expected

## Success criteria

- [ ] Every scoped `*Address` parameter / matching local renamed per the table; Keep / out-of-scope
      list untouched.
- [ ] No `Address` re-introduced on those roles “for clarity.”
- [ ] `make check` + both forks green.
- [ ] PR open with template; `docs/relaunch/README.md` Status points at this PR; next unassigned
      remains cutover (`CUTOVER_RUNBOOK.md`).
- [ ] No historical `docs/relaunch/R*.md` (other than this file) rewritten for the new names.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants unchanged; no behavior / gas / packing drift.
- [ ] Events and errors still use their pre-R105 names.
- [ ] Files beyond this list are direct fallout and named in the PR.
- [ ] Closed relaunch specs still use the names that shipped then.

## ABI / deploy / cutover impact

- ABI: none expected (constructor argument names are not selectors; no public function renames on
  deployed surfaces beyond optional script-only helpers).
- Scripts: yes — helper config fields / locals / deploy call sites.
- Cutover: none. Do not open consumer issues unless review finds a real public ABI name change.
