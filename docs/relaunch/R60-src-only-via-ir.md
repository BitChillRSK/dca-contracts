# R60 — Compile `src/` under `via_ir`, keep `test/` and `script/` on legacy codegen

Status: **not started** · Assigned: no · Optional/further-review: no · Order: after R55 ([#113](https://github.com/BitChillRSK/dca-contracts/pull/113))

## Objective

Ship `via_ir = true` for the deployed contracts only, using Foundry's per-path
`additional_compiler_profiles` / `compilation_restrictions` split, while every test and script file keeps
compiling under the current legacy (non-IR) codegen. Capture the hot-path gas win R55 measured
(`DcaManager.batchBuyRbtc` −2.6%, `testSinglePurchase` −2.0%, `testBatchPurchasesOneUser` −4.2%) and the
runtime-size reduction (~20–26%) without paying the costs R55 found: `ZeroTokenPurchaseUniswap`'s error
1284, the `RbtcWithdrawalTest.t.sol` stack-too-deep, and the `block.timestamp`/`vm.warp` rematerialization
that broke a fuzz test on six of seven lanes. All three of those only appear when the *test* files compile
under IR; none of them are `src/` files.

## Background

R55 (measure-and-recommend only, no compiler change) found `via_ir` gives a real but modest hot-path win
at a cost that looked, at the time, like it required touching test files to absorb: a legacy-codegen
carve-out for one settings test, a harness restructure for `RbtcWithdrawalTest.t.sol`, and an audit of
every `vm.warp`-adjacent test for the timestamp-caching hazard. R55 recommended against adopting `via_ir`
before relaunch on that basis.

The premise was that `via_ir` is a single project-wide setting. It is not, in Foundry 1.5.1. The same
`compilation_restrictions` primitive R55 already validated for the `ZeroTokenPurchaseUniswap` carve-out
(see R55's Findings, "The two `via_ir` compile failures") generalizes to a path glob, not just a single
file:

```toml
via_ir = true                 # [profile.default] — applies to src/ and everything else by default

[[profile.default.additional_compiler_profiles]]
name = "legacy-codegen"
via_ir = false
optimizer = true              # required: the extra profile does not inherit the default's optimizer
optimizer_runs = 200

[[profile.default.compilation_restrictions]]
paths = "test/**"
via_ir = false

[[profile.default.compilation_restrictions]]
paths = "script/**"
via_ir = false
```

Under this split:

- `ZeroTokenPurchaseUniswap` never compiles under IR, so error 1284 never fires — no legacy carve-out
  needed for that file specifically, since the whole `test/` tree is already legacy.
- `RbtcWithdrawalTest.t.sol`'s shared-harness stack-too-deep never fires, for the same reason.
- The `block.timestamp`/`vm.warp` rematerialization never fires: cheatcode-touching code never compiles
  under IR.
- `src/` — the only code that is ever deployed or that a user transaction executes — gets the IR
  optimizer's gas and size reduction.

This does **not** eliminate R55's residual risk items outright; it changes what has to be checked. R55
flagged that a solx deployment would be unverifiable on Rootstock's Blockscout. `via_ir` under stock solc
does not have solx's problem (same upstream compiler, same binary identity), but this PR must still prove,
not assume, that Blockscout's verifier accepts a `via_ir=true` artifact end to end on Rootstock, and that
mixing compiler profiles within one Foundry project does not change what gets sent to the verifier for the
deployed contract.

## Open product decisions

**none.** Ship only if the done-gate below passes in full. If Foundry's profile split does not actually
isolate `test/`/`script/` from IR-only failures (for example, if a profile mismatch silently serves stale
cached artifacts — R55's Findings flagged this exact trap), stop and report rather than forcing it.

## Scope

- [ ] Set `via_ir = true` in `[profile.default]` in `foundry.toml`.
- [ ] Add the `additional_compiler_profiles` / `compilation_restrictions` split above (or the minimal
      equivalent Foundry 1.5.1 actually requires — verify the exact glob and inheritance behavior against
      a clean build, not against a warm cache) so `test/**` and `script/**` compile under legacy codegen.
- [ ] Apply the same split to `[profile.ci]` if it does not inherit `[profile.default]`'s restrictions
      automatically — confirm which, don't assume.
- [ ] Full clean `forge build` (`forge clean && forge build`) with no `--match-*` filtering, to catch
      anything R55's sparse-compile blind spot could hide.
- [ ] Full `make check` (all seven lanes) on a clean build.
- [ ] Re-measure `DcaManager.batchBuyRbtc`, `testSinglePurchase`, `testBatchPurchasesOneUser` gas and
      every deployed contract's runtime size against the `#104` baseline, using the real project tree (not
      R55's scratchpad copy) — confirm the split configuration reproduces R55's `via_ir` numbers and does
      not regress them by compiling `src/` differently than R55's project-wide IR run did.
- [ ] Confirm `forge inspect storage-layout` and ABI JSON are unchanged for every deployed contract
      (compiler-invariance check, same as R55).
- [ ] Deploy to Rootstock testnet (chain 31) and verify on Blockscout — this is the one thing R55
      explicitly did not do, and it is now load-bearing: prove the verifier accepts the `via_ir=true`
      artifact, not just that its compiler-version list includes stock Solidity (R55 only established
      the latter).
- [ ] Confirm `forge verify-contract` sends the deployed contract's own compiler settings (the
      `via_ir=true` profile), not a project-wide setting that could be ambiguous under the split — check
      the verifier payload, don't assume Foundry resolves this correctly by construction.

## Out of scope

- Any change to Uniswap library sources, their `=0.7.6` pin, or `make patch-deps` (R23 territory).
- Adopting solx (closed against in R55 — unverifiable on Rootstock, cannot compile the pinned pragma).
- Restructuring `RbtcWithdrawalTest.t.sol`'s harness or auditing `vm.warp` usage — the split makes both
  moot, since `test/` never compiles under IR.
- Any product/business-logic change. This is a compiler-configuration PR only.

## Files likely touched

- `foundry.toml` (`via_ir = true` plus the profile/restriction split)
- `docs/relaunch/R55-solx-and-ir-evaluation.md` (cross-reference: R55's "keep stock solc, no IR"
  recommendation was project-wide; note that R60 supersedes it with a narrower `src/`-only adoption)
- `docs/relaunch/IMPLEMENTATION_ORDER.md`, `docs/relaunch/README.md` Status, once the PR opens

## Required tests

- `forge clean && forge build` (unfiltered — R55's two hidden failures were both invisible to
  `--match-*` runs).
- Full `make check` (all seven lanes), clean build.
- `make fork-sovryn` and `make fork-tropykus` before push (`AGENTS.md`).
- Rootstock testnet deploy + `forge verify-contract` against Blockscout for at least one representative
  contract (`DcaManager` or a Dex handler); ideally the full `OperationsAdmin`-driven deploy path so every
  contract that ships gets a real verification proof, not a sample.

## Success criteria

- [ ] `via_ir = true` applies to `src/**` only; `test/**` and `script/**` provably compile under legacy
      codegen (confirm via `forge build --sizes` per-profile, or equivalent evidence — not just "the
      build succeeded").
- [ ] Full seven-lane matrix passes on a clean build, including the invariant suite.
- [ ] Measured gas/size deltas on `src/` match or improve on R55's project-wide `via_ir` numbers.
- [ ] ABI and storage layout unchanged for every deployed contract.
- [ ] Rootstock testnet deploy succeeds and Blockscout verification succeeds for the `via_ir`-compiled
      bytecode.
- [ ] Open product decisions: none.

## Reviewer checklist

- [ ] `foundry.toml` diff is the profile/restriction split only — no other setting changed.
- [ ] CI is green on all seven lanes.
- [ ] Blockscout verification evidence (a real testnet address + explorer link, or the API response
      proving a successful verify) is in the PR body, not just claimed.
- [ ] Gas/size numbers in the PR body are reproducible from the commands listed, same as R55's Findings
      section.

## ABI / deploy / cutover impact

None expected — this changes bytecode, not interface. Storage layout and ABI must be confirmed unchanged
(see Success criteria) precisely because this PR has no other guard against it.
