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

## Decision records

- [`EXTERNAL_REWARDS.md`](./EXTERNAL_REWARDS.md) (GitHub [#57](https://github.com/BitChillRSK/dca-contracts/pull/57)) — lending handlers distribute native protocol interest only; external campaigns use off-chain forwarding if available. R9 must add a canonical per-user lending-share balance-transition event so forwarding does not depend on transaction traces or a provider response.

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
- Assigned: [R22-repo-layout.md](./R22-repo-layout.md) (PR 11, GitHub [#52](https://github.com/BitChillRSK/dca-contracts/pull/52)). Folders only; no product gates. Stacked on [#51](https://github.com/BitChillRSK/dca-contracts/pull/51).
- Assigned: [R22-idle-handler.md](./R22-idle-handler.md) (PR 12, GitHub [#53](https://github.com/BitChillRSK/dca-contracts/pull/53)). Idle DOC + MoC handler at index 0. No product gates. Stacked on [#52](https://github.com/BitChillRSK/dca-contracts/pull/52).
- Assigned: [R21-fee-on-transfer-deposits.md](./R21-fee-on-transfer-deposits.md) (PR 13, GitHub [#54](https://github.com/BitChillRSK/dca-contracts/pull/54)). Hop-1 received-on-deposit. FOT unsupported; withdraw still works if a listed token turns on a fee. No product gates. Stacked on [#53](https://github.com/BitChillRSK/dca-contracts/pull/53).
- Assigned: [R16-redeem-glossary.md](./R16-redeem-glossary.md) (PR 14, GitHub [#55](https://github.com/BitChillRSK/dca-contracts/pull/55)). Rename-only; first-party "redeem" now names the asset given up. Keeps PR 13's 1-wei batch-redemption event check. No product gates. Stacked on [#54](https://github.com/BitChillRSK/dca-contracts/pull/54).
- Supporting: [EXTERNAL_REWARDS.md](./EXTERNAL_REWARDS.md) (GitHub [#57](https://github.com/BitChillRSK/dca-contracts/pull/57)). Docs-only external-incentive boundary and indexer-ready R9 share-event requirement. Stacked on the live Sovryn probe [#56](https://github.com/BitChillRSK/dca-contracts/pull/56); no Solidity or ABI change in this PR.
- Assigned: [R22-layerbank-handler.md](./R22-layerbank-handler.md) (PR 15, GitHub [#58](https://github.com/BitChillRSK/dca-contracts/pull/58)). LayerBank DOC + MoC handler at index 1. No product gates. Stacked on [#57](https://github.com/BitChillRSK/dca-contracts/pull/57).
- Assigned: [R25-lending-redeem-naming.md](./R25-lending-redeem-naming.md) (PR 16, GitHub [#59](https://github.com/BitChillRSK/dca-contracts/pull/59)). Rename-only: `_redeemByUnderlying` / `_redeemByShares`, `*ToRedeem` locals, Sovryn interest-local alignment, and the unused `minPurchaseAmount` constructor arg dropped from the Tropykus/Sovryn leaves. No product gates. Stacked on [#58](https://github.com/BitChillRSK/dca-contracts/pull/58).
- Planning: GitHub [#60](https://github.com/BitChillRSK/dca-contracts/pull/60). Specs only: R26 (PR 17), R27 (PR 19, Tropykus cash guards), R28 (optional late, `LendingErc20Handler`). Stacked on [#59](https://github.com/BitChillRSK/dca-contracts/pull/59).
- Assigned: [R26-share-terminology.md](./R26-share-terminology.md) (PR 17, GitHub [#61](https://github.com/BitChillRSK/dca-contracts/pull/61)). Rename-only: “lending token” → `shares` (`getUserShares`, `_stablecoinToShares` / `_sharesToStablecoin`, `TokenLending__SharesRedeemed(Batch)`, `TokenLending__InsufficientShares`, Sovryn `_redeemShares`). Preserves R16 `underlyingAmount` event params. No product gates. Stacked on [#60](https://github.com/BitChillRSK/dca-contracts/pull/60).
- Next unassigned: `Start with R22 (deploy/CI)` (PR 18, [R22-deploy-ci.md](./R22-deploy-ci.md)) — constants, `DeployMocSwaps`, harness split, Makefile, CI matrix, plus the required LayerBank round-up solvency regression. Stack on [#61](https://github.com/BitChillRSK/dca-contracts/pull/61). Then `Start with R27` (PR 19, [R27-tropykus-lending-guards.md](./R27-tropykus-lending-guards.md)) — align Tropykus deposit/batch zero-cash guards with Sovryn/LayerBank; Tropykus is not in the new deploy map but the code must still be correct. Then R9 (PR 20). Optional late: [R28-lending-erc20-handler.md](./R28-lending-erc20-handler.md) extracts `LendingErc20Handler` (Idle out; cheapest before R9). Handler-replacement in `OperationsAdmin` stays unassigned (later). PR 2 (decision record) stays available when the human wants to record R18 / R19 / optionals.
