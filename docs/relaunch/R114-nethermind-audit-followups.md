# R114 — Nethermind AuditAgent report and lending purchase clamp

Status: **implemented — PR open for review** · Assigned: yes · Optional/further-review: no · Stack on: R113
([#179](https://github.com/BitChillRSK/dca-contracts/pull/179)) · PR: [#180](https://github.com/BitChillRSK/dca-contracts/pull/180)

## Objective

Preserve the supplied report. Resolve the batch failure in findings 1, 5, and 6 with one per-row
share clamp. Document accepted findings 2 and 3 and the operational mitigation for finding 4.

## Background

The automated report scans `docs/r113-audit-readiness-docs` at `284b3500`. It is evidence, not an
implementation instruction or a manual Nethermind engagement. BitChill authorized this rework on
2026-10-07 after independent review. Keep PR 180, its branch, its base, and its existing history.
R114 supersedes the R43/R110 decision to revert a lending batch on any share shortfall.

The initial reserve and buyer grouping design is withdrawn. The reserve changes loss handling:
a partial withdrawal can pay zero and the next purchase can revert despite sufficient shares for
that row. It also adds manager callbacks and schedule enumeration to the purchase path.
Review measurements used local mocks, the deploy profile, and Rootstock pricing: a steady-state
LayerBank tick with ten buyers cost 411,203 gas on R113, 491,278 with reserves and grouping, and
734,378 when each buyer held ten schedules. The review measured 412,131 for the clamp alone.
These are review measurements; the reproduced measurements below use the reviewer's probe with
separate gas/access tests.

## Open product decisions

**none.** Retain the one-dollar peg assumption, signer-bound native payments, and trusted-owner registry.
Require exact manager, token, and released-code checks before initial Safe acceptance or later assignment.

## Scope

- Restore principal withdrawals, interest withdrawals, quotes, and top-ups to R113 behavior.
- Remove the principal getter, manager callbacks, reserve, hash table, and buyer grouping.
- Convert and debit each purchase row separately. Preserve sequential per-row share events.
- If a row requests more shares than its buyer holds, use all that buyer's remaining shares.
  Replace that row's memory weight with `floor(shares × rate / scale)`.
  If that value is zero, revert `LendingHandler__ZeroShareValue` atomically.
- Compute fees and output allocation after the funding hook adjusts the memory weights.
  A healthy buyer retains its weight. No other buyer supplies the short row's shares.
- Keep schedule debits nominal, measured cash, exact share consumption, exact venue consumption,
  signer-bound withdrawals, and all-or-nothing batches.
- Retain the report unchanged, accepted-risk NatSpec, and assignment checks in the runbook.
- Second review follow-up (2026-10-08): pin the exactly covered row boundary, add gas/access assertions
  to the reviewer-derived harness, tighten funding comments and reviewer documents, and restore the
  five Krait candidate snapshots. Keep executable production code unchanged. Defer optional live-tail
  fork coverage and declaration cleanup; the supplied fork probe is not present in this checkout.

- Reachability follow-up (2026-10-08): retain the zero-value guard and rename its error
  to `LendingHandler__ZeroShareValue`, with the same arguments. Prove
  manager-path reachability with normal mint rounding and an index-loss scenario. Use `purchaseAmounts` as the mutable memory argument directly; remove the local copy.
  Use the completed direct-memory tests and the pre-rename gates. The human explicitly waived
  further tests after the error rename and removal of the local variable.

## Out of scope

- Principal reserves, buyer grouping, tolerance constants, changes to withdrawals or interest.
- Any other design for these findings, gas optimizations, dependency/compiler changes, deployment
  changes, broadcasts, live transactions, consumer implementations, and the next R-item.

## Files likely touched

- `src/LendingHandler.sol`, `src/interfaces/ILendingHandler.sol`
- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`, `src/interfaces/ITokenHandler.sol` (restore)
- `src/StablecoinSource.sol`, `src/idle/IdleHandler.sol`, `src/PurchaseRbtc.sol`, `src/PurchaseFees.sol`
- `src/interfaces/IPurchaseRbtc.sol`, `src/interfaces/IPurchaseUniswap.sol`
- `src/OperationsAdmin.sol`, `src/interfaces/IOperationsAdmin.sol`
- `test/ai-generated/audit/NethermindAuditFindings.t.sol`, `test/unit/LendingHandlerRedeemTest.t.sol`
- `test/unit/PurchaseRbtcTest.t.sol`, `test/unit/PurchaseUniswapMinOutTest.t.sol`
- `test/unit/BatchTailScheduleTest.t.sol`, `test/unit/FeeOnTransferDepositTest.t.sol`
- `test/ai-generated/unit/{EdgeCasesTest,layerbank/LayerBankDocHandlerMocTest,sovryn/SovrynDocHandlerMocTest,tropykus-legacy/TropykusDocHandlerMocTest}.t.sol`
- `test/ai-generated/unit/{layerbank/LayerBankHandlerTest,sovryn/SovrynHandlerTest,tropykus-legacy/TropykusHandlerTest}.t.sol`
- `test/ai-generated/fuzz/LendingPurchaseConservationInvariant.t.sol`
- `test/gas/R78FlatFeeFastPathGas.t.sol`, `test/gas/R87IdleLedgerRemovalGas.t.sol`
- `test/gas/R114PurchaseClampGas.t.sol`, `test/gas/reprice_r114.py` (reviewer-derived measurement evidence)
- `audits/2026-10-06-Nethermind/audit-agent-report.md` (unchanged), its `README.md`, `audits/README.md`
- `AUDIT_GUIDE.md`, `docs/PURCHASE_FEES.md`, `docs/relaunch/EXTERNAL_REWARDS.md` (restore)
- `docs/relaunch/CUTOVER_RUNBOOK.md`, `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`
- This spec and earlier documents reached by searches for the superseded tail-revert rule.

Expand only through imports, interfaces, inheritance, mocks, compiler errors, or failing tests.
Name additional paths in the PR body.

## Required tests

- Keep all NM1/NM5/NM6 scenarios. Assert successful purchases, nominal schedule debits, and equality
  between total virtual shares and external receipt shares. Keep NM2/NM3/NM4 boundary tests.
- Keep unchanged base tests, except funding-hook signatures, optimized-profile fixture corrections,
  and the seven old shortfall-revert tests explicitly assigned by the review.
  Any further base-test behavior change requires a report to BitChill before proceeding.
- Restore interest fuzz, sequential events, and exact row-sum tests. Remove getter fixtures and hash tests.
- Pin reduced-row funding beside a healthy buyer, exact credit allocation, `amountSpent`, and rollback
  when `minRbtcOut` is missed. Keep the pipeline-level reduced-funding fee test.
- Pin zero-share rollback, including a repeated buyer whose first row consumes all its shares.
- Fuzz that a reduced weight equals the debited shares' value and is below nominal.
- Fuzz that an exactly covered row keeps its nominal weight even when its shares are worth more.
  Verify that this test fails if the clamp condition changes from `>` to `>=`.
- Pin gas ceilings and access counts for the three cost cases under default and deploy profiles.
- After a 20% index loss, a funded purchase and partial withdrawal still pay the full request.
- Run `make check` under default and deploy profiles, `make fork-sovryn`, `make fork-layerbank`,
  formatting, and installed static analyzers. The final ABI difference is the zero-value error rename; external function ABIs remain unchanged.
- Measure steady-state lending and idle ticks under deploy. Read gas only without the state-diff
  recorder. Count storage/account accesses in separate tests and reprice on Rootstock's schedule.
- Preserve report SHA-256 `cdfdc50d03787e7fc0fdf861ee50ac5b78e352c998c3a22bc6bacb4e59abc4e5`.

## Success criteria

- One targeted fix resolves the positive-share batch failure in findings 1/5/6.
- Nominal principal may exceed share value by rounding dust. A zero-value row still reverts.
  After a lending loss, purchases continue while the buyer has shares that fund their rows.
- Every finding has a clear disposition and residual risk. Only the zero-value custom error changes in the ABI.
- Tests, forks, latest CI, artifact checks, and reproduced gas evidence pass.
- Focused new commits preserve the stack and history. PR 180 and all three consumer comments describe
  the final behavior. The separate Claude review remains BitChill's review step.

## Reviewer checklist

- [x] LendingHandler differs from R113 only in the funding hook.
- [x] No reserve, grouping, manager callback, or added getter remains.
- [x] Allocation and fees use funded weights. Exact-consumption invariants still hold.
- [x] Required tests pass unchanged except the assigned exceptions.
- [x] All six findings have current dispositions and consumer notes.
- [x] Both profiles, lending forks, ABI checks, and gas measurements are complete.

## ABI / deploy / cutover impact

The custom error changes from `LendingHandler__InsufficientShares(address,uint256,uint256)` to
`LendingHandler__ZeroShareValue(address,uint256,uint256)`. Function selectors, arguments, events,
schedule layout, and ERC-165 interface IDs remain unchanged. Consumers must update error decoding.
Share events remain one per row. `amountSpent` may be below nominal for a short lending row.
`ZeroShareValue` means no shares worth any stablecoin remain behind that row.
Interest quotes and withdrawals retain R113 behavior. Deploy the immutable contracts at cutover.

## Implementation and validation

The earlier gas tables and full gates below cover the calldata/local-copy implementation. The final
follow-up records the direct-memory experiment, the error rename, and the human's test waiver.

### Reproduced gas measurement (before the final memory-argument and error-name edits)

The harness adapts the independent reviewer's probe; it is not an independently designed measurement.
BitChill reran that harness on R113 and the revised tree. Both runs use solc 0.8.36, Cancun,
optimizer 200, the deploy profile, local protocol mocks, ten distinct buyers, and 25-token rows.
Each setup executes an initial tick, then advances one purchase period. This makes the measured tick
steady-state: cadence anchors and accumulated-rBTC balances are live.

`test_probe_gas` measures `gasleft()` without recording. `test_probe_accesses` records the same call
from the same setup state without measuring gas. Two micro-tests verify the Cancun cold/warm model.
The follow-up pins calls, SLOADs, write classes, logs, handler accesses, and clean Foundry gas ceilings.
Lending ceilings are 461,000 under default and 445,000 under deploy; idle ceilings are 313,000 and
302,000. These are compiler-profile regression ceilings, not production gas prices.
The repricer subtracts Cancun access charges and adds Rootstock charges: SLOAD 200, calls 700,
SET 20,000, and RESET/CLEAR 5,000. It preserves compute, memory, logs, and value-transfer costs.
Figures exclude transaction intrinsic gas and precede refunds; they are estimates from local mocks,
not measurements of a live Rootstock transaction.

| Steady-state tick | R113 Rootstock gas | Revised Rootstock gas | Delta | SLOAD before → after | Calls before → after | SSTORE before → after |
|-------------------|-------------------|-----------------------|-------|----------------------|----------------------|-----------------------|
| LayerBank, one schedule per buyer | 411,204 | 412,132 | +928 (+92.8/row) | 87 → 87 | 23 → 23 | 40 → 40 |
| LayerBank, ten schedules per buyer | 411,204 | 412,132 | +928 (+92.8/row) | 87 → 87 | 23 → 23 | 40 → 40 |
| Idle, one schedule per buyer | 271,566 | 272,641 | +1,075 (+107.5/row) | 59 → 59 | 12 → 12 | 26 → 26 |

For lending, the writes are two SET, two CLEAR, and 36 RESET on each tree; no same-value writes.
For idle, they are one SET, one CLEAR, and 24 RESET. Clear refunds are 30,000 and 15,000 respectively
and remain unchanged. Per handler, lending has 23 SLOAD and 21 SSTORE; idle has 13 SLOAD and 11 SSTORE.
Each tree calls the manager once, admin twice, and handler twice. The delta is compute/memory only.
Extra held schedules add no purchase-path access. The reproduced figures differ by one gas from
review lending figures; the measured delta agrees at 928 gas for ten rows.

Exact measurement commands, run from each tree with the same harness:

```sh
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=none STABLECOIN_TYPE=DOC FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R114PurchaseClampGas.t.sol -j 1 -vv
python3 test/gas/reprice_r114.py R113 /tmp/bitchill-r114-rework.wiDWFD/gas-base.log clamp /tmp/bitchill-r114-rework.wiDWFD/gas-clamp.log
```

### Regression and full-gate evidence (2026-10-07)

All nine NM1/NM5/NM6 scenarios fail against R113 with a share shortfall. They pass with the clamp.
The targeted default run passes 92 tests without failures or skips, including new loss/zero-value
regressions and measurement self-checks. A function-body comparison finds changes only in the seven
assigned base-test exceptions. Hook signatures and optimized-profile fixture corrections remain.

`make check` passes under the default profile: all eight unit lanes and all five invariant suites.
The deploy gate also passes all eight unit lanes and all five invariant suites. Each profile passes
24 invariant tests, zero failures, and zero skips, with 64 runs × 512 calls per stateful invariant.
The final targeted deploy run also passes 92 tests without failures or skips.
Latest-head CI is recorded in PR 180 after push.

| Unit lane | Passed under each profile | Route and benchmark skips |
|-----------|---------------------------|---------------------------|
| MoC / idle / DOC | 999 | 34 |
| MoC / LayerBank / DOC | 1,007 | 26 |
| MoC / Sovryn / DOC | 1,021 | 12 |
| DEX / idle / USDRIF | 958 | 45 |
| DEX / idle / USDT0 | 958 | 45 |
| DEX / Sovryn / USDRIF | 600 | 52 |
| DEX / LayerBank / USDRIF | 963 | 40 |
| DEX / LayerBank / USDT0 | 963 | 40 |

Both lending fork gates pass 491 tests, zero failures, and 39 route/benchmark skips each.
No required base test needs a further behavior change. Comments in `RbtcPurchaseTest` and the Sovryn
shortfall test now describe the current rule without changing their assertions.

Exact full-gate commands:

```sh
make check
FOUNDRY_PROFILE=deploy FOUNDRY_OUT=/tmp/bitchill-r114-rework.wiDWFD/deploy-out FOUNDRY_CACHE_PATH=/tmp/bitchill-r114-rework.wiDWFD/deploy-cache make check
make fork-sovryn
make fork-layerbank
```

All 42 first-party ABIs match R113 under both profiles. All ten concrete runtimes fit 24,576 bytes
and have no EOF prefix. Formatting and authored-file whitespace checks pass.
`make slither` reports 83 results and exits non-zero; `make aderyn` completes with two High and seven
Low categories. Findings remain triaged in R73; neither analyzer has a clean-zero claim.

Consumer corrections update the existing comments:
[front-end#11](https://github.com/BitChillRSK/front-end/issues/11#issuecomment-6045133192),
[bitchill-monitoring#10](https://github.com/BitChillRSK/bitchill-monitoring/issues/10#issuecomment-6045133656),
[swapper-bot#15](https://github.com/BitChillRSK/swapper-bot/issues/15#issuecomment-6045134182).
There is no new getter, interest or withdrawal change, or event cardinality change.
`amountSpent` can fall below nominal on a short lending row; `ZeroShareValue` identifies zero value.


### Second review follow-up (2026-10-08)

The exactly covered row fuzz keeps nominal weight when `ceil(nominal × scale / rate)` equals the
buyer's shares. A temporary `>` → `>=` mutation fails that test. The gas harness now asserts clean
Foundry gas ceilings and exact access counts under both profiles; an added `balanceOf` call fails
its call and SLOAD assertions. Both mutations were restored before the final builds.

Both comment rewrites are applied. Reviewer documents describe current behavior without withdrawn-design
rebuttals; the fee document contains fee facts. The five Krait candidate files match R113 exactly.
The measurement harness is explicitly reviewer-derived. Declaration and private-parameter cleanup
remain deferred. Existing fork gates do not spend a schedule's final tail through the live market;
the supplied `scratchpad/probe/R114ForkTail.t.sol` is absent from this checkout.

The final targeted run passes 93 tests with no failures or skips under each profile. The new boundary
fuzz runs 1,000 cases per profile. `forge build` and the deploy-profile build pass. All 42 first-party
ABIs and metadata-stripped creation/runtime bytecodes match `086973f4` under both profiles. Gas and
access counts remain unchanged; the earlier production-code fork evidence stands. Formatting and
whitespace checks pass. PR 180 records the new CI run after push.

### Memory parameter and zero-value reachability follow-up (2026-10-08)

The external implementation may declare `purchaseAmounts` as `memory` while its interface declares
`calldata`. External ABI encoding does not include the data location. The decoder then supplies the
mutable array to the funding hook. A separate calldata-to-memory copy also works. The final implementation declares `purchaseAmounts` in memory and passes it directly to funding,
fees, and allocation. The funding hook clamps that array in place. There is no extra local array
variable. This direct-memory form compiles and passes all 19 manager-path audit tests under both
default and deploy profiles in the completed experiment, before the error rename. That experiment
retains all 42 first-party ABIs; the subsequent custom-error rename is the only final ABI change. Solidity documents this
[external-function data-location rule](https://www.soliditylang.org/blog/2022/05/17/data-location-inheritance-bug/).

The manager checks nominal schedule balances, cadence, pause state, and route identity before calling
the handler. It does not check the buyer's share value. A lending loss can leave nominal schedules
behind an exhausted position. The manager-path rollback tests now use normal half-up mint rounding:
60-token and 40-token schedules at index `2 RAY` mint 50 shares in total. An index loss to `1 RAY`
leaves 50 tokens of value. The 60-token row consumes those 50 shares; the 40-token row then reaches
the funding hook with zero shares. This happens within one batch or on a later purchase. The test
models a loss boundary, not current live LayerBank index behavior.

Under LayerBank's current `index >= RAY` assumption, a positive scaled share is worth at least one
stablecoin wei. This does not rule out zero remaining shares. Other lending adapters can also produce
positive shares whose rounded-down value is zero. The guard covers both cases and retains
`LendingHandler__ZeroShareValue`. The name describes this guard's narrower condition.
The rename changes the error selector without changing the guard's behavior.

Removing the zero-value guard in a temporary mutation makes
`test_repeatedBuyerEmptySecondRowRollsBackSchedulesAndVenue` fail with `next call did not revert as
expected`: the batch succeeds and clears the unfunded nominal row. The original guard is restored.
This is a loss-mode reachability proof, not evidence that healthy live LayerBank operation can reach
the guard. A smaller payout caused only by an exit fee is a different case; it does not lower the
exchange rate in this test.

Before the error rename, the calldata/local-copy tree passes `make check` under both profiles: all eight unit lanes and all 24 invariant
tests (64 runs × 512 calls) pass. Both lending forks pass 492 tests with no failures and 39 route or
benchmark skips each. All 42 first-party ABIs and metadata-stripped creation/runtime bytecodes match
parent `838516e3` under both profiles. Formatting, whitespace, and changed-document links pass.
The original report and all five Krait snapshots remain unchanged. The final tree changes the custom-error selector and uses the tested direct-memory parameter form.
The human explicitly requested no further tests. Newly started reruns were interrupted. The earlier
results do not claim to test the final renamed error. Consumer comments record the new selector.

Exact pre-rename validation commands:

```sh
make check
FOUNDRY_PROFILE=deploy FOUNDRY_OUT=/var/folders/q9/4vzw5rqx0n19_0tyv8fw9khc0000gn/T/bitchill-r114-reachability.7sa7j1kp/final-deploy-out FOUNDRY_CACHE_PATH=/var/folders/q9/4vzw5rqx0n19_0tyv8fw9khc0000gn/T/bitchill-r114-reachability.7sa7j1kp/final-deploy-cache make check
make fork-sovryn
make fork-layerbank
forge fmt --check
```

### Rework commits

- `e8b7d6ad`: assign the narrowed spec before implementation.
- `aa958db`: replace reserves/grouping with the per-row clamp; restore withdrawals, quotes, events,
  original accounting tests, and manager fixtures; add successful and rollback regressions.
- `565460c`: retain reproducible gas/access probes and Rootstock repricing.
- Follow-up documents record the final risks, superseded decisions, validation, and consumer corrections.

The original report remains byte-identical with its recorded SHA-256. No work was broadcast,
no live transaction was sent, and dependency/compiler pins remain unchanged.
The next step is BitChill's independent review of PR 180. After review and merge, follow the cutover runbook.
