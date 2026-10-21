# Pashov skills AI scan — provenance and triage notes

## Provenance

BitChill ran the open-source [solidity-auditor](https://github.com/pashov/skills) skill (v4.1) from
Pashov Audit Group's skills repository. It ran in Claude Code on Claude Opus 5.5 between 2026-10-13 and 2026-10-16.
This is an automated scan. It is not an engagement with Pashov Audit Group or its auditors.

- Code: `refactor/r115-drop-single-rbtc-withdraw` at `d5c09c321d3525feb42a60bbcddff0c3510bdcc3`.
- Scope: the 20 contracts in `src/` and `script/DeployFinal.s.sol`, `script/DeployBase.s.sol` and
  `script/Constants.sol`. `src/tropykus-legacy/` is not deployed and is out of scope.
- Method: 3 passes of 12 specialist agents, with a confidence threshold of 75 and the skill's memory
  on, so each pass read the results of the passes before it. All three passes returned 12/12
  agents. The pass 3 flow-gap agent stopped at a usage limit and was resumed later. Before it
  wrote its report, it also read a draft of this folder, which held the results of the other 11
  pass 3 agents.
- [The report](./dca-contracts-pashov-ai-audit-report-20261013-135445.md) is the unchanged
  output of the skill's assembler. Its SHA-256 is
  `33e3aa21193300b7c8ee0d026686d43f0f8d1916267ecdb22502a1150213c918`.
- The agents could only read the repository. Their proof-of-concept tests and simulations stayed
  outside it. Some agents read live Rootstock state with read-only calls and a read-only fork. No
  agent sent a transaction.
- The X-Ray and Fizz skills from the same repository ran after this scan, on the same `src/`. The
  scan's agents did not read their output. See [X-Ray](#x-ray) and [Fizz](#fizz) below.

The report has 2 findings at confidence 75 and 28 leads. A lead is a code smell with an incomplete
exploit path. It is not scored and it is not a false positive. "Seen in k/3 runs" counts the passes
that raised the item, not the agents.

## Judging rules

The orchestrator applied the skill's gates with these rules in all three passes:

- Agreement between agents promotes an item only when one of them proves the harm path.
- An item that needs a trusted role (the swapper), or that causes only dust loss or a temporary
  stop, stays a lead.
- An owner-only item with no unprivileged path is rejected. This removed
  `OperationsAdmin.assignHandler` (a wrong assignment by the owner).
- A path that the code cannot reach is rejected. This removed a "zero-amount router call" item: an
  empty batch reverts in `DcaManager._batchBuyRbtc`, idle rows are at least the minimum
  purchase amount, and a lending row with zero cash reverts `LendingHandler__ZeroShareValue`.

## Status

Triage is in progress. On 2026-10-20, the owner confirmed F1's policy: keep deposits and schedule
creation open, and protect the quoted execution rate against actual input changes. The owner also
excluded all Sovryn integration from the initial release. A Sovryn handler can be deployed later;
its unresolved integration risks remain conditions for that future review. The owner also excluded
the alternate USDRIF → USDT → WRBTC path from the launch allowlist, retaining the primary path
through USDT0. [R117](../../docs/relaunch/R117-pashov-mitigations.md) now implements the selected
quote protection and deployment exclusions in PR #186 (which replaces #184), with regression tests. The notes below are scan input, not decisions. The separate
[disposition register](../../docs/relaunch/PASHOV_TRIAGE_DECISIONS.md) covers both findings, all 28
leads, and the Fizz follow-ups. It distinguishes confirmed policy, recommendations, existing
policy, and open verification conditions. The owner approved PR #184 and consumer publication on 2026-10-21.
All five consumer issues now contain the final requirements, linked from R117, with implementation gates before relaunch.
[R118](../../docs/relaunch/R118-pashov-optional-hardening.md) implements the four deferred hardening leads (L06, L14, L17, L25) in PR #187.
The generated report remains unchanged.

## Notes for triage

### Finding 1 — batch `minRbtcOut` does not scale with the batch input

All three passes raised it, and up to 8 agents in one pass. A pass 3 agent priced an extra loss of
about 100 USDRIF on a 5,000 USDRIF batch. Purchases do not need a live window
([`AUDIT_GUIDE.md`](../../AUDIT_GUIDE.md) line 226). `depositToken` and `createDcaSchedule` do not
have `whenUserMutationsAllowed`, so a lending row can grow after the quote. The report gives two
fixes. Fix A adds `maxStablecoinIn` to `Batch`. Fix B checks a price per token instead of an absolute
minimum. The window note below also makes this finding smaller.

### Finding 2 — `DeployFinal` assigns a Sovryn DOC market with no free DOC

One agent raised it in pass 1, and no later pass raised it again. The finding depends on live
state: at scan time 99.99% of the iDOC market's DOC was lent out. The Sovryn liquidity lead
describes the same risk for an exit. The guide accepts external illiquidity. The question is if
route 2 opens for deposits at launch. Fix B uses `OperationsAdmin.setDepositsPaused`, which exists.

### Deposits and new schedules in the protected window

Three leads (`depositToken`, `createDcaSchedule`, and `_batchRetrieveStablecoin` "window input
resize") have the same cause, and six or more agents raised them. `whenUserMutationsAllowed` is on
seven `DcaManager` functions but not on `depositToken` or `createDcaSchedule`. Users can therefore add
lending shares that a short row then spends. The simple fix is to add the modifier to both functions.
Without a lending loss the effect is rounding dust. Fizz reproduced that case: a 1-wei
`depositToken` inside a live window made a planned LayerBank batch burn one share more than
planned (property SP-64, `test_repro_adv_protectedBatchScenario` in
[`test/fizz/FoundryTester.sol`](../../test/fizz/FoundryTester.sol)).

### LayerBank round-up burns

The lead applies to all LayerBank redeems: withdrawals, schedule deletion, interest withdrawals and
purchases. A user who exits to re-enter a new handler can also see a revert. Simulations put the
revert rate at 50% just above index 1.0 RAY, 47.6% at 1.05, 39.8% at 1.2 and 25% at 1.5. The call
fails closed, and no funds are lost. A retry with another amount, or after the index changes, can
succeed. Under a round-up burn the floor amount alone is exact, so a replacement handler only drops
the `+ 1`. [`src/layerbank/README.md`](../../src/layerbank/README.md) already documents this risk under
"Burn rounding" and says that exits may need retries across index updates. It could also mention a
retry with another amount.

### Other leads with a simple response

- **Sovryn burn of a small remainder.** Sovryn also burns a remainder of ten units or fewer, so
  the exact-burn check reverts the last full exit. A fork test confirmed the rule on live iDOC. A seed
  of 11 or more iToken wei that no user owns, held by each Sovryn handler, prevents this state.
- **Zero-value transfer in `_withdrawToken`.** Skip `safeTransfer` when the amount is 0, as
  `withdrawInterest` already does. DOC, USDRIF and USDT0 accept zero transfers, so this is for
  future tokens.
- **Balance read before the handler call in `depositToken`.** Write `newTokenBalance` before the
  handler call, as the other mutation paths do. No listed token or market can call back.
- **Period edits.** `AUDIT_GUIDE.md` line 219 says that a period edit gives "one extra purchase, not
  a loop". A pass 2 simulation got five purchases in one UTC day with stepped period cuts (64, 32, 16,
  8, 7 days). Correct the guide, or re-anchor the cadence when the period changes. Only the schedule
  owner can do this, and the agents found no loss for other users.
- **Money on Chain gas cap.** On 2026-09-07 `maxGasPrice()` was about 16% above the network gas
  price. `batchBuyRbtcAcrossHandlers` is atomic, so the bot can send MoC batches in a separate
  transaction from Dex batches.
- **Pool move between window activation and the quote.** The response is in the bot: reject a
  quote made after activation if it is more than the normal tolerance below the oracle output.

### Overlap with earlier reviews

- The per-row share clamp from the Nethermind response (findings 1, 5 and 6) is the code that the
  "schedule with no backing shares", "clamped lending row" and "withdrawal after a lending loss"
  leads study. All three need a loss in the lending market.
- The stablecoin peg lead overlaps Nethermind finding 2 (an upward depeg), which BitChill accepted.
  The lead adds the downward case: a 3% USDRIF depeg stops USDRIF purchases until the owner lowers
  the floor.
- The swapper revoke lead matches the "Compromised swapper" procedure in
  [`docs/relaunch/CUTOVER_RUNBOOK.md`](../../docs/relaunch/CUTOVER_RUNBOOK.md#compromised-swapper).
- The back-to-back protected window lead is a risk that `AUDIT_GUIDE.md` and `AGENTS.md`
  invariant 10 accept.

## X-Ray

BitChill ran the [X-Ray](https://github.com/pashov/skills) skill (version 2) on 2026-10-16, in Claude
Code on Claude Opus 5.5, on the same `src/` as the scan. `src/tropykus-legacy/` was excluded.
X-Ray writes a pre-audit map, not findings. Its output is in [`x-ray/`](./x-ray/):

- [`x-ray.md`](./x-ray/x-ray.md): the protocol overview, trust model, and the areas a reviewer should
  read first.
- [`invariants.md`](./x-ray/invariants.md): 37 guards, 22 single-contract invariants, 6 cross-contract
  invariants and 3 economic invariants. 10 of them are not enforced on-chain.
- [`entry-points.md`](./x-ray/entry-points.md): every external entry point with its caller and access
  control.
- [`architecture.svg`](./x-ray/architecture.svg): the contract and route diagram.

The file headers name `f414708a`, the commit that added the scan report. `src/` there is identical to
`d5c09c32`.

## Fizz

BitChill ran the [Fizz](https://github.com/pashov/skills) skill (version 1) between 2026-10-17 and
2026-10-19, in Claude Code on Claude Opus 5.5, on the same `src/`. Fizz writes a stateful fuzzing
suite from the X-Ray output and runs it. Like the scan, it is automated and is not an engagement with
Pashov Audit Group.

- **Method.** Automatic mode. Opus subagents ran one at a time: 5 property-discovery agents and a
  synthesizer at high effort, then 2 implementers and a report writer at default effort. Tools:
  Foundry 1.7.1 and Medusa 1.5.1. Echidna 2.3.3 was installed but not run.
- **Harness.** [`test/fizz/`](../../test/fizz/) deploys one `DcaManager` and one `OperationsAdmin`
  with five routes: DOC idle, LayerBank and Sovryn on Money on Chain, and USDRIF idle and LayerBank on
  Uniswap with the oracle floor. Every venue is a local mock. The Sovryn iToken mock can lose value
  and charge an exit fee. `SovrynHandlerDex` is not deployed.
- **Properties.** [`PROPERTIES.md`](../../PROPERTIES.md) lists 106 properties: 29 global and 77
  checked after specific calls. 83 are SHOULD-HOLD, so a violation is a bug. 23 are EXPLORATORY, so a
  violation needs human review. All 106 are implemented.
- **Campaign.** One Medusa run: 10 workers, 8 min 25 s, 501,776 calls (it stopped at the 500,000
  call limit), 15,301 branches. Line coverage of the deployed in-scope contracts is 85% to 100%.

No SHOULD-HOLD property failed. Two EXPLORATORY properties failed, and each has a Foundry test in
[`test/fizz/FoundryTester.sol`](../../test/fizz/FoundryTester.sol) that replays the fuzzer's
sequence:

- **SP-64**, `test_repro_adv_protectedBatchScenario`. A deposit inside a protected window made the
  batch burn one share more than planned. This confirms the "Deposits and new schedules in the
  protected window" note above. Without a lending loss the effect is one share of dust.
- **GL-15**, `test_repro_property_sharePreviewPositive`. After the owner sets DOC's minimum purchase
  amount to 1 wei, a minimum deposit previews zero Sovryn shares. A real 1-wei deposit reverts and
  loses nothing. The property is too strong for an owner-set minimum.

Limits of this run:

- GL-24 failed once in a short trial run before the campaign but not in the campaign. It is an
  unconfirmed rounding-dust lead on Sovryn.
- SP-72 was never evaluated, because no Dex purchase used the path through USDT0.
- The run was short. The report recommends a run of 4 hours or more, then 24 hours before release,
  and an Echidna pass.

[`fizz_data/report.md`](../../fizz_data/report.md) has the full results, coverage per contract, and
next steps. [`fizz_data/property-plan.md`](../../fizz_data/property-plan.md) gives each property's
source and reasoning. The Medusa corpus, the coverage HTML and the compile caches are not committed.
To rerun, run `medusa fuzz` from the repository root, or
`forge test --match-contract FoundryTester` for the Foundry tests.
