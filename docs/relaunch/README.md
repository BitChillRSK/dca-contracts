# Relaunch task specs

Committed work orders for BitChill contract PRs. Implement from a spec here. The human prompt is `Start with R<n>` (see `AGENTS.md`).

## Progressive disclosure

1. Root [`AGENTS.md`](../../AGENTS.md).
2. [`IMPLEMENTATION_ORDER.md`](./IMPLEMENTATION_ORDER.md) — PR map and which product gates to ask.
3. **One** assigned spec in this folder (write it from [`TASK_TEMPLATE.md`](./TASK_TEMPLATE.md) if missing).
4. The files it names, then only imports / inheritance / mocks / failing tests / compiler errors.

Document any extra files in the PR. Do not search `out/`, `cache/`, or `lib/`. Do not implement from gitignored `.cursor/relaunch-plan.md` (read it only to draft the missing spec).

## How to add a spec

1. Copy [`TASK_TEMPLATE.md`](./TASK_TEMPLATE.md) to `R<n>-<short-slug>.md`.
2. Fill **Open product decisions** (or write **none**). Ask the human only if that section is not none and not yet answered.
3. Optional/further-review items get a spec only when explicitly assigned.
4. One spec = one PR unless **Scope** names a tight bundle.

## Status

- Merged: [R23-toolchain-baseline.md](./R23-toolchain-baseline.md) (PR 1, GitHub [#42](https://github.com/BitChillRSK/dca-contracts/pull/42)). Rootstock testnet accepted solc 0.8.36 / `cancun`.
- Assigned: [R2-utc-purchase-period.md](./R2-utc-purchase-period.md) (PR 3). No product gates. Does not wait on PR 2.
- Next unassigned: `Start with R7` (PR 4, DcaManager small fixes: R7 / R11 / R14). No product gates. PR 2 (decision record) stays available when the human wants to record fee / R18 / R19.
