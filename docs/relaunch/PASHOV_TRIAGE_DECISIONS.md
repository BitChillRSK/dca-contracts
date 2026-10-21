# Pashov results — dispositions and proposals for R117

Status: **selected implementation owner-approved and locally validated; consumer issues updated; verification gates remain open**. Updated on 2026-10-21.

This record accompanies [R117 implementation](./R117-pashov-mitigations.md) in PR #184. It records decisions, implementation evidence, and unresolved conditions.
The owner approved PR #184 and its consumer issue publication on 2026-10-21.
Items with unmet evidence or verification conditions remain open under their stated closure requirements.

## Evidence and limits

Reviewed documents at PR [#183](https://github.com/BitChillRSK/dca-contracts/pull/183), head
`52d5eacbe581e549d34b37b15bce767ceb422f57`:

- [Original scan report](../../audits/2026-10-13-Pashov-Skills/dca-contracts-pashov-ai-audit-report-20261013-135445.md).
- [Provenance and triage input](../../audits/2026-10-13-Pashov-Skills/README.md).
- [Fizz report](../../fizz_data/report.md), including its replay results and coverage limits.

Repository instructions and the relaunch status were read for workflow and existing policy.
Initial triage used only those reports. The selected implementation now inspects the purchase pipeline and deployment script and adds targeted tests.
Unverified report claims retain their conditional status. No new live-market conclusions follow from the implementation tests.
Liquidity and gas-price observations are historical snapshots, not current launch checks.

The scan has two findings and 28 leads. Its score of 75 measures confidence, not severity.
An incomplete exploit path is neither a confirmed exploit nor proof of a false positive.
The scan's lead category also contains withdrawal failures and trusted-role risks.
Therefore, a lead must not automatically become an accepted minor risk.

Fizz confirms a one-share change in a protected batch. It does not confirm material loss to another buyer.
No SHOULD-HOLD property failed in its short campaign. This does not establish production safety.
X-Ray supplies a map and candidate invariants, not another list of confirmed findings.

## Proposed decision groups

| Group | Recommended disposition | Closure requirement |
| --- | --- | --- |
| M | Mitigate before the affected feature or route opens | Demonstrate the reported condition, implement the selected control, and add a regression test. |
| X | Exclude the integration or path from the initial release | Verify that the launch deployment omits the selected handlers, route assignments, or path permissions. Retain unresolved risks for a future review. |
| O | Apply operational controls; acknowledge the residual risk | Identify the responsible component and verify its behaviour. Record the remaining impact. |
| A | Acknowledge expected behaviour or a dependency assumption | Confirm the stated scope. Distinguish existing policy from new acceptance. |
| N | Reject the security-finding interpretation | Identify the intended feature or missing security requirement. Preserve any accurate technical observation without treating it as an accepted vulnerability. |
| V | Verify before deciding | Keep the question open until evidence supports mitigation or acceptance. |
| H | Optional hardening | No current supported exploit is reported. Revisit before expanding supported dependencies. |
| D | Correct documentation or the test harness | Preserve intended contract behaviour unless a separate product decision changes it. |

These groups are dispositions, not audit severities. Multiple report items can share one control.
Existing acceptance is attributed to the report or repository policy; it is not a new owner decision.

## Findings

| ID | Report item | Proposal | Reason and closure evidence |
| --- | --- | --- | --- |
| F1 | Batch `minRbtcOut` does not scale with the input spent | M — policy confirmed | Keep deposits and creation open; protect the quoted execution rate against actual input changes. The owner confirmed this policy on 2026-10-20. Implemented through `quotedStablecoinIn` and an input-scaled minimum; validation is recorded below. The material attack remains conditional; SP-64 demonstrates only dust. |
| F2 | `DeployFinal` assigns a Sovryn DOC market with no free DOC | X — exclusion confirmed | The owner excluded all Sovryn integration from the initial release on 2026-10-20. Omit Sovryn handler deployment and route assignments. Implemented in this PR; validation is recorded below. This avoids new release exposure; it does not fix Sovryn liquidity or accept that risk. L28 has the same disposition. |

### F1 — confirmed policy and implementation requirements

**Confirmed policy: keep deposits and schedule creation open, and protect the quoted execution rate.**
The owner selected this policy on 2026-10-20. It preserves the current window policy.
The selected protection must account for actual execution input. The contract ABI and the required bot integration are specified in R117; consumer implementation remains outside this repository.

The reports describe two different situations:

1. Purchases without a protected window can see nominal purchase amounts change after a quote.
2. Inside a window, nominal rows stay fixed, but a deposit or new schedule can increase a short lending row's funding.

Blocking only `depositToken` is incomplete because creation also adds lending shares.
Blocking both calls addresses the reported window case, but purchases still need no window.
It therefore does not, alone, resolve the entire finding.

The batch now carries `minRbtcOut` and `quotedStablecoinIn`.
The latter is the actual gross stablecoin input used for the quote, in token base units.
After retrieving funds, `PurchaseRbtc` computes `ceil(minRbtcOut × actualInput / quotedStablecoinIn)` with full-precision arithmetic.
The same scaled minimum reaches the venue and checks measured gross output before purchase fees.
A nonzero minimum with zero quoted input reverts. Zero minimum retains the existing opt-out behaviour.
No token decimal conversion or per-row quote field is required.

A cap based only on nominal row amounts would miss funding changes in short rows.
The selected ratio applies after retrieval, so it covers both nominal amount edits and changed lending funding.

Regression coverage:

- An amount edit outside a window cannot weaken the quoted execution rate.
- A deposit and a new schedule inside a window cannot weaken it.
- A material short-row case after a simulated lending loss exercises the same control.
- Normal full rows, multiple rows, partial funding, and token decimals retain the selected semantics.
- The bot quotes with the same gross/net output basis as the contract.

The original SP-64 demanded exact input stability. The revised property checks the selected execution-rate guarantee.
The original dust sequence now reverts when upward rounding requires one additional output wei.
Its regression test verifies that the sequence exercises quote protection.
Successful purchases must satisfy the exact rate; a one-wei shortfall does not receive an execution tolerance.
SP-65 permits that rounding-induced refusal in its model-price liveness assertion.

### F2 — confirmed initial release scope

**Confirmed policy: the initial new BitChill release will not integrate Sovryn.**
The owner selected exclusion on 2026-10-20 and cited uncertainty surrounding Sovryn.
This applies to all Sovryn routes, not only DOC or a temporary deposit pause.
The initial deployment must omit Sovryn handlers and their route assignments.
`DeployFinal` now deploys six handlers and leaves Sovryn route 2 unregistered and unassigned.

A Sovryn handler can be deployed later if the owner decides to integrate Sovryn.
Before that integration, review current liquidity, remainder burns, exit-fee rounding, and adapter compatibility.
Keep L15, L18's Sovryn-specific case, L28, and the Sovryn-specific Fizz questions in that review.
They do not block an initial release that excludes Sovryn and has no exposure to it.
Shared lending logic and enabled integrations retain their own review requirements.

Exclusion does not repair an old Sovryn position or release funds from an earlier deployment.
No deletion of Sovryn source or tests follows from this decision.

### L09 — confirmed alternate-path exclusion

**Confirmed policy: exclude the alternate USDRIF → USDT → WRBTC path from the launch allowlist.**
The owner selected this policy on 2026-10-20. The report observed an empty pool on that path.
The observation is historical; this decision does not assert that the pool is still empty.
`DeployFinal` now omits the alternate path configuration and permission calls. Deployment tests check both USDRIF handlers.

This decision retains the primary USDRIF → USDT0 → WRBTC path described in the report.
It does not exclude USDRIF or USDT0 from launch.
Before adding the alternate path later, review current liquidity, execution quality, and quote protection.
Implemented in this PR; validation is recorded below. Exclusion does not fix the pool or accept its execution risk.

### L01/L08 — intended behaviour and bot execution context

The owner clarified that multiple schedules are allowed. A user need not delete a schedule to create another one.
The owner also stated that the bot will run weekly at launch and at most once daily under the intended operating policy.
These are owner-supplied requirements. The implementation review identified consumer integration points but did not verify the complete bot execution policy.

**L01: recommend closure as intended behaviour, not an accepted security risk.**
There is no stated wallet-wide purchase cooldown for the creation/deletion sequence to bypass.
Independent schedules can already purchase in one bot cycle. The report establishes no additional security failure from recreation.
Do not add a wallet-wide restriction or contract fix for this lead.

**L08: retain the technical observation as informational and correct the guide.**
The same-day sequence needs several successful purchases of the same schedule, interleaved with period reductions.
One successful purchase per schedule per bot cycle prevents that sequence under the declared daily/weekly policy.
A weekly cron alone does not establish that condition: one job can send several transactions or rebuild batches.
Do not assume that one job, one transaction, and one successful purchase per schedule mean the same thing.

When implementing bot follow-ups, verify that rescans, retries, and parallel batches cannot repeat a successfully purchased schedule in the same cycle.
Key that check by schedule, not by wallet, because several independent schedules are legitimate.
This is a proposed execution-policy check; it is not a claim that the current bot has a defect.

No contract change is recommended for L08 from this report alone, even if the bot frequency later changes.
The user deliberately edits their own schedule and funds each purchase; the report shows no loss to another user.
The missing security harm matters independently of the launch cron schedule.
Keep the accurate statement that period reductions can make a schedule eligible again.
Replace the guide's categorical “one extra purchase” claim with the eligibility behaviour and its swapper-execution dependency.
Do not describe multiple same-day executions as impossible on-chain.

## Complete lead register

L01–L28 identify leads in their original report order. They are local reference IDs, not severity scores.

| ID | Report item | Proposal | Reason and next action |
| --- | --- | --- | --- |
| L01 | Delete and create permit another purchase that day | N — intended behaviour | Multiple schedules are explicitly allowed. Another schedule can already purchase in the same cycle without deletion. No wallet-wide cooldown is required or bypassed. Recommend closure as not a security vulnerability, with no contract fix or risk acceptance. |
| L02 | Swapper opens protected windows without a gap | A — existing trust policy, material impact | The report and invariant 10 already accept this power. A compromised swapper can repeatedly block stablecoin exits. Record owner revocation, its response dependency, and the remaining active window. Do not label this minor because each window is short. |
| L03 | Pool moves between activation and quotation | O — bot mitigation | Apply a quote-quality limit against a reliable independent reference and expected price impact. Reject unacceptable quotes even when they clear the contract's broad oracle floor. Profitability of the reported attack is unproved; residual MEV remains. |
| L04 | Later handler batches pay earlier batches' price impact | O + A | Sequential swaps naturally affect later fills. Simulate the complete ordered bundle and check every quote. Document separate handler execution prices. Rotation or aggregation is an optional fairness change, not a required contract fix. |
| L05 | Creation inside the window grows a short lending row | M — duplicate of F1 | Cover creation as well as deposits in F1's regression cases. This is not another independent loss finding. |
| L06 | `depositToken` stores a balance read before the handler call | H | No listed token or market callback reaches the swapper in the report. Prefer checks-effects-interactions if this path changes. A theoretical callback is not proof of a current exploit. |
| L07 | Deposit inside the window adds shares to a short row | M — duplicate of F1 | Cover deposits in F1. The demonstrated no-loss case is rounding dust. |
| L08 | Period reductions permit several purchases on one day | D — informational; guide corrected | The guide now describes repeated eligibility rather than a categorical one-extra-purchase limit. The sequence requires repeat execution of the same schedule after edits. The owner states weekly launch execution, at most daily under the intended policy. Verify one success per schedule per cycle rather than relying on cron frequency alone. No loss to another user is reported. |
| L09 | Allowlisted USDRIF path uses a pool reported empty | X — exclusion confirmed | The owner excluded USDRIF → USDT → WRBTC from the launch allowlist on 2026-10-20. Retain the primary USDRIF → USDT0 → WRBTC path. Both USDRIF deployment tests verify that the alternate permission is absent. Any future addition needs a fresh review. |
| L10 | LayerBank cash shortage blocks exits and bundled purchases | O + A — material dependency risk | External illiquidity is already accepted according to the report. Verify reserve checks, retry behaviour, and exclusion of a failing route from unrelated bundles. Monitoring cannot guarantee an exit or prevent a borrower from taking cash. |
| L11 | LayerBank changes to round-up share burns | A — conditional upgrade risk | No current rounding mismatch is reported. Preserve exact consumption checks. Record upgrade monitoring, fork probes, replacement planning, and documented retry options. A replacement alone does not guarantee exit from an incompatible old handler. |
| L12 | A row without shares reverts every batch containing it | O + V — lending-loss case | Verify bot exclusion and recovery behaviour for funded-looking rows with zero backing. The report describes loss-dependent availability failures, not demonstrated theft. Share the review with L16; do not reopen previously declined reserve/grouping designs by default. |
| L13 | Clamped lending input grows after the snapshot | M — duplicate of F1 | Same funding change as L05/L07. Verify the material loss-dependent case separately from SP-64's dust case. |
| L14 | Lending deposit does not prove full market consumption | H | No supported market partially consumes a deposit in the report. Record full consumption as a dependency assumption. Consider a measured-input check before adding a market with different deposit behaviour. |
| L15 | Sovryn burns a small remainder and violates exact consumption | X — future integration condition | Sovryn is excluded from the initial release. The reported full-exit failure remains unresolved. Before a future integration, preserve exact accounting and validate a mitigation, including the proposed unowned seed if selected. See below. |
| L16 | Withdrawal after loss consumes backing of other schedules | O + V — same user, loss-dependent | The reported backing is shared across one user's schedules. This does not establish cross-user theft. Reproduce the modest-loss case, state the allocation policy, and verify exclusion/recovery for the remaining rows. External-loss acceptance does not automatically settle internal liveness. |
| L17 | Zero-valued withdrawal still transfers zero tokens | H — minor compatibility | The listed tokens accept zero transfers. Skipping the transfer is reasonable optional hardening. No current withdrawal failure follows from the supported-token case in the report. |
| L18 | Zero-valued interest redeem reverts combined withdrawal | X/V — Sovryn case deferred | The reported Sovryn fee-rounding premise remains unverified. Review it before a future Sovryn integration. If another enabled market can produce the same zero-valued redeem, assess that shared-code case separately. Do not mark the underlying behaviour fixed. |
| L19 | Money on Chain caps transaction gas price | O + A — dependency constraint | Read the current cap when building transactions. Separate MoC and Dex calls when needed and retry unsupported MoC execution. The historical 16% headroom is not a current limit. No contract redesign is recommended from this report alone. |
| L20 | Money on Chain redeems only available free DOC | O + A — dependency constraint | Check available capacity, size batches, and retry when capacity changes. Keep the exact-input revert. Do not accept a partial spend to force a purchase through. |
| L21 | MoC has no independent contract price floor | V + O | Establish MoC's output, fee, and oracle guarantees. Use a meaningful quote-derived minimum meanwhile. Zero minimum plus a trusted redemption venue is an assumption, not a demonstrated manipulation exploit. Add an independent floor only if the evidence requires it. |
| L22 | One large row worsens every row's average price | O + A — execution policy | Apply batch-size and price-impact limits in the bot. Model an excessive row and verify its handling. Shared execution price is expected; the broad contract floor is not a target execution quality. No profitable attacker strategy was established. |
| L23 | Uniswap floor ignores oracle publication age | V — price-protection gate | Verify the live oracle's `isValid` and publication rules. If validity already bounds age adequately, document that dependency. Otherwise add a suitable freshness check. Check positive-price behaviour. Do not invent an age threshold without the feed's specification. |
| L24 | Stablecoin floor assumes a dollar peg | A — explicit economic assumption | The report identifies prior acceptance of the peg assumption. Record the added downside: purchases can stop during a depeg while withdrawals remain available. Prefer a safe stop over an automatic floor reduction. A lower floor needs a deliberate risk decision. |
| L25 | Measured WRBTC is not checked against the oracle floor | H | The router enforces its output minimum; no divergence from measured receipt is shown. A second measured-output check is reasonable defence in depth. Do not classify a standard trusted router as compromised without evidence. |
| L26 | Swapper activates a path before owner revocation | O + A — existing procedure | The report identifies the Safe multisend or revoke-swapper-first response. Verify that procedure operationally. No additional loss beyond the revocation delay is shown. |
| L27 | Swapper changes path after quotation | A + O — role and quote assumption | The quote-derived minimum still binds. Document coordination between authorised callers. Avoid execution with a weak minimum and an unreviewed alternate path. A path commitment is optional unless multiple independent swappers require it. |
| L28 | Sovryn liquidity shortage blocks exits | X/F2 — duplicate | Sovryn is excluded from the initial release. Reassess liquidity before any future integration. Exclusion does not release existing funds or guarantee future exits. |

### L15 — do not weaken the exact-burn invariant

This work is deferred until a future Sovryn integration. It is not an initial release requirement while Sovryn remains excluded.

The companion proposes at least 11 unowned iToken wei in each Sovryn handler.
Treat that as a candidate mitigation, not a proved permanent reserve.
Verify that user accounting never assigns or consumes that seed.
Exercise deposits, principal exits, interest exits, batch purchases, donations, and the last two users' exits.
Confirm that the seed remains above the remainder-burn threshold after those sequences.

If those guarantees do not hold, choose another adapter or lifecycle design before enabling the route.
Do not permit an unexplained burn of up to ten user-owned shares as a shortcut.
If Sovryn stays disabled, record this as a condition for enabling it rather than a blocker for unrelated routes.

## Fizz and assurance follow-ups

| Item | Proposal | Closure requirement |
| --- | --- | --- |
| SP-64 | Resolve with F1's selected semantics | Keep its demonstrated dust behaviour distinct from the unproved material attack. Under a rate guarantee, test that guarantee instead of demanding fixed input. |
| GL-15 | D — property corrected; Sovryn excluded at launch | A real dust deposit reverts without loss. Condition the minimum-deposit assertion on minting at least one share. Keep the 1e18-deposit assertion. Update the replay's expected result. This harness correction does not require enabling Sovryn. |
| GL-24 | X/V — unconfirmed Sovryn rounding lead | Retain the smoke-run sequence for a future Sovryn review. Reproduce it before claiming a dust bound or changing the property. It is not an initial release blocker while Sovryn remains excluded. |
| SP-72 | D — coverage gap closed | The harness starts Dex routes through USDT0. `test_intermediatePathPurchaseEvaluatesSP72` proves a purchase executes, checks the intermediate balance, and checks the property evaluation counter. |
| Campaign duration | Extend after harness corrections | The report recommends at least four hours, then 24 hours before release, plus Echidna. Preserve results and limitations. Runtime duration alone is not a security proof. |
| Mock and coverage limits | Preserve limitations; add targeted checks | Mock venues do not validate live fee, burn, liquidity, or oracle rules. Verify those assumptions with focused tests or dependency evidence. Correct the report's coverage explanation through a separate annotation. |

## Priorities for the implementation spec

1. Specify and implement F1's confirmed execution-rate protection against actual input changes. Keep deposits and creation open.
2. Omit Sovryn handler deployment and route assignments from the initial release. Verify the resulting launch map.
3. The final deployment excludes USDRIF → USDT → WRBTC. Deployment tests verify both affected handlers.
4. Close L21, L23, the loss-recovery questions in L12/L16, and any enabled-market L18 case with targeted evidence.
5. Verify the operational controls for price impact, venue capacity, failed rows, and route isolation.
6. Correct the cadence documentation and Fizz properties, then run the selected assurance campaigns.
7. Keep optional hardening separate from required fixes.

Sovryn-specific remediation and evidence remain conditions for a future integration, not initial release blockers.
Checks can be scoped to enabled routes. An explicit disabled-route condition can defer its route-specific work.
Availability failures and price-protection gaps stay open until their control or acceptance is supported.

## Owner decision log

| Decision | Recommended position | Confirmed position |
| --- | --- | --- |
| Deposits and creation during protected windows | Keep them open; protect execution rate against actual input changes | Confirmed by the owner on 2026-10-20. This selects mitigation, not acceptance of F1. Implemented in this PR; validation is recorded below. |
| Sovryn integration at launch | Initial proposal was a paused DOC route; the owner selected broader exclusion | Confirmed by the owner on 2026-10-20: omit all Sovryn integration from the initial release. A handler can be deployed later. `DeployFinal` applies the exclusion; Sovryn-specific risks stay open for a future review. |
| Alternate path reported empty | Exclude it from the launch allowlist until reviewed | Confirmed by the owner on 2026-10-20: exclude USDRIF → USDT → WRBTC at launch. Retain the primary USDRIF → USDT0 → WRBTC path. Implemented in this PR; validation is recorded below. |
| PR #184 implementation and consumer updates | Retain the rate check; keep protected windows optional; publish the consumer requirements | Confirmed by the owner on 2026-10-21. Five dedicated R117 follow-up issues now contain the final requirements. Each requires a new PR above its existing relaunch stack. Links are in R117. |
| New residual risk acceptances | Review the A/O rows with their stated impact and controls | Evidence-dependent items remain open under their stated closure requirements. PR approval does not waive those conditions. |

Existing accepted policies remain attributed to the report and repository instructions.
They do not close new evidence gaps or approve unrelated future dependency behaviour.

## Implementation and validation

PR #184 includes the selected contract mitigation, launch exclusions, regression tests, and documentation.
The original scan and Fizz report outputs remain unchanged as evidence of the original runs.
The initial documentation-only boundary is superseded by the owner's request to include mitigations in the same PR.

- F1: `PurchaseRbtcTest` first reproduced diluted protection and overstrict reduced-input behaviour before the fix.
- Targeted purchase, quote, and deployment suites pass on the default profile.
- The updated `FoundryTester` passes all nine tests, including both original sequences and explicit SP-72 evaluation.
- Full default/deploy gates and required lending/path forks pass. Exact commands and results are in R117.
- The owner approved publication on 2026-10-21. All five dedicated R117 consumer issues are published and linked in R117.
- The older issues point to those independent implementation gates. Their existing PRs do not close the additional R117 work.
- Each dedicated issue retains an unchecked completion gate before relaunch. Publication does not imply consumer implementation is complete.
- No transaction has been broadcast. Source for excluded adapters remains available for a future integration.

This implementation does not close unverified oracle, dependency, or operational leads through an implied risk acceptance.
