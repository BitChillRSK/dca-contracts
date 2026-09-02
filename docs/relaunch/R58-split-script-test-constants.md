# R58 — Split test-only constants out of `script/Constants.sol`

Status: **assigned** · Assigned: yes · Optional/further-review: no

PR 54 of the relaunch stack. Test/Makefile only. No `src/` or deploy-broadcast change. Branched from
R56 / [#107](https://github.com/BitChillRSK/dca-contracts/pull/107), the latest open relaunch PR, whose
R56 rewrite of the slippage comments this spec's line numbers predate.

## Objective

Keep `script/Constants.sol` limited to values deploy scripts and helper configs actually read. Move the test-only block (account labels, fork holders, slippage tolerances, and duplicates) into `test/Constants.sol`, and point tests at the test barrel instead of importing `script/Constants.sol` directly where possible.

## Background

`script/Constants.sol` mixes production deploy defaults with a section labeled `TESTS CONSTANTS` (lines 85–106). Many tests import `script/Constants.sol` directly even though `test/Constants.sol` already re-exports script values and owns test-only symbols such as `TROPYKUS_INDEX`.

R37 deliberately keeps `TROPYKUS_STRING` in script (helper configs select mocks) while `TROPYKUS_INDEX` lives only in `test/Constants.sol` so no deploy script can name a Tropykus route index. R58 applies the same boundary to the rest of the test-only surface without changing production behavior.

Audit (2026-09-02):

**Stay in `script/Constants.sol`**

- Protocol/fee defaults, chain IDs, governance addresses, route indexes/strings (`IDLE_INDEX`, `LAYERBANK_*`, `SOVRYN_*`, `NONE_STRING`, `TROPYKUS_STRING`, stablecoin strings).
- Dex deploy defaults (`DEFAULT_AMOUNT_OUT_MINIMUM_*`).
- USDT0 live magnitudes and mainnet LayerBank aToken addresses.
- Local deploy account labels used by `DeployBase`: `OWNER_STRING`, `FEE_COLLECTOR_STRING`.
- `BTC_PRICE` — used by `DexHelperConfig.s.sol` and `UsdrifHelperConfig.s.sol` for mock routers despite sitting under the test comment block.

**Move to `test/Constants.sol`**

- `USER_STRING`, `ADMIN_STRING`, `SWAPPER_STRING`.
- `MAX_SLIPPAGE_PERCENT`, `DEX_MAX_SLIPPAGE_PERCENT` (`DcaDappTest` purchase tolerance).
- Fork holders: `DOC_HOLDER`, `USDRIF_HOLDER`, `DOC_HOLDER_TESTNET`.
- `EXCHANGE_RATE_DECIMALS` — test assertions only; handlers define their own scales.
- `FEE_PERCENTAGE_DIVISOR` — `TestsHelper.t.sol` only (`FeeHandler.sol` already declares its own).

**Remove or consolidate**

- `USDRIF_HOLDER_TESTNET` — never referenced; drop or merge with `USDRIF_HOLDER_TEST`.
- `DOC_HOLDER_TEST` / `USDRIF_HOLDER_TEST` in `test/Constants.sol` duplicate the script testnet holder addresses under different names; pick one naming scheme.
- `RESERVED_MOC_LENDING_INDEX` — defined nowhere outside the constants file; drop or document in test-only constants if still wanted as a burned-index reminder.

## Open product decisions

**none**

## Scope

- [x] Move the test-only constants listed above from `script/Constants.sol` into `test/Constants.sol` (re-export script constants via the existing import).
- [x] Remove the `TESTS CONSTANTS` section header from script once empty; keep `BTC_PRICE` with deploy/helper constants.
- [x] Update test and mock imports: prefer `test/Constants.sol` (or relative `../Constants.sol` under `test/`) over direct `script/Constants.sol` imports.
- [x] Consolidate duplicate fork-holder names (`DOC_HOLDER_TEST` vs `DOC_HOLDER_TESTNET`, etc.).
- [x] Drop dead constants unless a short comment in `test/Constants.sol` replaces `RESERVED_MOC_LENDING_INDEX`.

## Out of scope

- Changing production deploy values, route maps, or `src/` behavior.
- Moving `TROPYKUS_STRING` out of script (R37 invariant).
- Moving `TROPYKUS_INDEX` out of test (R37 invariant).
- Deduplicating `FEE_PERCENTAGE_DIVISOR` between `TestsHelper` and `FeeHandler` (separate hygiene).

## Files likely touched

- `script/Constants.sol`
- `test/Constants.sol`
- Test files that currently `import "script/Constants.sol"` or `../../script/Constants.sol` for moved symbols (start from grep hits; expand only through compiler errors).
- `test/mocks/MockMocProxy.sol`, `test/mocks/MockSwapRouter02.sol` if they reference moved constants.
- `docs/relaunch/IMPLEMENTATION_ORDER.md` and `docs/relaunch/README.md` Status when the PR opens.

## Required tests

- Full `make check` (no behavior change expected).
- `make fork-sovryn` and `make fork-tropykus` before push (`AGENTS.md`); fork tests use moved holder addresses.

## Success criteria

- [x] No test-only constant remains in `script/Constants.sol` except values deploy/helper scripts read (`BTC_PRICE` included).
- [x] Grep shows no test file importing `script/Constants.sol` solely for symbols now defined in `test/Constants.sol`.
- [x] `make check`, `make fork-sovryn`, and `make fork-tropykus` pass.
- [x] Open product decisions: none.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] R37 compile-time guard intact: no `script/` file names `TROPYKUS_INDEX`.
- [ ] Tests in the PR match **Required tests**.
- [ ] No unrelated refactors.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: constant relocation only; deploy script behavior unchanged.
- Cutover: none.

