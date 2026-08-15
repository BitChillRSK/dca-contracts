# Relaunch task specs

Committed work orders for BitChill contract PRs. Implement from a spec here, not from gitignored `.cursor/relaunch-plan.md`.

## Progressive disclosure

1. Root [`AGENTS.md`](../../AGENTS.md).
2. **One** assigned spec in this folder.
3. The files it names, then only imports / inheritance / mocks / failing tests / compiler errors.

Document any extra files in the PR. Do not search `out/`, `cache/`, or `lib/`.

## How to add a spec

1. Copy [`TASK_TEMPLATE.md`](./TASK_TEMPLATE.md) to `R<n>-<short-slug>.md`.
2. Optional/further-review items get a spec only when explicitly assigned.
3. One spec = one PR unless **Scope** names a tight bundle.

## Planning docs

- [`IMPLEMENTATION_ORDER.md`](./IMPLEMENTATION_ORDER.md) - agreed PR order, decision gates, and optional late work.

## Status

No relaunch specs are assigned yet. Do not change `src/`, `test/`, or `script/` from this README.
