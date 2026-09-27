# R98 — Remove the unreachable inner redeem clamp

Status: **implemented** · GitHub [#164](https://github.com/BitChillRSK/dca-contracts/pull/164) · Assigned: yes · Optional/further-review: no · Stack on: R96 ([#162](https://github.com/BitChillRSK/dca-contracts/pull/162))

## Objective

Delete the dead `sharesToRedeem > usersShares` branch inside `LendingHandler._redeemShares`, its
`LendingHandler__AmountToRedeemAdjusted` event, and the test-only entry that exercised it. Make the
helper `private`. Keep the outer withdrawal clamp and the batch `InsufficientShares` check. Prove the
bound through the real principal and interest withdrawal paths.

## Background

[R28](./R28-lending-erc20-handler.md) kept the inner clamp as a per-user solvency boundary because
schedule accounting can sit ahead of share-backed underlying and because `_retrieveStablecoin` (since
deleted) had no outer withdraw clamp. Today's production callers cannot produce the condition:

- **Principal** (`_withdrawToken`) first caps the request at `_sharesToStablecoin(usersShares, rate)`.
- **Interest** (`withdrawInterest`) redeems at most that same share-backed total minus locked principal.

So `ceil(amount × scale / rate) ≤ usersShares`. The remaining clamp test went through a harness
wrapper that bypassed those callers. Gas is incidental; this is source simplification and one fewer
ABI event before relaunch deploy.

[R97](./R97-redeem-lending-exits-to-user.md) (closed without merging in [#163](https://github.com/BitChillRSK/dca-contracts/pull/163))
does not change this analysis: exits still redeem onto the handler, and the two callers above still
bound the amount.

Sibling cleanups from the same 2026-09-27 review are [R99](./R99-centralize-deposit-share-accounting.md)
(deposit DRY) and [R100](./R100-invariant-suite-debt.md) (invariant suite honesty). Not this PR.

## Open product decisions

**none**

## Scope

- [x] In `_redeemShares`: drop the `sharesToRedeem > usersShares` branch and its emit; make the
      helper `private` (move it under **PRIVATE FUNCTIONS**); refresh the NatSpec so it no longer
      claims a clamp or names a deleted `_retrieveStablecoin` rationale.
- [x] Delete `LendingHandler__AmountToRedeemAdjusted` from `ILendingHandler`.
- [x] Replace `test_redeemShares_clampsToTheUsersOwnBook` with tests that go through
      `withdrawToken` / `withdrawInterest` (outer clamp still fires; interest amount stays
      ≤ share-backed value). Drop the harness's public `redeemShares` wrapper; route remaining
      single-redeem regressions through `withdrawToken` / `withdrawInterest`.
- [x] Drop the event from `EventIndexingTest`.
- [x] Consumer follow-up on `bitchill-monitoring` for the removed event (comment on [#23](https://github.com/BitChillRSK/bitchill-monitoring/issues/23) or a new issue if that one is the wrong home).

## Out of scope

- [x] Centralizing deposit-share measurement ([R99](./R99-centralize-deposit-share-accounting.md)).
- [x] Invariant suite / README honesty ([R100](./R100-invariant-suite-debt.md)).
- [x] Changing the outer `WithdrawalAmountAdjusted` clamp or batch `InsufficientShares`.
- [x] Any purchase-path or adapter change.

## Files likely touched

- `src/LendingHandler.sol`
- `src/interfaces/ILendingHandler.sol`
- `test/unit/LendingHandlerRedeemTest.t.sol`
- `test/unit/EventIndexingTest.t.sol`
- `docs/relaunch/R98-remove-unreachable-redeem-clamp.md`, `README.md`, `IMPLEMENTATION_ORDER.md`
- (same PR registers) `docs/relaunch/R99-centralize-deposit-share-accounting.md`,
  `docs/relaunch/R100-invariant-suite-debt.md`

## Required tests

```text
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-path "test/unit/{LendingHandlerRedeemTest,EventIndexingTest}.t.sol"
make check
make fork-sovryn
make fork-tropykus
```

Forks: no new fork-specific assertions; run as the executable-change gate.

## Success criteria

- [x] No `AmountToRedeemAdjusted` in `src/` or first-party tests.
- [x] `_redeemShares` is `private` and unreachable from subclasses without going through the
      production withdraw / interest paths.
- [x] Outer withdraw clamp and batch insufficient-shares behaviour unchanged.
- [x] `make check` and both fork lanes green.
- [x] Monitoring cutover issue opened or updated.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Invariants 1 and 11 unchanged; unchecked share debit is still safe because both callers bound
      the amount.
- [ ] No relaunch ticket ids in `src/` comments.
- [ ] Consumer issue URL in the PR cutover note.

## ABI / deploy / cutover impact

- ABI: **removes** `LendingHandler__AmountToRedeemAdjusted`. No function or error changes.
- Scripts: none.
- Cutover: `bitchill-monitoring` must not expect that event on relaunch handlers (regenerate
  `abi.json` / drop the fragment). Comment on or open an issue; paste the URL in the PR.
