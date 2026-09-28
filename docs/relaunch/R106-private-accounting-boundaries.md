# R106 — Private accounting boundaries

Status: **assigned** · Assigned: yes · Optional/further-review: no · Stack on: R105 ([#171](https://github.com/BitChillRSK/dca-contracts/pull/171))

## Objective

Make the remaining shared accounting storage compiler-enforced (`private`), and correct
`UserSharesUpdated` documentation so indexers do not assume every event equals the final getter
when a buyer appears twice in one batch.

## Background

R98 / R99 left all production reads and writes of `LendingHandler.s_shares` inside
`LendingHandler`. R102 made Uniswap path update helpers `private`, but `s_swapPath` and
`s_swapIntermediateTokens` stayed `internal`. A subclass can still write either field alone,
bypassing path approval or separating the executed path from the intermediate-token checks.
No production subclass reads or writes any of the three.

Same teeth as invariant 8 (`s_dcaSchedules`) and invariant 13 (`s_usersAccumulatedRbtc`): privacy
turns a future leaf mistake into a compile error.

`ILendingHandler` (and `EXTERNAL_REWARDS.md`) currently say each `UserSharesUpdated.newShares`
equals `getUserShares(user)` after the call / transaction. That is false when the same buyer
appears twice in a batch: earlier events carry intermediate balances; only the last event for
that user matches the final getter. Existing tests already assert sequential transitions.

## Open product decisions

**none**

## Scope

- [x] `LendingHandler.s_shares` → `private`.
- [x] `PurchaseUniswap.s_swapPath` and `s_swapIntermediateTokens` → `private`.
- [x] Adjust `LendingHandlerRedeemTest`'s harness `creditShares` so it seeds the private mapping
      through `stdstore` (via `getUserShares`) instead of a direct subclass write.
- [x] Fix `ILendingHandler` event / getter NatSpec: `newShares` is the balance immediately after
      this transition; only the latest event for that user matches `getUserShares` after the call.
- [x] Align the same sentence in `docs/relaunch/EXTERNAL_REWARDS.md`.
- [x] Note the three `private` fields in `AGENTS.md` (durable rule; no R-id in `src/`).

## Out of scope

- [x] Any behavior, ABI, selector, event signature, or storage-layout change.
- [x] Further visibility cleanups on unrelated `internal` state.
- [x] Consumer issues (NatSpec / docs only for the event wording; visibility is not ABI).

## Files likely touched

- `src/LendingHandler.sol`
- `src/PurchaseUniswap.sol`
- `src/interfaces/ILendingHandler.sol`
- `test/unit/LendingHandlerRedeemTest.t.sol`
- `AGENTS.md`
- `docs/relaunch/EXTERNAL_REWARDS.md`
- `docs/relaunch/R106-private-accounting-boundaries.md`
- `docs/relaunch/README.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`

## Required tests

Executable `src/` change → full gate:

1. `make check`
2. `make fork-sovryn`
3. `make fork-layerbank`
4. Metadata-stripped runtime / creation comparison under both profiles vs R105 tip: all ten
   concrete contracts identical (visibility-only; reviewer already verified with solc 0.8.36).

No new fork-specific assertions. Targeted: `forge test --match-path test/unit/LendingHandlerRedeemTest.t.sol`.

## Success criteria

- [x] The three fields are `private`; a subclass cannot compile a direct read or write.
- [x] Event docs describe per-transition balances, not a post-call getter equality for every emit.
- [x] ABI, storage layout, and metadata-stripped bytecode unchanged on both profiles.
- [x] `make check` + both production fork lanes green.
- [x] Spec assigned; README Status and `IMPLEMENTATION_ORDER.md` updated.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (accounting privacy strengthened).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none (visibility + NatSpec / docs only).
- Scripts: none.
- Cutover: none (no consumer issue — NatSpec is not an ABI change).
