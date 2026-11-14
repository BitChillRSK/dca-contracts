# R37 — Retire Tropykus from every live path

Status: **implemented** · Assigned: yes · Optional/further-review: no · R36 landed as PR [#92](https://github.com/BitChillRSK/dca-contracts/pull/92)

PR 44 of the relaunch stack. Stack on R50 (PR 43).

## Objective

Make "Tropykus is never deployed again" a property the build enforces rather than a comment: remove
Tropykus from every live deploy branch, move its deploy scripts under `script/tropykus-legacy/`, and
move `TROPYKUS_INDEX` out of `script/Constants.sol` into `test/Constants.sol` so that any future
`script/` file referencing it fails to compile. The handler contracts and their tests stay.

## Background

R22 (PR 29 / [#73](https://github.com/BitChillRSK/dca-contracts/pull/73)) took Tropykus off the
production MoC map and relabelled `TROPYKUS_INDEX` as legacy. It is still live on the **dex** map:
`DeployDexSwaps`' live branch deploys a `TropykusErc20HandlerDex`, and `DeployUsdrifHandler` registers
one for USDRIF. R36 replaces the USDRIF path with a LayerBank dex handler (and adds USDT0 on the same contract);
this spec removes what R36 made redundant. **Do not start this before R36 has landed** — removing
the Tropykus dex arm without a replacement deletes USDRIF DCA. USDT0 is new and was never on
Tropykus, so it does not change this block.

Why a sentinel index is not the mechanism, having been considered and rejected: `routeIndex` is a plain
unpacked `uint256` in `DcaDetails`, `s_routeClass` is a sparse mapping, and nothing in `src/` enumerates
route indexes. `registerRoute(type(uint256).max, true)` therefore succeeds exactly as readily as
`registerRoute(4, true)`, at the same gas. An "unreachable" index number is documentation, not a guard —
the same category of protection as the comment that was already wrong. What actually enforces the rule
is that no script deploys Tropykus, and that the index constant is not in scope for `script/` at all.

R22-repo-layout (PR 11) created `src/tropykus-legacy/` but left `script/` unsorted; this completes that
split symmetrically.

`TROPYKUS_STRING` must **stay** in `script/Constants.sol`. `MocHelperConfig` and `DexHelperConfig` read
it to select Tropykus mocks for the local `LENDING_PROTOCOL=tropykus` lane, and neither uses the index.
Only the index ever lands in production storage, so only the index needs to leave.

## Open product decisions

**none** — decided 2026-08-27: keep `moc-tropykus`, `dex-tropykus`, and `fork-tropykus` as legacy test lanes; keep production index **4 burned** so it is never reinterpreted as a different venue.

## Scope

- [x] `script/tropykus-legacy/` — **not created: there is nothing Tropykus-only left to move.** R36
      repurposed `DeployUsdrifHandler.s.sol` wholesale into a `LayerBankErc20HandlerDex` add-on, so it
      stays in `script/`. Every other script (`DeployDexSwaps`, `DeployMocSwaps`,
      `DeployMocAndUniswap`, both helper configs) is shared and keeps a Tropykus branch for the
      local/fork lanes; moving any of them would break the live paths they also serve. Git cannot
      track an empty folder, so the `src/` ↔ `script/` symmetry R22 started is completed by the
      compile-scope rule below instead: `script/` cannot name a Tropykus route at all.
- [x] `script/DeployDexSwaps.s.sol` — the Tropykus arm is gone from the **live**
      (`TESTNET`/`MAINNET`) branch, `registerRoute(TROPYKUS_INDEX, true)` included, and
      `_deployLiveDexHandlers` now rejects `Protocol.TROPYKUS` the way `DeployMocSwaps` already
      rejects it on the MoC map — a live Tropykus dex run reverts instead of silently returning a
      zero handler. The `LOCAL`/`FORK` branch still builds a Tropykus handler, so `make dex-tropykus`
      and `make fork-tropykus` are unaffected.
- [x] `uint256 constant TROPYKUS_INDEX` moved from `script/Constants.sol` to `test/Constants.sol`.
      `TROPYKUS_STRING` stayed. Twelve test files that imported `script/Constants.sol` directly now
      import `test/Constants.sol`, which re-exports it.
- [x] `grep -rn "TROPYKUS_INDEX" script/` returns nothing, and any script that reintroduced it would
      fail to compile — `script/` never imports `test/Constants.sol`.
- [x] The index-map comment block in `script/Constants.sol` says what is now true: test-only on both
      maps, index 4 burned, and *why* the constant lives under `test/`.
- [x] `AGENTS.md` — layout tree, the `script/` bullet (the compile-scope rule), and the CI/lanes
      bullet.
- [x] Beyond the spec's list: `UsdrifHelperConfig`'s `kUsdrifTokenAddress` field, its mainnet/testnet
      values, and the Anvil `MockKToken` it built are removed. R36 left them with the comment "kept
      until R37 removes the Tropykus dex arm"; nothing ever read the field.

## Out of scope

- [ ] Deleting `src/tropykus-legacy/` or its tests (see decision 1).
- [ ] Removing the `moc-tropykus` / `dex-tropykus` / `fork-tropykus` lanes unless decision 1 says so.
- [ ] Any change to the MoC production map (idle `0` / LayerBank `1` / Sovryn `2` / reserved `3`).
- [ ] Behavior changes to `LendingErc20Handler` or any shipped handler.
- [ ] `--broadcast` or live-chain interaction.

## Files likely touched

- `script/Constants.sol`, `test/Constants.sol`
- `script/DeployDexSwaps.s.sol`
- `script/tropykus-legacy/` (new folder; moved deploy scripts)
- `AGENTS.md`
- Any test importing `TROPYKUS_INDEX` (compiler will list them; `test/Constants.sol` already imports
  `script/Constants.sol`, so most test files need no change)

## Required tests

```
make check
make moc-tropykus
STABLECOIN_TYPE=USDRIF make dex-tropykus
STABLECOIN_TYPE=USDRIF make dex-layerbank
make fork-sovryn
make fork-tropykus
```

Assert:

- Every lane keeps its current pass/skip counts; this is a move, not a behavior change.
- `grep -rn "TROPYKUS_INDEX" script/` is empty.
- A live `DeployDexSwaps` run registers no Tropykus route (extend the deployment tests to assert
  `getRouteClass(TROPYKUS_INDEX) == Unregistered` on the live branch).
- `make fork-tropykus` still pins `--fork-block-number 8700000`; the legacy fork lane is unaffected.

## Success criteria

- [x] No `script/` file can name a Tropykus route index — enforced by the compiler, not by review.
- [x] No live deploy branch constructs a Tropykus handler; both live branches revert on
      `Protocol.TROPYKUS`.
- [x] Local and fork Tropykus lanes still pass. **Passing counts are identical in every lane**; each
      lane's total and skip count rise by exactly one, from the one test this PR adds
      (`test_dexLive_revertsForTropykus`, which runs only on the Tropykus lanes and skips elsewhere).
      In the `dex-tropykus` lane the two trade places: `test_dexLive_mainnetStyle_registersRoutesThenProposes`
      is now skipped there (a live Tropykus dex deploy is no longer a supported configuration, exactly
      as `_skipIfMocLiveUnsupported` has always skipped it on the MoC side) and the new revert test
      passes in its place.

      | lane | before (pass / skip / total) | after |
      |---|---|---|
      | `STABLECOIN_TYPE=USDRIF make dex-tropykus` | 686 / 22 / 708 | 686 / 23 / 709 |
      | `make moc-tropykus` | 714 / 16 / 730 | 714 / 17 / 731 |
      | `STABLECOIN_TYPE=USDRIF make dex-layerbank` | 686 / 22 / 708 | 686 / 23 / 709 |
      | `make moc-sovryn` | 726 / 4 / 730 | 726 / 5 / 731 |
      | `make fork-tropykus` | 292 / 17 / 309 | 292 / 18 / 310 |
      | `make fork-sovryn` | 299 / 13 / 312 | 299 / 14 / 313 |
- [x] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold — this PR should not touch any of them.
- [ ] `TROPYKUS_STRING` stayed in `script/Constants.sol` and the local lane still selects mocks.
- [ ] Pass/skip counts per lane are identical before and after.
- [ ] No unrelated refactors; the file moves are pure moves.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: `DeployDexSwaps` stops deploying Tropykus on live networks; Tropykus deploy scripts move
  under `script/tropykus-legacy/`.
- Cutover: the dex map loses its Tropykus route. Anything still pointing at that index must have been
  migrated by R36 first. Confirmed at implementation time: nothing is deployed on the relaunch dex map,
  so this is a map change on paper rather than a migration. The five consumer tracking issues R36
  opened already state that Tropykus leaves every live path and that index 4 is burned, naming R37 —
  so this PR comments on them rather than opening duplicates.
