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
- The X-Ray and Fizz skills from the same repository have not run yet.

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

BitChill has not triaged this report yet. The notes below are triage input from the scan, not
decisions.

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
Without a lending loss the effect is rounding dust.

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
