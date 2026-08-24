# R__ — \<short title\>

Status: **not started** · Assigned: no · Optional/further-review: no

Copy this file to `docs/relaunch/R<n>-<short-slug>.md`. Delete unused prompts. Do not leave placeholder text in an assigned spec.

## Objective

One or two sentences: what changes and why. The PR must be reviewable against this paragraph alone.

## Background

Only what the implementer needs (current bug, invariant, or product rule). Do not paste the private relaunch plan. Link related specs in this folder if they must land first.

## Open product decisions

**none** — or list the questions this PR must ask the human. Do not ask gates that belong to another PR (`IMPLEMENTATION_ORDER.md`). If this section is **none**, implement without asking.

## Scope

- [ ] Concrete code/behavior changes for this PR.

## Out of scope

- [ ] Nearby work that must **not** ship in this PR (other R-items, optional items, refactors, file moves, deploy broadcasts).

## Files likely touched

List paths. Prefer the smallest set (`src/…`, matching `src/interfaces/…`, matching tests). Do not add `script/` unless this spec changes deploy/config.

The implementer may follow imports, inheritance, mocks, failing tests, and compiler errors from this list. Extra files belong in the PR write-up, not in a repo-wide search.

## Required tests

- Commands to run (include `SWAP_TYPE` / `LENDING_PROTOCOL` / `STABLECOIN_TYPE` or `--match-path` / `--match-test`).
- Behaviors to assert (happy path, revert, fee=0 vs net≠gross, sibling path unchanged, etc.).
- Fork tests: still run `make fork-sovryn` and `make fork-tropykus` before push (`AGENTS.md`). Use this line only to say whether this item adds fork-specific assertions.

## Success criteria

- [ ] Checklist the author and reviewer can verify. No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold unless this spec explicitly changes one.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none / describe event or function changes.
- Scripts: none / which `script/` files and whether they are local-only.
- Cutover: none / what ops or frontend must know. Do not include broadcast steps or live addresses as instructions to execute.
