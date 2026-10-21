# R117 — Pashov triage and mitigations

Status: **implemented; local validation passed; owner approved; consumer issues updated** · Assigned: yes · Optional/further-review: no

## Objective

Implement the selected Pashov mitigations, regression tests, and decision records in PR #184, stacked on #183.
Keep the original generated reports unchanged.

## Background

[The disposition register](./PASHOV_TRIAGE_DECISIONS.md) records the report and the owner's decisions.
On 2026-10-20, the owner requested one PR containing the mitigations, decisions, and documentation updates.
This supersedes the initial documentation-only boundary for #184.
On 2026-10-21, the owner approved PR #184 and authorised publication of the five consumer issue updates.
The quoted-rate check stays in place. Protected purchase windows remain optional.

## Open product decisions

None for the selected implementation:

- Deposits and schedule creation remain open during protected windows.
- Protect the quoted execution rate against changes in actual funded batch input.
- Omit all Sovryn integration from the initial deployment. Retain its source and test support for a possible future integration.
- Exclude the alternate USDRIF → USDT → WRBTC launch path. Retain the primary path through USDT0.
- Treat L01 as intended scheduling behaviour. Treat L08 as informational and correct the guide; do not change cadence rules.

Other unverified leads remain explicitly open in the register. Do not silently accept new residual risks.

## Scope

- [x] Validate F1 against the full purchase pipeline and add regression cases before changing its protection.
- [x] Associate each supplied output minimum with its quoted stablecoin input. Scale the execution minimum using actual retrieved input.
- [x] Apply the same scaled minimum to venue execution and measured-output verification. Use full-precision arithmetic with conservative rounding.
- [x] Specify zero-quote behaviour, fee basis, and token base units. Keep batch rows as bare schedule IDs.
- [x] Omit Sovryn handlers and assignments from the final launch deployment.
- [x] Omit the alternate USDRIF path from launch permissions and assert both deployment exclusions.
- [x] Correct the L08 guide wording and update launch, ABI, and operational documentation affected by these changes.
- [x] Update SP-64 to test the selected execution-rate guarantee. Correct GL-15 and exercise SP-72's intermediate path.
- [x] Update the decision register with verified results and remaining conditions. Preserve generated report provenance.
- [x] Open or update affected consumer issues with exact ABI and launch-map changes.

## Out of scope

- Deployment broadcasts or changes to live contracts.
- Sovryn-specific fixes for an integration excluded from the initial release.
- Unrelated refactors, wallet-wide cooldowns, new reentrancy policy, or changes to exact lending-share consumption.
- Sibling consumer implementations; record their required changes in linked issues.
- Automatically converting all leads into vulnerabilities or implementing optional hardening without supporting evidence.

## Files likely touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`.
- `src/PurchaseRbtc.sol`, `src/interfaces/IPurchaseRbtc.sol`, and directly affected handler interfaces or overrides.
- `script/DeployFinal.s.sol` and its direct deployment dependencies.
- `test/unit/BatchMinRbtcOutTest.t.sol`, `test/unit/DcaManagerBatchHandlersTest.t.sol`, `test/unit/ProtectedPurchaseWindowTest.t.sol`.
- `test/unit/deployment/LiveDeployPathTest.t.sol` and direct launch-deployment tests.
- Existing tests, mocks, and helpers that construct `Batch` or call the changed purchase ABI.
- `test/fizz/Properties.sol`, `test/fizz/FoundryTester.sol`, and their directly affected handlers and simulator.
- `AGENTS.md`, `AUDIT_GUIDE.md`, `ADDRESSES.md`, and launch/cutover documentation affected by the selected controls.
- `docs/relaunch/R117-pashov-mitigations.md`, `docs/relaunch/PASHOV_TRIAGE_DECISIONS.md`, `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`.
- `audits/2026-10-13-Pashov-Skills/README.md` for implementation status and evidence links.

Follow direct imports, callers, compilation errors, and failing tests. List expanded paths in the PR description.

## Required tests

- Targeted F1 regressions: changed nominal amounts, short lending rows, deposits and creation during a window, and unchanged input.
- Exercise conservative rounding, invalid quote input, zero caller minimum, 6/18 decimal tokens, and fee accounting.
- Deployment tests: Sovryn absent; the alternate USDRIF path disallowed; primary paths and enabled handlers preserved.
- Fizz replay and coverage tests for SP-64, GL-15, and SP-72 under default and deploy profiles.
- `make check` and `make check-deploy`.
- `make fork-sovryn` and `make fork-layerbank` before pushing executable changes. Preserve Sovryn adapter tests despite launch exclusion.
- Relevant path fork tests if the allowlist deployment changes affect their expectations.

## Success criteria

- [x] A changed actual input cannot weaken the quoted execution-rate guarantee.
- [x] Deposits and creation remain available inside protected windows.
- [x] Launch deployment excludes Sovryn and the selected alternate path.
- [x] The original report hash remains unchanged.
- [x] Selected regression tests, both profile gates, and required forks pass.
- [x] Decision and deployment documents match the final code and distinguish remaining open leads.
- [x] PR description and affected consumer issues describe the final ABI and launch map.

## Reviewer checklist

- [x] No optional hardening or unrelated refactors.
- [x] Bare schedule-ID rows and exact measured accounting remain intact.
- [x] Required tests cover input growth and conservative scaling, not only expected reverts.
- [x] Original reports remain unchanged.
- [x] Every path beyond this initial list is justified in the PR.

## ABI / deploy / cutover impact

