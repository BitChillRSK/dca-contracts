# R100 — Invariant suite honesty and integrated lending/purchase coverage

Status: **in progress** · Assigned: this PR · Optional/further-review: no · Stack on: R99

## Objective

Fix known invariant-suite debt so the fuzz README and the named invariants match what the suite
actually proves, and add stronger coverage of the combined production lending + purchase pipeline
where the current fixture substitutes its own purchase / rBTC accounting.

## Background

This is existing test debt from the 2026-09-27 source-cleanup review, not a new discovery:

1. `invariant_interestOnlyIncreases` in `test/ai-generated/fuzz/Invariants.t.sol` asserts
   `uint256 >= 0` on share balances — a tautology. [R54](./R54-schedule-top-up-from-interest.md)
   already recorded that.
2. The main lending invariant fixture substitutes its own purchase and rBTC-accounting
   implementations. The separate production `PurchaseRbtc` conservation suite helps, but does not
   exercise the combined production lending/purchase pipeline.
3. `test/ai-generated/fuzz/README_INVARIANTS.md` still claims the removed / tautological rBTC check
   proves solvency (`address(handler).balance >= 0`).

No `src/` change is required unless a real gap forces one. Prefer fixing tests and docs first.

## Open product decisions

**none**

## Scope

- [x] Replace or delete `invariant_interestOnlyIncreases` so the name matches a real property (or
      rename / drop it and update the coverage list).
- [x] Correct `README_INVARIANTS.md` so it no longer claims the tautological rBTC check proves
      solvency; document what the suite actually covers.
- [x] Add or extend coverage that runs the production lending handler + production `PurchaseRbtc`
      path under the invariant / conservation harness (minimal fixture change; do not rewrite the
      whole suite).

## Out of scope

- [x] R98 / R99 Solidity cleanups.
- [x] Broad invariant-suite rewrites unrelated to the three items above.
- [x] Claiming “blue-chip quality” as a success criterion.

## Files likely touched

- `test/ai-generated/fuzz/Invariants.t.sol`
- `test/ai-generated/fuzz/README_INVARIANTS.md`
- related fuzz handlers / wrappers under `test/ai-generated/fuzz/`
- possibly `test/` conservation suites that already cover `PurchaseRbtc`
- `docs/relaunch/R100-invariant-suite-debt.md`, `README.md`, `IMPLEMENTATION_ORDER.md`

## Required tests

```text
make invariants-sovryn
# plus whatever targeted forge commands the new coverage adds
make check   # if executable test helpers change shared bases
```

Forks: only if the PR changes `src/` or deployable scripts (unexpected here).

## Success criteria

- [x] No tautological `>= 0` invariant left under a name that implies a real property.
- [x] README matches the suite.
- [x] At least one path exercises production lending + purchase accounting together.
- [x] `make invariants-sovryn` green.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Does not weaken an existing real invariant to make the suite “pass.”
- [ ] Docs-only or test-only gate tier in `AGENTS.md` is followed.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none.
- Cutover: none.
