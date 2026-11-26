# R128 — Lending rounding and period invariant tests

Status: **implemented; [PR #205](https://github.com/BitChillRSK/dca-contracts/pull/205) open**. Assigned follow-up to PR #204. This test and documentation change preserves production behavior.

## Scope

- Correct the LayerBank two-deposit fork rounding bound.
- Verify handler share movement, forfeiture, user redemption, cash receipts, and preservation of a separate wallet position.
- Replace the invalid launch-minimum invariant with the permanent one-day, whole-day rules.
- Check governance changes and rejection of creation and edits below the current minimum.
- Document the pinned-block example and its assumptions in `LAYERBANK_ROUNDING.md`.

## Validation

Run both changed suites under default and deploy profiles. Run the LayerBank share-withdrawal suite against block 9443471 and the chain tip under both profiles. Run the original invariant seed. See the PR for commands and results.
