# R112 — Krait audit report and follow-ups

Status: **implemented** · Assigned: yes · Optional/further-review: no · Stack on: R111
([#177](https://github.com/BitChillRSK/dca-contracts/pull/177)) · PR: [#178](https://github.com/BitChillRSK/dca-contracts/pull/178)

## Objective

Publish the Krait AI audit of `src/` under `audits/2026-10-02-Krait/` and close its observations. Every
change is a comment or a document; no executable code changes, so the report still describes the code
that ships.

## Background

[Krait](https://github.com/ZealynxSecurity/krait) is Zealynx Security's open-source AI security
auditor. BitChill ran it on 2026-10-02 over `src/` at `5a9ff0fe` (R111 head), without
`src/tropykus-legacy/`: 0 Critical / High / Medium, 33 candidates raised, none reportable. It is an
automated audit, not a manual engagement by Zealynx Security's auditors; the published report and
`audits/README.md` say so, and the statement that the relaunch has no third-party manual audit stays.

### Observations

1. **Leaked swapper key.** Three accepted behaviours share one precondition: a window can be reopened
   in the block the previous one ends, a zero caller minimum leaves only the oracle floor, and any
   swapper can activate any allowlisted path. Combined, users cannot pause or exit while windows are
   chained, and each Dex schedule that comes due can be filled down to the floor (3% below the oracle
   at launch settings) until `revokeSwapper`. The report asked for one more decision on a mandatory gap
   between windows.
2. **`setMocOracle` is outside the "one-transaction wall".** NatSpec on
   `PurchaseUniswap._validateSlippageSettings` and `IPurchaseUniswap.setAmountOutMinimumSafetyCheck`
   says no single owner transaction can widen the live floor. Replacing the oracle moves the floor in
   one call.
3. **Fee collector rotation.** `setFeeCollector` redirects future credits only. The runbook says so in
   its preconditions but has no rotation step.
4. **Owner-side Dex parameters are single-step.** Matches the documented governance trust.
5. **Two documents out of step.** `AUDIT_GUIDE.md` says idle handlers keep per-user balances (R87
   removed that book). `DEPENDENCY_MODIFICATIONS.md` says there is no `[profile.deploy]` (R60 added it).

## Open product decisions

**none.** Item 1 was decided on 2026-10-02: no mandatory gap. A gap gives users a few open blocks they
are unlikely to use before the Safe revokes the key, a loose fill pays the key holder only if they also
move the pool around the batch, and the loss is capped at the floor on due Dex purchases. The worst
case is documented instead. Item 2 is a comment correction: bounding a new oracle against the old one
is not assigned.

## Scope

- [x] `audits/2026-10-02-Krait/`: `krait-report.md`, `krait-findings.json`, and the `findings/`
      candidate files, as generated. The report gains a provenance note at the top and a
      **Resolution** section at the end. Not published: the Slither JSON (`make slither` reproduces
      it) and the tool's recon and known-issue working files.
- [x] `audits/README.md`: a **Krait AI audit** section naming Krait and Zealynx Security.
- [x] `.gitignore`: ignore `.audit/` and `.krait-cache/`, the tool's working output.
- [x] `AUDIT_GUIDE.md`: the leaked-swapper worst case stated once; `setMocOracle` named as outside the
      safety-check wall; idle handlers keep no per-user book.
- [x] NatSpec on `PurchaseUniswap._validateSlippageSettings`,
      `IPurchaseUniswap.setAmountOutMinimumSafetyCheck`, and `IPurchaseUniswap.setMocOracle`.
- [x] `docs/relaunch/CUTOVER_RUNBOOK.md`: a fee collector rotation section.
- [x] `DEPENDENCY_MODIFICATIONS.md`: describe `[profile.deploy]`.

## Out of scope

- [ ] A mandatory gap between protected purchase windows (decided against, above).
- [ ] Any bound on `setMocOracle`, a timelock on owner setters, or any other executable change.
- [ ] Editing the body of the generated report or its candidate files.

## Files likely touched

`audits/README.md`, `audits/2026-10-02-Krait/**`, `.gitignore`, `AUDIT_GUIDE.md`,
`DEPENDENCY_MODIFICATIONS.md`, `src/PurchaseUniswap.sol`, `src/interfaces/IPurchaseUniswap.sol`,
`docs/relaunch/CUTOVER_RUNBOOK.md`, `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`.

## Required tests

Comment-only tier (**Scale the gate to the change** in `AGENTS.md`): build `src/` under the default
and `deploy` profiles and compare metadata-stripped runtime and creation code against the parent. No
test lanes, no forks (human instruction for this PR, and the tier does not require them).

## Success criteria

- [x] `audits/README.md` names Krait and Zealynx Security and says the audit is automated.
- [x] Every observation has a stated status in the report's **Resolution** section.
- [x] Metadata-stripped bytecode is identical to `5a9ff0fe` on every `src/` artifact, both profiles.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` unchanged.
- [ ] The only `src/` edits are NatSpec.
- [ ] The published report contains no local paths, keys, or RPC URLs.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none.
- Cutover: one new runbook section (fee collector rotation). No consumer has to change.
