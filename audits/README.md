# Security reviews

For the current scope, trust boundaries, and accepted risks, start with
[`AUDIT_GUIDE.md`](../AUDIT_GUIDE.md).

| Date | Reviewer | Kind | Code reviewed | Findings | Report |
|------|----------|------|---------------|----------|--------|
| April 2025 | [Ivan Fitro](https://twitter.com/FitroIvan) | Manual | Pre-relaunch protocol (Tropykus and Sovryn lending, Money on Chain purchases) | 3 Medium, 4 Low, 2 Info | [PDF](./pre-relaunch/2025-04-29-Ivan-Fitro.pdf) |
| June 2025 | [Ivan Fitro](https://twitter.com/FitroIvan) | Manual | Mitigations of the April findings, and the Uniswap V3 integration | 1 Low, 1 Info | [PDF](./pre-relaunch/2025-06-02-Ivan-Fitro.pdf) |
| 2026-10-02 | [Krait](https://github.com/ZealynxSecurity/krait) by [Zealynx Security](https://zealynx.io) | Automated (AI) | Relaunch `src/` at `5a9ff0fe`, without `src/tropykus-legacy/` (not deployed) | 0 Critical, 0 High, 0 Medium; observations only | [report](./2026-10-02-Krait/krait-report.md) · [JSON](./2026-10-02-Krait/krait-findings.json) · [candidates](./2026-10-02-Krait/findings/) |
| 2026-10-06 | Nethermind AuditAgent (BitChill-supplied report) | Automated (AI) | Relaunch at `284b3500` on `docs/r113-audit-readiness-docs`; 37 contracts listed in the report | Original: 3 Medium, 3 Low; all six have explicit BitChill dispositions | [original report](./2026-10-06-Nethermind/audit-agent-report.md) · [provenance and dispositions](./2026-10-06-Nethermind/README.md) |
| 2026-10-13 | [Pashov skills](https://github.com/pashov/skills) solidity-auditor by Pashov Audit Group | Automated (AI) | Relaunch at `d5c09c32` on `refactor/r115-drop-single-rbtc-withdraw`; `src/` without `src/tropykus-legacy/`, and the deploy scripts | 2 findings (confidence 75), 28 leads; not triaged yet | [report](./2026-10-13-Pashov-Skills/dca-contracts-pashov-ai-audit-report-20261013-135445.md) · [provenance and triage notes](./2026-10-13-Pashov-Skills/README.md) |

The relaunch code has not had a third-party manual audit.

## 2025 manual reviews

Both were performed by Ivan Fitro, an independent researcher (later of Pashov Audit Group), on the
code as it stood in 2025. Several contracts had different names then (`AdminOperations`,
`TropykusDocHandler`), and the findings were addressed in that generation of the code.

The 2026 relaunch changed most of what those reports describe: OpenZeppelin v5.7.0, solc 0.8.36, the
idle, LayerBank, and Sovryn route map, the protected purchase window, exact lending-share consumption,
and fees taken in rBTC. Some 2025 mitigations were later removed or redesigned on purpose, among them
the owner's stuck-rBTC rescue and the hashed schedule id. The reports are evidence about the 2025
code, not about the relaunch. The reason for each later change is in its spec under
[`docs/relaunch/`](../docs/relaunch/).

## Krait AI audit (October 2026)

Krait is Zealynx Security's open-source AI security auditor. BitChill ran it on the relaunch code; it is
an automated audit, not a manual engagement by Zealynx Security's auditors. The report is as Krait
produced it, with a **Resolution** section at the end stating what BitChill fixed or accepted. The
`findings/` folder holds all 33 candidates Krait raised and the reason each was kept, downgraded, or
dismissed. Limits the report states: external protocol source (Money on Chain, Sovryn, LayerBank,
Uniswap) was not in scope, and the repository's test and fork lanes were not run as part of the audit.
The R112 response changed comments and documents. R114 later changes lending accounting, so the
final release differs from the code Krait audited.

The report and its candidate files cite documents as they stood at `5a9ff0fe`. Where a candidate
cites README "Compromised swapper", that procedure is in
[`docs/relaunch/CUTOVER_RUNBOOK.md`](../docs/relaunch/CUTOVER_RUNBOOK.md#compromised-swapper).

## Nethermind AuditAgent scan (October 2026)

BitChill supplied this automated report from Nethermind's AuditAgent.
It is not a manual engagement by Nethermind's auditors.
The original artifact is unchanged; its companion document records provenance, reproductions, and all six decisions.
None of the six mechanisms is dismissed as a false positive.
BitChill resolves the batch failure in findings 1/5/6 with one per-row share clamp and funded weights.
It accepts the peg and unsupported-wallet limitations and mitigates manager assignment mistakes
through deployment checks. The [dispositions](./2026-10-06-Nethermind/README.md) describe the remaining risks.
The reproductions use local mocks; they do not measure live incidence or prove profitable pool manipulation.

The follow-up changes executable lending and purchase accounting. Regression tests and full default,
deploy, and lending-fork gates validate those changes. The original report remains byte-identical.
The final release must be reviewed with these fixes; the report describes the earlier audited revision.

## Pashov skills AI scan (October 2026)

BitChill ran Pashov Audit Group's open-source solidity-auditor skill in Claude Code on the relaunch code.
It is an automated scan, not an engagement with Pashov Audit Group's auditors.
The scan ran 3 passes of 12 agents, and all 36 agent runs returned a report.
The report is the unchanged output of the skill. It has 2 findings at confidence 75 and 28 leads.
A lead is a code smell with an incomplete exploit path, not a scored finding.
BitChill has not triaged the report yet. The [companion document](./2026-10-13-Pashov-Skills/README.md)
records provenance, the judging rules, and triage notes. The X-Ray and Fizz skills have not run yet.

## Static analysis

`make slither` and `make aderyn` are triaged in
[`docs/relaunch/R73-RELEASE_RECORD.md`](../docs/relaunch/R73-RELEASE_RECORD.md#static-analysis-triage).
Analyzers are not audits.
