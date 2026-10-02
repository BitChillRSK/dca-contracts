# R113 — Reviewer-facing documents

Status: **implemented** · Assigned: yes · Optional/further-review: no · Stack on: R112
([#178](https://github.com/BitChillRSK/dca-contracts/pull/178)) · PR: [#179](https://github.com/BitChillRSK/dca-contracts/pull/179)

## Objective

Make the documents an external auditor reads state the current protocol, once each, and nothing else.
Markdown only: no Solidity, script, test, Makefile, or configuration change.

## Background

The root documents grew by accretion across the relaunch. Checked against `src/`, `script/`,
`foundry.toml`, and the `Makefile` at R112's head:

1. `README.md` carries generic sections that describe no specific behaviour ("comprehensive parameter
   validation", "path optimization for best rates"), test commands for the legacy Tropykus lanes, the
   `DeployFinal` command twice, and operator procedures (ownership handoff, add-on handlers,
   compromised swapper) that belong in the runbook.
2. `AUDIT_GUIDE.md` has no explicit out-of-scope list, no launch parameters, no pointer to earlier
   reviews, and says two test contracts use legacy codegen (`foundry.toml` carves out one file).
3. `DEPENDENCY_MODIFICATIONS.md` describes no modification. Its durable content is the compiler target
   and the OpenZeppelin pin; the rest answers questions no reader has (a warning that no longer fires,
   whether Rootstock requires 0.8.19).
4. `ADDRESSES.md` lists a pre-relaunch testnet deployment with a Tropykus handler and omits USDRIF,
   USDT0, and LayerBank.
5. `docs/relaunch/CUTOVER_RUNBOOK.md` gates on "PR 134" and `make fork-tropykus`; the gate is
   `make fork-sovryn` and `make fork-layerbank` (`AGENTS.md`), and the stack has moved on.
6. `src/idle/README.md` describes only the DOC leaf; `IdleHandlerDex` ships for USDRIF and USDT0.

## Open product decisions

**none.**

## Scope

- [x] `AUDIT_GUIDE.md`: explicit in-scope and out-of-scope lists; **Compiler and dependencies**;
      **Launch configuration**; the single ownership check and the reentrancy model; the Sovryn exit
      fee; **Earlier reviews and static analysis**; open items trimmed to what a reviewer needs.
      Existing section titles are kept because the Krait report cites them.
- [x] `README.md`: introduction, contract map, build and test lanes that exist, one deployment
      command, license, contact. Operator procedures move to the runbook.
- [x] `DEPENDENCY_MODIFICATIONS.md`: deleted. Compiler target and pins move to `AUDIT_GUIDE.md`;
      contributor rules move to `AGENTS.md`.
- [x] `ADDRESSES.md`: the external mainnet contracts `DeployFinal` binds to, from `script/`.
- [x] `docs/relaunch/CUTOVER_RUNBOOK.md`: current gates; ownership handoff, add-on handlers, and
      compromised-swapper order received from the README.
- [x] `audits/README.md`, `SECURITY.md`, `src/idle/README.md`, `src/layerbank/README.md`,
      `test/ai-generated/fuzz/README_INVARIANTS.md`: corrections and trims.
- [x] `audits/2026-10-02-Krait/krait-report.md`: one **Resolution** row updated for the deleted file.

## Out of scope

- [ ] Any change under `src/`, `script/`, `test/**/*.sol`, the `Makefile`, `foundry.toml`,
      `.gitmodules`, or `.env.example`. Non-document findings are listed in the PR for a later item.
- [ ] Rewriting the historical specs in this folder, or the body of the generated Krait report.

## Files likely touched

`AUDIT_GUIDE.md`, `README.md`, `DEPENDENCY_MODIFICATIONS.md`, `ADDRESSES.md`, `SECURITY.md`,
`AGENTS.md`, `audits/README.md`, `audits/2026-10-02-Krait/krait-report.md`, `src/idle/README.md`,
`src/layerbank/README.md`, `test/ai-generated/fuzz/README_INVARIANTS.md`,
`docs/relaunch/CUTOVER_RUNBOOK.md`, `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`.

## Required tests

Markdown-only tier (**Scale the gate to the change** in `AGENTS.md`): run nothing.

## Success criteria

- [x] Every command, file path, address, and parameter in the edited documents matches the tree.
- [x] No relative Markdown link in the edited documents is broken.
- [x] `git diff --name-only` against R112 lists only `.md` files.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` unchanged.
- [ ] No claim was added that the code or scripts do not support.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none.
- Cutover: the runbook's preconditions now name `make fork-layerbank` instead of `make fork-tropykus`.
  No consumer has to change.
