# R91 — `forge fmt` one-shot and CI enforce

Status: **implemented** · GitHub [#156](https://github.com/BitChillRSK/dca-contracts/pull/156) · Assigned: yes · Optional/further-review: no

## Objective

Make the first-party tree `forge fmt`-clean in one shot, then enforce `forge fmt --check` in
`make check` and CI so formatting cannot drift again. Format-only: no behavior, ABI, storage, or
NatSpec wording change. Prove metadata-stripped creation and runtime bytecode stay identical on every
deployable contract under both profiles (R85 method).

## Background

R90 measured that `forge fmt --check` would touch ~115–118 files (src / test / script) and deferred
the cleanup so the packing + unchecked PR stayed free of format noise. The human approved the cleanup
as its own PR. Diffs are whitespace and wrapping (including trailing blank lines and multi-line
returns). Section-banner conventions must remain intact after format.

## Open product decisions

**none** — approved under R90 (2026-09-27): make the repo `forge fmt`-clean and enforce in
`make check` / CI.

## Scope

- [x] Run `forge fmt` across first-party `src/`, `test/`, and `script/` (Foundry's default scope).
      **Result:** 114 first-party `.sol` files reformatted. Vendored `IkToken` was touched by the first
      pass and **reverted**; it stays upstream-shaped.
- [x] Add `forge fmt --check` to `make check` (and the CI path that mirrors it), so a dirty tree fails
      the done-gate. **Result:** `make fmt-check` target; wired into `make check` and `make ci`;
      dedicated `fmt-check` job in `.github/workflows/test.yml`.
- [x] Update `AGENTS.md` and the Makefile comment that currently say `src/` is not fmt-clean / do not
      `forge fmt` unless a spec says so. **Result:** AGENTS now requires the tree stay fmt-clean;
      vendored ABIs listed in `foundry.toml` `[fmt].ignore`.
- [x] Prove metadata-stripped runtime **and** creation code are byte-identical vs the R90 parent on
      every deployable contract, under both `[profile.default]` and `[profile.deploy]`. Complete
      `deployedBytecode` / `bytecode` may differ only in the CBOR metadata suffix.
      **Result:** 0 mismatches across 10 contracts × 2 profiles × (runtime + creation).
- [x] Confirm section banners (Foundry-style centred titles) still match the `AGENTS.md` convention
      after format — no banner text or order change. **Result:** spot-checked `DcaManager`,
      `PurchaseRbtc`, `TokenHandler`, `FeeHandler`; titles and section presence unchanged.

## Out of scope

- [ ] FeeHandler ownership move (R92).
- [ ] Wording, NatSpec content, section-header ownership, or delimiter rules (R10 / R63 / R65 / R85).
- [ ] `lib/` and vendored interfaces listed as leave-alone in `AGENTS.md`.
- [ ] Any intentional behavior, ABI, storage, event, or error change.
- [ ] Deploy broadcasts or consumer-repo implementations.

## Files likely touched

- Every first-party `.sol` under `src/`, `test/`, and `script/` that `forge fmt --check` reports.
- `Makefile` (`fmt-check` / wire into `check`)
- `.github/workflows/test.yml` (or equivalent CI step)
- `AGENTS.md` (drop the "not fmt-clean" exception)
- `docs/relaunch/R91-forge-fmt.md`, `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/R90-final-optimization-decisions.md` (point the deferred row at this PR once open)

## Required tests

Format-only + Makefile/CI change → full local gate per `AGENTS.md` **Scale the gate to the change**:

```text
forge fmt --check
make check
make fork-sovryn
make fork-tropykus
```

Also, before push:

1. Build the R90 parent and this branch under default and `FOUNDRY_PROFILE=deploy`.
2. For each deployable contract (`DcaManager`, `OperationsAdmin`, and the eight
   `*DocHandlerMoc` / `*Erc20HandlerDex` leaves including Tropykus), strip the CBOR metadata suffix
   from `bytecode` and `deployedBytecode` and require equality parent ↔ branch on both profiles.
3. Spot-check that centred section banners in a sample of touched `src/` files still match the
   `AGENTS.md` titles and padding.

No new behavior tests. Forks add no R91-specific live-state assertion; they are the Makefile gate.

## Success criteria

- [x] `forge fmt --check` exits 0 on the tree.
- [x] `make check` runs `forge fmt --check` and fails if formatting drifts.
- [x] CI enforces the same check.
- [x] `AGENTS.md` no longer says existing files must not be formatted / `src/` is not fmt-clean.
- [x] Metadata-stripped creation and runtime code identical on all ten deployable contracts, both
      profiles, vs the R90 parent (`97d454a`).
- [x] Section banners unchanged in title and presence.
- [x] No ABI, storage-layout, selector, event, or error change (format cannot introduce one; the
      bytecode identity check is the proof).

## Tests run (this PR)

```text
forge fmt --check
make check
make fork-sovryn
make fork-tropykus
```

Bytecode: stripped creation + runtime identical for all ten deployable contracts under default and
`FOUNDRY_PROFILE=deploy` vs parent `97d454a`.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Diff is whitespace/wrapping only — no logic edits mixed in.
- [ ] Metadata-stripped bytecode identity recorded for both profiles.
- [ ] `forge fmt --check` is in the done-gate, not a one-off manual step.
- [ ] Files beyond this list are named in the PR.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: format-only under `script/`; no deploy-config or constructor change.
- Cutover: none. No consumer issue.
