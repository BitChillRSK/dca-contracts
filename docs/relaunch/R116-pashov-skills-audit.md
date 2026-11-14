# R116 — Pashov skills audit results

Status: **implemented** · Assigned: yes · Optional/further-review: no · Stack on: R115
([#182](https://github.com/BitChillRSK/dca-contracts/pull/182)) · PR: [#183](https://github.com/BitChillRSK/dca-contracts/pull/183)

## Objective

Publish the output of three of Pashov Audit Group's open-source skills, all run on R115's `src/`: the
solidity-auditor scan, the X-Ray pre-audit map, and the Fizz fuzzing suite. Record them in the audit
index. Nothing in `src/` or `script/` changes. Triage and fixes belong to R117.

## Background

BitChill ran the three [Pashov skills](https://github.com/pashov/skills) in Claude Code on Claude Opus
5.5 between 2026-10-13 and 2026-10-19. The code was `src/` at `d5c09c32` (R115's head), without
`src/tropykus-legacy/`. These are automated runs, not an engagement with Pashov Audit Group.

1. **solidity-auditor** ran 3 passes of 12 agents. It reported 2 findings at confidence 75 and 28
   leads. Finding 1: a batch's `minRbtcOut` does not scale with the batch's input. Finding 2:
   `DeployFinal` assigns a Sovryn DOC market that has no free DOC.
2. **X-Ray** wrote a pre-audit map: the threat model, 68 invariants (10 not enforced on-chain) and the
   entry points. It has no findings.
3. **Fizz** wrote a stateful suite of 106 properties against local mocks of the venues and ran one
   Medusa campaign of 8 min 25 s (501,776 calls).
   - No SHOULD-HOLD property failed.
   - Two EXPLORATORY properties failed:
     - **SP-64:** a deposit inside a protected window makes a planned LayerBank batch burn one share
       more than planned. This confirms the scan's lead on deposits inside the window; without a
       lending loss the effect is dust.
     - **GL-15:** the property is too strong for an owner-set minimum of 1 wei.

## Open product decisions

**none** for this PR. R117 owns the triage, including the scan's simple fix for the window-deposit
lead. That fix would add `whenUserMutationsAllowed` to `depositToken` and `createDcaSchedule`, which
broadens the guarded set of `AGENTS.md` invariant 10, so it needs a product decision.

## Scope

- [x] `audits/2026-10-13-Pashov-Skills/`:
  - the scan report, unchanged from the skill's output;
  - a README with provenance, the judging rules and the triage notes, plus X-Ray and Fizz sections;
  - the X-Ray output in `x-ray/`.
- [x] `audits/README.md`: rows for the scan, X-Ray and Fizz, and a section that says all three are
      automated.
- [x] `AUDIT_GUIDE.md`: the earlier-reviews paragraph names the Pashov scan.
- [x] `test/fizz/`: the Fizz suite, formatted with `forge fmt`.
  - `FuzzTester` is the Medusa and Echidna target.
  - `FoundryTester` has the harness smoke and gas tests and a replay test for each violation.
- [x] `PROPERTIES.md`, plus `medusa.json` and `echidna.yaml` at the root.
- [x] `fizz_data/`: the Fizz metadata, property plan, report, violation files, coverage `lcov.info`
      and run logs.
- [x] `.gitignore`:
  - ignore Fizz's regenerable caches: the Medusa corpus sequences, the coverage HTML, the
    crytic-compile export and the Slither cache;
  - stop the Aderyn `report.md` rule from hiding `fizz_data/report.md`.

## Out of scope

- [ ] Any `src/` or `script/` change, including fixes for the scan's findings and leads (R117).
- [ ] Dispositions for the findings, leads and Fizz violations (R117).
- [ ] Fizz harness follow-ups. Each is listed in `fizz_data/report.md`:
  - a condition on GL-15's minimum-deposit half;
  - a Dex purchase on the USDT0 path, so that SP-72 runs;
  - longer Medusa campaigns and an Echidna campaign.
- [ ] Editing the generated scan report or the X-Ray output.

## Files likely touched

`audits/README.md`, `audits/2026-10-13-Pashov-Skills/**`, `AUDIT_GUIDE.md`, `test/fizz/**`,
`PROPERTIES.md`, `medusa.json`, `echidna.yaml`, `fizz_data/**`, `.gitignore`,
`docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`.

## Required tests

This PR uses the test-only tier (**Scale the gate to the change** in `AGENTS.md`). The new suite
imports only existing mocks, and no shared base, mock or helper changes.

- `forge test --match-contract FoundryTester` under the default profile and under
  `FOUNDRY_PROFILE=deploy`.
- `forge fmt --check`.

No other lanes and no forks.

The two `test_repro_*` tests pass only while the behaviour they replay still exists. R117 turns a repro
into a regression test when it fixes that behaviour.

## Success criteria

- [x] `src/` and `script/` are identical to `d5c09c32`.
- [x] The scan report's SHA-256 is
      `33e3aa21193300b7c8ee0d026686d43f0f8d1916267ecdb22502a1150213c918`, as recorded in its README.
- [x] `FoundryTester` passes under both profiles. The repros fire the SP-64 and GL-15 assertions with
      the fuzzer's values.
- [x] `forge fmt --check` is clean.
- [x] `audits/README.md` says all three runs are automated and that the relaunch has had no
      third-party manual audit.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] No change under `src/` or `script/`.
- [ ] Protocol invariants in `AGENTS.md` unchanged.
- [ ] The published files contain no keys or RPC URLs.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none.
- Cutover: none. Every CI test job now also compiles and runs `test/fizz/FoundryTester`.