## As implemented

Every audited symbol moved as listed. Four decisions the audit left open, and one boundary the audit
did not name:

- **`RESERVED_MOC_LENDING_INDEX` dropped, not moved.** It reserves index 3 on the *production* MoC
  map, so `test/Constants.sol` is the wrong home for it. The declaration is replaced by a two-line
  comment beside `SOVRYN_INDEX`: an unused constant is what invites a script to register it, while a
  comment reserves the number without offering a symbol to pass.
- **Fork holders keep the `_TESTNET` suffix.** `DOC_HOLDER_TESTNET` is the name `DcaDappTest`
  already calls, and it reads as the testnet counterpart of `DOC_HOLDER`. The unreferenced
  `DOC_HOLDER_TEST` / `USDRIF_HOLDER_TEST` pair in `test/Constants.sol` is gone;
  `USDRIF_HOLDER_TESTNET` survives the merge as the USDRIF half of that pair.
- **`OWNER_STRING` and `FEE_COLLECTOR_STRING` stay in script, now with a reason.** `DeployBase`
  derives the local and fork owner and fee collector from them, so they are deploy inputs the
  harness reads back, not harness labels. `USER_STRING` / `ADMIN_STRING` / `SWAPPER_STRING` have no
  deploy-side reader and moved.
- **`BTC_PRICE` moved up out of the deleted test block** rather than staying under a banner that no
  longer exists. `DexHelperConfig` and `UsdrifHelperConfig` pass it to `MockSwapRouter02`.

**Script-reachable mocks stay on `script/Constants.sol`.** The R37 guard survives today only because
`script/*.s.sol` imports mocks with the named `import {Mock} from …` form, which does not re-export a
plain `import "…"` inside the mock; `MockMocOracle` was already reaching into `test/Constants.sol`, so
one more plain import anywhere in that chain would have put `TROPYKUS_INDEX` in a deploy script's
scope. `MockMocOracle` is repointed at `script/Constants.sol` and `MockMocProxy` stays there, so no
mock a script can construct sees a test-only symbol regardless of import form. `MockSwapRouter02`'s
`script/Constants.sol` import referenced nothing and is deleted.
