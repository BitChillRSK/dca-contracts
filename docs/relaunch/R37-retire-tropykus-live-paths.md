# R37 — Retire Tropykus from every live path

Status: **not started** · Assigned: no · Optional/further-review: no · **Blocked on R36**

PR 42 of the relaunch stack. Stack on R36 (PR 41).

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

- [ ] `script/tropykus-legacy/` — move the Tropykus-only deploy scripts there (at minimum
      `DeployUsdrifHandler.s.sol` if it still exists after R36; delete it instead if R36 replaced it
      wholesale). Fix imports; do not `forge fmt` the moved files.
- [ ] `script/DeployDexSwaps.s.sol` — remove the Tropykus arm from the **live** (`TESTNET`/`MAINNET`)
      branch, including its `registerRoute(TROPYKUS_INDEX, true)`. The `LOCAL`/`FORK` branch keeps
      building a Tropykus handler so `make dex-tropykus` and `make fork-tropykus` still work.
- [ ] Move `uint256 constant TROPYKUS_INDEX` from `script/Constants.sol` to `test/Constants.sol`.
      Leave `TROPYKUS_STRING` in `script/Constants.sol`.
- [ ] Verify the enforcement holds: `grep -rn "TROPYKUS_INDEX" script/` returns nothing, and the build
      would break if it did not.
- [ ] Update the index-map comment block in `script/Constants.sol` — after this PR, Tropykus really is
      test-only and the comment R22 had to correct becomes true.
- [ ] `AGENTS.md` — the layout tree and the Tropykus bullets, so the next agent reads the enforced rule.

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

- [ ] No `script/` file can name a Tropykus route index — enforced by the compiler, not by review.
- [ ] No live deploy branch constructs a Tropykus handler.
- [ ] Local and fork Tropykus lanes still pass with unchanged counts.
- [ ] No open product decisions.

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
  migrated by R36 first. Nothing is deployed on the current dex map, so this is a map change on paper
  rather than a migration — confirm that is still true when this lands.