- ABI: `Batch` appends `uint256 quotedStablecoinIn` after `minRbtcOut`.
  Manager selectors become `batchBuyRbtc((uint64[],address,uint256,uint256,uint256))` and
  `batchBuyRbtcAcrossHandlers((uint64[],address,uint256,uint256,uint256)[])`.
  Handler calls become `batchBuyRbtc(address[],uint64[],uint256[],uint256,uint256)`.
  A positive output minimum with zero quoted input reverts `PurchaseRbtc__ZeroQuotedStablecoinInput()`.
  The minimum is gross rBTC/WRBTC wei for quoted actual gross input in token base units.
  Execution checks `ceil(quotedMinimum × actualRetrievedInput / quotedStablecoinIn)` before BitChill fees.
  Events, schedule fields, and user mutation signatures remain unchanged.
- Scripts: final launch deployment omits Sovryn and the alternate USDRIF path. No broadcast.
- Cutover: update swapper ABI/quotes and affected consumer route maps or error decoders through linked issues.

## Consumer follow-up status

The owner authorised publication on 2026-10-21. The first updates were comments on the five existing relaunch issues.
Those issues already have related implementation PRs, so R117 now has separate follow-up issues for the additional work.
Each dedicated issue requires a new follow-up PR above its current relaunch stack and retains an unchecked completion gate.
The older issues point to the new gates. Merging their existing PRs does not complete R117.
The contracts PR does not implement sibling repositories. Consumer implementation remains a release requirement.

| Consumer | R117 follow-up issue | Current PR base | Required R117 update |
| --- | --- | --- | --- |
| swapper-bot | [#23](https://github.com/BitChillRSK/swapper-bot/issues/23) | [#21](https://github.com/BitChillRSK/swapper-bot/pull/21) | Regenerate manager/handler ABIs; retain the existing quote input with its minimum; send the new field; classify the zero-quote error; use six launch handlers; check per-schedule cycle execution. |
| front-end | [#42](https://github.com/BitChillRSK/front-end/issues/42) | [#40](https://github.com/BitChillRSK/front-end/pull/40) | Regenerate ABIs; omit Sovryn creation and live-yield choices on the new deployment; preserve historical positions. |
| bitchill-monitoring | [#49](https://github.com/BitChillRSK/bitchill-monitoring/issues/49) | [#46](https://github.com/BitChillRSK/bitchill-monitoring/pull/46) | Watch six new handlers; regenerate error ABIs; interpret the minimum error's second argument as the scaled threshold. Events remain unchanged. |
| data-api | [#25](https://github.com/BitChillRSK/data-api/issues/25) | [#23](https://github.com/BitChillRSK/data-api/pull/23) | Serve the new six-handler map; omit Sovryn availability; preserve deployment-specific historical labels. Schedule getters remain unchanged. |
| metrics-dashboard | [#17](https://github.com/BitChillRSK/metrics-dashboard/issues/17) | [#15](https://github.com/BitChillRSK/metrics-dashboard/pull/15) | Consume the new deployment map; omit new-deployment Sovryn availability; preserve historical labels. |

Use the subsequent tip if a consumer stack advances. Each issue records its checked base commit and the original approved requirements.
Already compatible paths need configuration or verification evidence; avoid unnecessary code changes.

The bot update targets its relaunch stack, not the legacy local branch.
The stack already sums purchase amounts and obtains DEX quotes; R117 retains that input alongside its minimum.
This argument needs no new database field or additional database read by itself.
Splitting a batch does not mandate a new quote: a consistent original input/minimum pair preserves its rate limit.
Fresh quotes can improve accuracy when trade size or pool state changes.

## Implementation evidence

- The pre-fix purchase tests reproduced diluted protection after input growth and rejection after input reduction.
- Real LayerBank tests cover a short row after a simulated loss. A deposit or new schedule restores funding inside a protected window.
- Both cases keep the quoted row's nominal amount unchanged. Both verify the minimum error, rollback, and an acceptable successful fill.
- Coverage includes unchanged input, zero minimum, invalid quote input, conservative rounding, overflowing intermediate multiplication, and 6/18-decimal base units.
- Deployment tests construct the six-handler stack and verify both USDRIF path exclusions.
- All nine Fizz replay/smoke tests pass. The mock fixture starts before deployment, including when run inside fork checks.
- A separate read-only review of the mitigation diff found no production defect. Its coverage requests are addressed.
- `make check`, `make check-deploy`, `make fork-sovryn`, `make fork-layerbank`, and `make fork-dex-path` pass on the final executable tree.
- No extended Medusa or Echidna campaign was run for R117. The original reports remain historical evidence.

## Final local validation

| Command | Result |
| --- | --- |
| `make check` | All eight unit lanes pass; all 24 dedicated invariant tests pass. |
| `make fork-sovryn` | 508 passed, 0 failed, 42 skipped. Retained adapter coverage; no launch integration. |
| `make fork-layerbank` | 508 passed, 0 failed, 42 skipped. |
| `make fork-dex-path` | Both idle and LayerBank: 16 passed, 0 failed, 1 skipped per lane. |
| `FOUNDRY_OUT=/tmp/r117-deploy-out FOUNDRY_CACHE_PATH=/tmp/r117-deploy-cache make check-deploy` | All eight unit lanes pass; all 24 dedicated invariant tests pass. |

The temporary output/cache paths isolate compiler profiles. Repository compiler settings and test lanes remain unchanged.
The original scan hash remains `33e3aa21193300b7c8ee0d026686d43f0f8d1916267ecdb22502a1150213c918`.
The owner approved the selected implementation. Consumer issue publication is complete.
Consumer implementations and the register's remaining verification conditions stay open before release. No broadcast occurred.
