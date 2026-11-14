# R73 — Deploy script, static analysis, and release-document truthfulness

Status: **in progress** · Assigned: yes · Optional/further-review: no · Order: after R71 (source phase,
merged) and R72 (licensing), before any final mainnet deployment

## Objective

This is [R71](./R71-final-predeployment-hardening.md)'s **phases 3–5**, split into its own spec on
2026-09-07 because the source phase alone ([#128](https://github.com/BitChillRSK/dca-contracts/pull/128))
already grew larger than expected and deserved review on its own. Nothing here is new work discovered
since R71 was written — it is R71's own **Mandatory implementation order** phases 3, 4, and 5, verbatim,
scoped out into a PR of their own so R71's source-level changes could ship and be reviewed first.

R71's phases, unchanged, with one R73 addition called out:

3. Implement the canonical deployment script and deployment tests against the frozen R71+R72 source.
4. Run Slither **and Aderyn**, full release-artifact/size/storage checks, and the full local/fork gates.
   (Aderyn was not named in R71's phase-4 wording; added here 2026-09-08 as a second static analyzer
   on the same frozen source. Expect mostly false positives / accepted design choices; triage each.)
5. Update README/audit/security prose, the runbook, release record, consumer issues, and PR body to
   describe the code that actually passed the gates — including R72's license.

## Background

Read [R71](./R71-final-predeployment-hardening.md) in full; this spec does not repeat it. In
particular, R71's **Background** section 5 (public security documentation is currently promotional
rather than precise — stale OpenZeppelin version, stale install path, an overstated multi-audit claim,
mitigations that later changed, `SECURITY.md` promising patches an immutable deployment cannot give,
and a licence statement that was simply wrong before [R72](./R72-licensing.md)) is this PR's phase-5
mandate, and still applies. R72 has now settled the license question that section flagged as blocking;
phase 5 should describe BUSL-1.1 accurately, including the Additional Use Grant and that pre-relaunch
code stays MIT.

Also carried over from R71, now closed: the **Ops checks** section's `redeemDocRequest` standing-
settlement question. See R71's own **Ops checks (not Solidity)** section for the answer (closed
2026-09-07, no action needed) — it is R71's item, recorded there rather than duplicated here. The
runbook this PR writes (phase 5) should still mention it was checked and closed, for anyone auditing
the cutover decision trail later.

## Open product decisions

**none** — R71 already answered every product gate this work depends on (see R71 **Open product
decisions**). R72 answered licensing. This PR implements; it does not ask.

## Scope

- [ ] Canonical deployment script for the frozen R71+R72 source (may already substantially exist —
      check `script/` for what R71's phase-3 note assumed versus what is current).
- [ ] Deployment tests against that script.
- [ ] Slither run and triage of findings against the shipped bytecode.
- [ ] Aderyn run and triage of findings against the same frozen `src/` (add `make aderyn`; exclude
      `test/`, `script/`, and `lib/` the same way Slither does; do not commit the raw `report.md`
      unless the release record needs a checked-in excerpt).
- [ ] Release-artifact / size / storage checks per `IMPLEMENTATION_ORDER.md`'s **Measurement basis**.
- [ ] Full local + fork gate run (`make check`, `make fork-sovryn`, `make fork-tropykus`) against the
      exact commit that will deploy.
- [ ] `README.md`, `SECURITY.md`, `audits/README.md`: correct the OpenZeppelin version, install path,
      audit-count/independence overstatement, stale mitigation descriptions, unkeepable patch/backport
      promise, and license statement (now BUSL-1.1 per R72, not "final license while licensing is
      open").
- [ ] Cutover runbook.
- [ ] Release record.
- [ ] Any consumer-repo issues this phase's changes require (`AGENTS.md` **Consumer follow-up**).

## Out of scope

- [ ] Any further `src/` behavior change. Source is frozen as of R71+R72; if this phase finds a source
      defect, stop and open a new R-item rather than fixing it inline.
- [ ] [R74](./R74-economics-parameters-revisit.md) — unassigned, post-cutover, not a blocker here.
- [ ] Broadcasting to Rootstock mainnet or testnet. `AGENTS.md` forbids broadcasting from an agent
      session; the deploy script and its tests are prepared here, the human operator runs it.

## Files likely touched

`script/**`, `Makefile` (`make aderyn`), `aderyn.toml` (or equivalent exclude config),
`docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md` (Status), `README.md`,
`SECURITY.md`, `audits/README.md`, a new cutover-runbook doc if one does not already exist,
plus the Slither/Aderyn triage section of the release record.

## Required tests

- Whatever the new/updated deployment script needs to prove it deploys the frozen source correctly on
  a fork or testnet-equivalent harness.
- `make check`, `make fork-sovryn`, `make fork-tropykus`: full pass, same commit that deploys.
- Slither: run and record findings; triage each as fixed, accepted-risk (with reason), or false-positive.
- Aderyn: same triage bar as Slither.

## Success criteria

- [ ] Deployment script exists, is tested, and deploys the exact frozen R71+R72 source.
- [ ] Slither and Aderyn have been run against that source and every finding is triaged.
- [ ] README/SECURITY/audits describe the code that actually passed the gates, including the license.
- [ ] Runbook and release record exist and are accurate.
- [ ] No open product decisions remain.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**, especially no further `src/` behavior change.
- [ ] Every documentation claim (audit count, OZ version, license, patch policy) is checked against the
      actual current state of the repo, not copied from the previous (stale) prose.
- [ ] No broadcast commands executed by an agent session.

## ABI / deploy / cutover impact

- ABI: none expected — this phase deploys and documents the source R71+R72 already froze.
- Scripts: this phase's entire point.
- Cutover: this phase's entire point. The human operator runs the actual broadcast, ownership
  acceptance, and Blockscout verification; this spec prepares everything up to that point.
