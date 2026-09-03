# R60 — A `via_ir` deploy profile that runs the whole suite against the shipped bytecode

Status: **implemented; Rootstock testnet deploy + Blockscout verification not yet performed** · Assigned:
yes · Optional/further-review: no · Order: after R55 ([#113](https://github.com/BitChillRSK/dca-contracts/pull/113))

## Objective

Give the deployed contracts the `via_ir` gas and size win R55 measured, without paying via-IR's compile
time on every `make check`, and — this is the requirement that actually drives the design below — without
running the test suite against a different bytecode than what ships. A `[profile.deploy]` in
`foundry.toml`, activated only by `FOUNDRY_PROFILE=deploy`, compiles `via_ir = true` across `src/`,
`test/`, and `script/`; a new `make check-deploy` target runs the full seven-lane matrix under it. Default
`make check`/`make ci` are untouched and stay legacy codegen, so day-to-day iteration does not slow down.

## Background

R55 (measure-and-recommend only) found `via_ir` gives a real but modest hot-path win
(`DcaManager.batchBuyRbtc` −2.6%, `testSinglePurchase` −2.0%, `testBatchPurchasesOneUser` −4.2%, ~20–26%
smaller runtime) at a cost it judged not worth paying before relaunch: `ZeroTokenPurchaseUniswap`'s solc
error 1284, a `RbtcWithdrawalTest.t.sol` stack-too-deep, and a `block.timestamp`/`vm.warp` rematerialization
that broke a fuzz test on six of seven lanes.

This PR was originally scoped around a different premise than what it actually implements, and that
turn is worth recording because it is the reason the design looks the way it does. The first draft proposed
compiling only `src/**` under IR via `compilation_restrictions`, with `test/**`/`script/**` kept on legacy
codegen — cheap, and it does make all three of R55's failures disappear, because none of them are `src/`
files. But a `compilation_restrictions` glob does not change what a *legacy-compiled* test's `new
DcaManager(...)` deploys: Foundry resolves a constructor call to the artifact built in the same
compilation unit/profile as the calling file, so a `test/` file kept on legacy codegen links against a
**second, legacy-codegen build of `DcaManager`**, not the IR one. Traced directly (`forge test -vvvv`
against `ModifiersTest`): under that split, `dcaManager.getOperationsAdminAddress()` resolves to
`DcaManager.legacy-codegen::getOperationsAdminAddress()` in the call trace — proof the test suite was
exercising a contract nothing would ever deploy. That does not satisfy "run the whole suite against the
final bytecode"; it is parity evidence between two different builds, not identity. Confirmed by asking:
answer was to keep the literal guarantee and put in the extra work, not settle for parity.

So `[profile.deploy]` compiles `via_ir = true` with no path restriction, everywhere, and R55's three
failures had to be fixed for real rather than routed around:

1. **`ZeroTokenPurchaseUniswap` (error 1284) — not fixable in `src/PurchaseUniswap.sol`.** This is the
   known upstream solc/via-IR limitation [ethereum/solidity#11642](https://github.com/ethereum/solidity/issues/11642):
   when the optimizer can prove a constructor always reverts, the dead-code eliminator strips everything
   after the revert — including the `setimmutable` for `i_stablecoinToUsdScale` — and a later checker then
   reports "immutables read but never assigned." `ZeroTokenPurchaseUniswap`'s `_purchaseToken()` override is
   `pure` and hardcoded to `address(0)`, so its constructor is provably, deliberately always-reverting by
   design (that is the entire point of the test: proving a reversed `is` list cannot deploy). No reordering
   inside `PurchaseUniswap`'s real constructor changes that this specific derived *test* contract always
   reverts — the guard tried first (moving the zero-token check earlier in the constructor) did not clear
   the error, confirming the analysis is about this contract's always-reverting shape, not statement order.
   Fixed by moving `ZeroTokenPurchaseUniswap` and its one test out of `PurchaseUniswapSettingsTest.sol`
   (which has 18 unrelated tests) into `test/unit/ZeroTokenPurchaseUniswapTest.sol`, and excluding only that
   new file from IR via `compilation_restrictions` — the sole exception in `[profile.deploy]`. No `src/`
   file changed.
2. **`RbtcWithdrawalTest.t.sol` stack-too-deep, in the shared harness `DcaDappTest.makeSeveralPurchasesWithSeveralSchedules`.**
   That function held ~13 locals live across two nested loops. Split the inner per-schedule loop out into a
   private helper (`_runSchedulePurchases`); no assertion changed. Confirmed fixed by a clean, unfiltered
   `FOUNDRY_PROFILE=deploy forge build` with zero `1284`/"too deep" hits anywhere in the log.
3. **`RbtcPurchaseTest.t.sol`'s `testLastPurchaseTimestampConsistencyWhenScheduleResumed` fuzz failure.**
   Root cause: `uint256 firstPurchaseTimestamp = block.timestamp;` cached in a stack local, followed by
   `vm.warp`. Under legacy codegen the local keeps its pre-warp value, as Solidity's local-variable
   semantics require; under via-IR the Yul optimizer rematerializes the `TIMESTAMP` opcode at the read site
   instead of keeping the assigned local — valid for any real transaction (`block.timestamp` cannot change
   mid-call), wrong the moment a cheatcode moves the clock out from under it. A stack local is not immune to
   this under IR; storage is (nothing rematerializes a `SLOAD` across a warp). Fixed by moving the cached
   timestamp into a private storage variable (`s_firstPurchaseTimestampForResumeTest`) instead of a stack
   local. Confirmed with 1000 fuzz runs under `[profile.deploy]`: 0 failures.

With all three fixed, a clean `FOUNDRY_PROFILE=deploy forge build` compiles 205 files with zero errors, and
`FOUNDRY_PROFILE=deploy make check` passes all seven lanes with the same counts R55 recorded for its
project-wide via-IR run (`801 / 805 / 815 / 469 / 786 / 786` plus 11 invariants at 64×512, zero reverts).
A from-scratch `forge clean && FOUNDRY_PROFILE=deploy forge build --sizes` shows `DcaManager` at 11,712 B —
R55's IR number, with no `.legacy-codegen` duplicate anywhere, confirming the file-level restriction stays
scoped to the one excluded file and does not propagate through an import graph the way a package-wide
`test/**` restriction would (see R55's Findings, "the restriction propagates to the file's whole import
graph" — that trap is why this PR restricts one file instead of a directory).

## Open product decisions

**none.**

## Scope

- [x] Add `[profile.deploy]` to `foundry.toml`: `via_ir = true`, `fuzz.runs = 1000` (same as default,
      since CI's reduced 256 stays CI-only).
- [x] Exclude exactly one file from `[profile.deploy]`'s IR compilation, via
      `additional_compiler_profiles` (`legacy-codegen`, `via_ir = false`, `optimizer = true`,
      `optimizer_runs = 200` — the extra profile does not inherit the default's optimizer settings) plus
      `compilation_restrictions` on `test/unit/ZeroTokenPurchaseUniswapTest.sol`.
- [x] Split `ZeroTokenPurchaseUniswap` + `PurchaseUniswapZeroTokenTest` out of
      `test/unit/PurchaseUniswapSettingsTest.sol` into `test/unit/ZeroTokenPurchaseUniswapTest.sol`.
      No behavior change to either contract; only the file boundary moved.
- [x] Split `DcaDappTest.makeSeveralPurchasesWithSeveralSchedules`'s inner loop into a private
      `_runSchedulePurchases` helper. No assertion changed.
- [x] Move `RbtcPurchaseTest.testLastPurchaseTimestampConsistencyWhenScheduleResumed`'s cached
      pre-warp timestamp from a stack local into a private storage variable. No assertion changed.
- [x] Add `make check-deploy` / `make build-deploy` targets, mirroring `check`/`build`/`ci`'s existing
      shape, each sub-lane run under `FOUNDRY_PROFILE=deploy`.
- [x] Full clean `forge clean && FOUNDRY_PROFILE=deploy forge build` — 205 files, 0 errors.
- [x] Full `FOUNDRY_PROFILE=deploy make check` (all seven lanes) — 0 failures, counts match R55.
- [x] Confirm via a from-scratch `--sizes` build that `src/` contracts compile at R55's IR sizes with no
      stray `.legacy-codegen` duplicates (the file-level restriction does not leak beyond the one file).
- [ ] Deploy to Rootstock testnet (chain 31) and verify on Blockscout — **not performed in this PR**, for
      the same reason R55 did not: `AGENTS.md` forbids broadcasting from an agent session. This needs a
      human operator running `FOUNDRY_PROFILE=deploy forge script ... --broadcast` plus
      `forge verify-contract` against Blockscout for at least one representative contract. Until that
      happens, "Blockscout accepts a `via_ir=true` artifact from this exact split configuration" is
      inferred (stock solc, standard settings, no reason to expect rejection) but not proven end to end.

## Out of scope

- Any change to Uniswap library sources, their `=0.7.6` pin, or `make patch-deps` (R23 territory).
- Adopting solx (closed against in R55 — unverifiable on Rootstock, cannot compile the pinned pragma).
- Any product/business-logic change. `_runSchedulePurchases` and the storage-variable timestamp fix are
  test-only refactors with no assertion changed; the `ZeroTokenPurchaseUniswap` move is a file-boundary
  change only.
- Making `[profile.deploy]` the default, or wiring it into CI. It exists to be run deliberately, once,
  before an actual deploy.

## Files likely touched

- `foundry.toml` (`[profile.deploy]`, its `additional_compiler_profiles` / `compilation_restrictions`)
- `Makefile` (`check-deploy`, `build-deploy` targets, `.PHONY`, `help` text)
- `test/unit/ZeroTokenPurchaseUniswapTest.sol` (new — split out of `PurchaseUniswapSettingsTest.sol`)
- `test/unit/PurchaseUniswapSettingsTest.sol` (the two moved contracts removed)
- `test/unit/DcaDappTest.t.sol` (`_runSchedulePurchases` split)
- `test/unit/RbtcPurchaseTest.t.sol` (storage-variable timestamp fix)
- `docs/relaunch/IMPLEMENTATION_ORDER.md`, `docs/relaunch/README.md` Status, once the PR opens

## Required tests

- `forge clean && FOUNDRY_PROFILE=deploy forge build` (unfiltered — R55's hidden failures were invisible
  to `--match-*` runs; this is what actually caught both compile failures during this PR).
- `FOUNDRY_PROFILE=deploy make check` (all seven lanes), clean build.
- `make fork-sovryn` and `make fork-tropykus` before push (`AGENTS.md`) — run under the *default* profile,
  since forks are not a deploy-profile gate here.
- `make check` (default profile) — confirms the split did not change default/CI behavior.

## Success criteria

- [x] `FOUNDRY_PROFILE=deploy forge build` compiles clean (0 errors) from scratch, `src/`, `test/`, and
      `script/` all under `via_ir=true` except the one excluded file.
- [x] A test's `new DcaManager(...)` (or any deployed contract) under `[profile.deploy]` deploys the same
      artifact `forge script` would broadcast — no `.legacy-codegen` duplicate for any deployed contract.
- [x] Full seven-lane matrix passes under `[profile.deploy]`, including the invariant suite (11 invariants,
      64×512, 0 reverts).
- [x] Measured `src/` sizes under `[profile.deploy]` match R55's project-wide `via_ir` numbers exactly
      (`DcaManager` 11,712 B, confirmed from a clean rebuild).
- [x] Default `make check` / `make ci` behavior is unchanged (still `via_ir=false`, still fast).
- [ ] Rootstock testnet deploy succeeds and Blockscout verification succeeds for the `via_ir`-compiled
      bytecode — **outstanding**, needs a human operator (see Scope).
- [x] Open product decisions: none.

## Reviewer checklist

- [ ] `foundry.toml` diff is `[profile.deploy]` plus its restriction only — default/CI profiles unchanged.
- [ ] CI is green on all seven lanes (default profile, unaffected by this PR).
- [ ] `ZeroTokenPurchaseUniswapTest.sol`'s doc comment on `ZeroTokenPurchaseUniswap` explains *why* it is
      excluded (the always-reverting-constructor / solc#11642 shape), not just that it is excluded.
- [ ] `_runSchedulePurchases` and the storage-variable timestamp fix are confirmed assertion-identical to
      what they replaced (diff review, not just "tests still pass").
- [ ] Someone is assigned to actually run the Rootstock testnet deploy + Blockscout verification before
      `[profile.deploy]` is used for a real deploy.

## ABI / deploy / cutover impact

None from this PR alone — it changes what bytecode `[profile.deploy]` produces, not any interface, and
`[profile.default]`/`[profile.ci]` (what CI and every existing consumer integration test against) are
untouched. The moment `[profile.deploy]` is actually used to deploy, the bytecode changes (smaller, less
gas per purchase) but the ABI does not — confirmed by the identical test-suite pass counts against
`[profile.default]`'s behavior. Blockscout verification is the one unproven link in that chain (see Scope).
