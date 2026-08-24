# R16 — Redeem glossary

Status: **not started** · Assigned: no · Optional/further-review: no

PR 14. Stack on R21. Land before LayerBank and before R10 natspec.

## Objective

Rename first-party internals, events, variables, and comments so "redeem" names the token being **given up**. No behavior change. No new tests.

## Background

BitChill currently uses "redeem" for three different motions:

- PurchaseRbtc's `_redeemStablecoin` hook: "make DOC available on the handler to spend." Idle only debits `s_idleBalances`. Lending burns k/iTokens to pull DOC in. The name dates from the lending burn.
- PurchaseMoc's `_redeemRbtc`: spends DOC, receives rBTC. MoC's own ABI (`redeemDocRequest`, `redeemFreeDoc`) is backwards; first-party comments already say so.
- `TokenLending__UnderlyingRedeemed`: reports DOC that arrived, not the lending token given up.

The glossary for this PR: **redeem = the asset leaving**. Third-party ABI names stay (`redeemUnderlying`, `redeemFreeDoc`, iToken `burn`, …). LayerBank must not copy `_redeemStablecoin` as a debit hook.

Suggested first-party direction (implementer may pick equivalent names if they read more clearly in context; be consistent):

- PurchaseRbtc hook: name the stablecoin being made available to spend (e.g. `_takeStablecoin` / `_freeStablecoin`), not "redeem stablecoin."
- Idle: the mapping debit is already `_debitIdleBalance`; the PurchaseRbtc override should call that, not a "redeem."
- Lending: the share burn is redeeming the **lending token** (or "repay shares"); the DOC that arrives is received, not redeemed.
- MoC first-party wrapper: spend/repay DOC, receive rBTC. Do not rename MoC's functions.
- Events / errors / comments / natspec on first-party types follow the same glossary. R10 will rewrite natspec after this; this PR only has to stop lying in names.

**Why the batch-redeem event needs a value guard in this PR.** These renames touch the `TokenLending__UnderlyingRedeemedBatch` emit sites in both lending handlers, where the emitted amount and the returned amount are the same local variable one line apart. PR 12 already asserts topic1 within 1 wei of the requested amount (`tokenPrice` rounding; SIP-0094 is not charging). Keep that check through the rename — do not widen it. A rename that touches only the emit expression would otherwise ship a lying event with every fund-flow test still green. See **Required tests**.

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 14. Implement without asking.

## Scope

- [ ] Rename first-party functions, variables, events, errors, and comments so "redeem" means the token given up.
- [ ] Keep third-party ABI identifiers and any comment that quotes them.
- [ ] Update interfaces in lockstep with implementations (`IPurchaseRbtc`, `ITokenLending`, handler interfaces, tests that reference renamed first-party symbols).
- [ ] No logic, rounding, or access-control changes.

## Out of scope

- [ ] LayerBank handler (PR 15).
- [ ] R10 natspec rewrite. Do not drive-by the rest of the comments.
- [ ] R9 event *indexing*. Renaming an event is in scope; changing which fields are `indexed` is not.
- [ ] Behavior, ABI meaning (parameter order/types), deploy scripts, fee model.

## Files likely touched

Any first-party file that says "redeem" for the wrong asset. Start here and follow the compiler:

- `src/PurchaseRbtc.sol`
- `src/PurchaseMoc.sol`
- `src/PurchaseUniswap.sol`
- `src/TokenLending.sol`
- `src/interfaces/IPurchaseRbtc.sol`
- `src/interfaces/IPurchaseMoc.sol`
- `src/interfaces/ITokenLending.sol`
- `src/idle/IdleErc20Handler.sol`
- `src/idle/IdleDocHandlerMoc.sol`
- `src/sovryn/SovrynErc20Handler.sol` (and Moc/Dex subclasses)
- `src/tropykus-legacy/TropykusErc20Handler.sol` (and Moc/Dex subclasses)
- Matching tests that call renamed first-party wrappers (compile fixes only)

## Required tests

Renames are compile-breaking until tests import the new names, so `make check` must still pass. One assertion to add, for the reason in **Background**.

```
make check
```

Behaviors to assert:

- `makeBatchPurchasesOneUser` (`test/unit/DcaDappTest.t.sol`) checks that `TokenLending__UnderlyingRedeemedBatch` reports the **measured** stablecoin, not the requested gross. PR 12 already does this with `vm.recordLogs()` and `assertApproxEqAbs(..., 1)`: `expectEmit` cannot, because topic1 is exact and live iSUSD `tokenPrice` rounding is 1 wei off (SIP-0094 is **not** charging). Keep that 1-wei check through the rename. Leave `lendingTokenAmountRepayed` unasserted — it always has been.

Fork tests: no fork-specific assertions. The 1-wei tolerance exists so the check passes on `make fork-sovryn` at tip as well as on the Anvil lanes. If the Perimeter Fee starts charging, that check will fail — that is the signal.

## Success criteria

- [ ] Grep of first-party `src/` no longer uses "redeem" for the token being received, except when quoting a third-party ABI.
- [ ] Third-party function names unchanged.
- [ ] `make check` passes. No behavior change.
- [ ] The batch-redeem measured-amount assertion is restored with a tolerance and passes on `make check` and `make fork-sovryn`.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: first-party event/error *names* may change. No parameter-layout change. External `buyRbtc` / `batchBuyRbtc` / `withdrawToken` selectors stay. Frontend that keys on `PurchaseRbtc__RbtcBought` / `TokenLending__UnderlyingRedeemed` must follow the new event names if those are renamed.
- Scripts: none.
- Cutover: none for users. Indexers that filter old event names need the new signatures.
