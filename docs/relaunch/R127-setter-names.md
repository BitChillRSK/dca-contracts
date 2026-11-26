# R127 — Consistent configuration setter names

Status: **in progress** · Assigned: yes (2026-11-26) · Optional/further-review: no

## Objective

Use `set…` functions and `…Set` events for explicit configuration assignments.
Keep `…Updated` for accounting balance changes.

## Background

The owner approved six event renames and two function renames in this chat.
This PR stacks on R126, GitHub #203, branch `fix/r126-dex-floor-cap`.
The ABI changes are intentional. No compatibility aliases are required.

## Open product decisions

**none** — the owner approved the naming convention and ABI changes.

## Scope

- [ ] Rename `updatePurchaseAmount` to `setPurchaseAmount`.
- [ ] Rename `updatePurchasePeriod` to `setPurchasePeriod`.
- [ ] Rename these events, preserving each contract prefix:
  - `PurchaseAmountUpdated` → `PurchaseAmountSet`.
  - `PurchasePeriodUpdated` → `PurchasePeriodSet`.
  - `MaxSchedulesPerTokenModified` → `MaxSchedulesPerTokenSet`.
  - `MinPurchasePeriodModified` → `MinPurchasePeriodSet`.
  - `AmountOutMinimumPercentUpdated` → `AmountOutMinimumPercentSet`.
  - `OracleUpdated` → `OracleSet`.
- [ ] Preserve function arguments, event fields, indexing, validation, authorization, guards, and emission conditions.
- [ ] Update matching tests, fuzz handlers, ABI inventories, and current operational references.
- [ ] Check all first-party explicit configuration setters against the convention.
- [ ] Record the convention in `AGENTS.md` and update its current function references.
- [ ] Open or update affected consumer issues in the same turn as the PR.
- [ ] Correct the pre-existing LayerBank share-withdrawal fork assertion described below. Preserve its exact share-transfer and cash-receipt checks.
- [ ] Correct the pre-existing schedule-period invariant described below and add its deterministic regression.

## Out of scope

- `TokenBalanceUpdated` and `UserSharesUpdated` retain their names.
- Registration, handler assignment, swapper membership, ownership, deposits, withdrawals, and purchases retain their action names.
- Existing `…Set` events retain their names, including `NewPathSet` and `FeeCollectorAddressSet`.
- No new production behavior, compatibility aliases, parameter changes, storage changes, deployments, or merges.
- Historical specs, audit reports, recorded fuzz logs, and corpora remain historical records.
- No consumer code or consumer pin changes.

## Files likely touched

- `AGENTS.md`
- `AUDIT_GUIDE.md`
- `docs/relaunch/CUTOVER_RUNBOOK.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/README.md`
- `fizz_data/contracts.json`
- `fizz_data/entry-point-selection.json`
- `fizz_data/invariant-context.md`
- `fizz_data/last-run.json`
- `fizz_data/property-plan.md`
- `src/DcaManager.sol`
- `src/PurchaseUniswap.sol`
- `src/interfaces/IDcaManager.sol`
- `src/interfaces/IPurchaseUniswap.sol`
- `test/ai-generated/audit/NethermindAuditFindings.t.sol`
- `test/ai-generated/fuzz/Handler.t.sol`
- `test/ai-generated/fuzz/Invariants.t.sol`
- `test/ai-generated/unit/DcaManagerEdgeCasesTest.t.sol`
- `test/ai-generated/unit/sovryn-legacy/SovrynHandlerDexTest.t.sol`
- `test/ai-generated/unit/tropykus-legacy/TropykusHandlerDexTest.t.sol`
- `test/fizz/Base.sol`
- `test/fizz/FoundryTester.sol`
- `test/fizz/handlers/AdversarialHandler.sol`
- `test/fizz/handlers/DcaManagerHandler.sol`
- `test/gas/R82TransientGuardGas.t.sol`
- `test/unit/BatchMinRbtcOutTest.t.sol`
- `test/unit/ConstructorConfigEventsTest.t.sol`
- `test/unit/DcaConfigurationTest.t.sol`
- `test/unit/DcaScheduleTest.t.sol`
- `test/unit/DepositsPauseTest.t.sol`
- `test/unit/EventIndexingTest.t.sol`
- `test/unit/LendingShareWithdrawalTest.t.sol`
- `test/unit/ModifiersTest.t.sol`
- `test/unit/ProtectedPurchaseWindowTest.t.sol`
- `test/unit/PurchaseUniswapSettingsTest.sol`
- `test/unit/RbtcPurchaseTest.t.sol`
- `test/unit/ScheduleOwnershipTest.t.sol`
- `test/unit/SchedulePackingTest.t.sol`
- `test/unit/SchedulePauseTest.t.sol`
- `test/unit/TopUpFromInterestTest.t.sol`

## Required tests

Run the existing configuration, constructor-event, event-indexing, and protected-window suites first:

```bash
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=DOC forge test --match-contract 'DcaConfigurationTest|ConstructorConfigEventsTest|EventIndexingTest|ProtectedPurchaseWindowTest|ModifiersTest'
SWAP_TYPE=dexSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=USDRIF forge test --match-contract 'DcaConfigurationTest|ConstructorConfigEventsTest|EventIndexingTest|ProtectedPurchaseWindowTest|ModifiersTest|LayerBankHandlerDexTest'
make check
make check-deploy
make fork-layerbank
```

