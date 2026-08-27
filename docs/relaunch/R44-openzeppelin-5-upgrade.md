# R44 — OpenZeppelin 5.7 upgrade

Status: **not started** · Assigned: no · Optional/further-review: no

PR 31 of the relaunch stack. Stack on R39 (PR 30). Land before every remaining authority, storage, handler, and ABI PR.

## Objective

Upgrade the pinned OpenZeppelin Contracts dependency from `v4.9.3` to the latest stable `v5.7.0` before the fresh relaunch deploy, without mixing new BitChill behavior into the dependency migration.

## Background

The relaunch has no proxy or deployed storage to migrate. This is therefore the cheap point to take the supported major version, while the subsequent PRs can be written and tested against the dependency that will actually ship. OpenZeppelin 5 changes import paths, `Ownable` construction, revert formats, and some library APIs. Treat those as an explicit migration, not search-and-replace noise.

R39 lands first so the size comparison reflects the batch-only purchase surface. R45 then adds two-step ownership using the v5 implementation; do not add it here.

## Open product decisions

**none** — pin stable `v5.7.0`. Do not track `master`, a release candidate, or a floating 5.x reference.

## Scope

- [ ] Update the `lib/openzeppelin-contracts` submodule pin and any remapping/import path required by v5.7.0.
- [ ] Migrate first-party contracts and test mocks to v5 constructors and APIs while preserving the current owner at construction (`msg.sender`) in this PR.
- [ ] Update tests that intentionally assert OZ revert data to v5 custom errors. Do not weaken them to generic `expectRevert()`.
- [ ] Record before/after runtime sizes and gas snapshots for `DcaManager`, `OperationsAdmin`, and every concrete handler.
- [ ] Inspect storage layouts. There is no proxy migration, but unexpected BitChill state reordering is still a review failure.
- [ ] Exercise every OZ surface the repo uses: ownership, reentrancy guard, SafeERC20, ERC20/permit mocks, ERC165, and Math.

## Out of scope

- [ ] Ownable2Step or renounce policy (R45).
- [ ] Any BitChill selector, event, storage-field, fee, purchase, or routing behavior change.
- [ ] Upgrading Uniswap dependencies or changing solc/EVM pins.
- [ ] Live/testnet broadcasts.

## Files likely touched

- `lib/openzeppelin-contracts` submodule pin
- First-party OZ import/constructor call sites under `src/`
- OZ-based mocks under `test/mocks/`
- Tests that assert OZ4 revert strings
- `foundry.toml` or remappings only if v5 requires it

## Required tests

Run focused ownership/reentrancy/handler suites, `forge build --sizes`, `forge inspect` storage layouts, then `make check`, `make ci`, `make fork-sovryn`, and `make fork-tropykus`. The fork lanes are the Rootstock deployment/call smoke; do not broadcast.

## Success criteria

- [ ] The repository is pinned exactly to OpenZeppelin Contracts `v5.7.0`.
- [ ] Existing BitChill behavior is unchanged and v5 error assertions remain exact.
- [ ] Every concrete contract remains below EIP-170 with recorded margin.
- [ ] No unplanned BitChill storage-layout change.
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Dependency diff is the stable v5.7.0 tag, not a moving ref.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are direct migration fallout and named in the PR.

## ABI / deploy / cutover impact

- ABI: OZ-owned error data and ownership constructor plumbing may change; no first-party selector/event change.
- Scripts: compile-only constructor adaptation; ownership behavior stays single-step until R45.
- Cutover: fresh deployment only. No proxy/storage migration.
