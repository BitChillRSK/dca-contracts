# R114 — Nethermind AuditAgent report and accounting fixes

Status: **in progress** · Assigned: yes · Optional/further-review: no · Stack on: R113
([#179](https://github.com/BitChillRSK/dca-contracts/pull/179)) · PR: [#180](https://github.com/BitChillRSK/dca-contracts/pull/180)

## Objective

Preserve the supplied report. Fix findings 1, 5, and 6 with consistent lending-share accounting.
Document accepted findings 2 and 3 and the operational mitigation for finding 4.

## Background

The report audits `docs/r113-audit-readiness-docs` at `284b3500ed35b8ee8fc8802b7a3bb0f7bb3be0f8`.
It is an automated scan, not a manual Nethermind engagement or an implementation instruction.
The human authorized executable fixes on 2026-10-07 after reviewing the initial documentation-only PR.
This authorization supersedes this PR's initial acceptance of findings 1, 5, and 6 and the earlier
tail-revert decisions in R43/R110. The human arranges the separate Claude review.

## Open product decisions

**none.** Retain the one-dollar peg assumption, signer-bound native payments, and trusted-owner registry.
Require exact manager, token, and released-code checks before initial Safe acceptance or later assignment.

## Scope

- Preserve the report byte-for-byte and keep BitChill's decisions in a separate document.
- Reserve `ceil(remaining principal × scale / rate)` shares before principal or interest withdrawals.
  DcaManager reports remaining principal from its schedule books after its existing effects.
  Interest quotes and top-ups use the stablecoin value of shares above that reserve.
- Aggregate each buyer's purchase amounts before converting to shares, regardless of row order.
  Debit each buyer once. Redeem exactly the sum of those debits.
- Apply the same reserve to purchases. Limit the debit to this buyer's shares above the reserve.
  When that limit reduces funding, reduce this buyer's allocation weights and fees accordingly.
  Do not allocate the shortfall across unrelated buyers using the original purchase weights.
- Keep deposits and schedule debits nominal. Receipt shares remain the actual lending claim.
  A completed purchase can spend slightly less than nominal because of rounding, or less after a loss.
  Preserve the remaining principal reserve; do not invent receipt shares or reject ordinary rounded deposits.
- Retain measured cash, exact receipt-share consumption, exact venue input consumption, and atomic rollback.
- Turn existing reproductions into successful regressions for 1/5/6. Extend coverage for multiple
  schedules, non-adjacent repeated buyers, flat rates, allocation fairness, and failure rollback.
- Update NatSpec, dispositions, cutover notes, consumer follow-ups, and the PR body.

## Out of scope

- Stablecoin/USD feeds, alternate rBTC recipients, wrapped claims, owner rescue, or canonical-manager storage.
- Dependency/compiler changes, deployment-script changes, broadcasts, and live-contract transactions.
- Consumer implementation changes, unrelated refactors, or a new automated audit.
- Gas optimizations as a separate objective. Any storage-write observations use Rootstock's schedule.

## Files likely touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- `src/LendingHandler.sol`, `src/interfaces/ILendingHandler.sol`
- `src/StablecoinSource.sol`, `src/idle/IdleHandler.sol`
- `src/PurchaseRbtc.sol`, `src/PurchaseFees.sol`, `src/interfaces/IPurchaseRbtc.sol`
- Existing R114 NatSpec files: `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol`,
  `src/interfaces/IPurchaseUniswap.sol`
- `test/ai-generated/audit/NethermindAuditFindings.t.sol`
- `test/unit/LendingHandlerRedeemTest.t.sol`
- Funding-hook overrides reached through inheritance: `test/unit/PurchaseRbtcTest.t.sol`,
  `test/unit/PurchaseUniswapMinOutTest.t.sol`, `test/gas/R87IdleLedgerRemovalGas.t.sol`
- Direct funding harnesses and assertions reached through failing tests: lending/idle handler tests
  under `test/ai-generated/unit/`, `test/ai-generated/fuzz/Invariants.t.sol`
- `audits/2026-10-06-Nethermind/audit-agent-report.md` (unchanged), its `README.md`, `audits/README.md`
- `AUDIT_GUIDE.md`, `docs/relaunch/EXTERNAL_REWARDS.md`, `docs/relaunch/CUTOVER_RUNBOOK.md`
- `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`, this spec

Expand only through imports, interfaces, inheritance, mocks, compiler errors, or failing tests.
Name any additional paths in the final PR body.

## Required tests

- Targeted accounting regressions and affected suites under default and deploy profiles.
- `make check`, `make fork-sovryn`, `make fork-layerbank` before pushing executable changes.
- `make fmt-check` and authored-file whitespace checks, excluding the unchanged original report.
- Verify the report SHA-256: `cdfdc50d03787e7fc0fdf861ee50ac5b78e352c998c3a22bc6bacb4e59abc4e5`.
- Inspect first-party ABI changes and ensure deploy-profile artifacts fit the contract size limit.

## Success criteria

- Findings 1/5/6 have executable fixes and meaningful regressions under both profiles.
- Every finding has an explicit disposition, trigger, consequence, and residual risk.
- Remaining nominal principal keeps its required share reserve after successful operations when backed.
- A buyer's reduced funding reduces that buyer's weights, without using another buyer's shares.
- Virtual debits equal the external share burn. Failed operations roll back all books and credits.
- Required local gates and latest CI pass. The report remains byte-identical.
- Focused commits remain stacked on PR 179; PR 180 describes the final implementation and consumer impact.

## Reviewer checklist

- [ ] Matches scope; no unrelated or optional implementation.
- [ ] Protocol invariants remain unchanged, including measured cash and exact claim consumption.
- [ ] Tests cover successful rounding cases and meaningful rollback failures.
- [ ] New principal reads query schedule liabilities, not an external protocol's cash estimate.
- [ ] Actual allocation weights reflect reduced funding; fees remain bounded by each row's nominal amount.
- [ ] Original report and BitChill's assessment remain distinct.

## ABI / deploy / cutover impact

- DcaManager gains a read-only getter for a user's remaining principal held by a specified handler.
- Existing user and swapper mutation selectors, schedule layout, and event signatures stay stable.
- Lending share-transition events become one event per buyer per batch. Purchase amounts reflect adjusted funding weights.
- Redeploy the immutable contracts at cutover. Refresh consumer ABIs and document the interest/funding semantics.
- Consumer issue URLs and completed validation results belong in the final PR body and disposition document.
