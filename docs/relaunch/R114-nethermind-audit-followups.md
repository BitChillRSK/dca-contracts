# R114 — Nethermind AuditAgent report and lending purchase clamp

Status: **review rework in progress** · Assigned: yes · Optional/further-review: no · Stack on: R113
([#179](https://github.com/BitChillRSK/dca-contracts/pull/179)) · PR: [#180](https://github.com/BitChillRSK/dca-contracts/pull/180)

## Objective

Preserve the supplied report. Resolve the batch failure in findings 1, 5, and 6 with one per-row
share clamp. Document accepted findings 2 and 3 and the operational mitigation for finding 4.

## Background

The automated report scans `docs/r113-audit-readiness-docs` at `284b3500`. It is evidence, not an
implementation instruction or a manual Nethermind engagement. BitChill authorized this rework on
2026-10-07 after independent review. Keep PR 180, its branch, its base, and its existing history.
R114 supersedes the R43/R110 decision to revert a lending batch on any share shortfall.

The initial reserve and buyer grouping design is withdrawn. The reserve changes loss handling:
a partial withdrawal can pay zero and the next purchase can revert despite sufficient shares for
that row. It also adds manager callbacks and schedule enumeration to the purchase path.
Review measurements used local mocks, the deploy profile, and Rootstock pricing: a steady-state
LayerBank tick with ten buyers cost 411,203 gas on R113, 491,278 with reserves and grouping, and
734,378 when each buyer held ten schedules. The review measured 412,131 for the clamp alone.
These are review measurements; independent measurements below will use separate gas/access tests.

## Open product decisions

**none.** Retain the one-dollar peg assumption, signer-bound native payments, and trusted-owner registry.
Require exact manager, token, and released-code checks before initial Safe acceptance or later assignment.

## Scope

- Restore principal withdrawals, interest withdrawals, quotes, and top-ups to R113 behavior.
- Remove the principal getter, manager callbacks, reserve, hash table, and buyer grouping.
- Convert and debit each purchase row separately. Preserve sequential per-row share events.
- If a row requests more shares than its buyer holds, use all that buyer's remaining shares.
  Replace that row's memory weight with `floor(shares × rate / scale)`.
  If that value is zero, revert `LendingHandler__InsufficientShares` atomically.
- Compute fees and output allocation after the funding hook adjusts the memory weights.
  A healthy buyer retains its weight. No other buyer supplies the short row's shares.
- Keep schedule debits nominal, measured cash, exact share consumption, exact venue consumption,
  signer-bound withdrawals, and all-or-nothing batches.
- Retain the report unchanged, accepted-risk NatSpec, and assignment checks in the runbook.

## Out of scope

- Principal reserves, buyer grouping, tolerance constants, changes to withdrawals or interest.
- Any other design for these findings, gas optimizations, dependency/compiler changes, deployment
  changes, broadcasts, live transactions, consumer implementations, and the next R-item.

## Files likely touched

- `src/LendingHandler.sol`, `src/interfaces/ILendingHandler.sol`
- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`, `src/interfaces/ITokenHandler.sol` (restore)
- `src/StablecoinSource.sol`, `src/idle/IdleHandler.sol`, `src/PurchaseRbtc.sol`, `src/PurchaseFees.sol`
- `src/interfaces/IPurchaseRbtc.sol`, `src/interfaces/IPurchaseUniswap.sol`
- `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol`
- `test/ai-generated/audit/NethermindAuditFindings.t.sol`, `test/unit/LendingHandlerRedeemTest.t.sol`
- `test/unit/PurchaseRbtcTest.t.sol`, `test/unit/PurchaseUniswapMinOutTest.t.sol`
- `test/unit/BatchTailScheduleTest.t.sol`, `test/unit/FeeOnTransferDepositTest.t.sol`
- `test/ai-generated/unit/{EdgeCasesTest,layerbank/LayerBankDocHandlerMocTest,sovryn/SovrynDocHandlerMocTest,tropykus-legacy/TropykusDocHandlerMocTest}.t.sol`
- `test/ai-generated/unit/{layerbank/LayerBankHandlerTest,sovryn/SovrynHandlerTest,tropykus-legacy/TropykusHandlerTest}.t.sol`
- `test/ai-generated/fuzz/LendingPurchaseConservationInvariant.t.sol`
- `test/gas/R78FlatFeeFastPathGas.t.sol`, `test/gas/R87IdleLedgerRemovalGas.t.sol`
- `test/gas/R114PurchaseClampGas.t.sol`, `test/gas/reprice_r114.py` (independent measurement evidence)
- `audits/2026-10-06-Nethermind/audit-agent-report.md` (unchanged), its `README.md`, `audits/README.md`
- `AUDIT_GUIDE.md`, `docs/PURCHASE_FEES.md`, `docs/relaunch/EXTERNAL_REWARDS.md` (restore)
- `docs/relaunch/CUTOVER_RUNBOOK.md`, `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`
- This spec and earlier documents reached by searches for the superseded tail-revert rule.

Expand only through imports, interfaces, inheritance, mocks, compiler errors, or failing tests.
Name additional paths in the PR body.

## Required tests

- Keep all NM1/NM5/NM6 scenarios. Assert successful purchases, nominal schedule debits, and equality
  between total virtual shares and external receipt shares. Keep NM2/NM3/NM4 boundary tests.
- Keep unchanged base tests, except funding-hook signatures, optimized-profile fixture corrections,
  and the seven old shortfall-revert tests explicitly assigned by the review.
  Any further base-test behavior change requires a report to BitChill before proceeding.
- Restore interest fuzz, sequential events, and exact row-sum tests. Remove getter fixtures and hash tests.
- Pin reduced-row funding beside a healthy buyer, exact credit allocation, `amountSpent`, and rollback
  when `minRbtcOut` is missed. Keep the pipeline-level reduced-funding fee test.
- Pin zero-share rollback, including a repeated buyer whose first row consumes all its shares.
- Fuzz that a reduced weight equals the debited shares' value and is below nominal.
- After a 20% index loss, a funded purchase and partial withdrawal still pay the full request.
- Run `make check` under default and deploy profiles, `make fork-sovryn`, `make fork-layerbank`,
  formatting, and installed static analyzers. Compare all first-party ABIs with R113: no differences.
- Measure steady-state lending and idle ticks under deploy. Read gas only without the state-diff
  recorder. Count storage/account accesses in separate tests and reprice on Rootstock's schedule.
- Preserve report SHA-256 `cdfdc50d03787e7fc0fdf861ee50ac5b78e352c998c3a22bc6bacb4e59abc4e5`.

## Success criteria

- One targeted fix resolves the positive-share batch failure in findings 1/5/6.
- Nominal principal may exceed share value by rounding dust. A zero-value row still reverts.
  After a lending loss, purchases continue while the buyer has shares that fund their rows.
- Every finding has a clear disposition and residual risk. No first-party ABI changes.
- Tests, forks, latest CI, artifact checks, and independently measured gas evidence pass.
- Focused new commits preserve the stack and history. PR 180 and all three consumer comments describe
  the final behavior. The separate Claude review remains BitChill's review step.

## Reviewer checklist

- [ ] LendingHandler differs from R113 only in the funding hook.
- [ ] No reserve, grouping, manager callback, or added getter remains.
- [ ] Allocation and fees use funded weights. Exact-consumption invariants still hold.
- [ ] Required tests pass unchanged except the assigned exceptions.
- [ ] All six findings have current dispositions and consumer notes.
- [ ] Both profiles, lending forks, ABI checks, and gas measurements are complete.

## ABI / deploy / cutover impact

No selector, argument, event signature, schedule layout, or first-party ABI changes.
Share events remain one per row. `amountSpent` may be below nominal for a short lending row.
`InsufficientShares` means no shares worth any stablecoin remain behind that row.
Interest quotes and withdrawals retain R113 behavior. Deploy the immutable contracts at cutover.

## Implementation and validation

Pending. Record exact gate commands, results, independent gas/access table, and consumer links here.
