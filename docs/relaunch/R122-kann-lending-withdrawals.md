# R122 — Kann lending withdrawals

Status: **assigned** · Assigned: yes · Optional/further-review: no

Base: `main`, after merged R121 / [#198](https://github.com/BitChillRSK/dca-contracts/pull/198).

## Objective

Implement the approved lending-withdrawal responses to Kann #14, #19, and #20 item 1.
An in-kind exit forfeits a measured one-share remainder, so an impaired route no longer blocks subsequent bulk interest claims.

## Background

- [Kann #14](https://github.com/Kann-Audits/BitChill-Audit/issues/14): LayerBank's half-up transfer can leave one scaled share booked after schedule principal becomes zero. Its attempted cash redemption can revert a later bulk interest claim.
- [Kann #19](https://github.com/Kann-Audits/BitChill-Audit/issues/19): the owner chose neither dedicated clamp event. Remove the withdrawal adjustment event and retain measured-payout and share-update events.
- [Kann #20](https://github.com/Kann-Audits/BitChill-Audit/issues/20), item 1: the share-exit loop already obtains ids from the caller's own list. Rechecking each stored owner adds no access protection.
- Owner decisions: 2026-11-25. Responses are posted. #15 duplicates #14 and gets no separate work.

## Open product decisions

**none** — the owner approved this PR's scope and the four-PR implementation sequence.

## Scope

- [ ] In `LendingHandler.withdrawShares`, retain the positive and non-excessive measured-transfer checks. Compute the remaining book after the transfer. If exactly one share remains, book zero; leave a larger remainder booked. Apply this rule only on the share-withdrawal path.
- [ ] Keep `withdrawnShares` and `SharesWithdrawn.shares` equal to the measured external transfer. `UserSharesUpdated` reports the final book, including any one-share forfeiture. Add no production surplus counter, sweep, second transfer, or forfeiture event.
- [ ] Remove `LendingHandler__WithdrawalAmountAdjusted` from its interface, implementation, and active tests. Preserve the withdrawal clamp and its measured-payout events. Describe the accepted loss of an explicit clamp marker.
- [ ] Express both clamp comparisons as `available < requested`. Preserve arithmetic, rounding, and batch allocation.
- [ ] Read `s_dcaSchedules[token][scheduleId]` directly only in `withdrawLendingShares`, with a comment explaining the caller-owned id list. Retain the route filter, pause-window check, and reentrancy guard.
- [ ] Update invariant 8's access exceptions and invariant 11's share-exit rule. Update applicable interface, audit-guide, property, and R64 descriptions. Add a dated R119 amendment rather than silently replacing its historical decision.
- [ ] Preserve the unconditional receipt-backing inequality. Reconcile the main stateful suite exactly using test-only accounting for forfeited shares. State the assumptions of Fizz GL-08: its closed environment has no external receipt-token donations or share-exit actions.
- [ ] Add regression coverage for the reported impaired+healthy route scenario, one-share forfeiture, larger retained remainders, exact external transfer reporting, caller/route isolation, and removed-event behavior.

## Out of scope

- [ ] #12, #23 and #20 item 5: configuration changes belong to PR 2.
- [ ] #18 I-09: purchase reentrancy guards belong to PR 3. Preserve the current callback protections.
- [ ] Remaining audit documentation and the general source-consistency sweep belong to PR 4. This PR includes only documentation required by its behavior changes.
- [ ] A general bulk partial-success mechanism, changed share conversion, automatic dust forfeiture on another path, or an owner rescue.
- [ ] Consumer code, consumer pin changes, deployment, merge, and audit issue closure.

## Files likely touched

- `src/DcaManager.sol`, `src/LendingHandler.sol`, `src/interfaces/IDcaManager.sol`, `src/interfaces/ILendingHandler.sol`
- `test/unit/LendingShareWithdrawalTest.t.sol`, `test/unit/ResidualShareWithdrawAllInterestTest.t.sol`, `test/unit/LendingHandlerRedeemTest.t.sol`, `test/unit/EventIndexingTest.t.sol`, `test/unit/DcaDappTest.t.sol`, `test/unit/StablecoinLendingTest.t.sol`
- `test/ai-generated/unit/layerbank/LayerBankHandlerTest.t.sol`
- `test/ai-generated/fuzz/Handler.t.sol`, `test/ai-generated/fuzz/Invariants.t.sol`, `test/ai-generated/fuzz/README_INVARIANTS.md`
- `test/fizz/Properties.sol`, `PROPERTIES.md`, `AGENTS.md`, `AUDIT_GUIDE.md`
- `docs/relaunch/R64-batch-calldata-and-schedule-keying.md`, `docs/relaunch/R119-in-kind-lending-exit.md`
- This spec, `docs/relaunch/IMPLEMENTATION_ORDER.md`, `docs/relaunch/README.md`

## Required tests

Approved public test boundaries: `DcaManager.withdrawLendingShares`, bulk interest withdrawal, and handler withdrawal/getter/event interfaces.

- Red/green: `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=layerbank STABLECOIN_TYPE=DOC forge test --match-contract ResidualShareWithdrawAllInterestTest -vv`.
- Targeted share-exit and redeem tests in the LayerBank MoC lane; the six regular lanes cover idle routes and both Dex stablecoins.
- One-share forfeiture leaves zero interest on the exited route; the same bulk claim pays the healthy route while the impaired route still refuses cash redemptions.
- Preserve nonzero/excessive transfer rejection, another user's claim, other-route principal, larger partial remainders, and measured `SharesWithdrawn` amounts.
- Deterministically exercise forfeiture through the invariant handler and verify its exact receipt/book/surplus reconciliation.
- Clamp still pays measured cash, protects another user's shares, and emits no removed adjustment event.
- `make check` and `make fork-layerbank` before push. Run targeted deployment-profile regressions as well. No new live-chain mutation is authorized.

## Success criteria

- [ ] All scope items and regression tests pass, with no changes from later PRs.
- [ ] Every ABI/behavior consumer dependency has an existing issue updated or a new issue opened when this PR opens.
- [ ] The PR records exact validation commands and the before/after reproducer result.

## Reviewer checklist

- [ ] Only the measured one-share remainder is forfeited; larger remainders stay claimable.
- [ ] External shares moved and virtual shares forfeited remain distinguishable.
- [ ] Share-backing checks remain unconditional; exact equality tests explicitly account for surplus.
- [ ] Direct schedule access relies on the caller's own list and cannot alter another user's schedule.
- [ ] Invariants 8 and 11 are explicitly amended; other protocol invariants remain in force.
- [ ] Extra files follow direct dependencies or failing tests and are identified in the PR.

## ABI / deploy / cutover impact

- ABI: remove `LendingHandler__WithdrawalAmountAdjusted(address,uint256,uint256)`. No function selector or argument changes.
- Behavior: a successful share exit forfeits a remainder of exactly one untransferred receipt share, so a later exit has nothing of it to recover. A larger remainder stays booked and claimable. Measured transfer events retain their external-transfer meaning.
- Scripts: unchanged. Contracts remain immutable; this change applies to the future release artifact.
- Consumers: search existing issues first. Track the front-end remainder-recovery flow and the event removal in affected front-end/monitoring consumers. Record exact inspected consumer heads; do not move pins.