- Existing assertions must cover new event topics, unchanged fields and indexing, caller ownership, validation, and the protected window.
- Compare the four changed `src/` files with the parent plus the approved identifier substitutions.
- Check all 13 configuration setters and their 15 events against the convention.
- Run no new live-contract calls. The existing LayerBank fork lane is the required fork gate.

## Success criteria

- [ ] The two new function names replace their old names without aliases.
- [ ] The six new event names replace their old names.
- [ ] Only `TokenBalanceUpdated` and `UserSharesUpdated` retain `Updated` in first-party events; no event retains `Modified`.
- [ ] The production-source change consists only of approved identifier substitutions.
- [ ] Required commands pass and affected consumers have linked follow-ups.
- [ ] The PR preserves ancestry from #203 and README Status names the new PR.

## Reviewer checklist

- [ ] Matches Scope and preserves protocol invariants.
- [ ] Required checks pass and exact commands appear in the PR.
- [ ] Extra paths are direct dependencies and appear in the PR description.
- [ ] No unrelated changes, deployments, or merges.

## ABI / deploy / cutover impact

- ABI: two renamed DcaManager selectors and six renamed event signature hashes (`topic0`). Arguments and event fields are unchanged.
- Scripts: no deploy/config changes. New bytecode requires regenerated artifacts for the relaunch deployment.
- Cutover: front-end must update schedule-edit calls and ABIs. Monitoring must regenerate ABIs and review renamed event decoding.
- Check existing issues and actual consumer references before opening follow-ups. Update relevant documentation references when required.
- No broadcast or live addresses are authorized by this spec.

## Fork-gate amendment — 2026-11-26

The first `make fork-layerbank` run failed only in `test_fork_layerBankWithdrawalThenRedeemAtPool` at block 9443471.
The payout was `3999999999999999999997` against principal `4000000000000000000000`.
The assertion allowed two underlying base units, but the difference was three.
The same isolated test failed identically on parent `c6fd7703` at that block.

This fixture makes two deposits. Half-up minting can lose at most one scaled share across those deposits.
The share transfer can leave one further scaled share on the handler.
The correct underlying tolerance is therefore `ceil(2 * index / 1e27)`, not a fixed two base units.
At the failing live index, this bound is three base units.

Change only this test assertion and its explanatory comment. Keep the exact measured share and cash checks.
Run the isolated regression at block 9443471 under both compiler profiles, then repeat the required gates.

```bash
# Load RSK_MAINNET_RPC_URL from .env without displaying its value.
set -a; . ./.env; set +a
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=DOC forge test --match-contract LendingShareWithdrawalTest --match-test test_fork_layerBankWithdrawalThenRedeemAtPool --fork-block-number 9443471 --fork-url "$RSK_MAINNET_RPC_URL"
FOUNDRY_PROFILE=deploy SWAP_TYPE=mocSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=DOC forge test --match-contract LendingShareWithdrawalTest --match-test test_fork_layerBankWithdrawalThenRedeemAtPool --fork-block-number 9443471 --fork-url "$RSK_MAINNET_RPC_URL"
```

This amendment changes no production lending code or protocol invariant.

## Parent update — 2026-11-26

The owner requested a rebase onto #203 commit `fa838c6e`.
The branch preserves its internal Dex floor bound and removed public getter.
Repeat the full gates for this combined tree because the parent update changes executable code.

## Invariant-gate amendment — 2026-11-26

The rebased `make check` found a second test-only defect in `invariant_userBalancesReasonable`.
Its two-call counterexample lowers the protocol minimum, then creates a schedule below the seven-day launch default.
The invariant compares that valid schedule against the launch default instead of the permanent one-day floor.
Existing schedules also remain valid when governance later raises the minimum.

Add a regression that creates a one-day schedule after lowering the minimum and checks it again after a later increase.
Assert the permanent one-day floor and whole-day periods in the invariant. Preserve the other balance assertions.
Replay the exact two-action pattern on the parent before accepting this correction.
This changes no contract or schedule behavior.

The same deterministic regression fails on parent `fa838c6e`: `86400 >= 604800` is false.
The corrected invariant and regression both pass with the failing seed:

```bash
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=layerbank EXPECTED_LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=DOC forge test --match-contract '^InvariantTest$' --match-test 'test_invariantAllowsSchedulesBelowTheLaunchMinimum|invariant_userBalancesReasonable' --fuzz-seed 0x77dc9eec8cfcdd8facc3f2a5e6fc2bccbf842cada378658f8546a8e20d2c6e46 -vv
```

## Verification results — combined tree on `fa838c6e`

- Targeted MoC suites: 51 passed, 0 failed.
- Targeted Dex suites: 78 passed, 0 failed.
- `make check` and `make check-deploy`: all six lanes pass, with 1031 / 1047 / 988 / 988 / 1003 / 1003 tests passed.
- Both profiles: 20 invariant tests pass, 0 failed.
- `make fork-layerbank`: 543 passed, 0 failed.
- Pinned fork regression at block 9443471: passes under both profiles.
- The deterministic schedule-period regression and the original failing seed pass.
- All four production files match the updated parent plus the approved name substitutions.
- The inventory contains 13 configuration setters and 15 `Set` events.
