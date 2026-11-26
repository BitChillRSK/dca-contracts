# R127 — Consistent configuration setter names

Status: **implemented; PR [#204](https://github.com/BitChillRSK/dca-contracts/pull/204) open** · Assigned: yes (2026-11-26) · Optional/further-review: no

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

- [x] Rename `updatePurchaseAmount` to `setPurchaseAmount`.
- [x] Rename `updatePurchasePeriod` to `setPurchasePeriod`.
- [x] Rename these events, preserving each contract prefix:
  - `PurchaseAmountUpdated` → `PurchaseAmountSet`.
  - `PurchasePeriodUpdated` → `PurchasePeriodSet`.
  - `MaxSchedulesPerTokenModified` → `MaxSchedulesPerTokenSet`.
  - `MinPurchasePeriodModified` → `MinPurchasePeriodSet`.
  - `AmountOutMinimumPercentUpdated` → `AmountOutMinimumPercentSet`.
  - `OracleUpdated` → `OracleSet`.
- [x] Preserve function arguments, event fields, indexing, validation, authorization, guards, and emission conditions.
- [x] Update matching tests, fuzz handlers, ABI inventories, and current operational references.
- [x] Check all first-party explicit configuration setters against the convention.
- [x] Record the convention in `AGENTS.md` and update its current function references.
- [x] Open or update affected consumer issues in the same turn as the PR.

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

- [x] The two new function names replace their old names without aliases.
- [x] The six new event names replace their old names.
- [x] Only `TokenBalanceUpdated` and `UserSharesUpdated` retain `Updated` in first-party events; no event retains `Modified`.
- [x] The production-source change consists only of approved identifier substitutions.
- [x] Required commands pass and affected consumers have linked follow-ups.
- [x] The PR preserves ancestry from #203 and README Status names the new PR.

## Reviewer checklist

- [x] Matches Scope and preserves protocol invariants.
- [x] Required checks pass and exact commands appear in the PR.
- [x] Extra paths are direct dependencies and appear in the PR description.
- [x] No unrelated changes, deployments, or merges.

## ABI / deploy / cutover impact

- ABI: two renamed DcaManager selectors and six renamed event signature hashes (`topic0`). Arguments and event fields are unchanged.
- Scripts: no deploy/config changes. New bytecode requires regenerated artifacts for the relaunch deployment.
- Cutover: front-end must update schedule-edit calls and ABIs. Monitoring must regenerate ABIs and review renamed event decoding.
- Check existing issues and actual consumer references before opening follow-ups. Update relevant documentation references when required.
- No broadcast or live addresses are authorized by this spec.

## Parent update — 2026-11-26

The owner requested a rebase onto #203 commit `fa838c6e`.
The branch preserves its internal Dex floor bound and removed public getter.
Repeat the full gates for this combined tree because the parent update changes executable code.

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

## Consumer follow-ups

- [front-end#64](https://github.com/BitChillRSK/front-end/issues/64): schedule-edit selectors, feedback cases, and generated ABIs.
- [bitchill-monitoring#59](https://github.com/BitChillRSK/bitchill-monitoring/issues/59): renamed event decoding and relaunch ABIs.
- [docs#16](https://github.com/BitChillRSK/docs/issues/16): relaunch signatures, events, and related documentation issues.
- No batching, getter, schedule model, token, or route changes require follow-ups in the other three consumers.

The scoped stack check for #204 reports zero ancestry gaps against parent `fa838c6e`.
Next unassigned: none.
