# Security Audits

For the current production scope, trust boundaries, intentional trade-offs, and commands an auditor can
reproduce, start with [`AUDIT_GUIDE.md`](../AUDIT_GUIDE.md).

BitChill has two published reviews by the same independent researcher. They are **historical** reviews of
pre-relaunch code. They are not a substitute for reviewing the 2026 relaunch diff, and they are **not**
independent multi-firm audits.

## Audit Reports

| Date | Auditor | Scope (at the time) | Findings | Report |
|------|---------|---------------------|----------|--------|
| April 2025 | [Ivan Fitro](https://twitter.com/FitroIvan) | Then-current protocol (Tropykus/Sovryn MoC stack) | 3 Medium, 4 Low, 2 Info | [PDF](./2025-04-29-Ivan-Fitro.pdf) |
| June 2025 | [Ivan Fitro](https://twitter.com/FitroIvan) | Mitigations + Uniswap V3 integration | 1 Low, 1 Info | [PDF](./2025-06-02-Ivan-Fitro.pdf) |

Both engagements were performed by **Ivan Fitro** (later of Pashov Audit Group / OpenZeppelin). Same auditor
twice is useful continuity; it is not “multiple independent audits.”

## Krait AI audit (October 2026)

| Date | Auditor | Scope | Findings | Report |
|------|---------|-------|----------|--------|
| 2026-10-02 | [Krait](https://github.com/ZealynxSecurity/krait) by [Zealynx Security](https://zealynx.io) | Relaunch `src/` at `5a9ff0fe`, without `src/tropykus-legacy/` (not deployed) | 0 Critical, 0 High, 0 Medium; observations only | [report](./2026-10-02-Krait/krait-report.md) · [JSON](./2026-10-02-Krait/krait-findings.json) · [candidates](./2026-10-02-Krait/findings/) |

Krait is Zealynx Security's open-source AI security auditor. BitChill ran it on the relaunch code; it is
an automated audit, not a manual engagement by Zealynx Security's auditors. The report is as Krait
produced it, with a **Resolution** section at the end stating what BitChill fixed or accepted. The
`findings/` folder holds all 33 candidates Krait raised and the reason each was kept, downgraded, or
dismissed. Limits the report states: external protocol source (Money on Chain, Sovryn, LayerBank,
Uniswap) was not in scope, and the repository's test and fork lanes were not run as part of the audit.
The changes made in response to it are comments and documents, so the audited code is the code that
ships.

## What the 2025 reports covered

### Initial review (April 2025)

Contracts then named differently in places (`AdminOperations`, `TropykusDocHandler`, schedule-id model, stuck-fund recovery paths, etc.). Findings listed in the PDF were addressed in that generation of the codebase.

### Mitigation + Uniswap review (June 2025)

Follow-up on prior mitigations plus `PurchaseUniswap` / Dex handler surface as it existed then.

## Relaunch status (2026)

The relaunch stack (OpenZeppelin **v5.7.0**, solc **0.8.36** / `cancun`, idle + LayerBank + Sovryn route map,
BUSL-1.1 on `src/`, protected purchase window, exact lending-share consumption, and related work) has
**not** received a separate third-party manual audit as of this writing unless a later report is added
to the **Audit Reports** table above. The Krait AI audit covers that code but is automated.

Treat the PDFs as evidence about the **2025** code under review, not as a claim that every 2026 change was
re-audited. Several mitigations described in older summaries (for example owner stuck-rBTC rescue, or the
old schedule-id construction) were later removed or redesigned on purpose — see the relaunch specs under
[`docs/relaunch/`](../docs/relaunch/).

Static analysis at cutover (`make slither`, `make aderyn`) is triaged in
[`docs/relaunch/R73-RELEASE_RECORD.md`](../docs/relaunch/R73-RELEASE_RECORD.md); analyzers are not audits.
