# R114 — Nethermind AuditAgent report and dispositions

Status: **implemented; PR pending** · Assigned: yes · Optional/further-review: no · Stack on: R113
([#179](https://github.com/BitChillRSK/dca-contracts/pull/179))

## Objective

Preserve the supplied AuditAgent report and resolve all six findings through explicit risk decisions,
reproduction tests, accurate NatSpec, and deployment checks. Preserve executable contract behaviour.

## Background

The supplied automated report identifies scan `ca256ac8-f203-4034-ab2a-1656bef69a13` and reviews
`docs/r113-audit-readiness-docs` at `284b3500ed35b8ee8fc8802b7a3bb0f7bb3be0f8`.
The human requested a stacked PR and will arrange a separate Claude review after implementation.
The report is evidence, not an implementation instruction or a manual Nethermind engagement.

Findings 1, 5, and 6 describe share-rounding purchase failures. They extend the accepted lending-tail
policy in [R43](./R43-dex-path-review.md) and [R110](./R110-internal-audit-followups.md).
Finding 5 concerns current mint rounding; it does not require a proxy upgrade.
Finding 6 can persist after one underlying base unit of additional interest.
Finding 2 describes the existing one-dollar pricing assumption.
Finding 3 describes unsupported accounts that reject native rBTC.
Finding 4 concerns the trusted owner's permanent handler assignment.

## Open product decisions

**none.** The human accepts the peg assumption and unsupported-wallet limitation.
The authorized triage retains strict share accounting and atomic batches.
For finding 4, mitigate assignment mistakes through exact manager checks before governance approval.
Do not add canonical-manager storage or change the withdrawal or purchase ABI.

## Scope

- [x] Copy the original report unchanged into `audits/2026-10-06-Nethermind/`.
- [x] Add a separate provenance and disposition document with evidence for all six findings.
- [x] Record accepted liveness, peg, wallet, and governance risks in `AUDIT_GUIDE.md`.
- [x] Correct NatSpec about upward depegs, native receiving requirements, and registry affiliation.
- [x] Require exact immutable manager, stablecoin, and released-code checks in the cutover procedure.
- [x] Add isolated local reproductions for all six findings, including one-wei interest after compounding.
- [x] Register this spec and the stacked PR in the relaunch index.

## Out of scope

- [ ] Changes to rounding, principal accounting, exact share consumption, or atomic purchase batches.
- [ ] Per-buyer aggregate conversion, withdrawal reserve accounting, or automatic tail clamping.
- [ ] A stablecoin/USD feed, alternate rBTC recipients, wrapped claims, or owner rescue.
- [ ] Canonical-manager registry storage, deployment-script changes, broadcasts, or live-contract calls.
- [ ] Consumer implementation changes or a new automated audit.

## Files likely touched

- `audits/2026-10-06-Nethermind/audit-agent-report.md`
- `audits/2026-10-06-Nethermind/README.md`
- `audits/README.md`
- `AUDIT_GUIDE.md`
- `docs/relaunch/CUTOVER_RUNBOOK.md`
- `docs/relaunch/README.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/R114-nethermind-audit-followups.md`
- `src/OperationsAdmin.sol`
- `src/interfaces/IOperationsAdmin.sol`
- `src/interfaces/IDcaManager.sol`
- `src/interfaces/IPurchaseRbtc.sol`
- `src/interfaces/IPurchaseUniswap.sol`
- `test/ai-generated/audit/NethermindAuditFindings.t.sol`

Tests may import existing LayerBank deployment fixtures, Uniswap min-out fixtures, mocks, and test
utilities. Do not modify those shared files.

## Required tests

- Build `src/` under `default` and `deploy` profiles.
- Compare metadata-stripped runtime and creation code, plus ABIs, with the R113 parent under both profiles.
- Run the new audit reproductions under both profiles:
  `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=none STABLECOIN_TYPE=DOC forge test --match-path test/ai-generated/audit/NethermindAuditFindings.t.sol --match-test test_NM`.
- Repeat that command with `FOUNDRY_PROFILE=deploy`.
- Run `FinalDeploymentTest` under both profiles to confirm exact manager and token wiring for all seven handlers:
  `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=none STABLECOIN_TYPE=DOC forge test --match-path test/unit/deployment/FinalDeploymentTest.t.sol --match-contract FinalDeploymentTest`.
- Repeat that command with `FOUNDRY_PROFILE=deploy`.
- Run `make fmt-check` and `git diff --check` on authored files.
  Exclude the unchanged report, which contains six intentional Markdown hard-break lines with trailing spaces.
- Verify the copied report's SHA-256 against the supplied file.

This PR changes only documents, NatSpec, and an isolated test file.
The scaled gate does not require `make check`, full test lanes, or forks.
Reproductions use local mocks; they do not establish live incidence or profitable pool manipulation.

### Results — 2026-10-07

| Check | Default | Deploy |
|-------|---------|--------|
| New audit reproductions | 8 passed, 0 failed, 0 skipped | 8 passed, 0 failed, 0 skipped |
| Existing `FinalDeploymentTest` | 6 passed, 0 failed, 0 skipped | 6 passed, 0 failed, 0 skipped |
| First-party `src/` artifacts compared | 42 | 42 |
| Artifacts with creation code | 10 | 10 |
| Metadata-stripped runtime and creation code | Identical to R113 | Identical to R113 |
| ABIs | Identical to R113 | Identical to R113 |

The comparison builds the parent before the NatSpec edits and the completed source afterwards.
Both builds use separate output and cache directories under `/tmp/bitchill-r114-validation.G3wqpq/`.
For each first-party declaration, it compares ABI JSON and both bytecode fields after removing trailing CBOR metadata and its two-byte length.
All ten non-empty runtime artifacts have different metadata, confirming the comparison observes the edited source.
`make fmt-check`, the whitespace check on authored files, and the report's SHA-256 comparison also pass.
The original report retains six two-space Markdown hard breaks, so the whitespace check excludes that artifact.

## Success criteria

- [x] Every original finding has an explicit disposition, trigger, consequence, and residual risk.
- [x] The report remains byte-identical to the supplied artifact.
- [x] All reproductions pass under both profiles.
- [x] Runtime, creation code, and ABI comparisons confirm unchanged executable contracts.
- [ ] The PR stacks on R113 and remains ready for the human's separate review.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` remain unchanged.
- [ ] Tests prove the stated boundaries and do not claim to eliminate accepted risks.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] The report's original severity and BitChill's assessment remain distinguishable.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none.
- Cutover: verify the exact handler manager and released code before Safe acceptance or later assignment.
- Consumers: no new selectors, grouping rules, token settings, or event/error changes.
  Existing simulation and quote requirements remain in force; no consumer issue is required.
