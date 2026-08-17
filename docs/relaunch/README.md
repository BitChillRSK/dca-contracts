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
- Assigned: [R2-utc-purchase-period.md](./R2-utc-purchase-period.md) (PR 3, GitHub [#44](https://github.com/BitChillRSK/dca-contracts/pull/44)). No product gates. Does not wait on PR 2.
- Assigned: [R7-dca-manager-small-fixes.md](./R7-dca-manager-small-fixes.md) (PR 4, GitHub [#45](https://github.com/BitChillRSK/dca-contracts/pull/45)). Bundles R7 / R11 / R14. No product gates. Stacked on [#44](https://github.com/BitChillRSK/dca-contracts/pull/44).
- Assigned: [R3-fee-handling.md](./R3-fee-handling.md) (PR 5, GitHub [#46](https://github.com/BitChillRSK/dca-contracts/pull/46)). Bundles R3 / R4 / R5. Keep linear (gate answered this chat). Stacked on [#45](https://github.com/BitChillRSK/dca-contracts/pull/45).
- Assigned: [R6-hot-path-cleanup.md](./R6-hot-path-cleanup.md) (PR 6, GitHub [#47](https://github.com/BitChillRSK/dca-contracts/pull/47)). Bundles R6 / R17. Spec revised after review and re-implemented. No product gates. Stacked on [#46](https://github.com/BitChillRSK/dca-contracts/pull/46).
- Assigned: [R8-remove-stuck-rbtc-rescue.md](./R8-remove-stuck-rbtc-rescue.md) (PR 7, GitHub [#48](https://github.com/BitChillRSK/dca-contracts/pull/48)). No product gates. Stacked on [#47](https://github.com/BitChillRSK/dca-contracts/pull/47).
- Assigned: [R1-integration-cash-accounting.md](./R1-integration-cash-accounting.md) (PR 8, GitHub [#49](https://github.com/BitChillRSK/dca-contracts/pull/49)). Bundles R1 / R20 and owns the R6 clamp-desync leftover. No product gates. Stacked on [#48](https://github.com/BitChillRSK/dca-contracts/pull/48).
- Assigned: [R24-test-harness-matrix.md](./R24-test-harness-matrix.md) (PR 9, GitHub [#50](https://github.com/BitChillRSK/dca-contracts/pull/50)). Test/Makefile only. Stacked on [#49](https://github.com/BitChillRSK/dca-contracts/pull/49). Merge after #49.
- Assigned: [R15-withdraw-all-sentinel.md](./R15-withdraw-all-sentinel.md) (PR 10, GitHub [#51](https://github.com/BitChillRSK/dca-contracts/pull/51)). Withdraw-all sentinel only; lending-share dust deferred (decision recorded in the spec). No product gates. Stacked on [#50](https://github.com/BitChillRSK/dca-contracts/pull/50).
- Next unassigned: `Start with R22` (PR 11, repo layout preparation). No product gates. PR 2 (decision record) stays available when the human wants to record R18 / R19 / optionals.
