# R16 — Redeem glossary

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 14. Stack on R21. Land before LayerBank and before R10 natspec.

## Objective

Rename first-party internals, events, variables, and comments so "redeem" names the token being **given up**. No behavior change. No new tests.

## Background

BitChill currently uses "redeem" for three different motions:

- PurchaseRbtc's `_redeemStablecoin` hook: "make DOC available on the handler to spend." Idle only debits `s_idleBalances`. Lending burns k/iTokens to pull DOC in. The name dates from the lending burn.
- PurchaseMoc's `_redeemRbtc`: spends DOC, receives rBTC — so it named the asset arriving. MoC's own ABI (`redeemDocRequest`, `redeemFreeDoc`) already names the asset leaving.
- `TokenLending__UnderlyingRedeemed`: reports DOC that arrived, not the lending token given up.

The glossary for this PR: **redeem = the asset leaving**. Third-party ABI names stay (`redeemUnderlying`, `redeemFreeDoc`, iToken `burn`, …). LayerBank must not copy `_redeemStablecoin` as a debit hook.

Suggested first-party direction (implementer may pick equivalent names if they read more clearly in context; be consistent):

- PurchaseRbtc hook: name the stablecoin being made available to spend (e.g. `_takeStablecoin` / `_freeStablecoin`), not "redeem stablecoin."
- Idle: the mapping debit is already `_debitIdleBalance`; the PurchaseRbtc override should call that, not a "redeem."
- Lending: the share burn is redeeming the **lending token** (or "repay shares"); the DOC that arrives is received, not redeemed.
- MoC first-party wrapper: spend/repay DOC, receive rBTC. Do not rename MoC's functions.
- Events / errors / comments / natspec on first-party types follow the same glossary. R10 will rewrite natspec after this; this PR only has to stop lying in names.

**Why the batch-redeem event needs a value guard in this PR.** These renames touch the `TokenLending__UnderlyingRedeemedBatch` emit sites in both lending handlers, where the emitted amount and the returned amount are the same local variable one line apart. PR 12 already asserts topic1 within 1 wei of the requested amount (`tokenPrice` rounding; SIP-0094 is not charging). Keep that check through the rename — do not widen it. A rename that touches only the emit expression would otherwise ship a lying event with every fund-flow test still green. See **Required tests**.

## Glossary as implemented

| Motion | Name |
| --- | --- |
| Put a user's stablecoin on the handler so a purchase can spend it | `_retrieveStablecoin` / `_batchRetrieveStablecoin` |
| Give up k/i/aToken to get the stablecoin back | Sovryn: `_redeemLendingToken` (+ recipient overload). Tropykus/LayerBank: `_redeemByUnderlying` / `_redeemByShares` over the shared `_redeemLendingTokenInternal` — **[R25](./R25-lending-redeem-naming.md)** replaced R16's `_burnKtoken` wrapper. |
| Give up DOC to get rBTC at MoC | `_redeemDoc` |
| Shares leaving a user's book | "repay" locals were an R16 alias; **[R25](./R25-lending-redeem-naming.md)** renames them to `*ToRedeem` / `_redeemByUnderlying` / `_redeemByShares`. It also renamed the event to `TokenLending__AmountToRedeemAdjusted`; R16 had held it back as ABI, which the relaunch made moot. |
| Stablecoin arriving | "received" (`stablecoinReceived` in both lending handlers, `TokenLending__ZeroStablecoinReceived` when none arrives). The shared event's amount parameter stays the neutral `underlyingAmount`: inside a batch it fires per user with a planned share, not a receipt. |

MoC's `redeemDocRequest` / `redeemFreeDoc` follow this glossary already: DOC is what leaves. The first-party name that did not was `_redeemRbtc`, now `_redeemDoc`.

"Retrieve" rather than "withdraw" for the hook: every other `withdraw*` in `src/` moves funds out to the user, while this one leaves them on the handler to be spent.

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 14. Implement without asking.

## Scope

- [x] Rename first-party functions, variables, events, errors, and comments so "redeem" means the token given up.
- [x] Keep third-party ABI identifiers and any comment that quotes them.
- [x] Update interfaces in lockstep with implementations (`IPurchaseRbtc`, `ITokenLending`, handler interfaces, tests that reference renamed first-party symbols).
- [x] No logic, rounding, or access-control changes.
- [x] Beyond a pure rename, at the maintainer's direction: the two redeem-side failure conditions are unified into `ITokenLending`, mirroring `TokenLending__LendingProtocolDepositFailed`, which both handlers already share despite raising it from different idioms. Sovryn's zero-received error gains the amount it always had in scope. `ISovrynErc20Lending` and `ITropykusErc20Lending` are deleted: both were empty once their errors moved, and `TokenLending` already supplies `ITokenLending` to each handler.

## Out of scope

- [ ] LayerBank handler (PR 15).
- [ ] R10 natspec rewrite. Do not drive-by the rest of the comments.
- [ ] R9 event *indexing*. Renaming an event is in scope; changing which fields are `indexed` is not.
- [ ] Behavior, deploy scripts, fee model. ABI meaning (parameter order/types) too, with one carve-out recorded in **Scope**: the unified `TokenLending__ZeroStablecoinReceived` carries a `uint256` that Sovryn's error did not.

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

- `makeBatchPurchasesOneUser` (`test/unit/DcaDappTest.t.sol`) checks that `TokenLending__LendingTokenRedeemedBatch` (was `TokenLending__UnderlyingRedeemedBatch`) reports the **measured** stablecoin, not the requested gross. PR 12 already does this with `vm.recordLogs()` and `assertApproxEqAbs(..., 1)`: `expectEmit` cannot, because topic1 is exact and live iSUSD `tokenPrice` rounding is 1 wei off (SIP-0094 is **not** charging). Keep that 1-wei check through the rename. Leave `lendingTokenAmountRepayed` unasserted — it always has been.

Fork tests: no fork-specific assertions. The 1-wei tolerance exists so the check passes on `make fork-sovryn` at tip as well as on the Anvil lanes. If the Perimeter Fee starts charging, that check will fail — that is the signal.

## Success criteria

- [x] Grep of first-party `src/` no longer uses "redeem" for the token being received, except when quoting a third-party ABI.
- [x] Third-party function names unchanged.
- [x] `make check` passes. No behavior change.
- [x] The batch-redeem measured-amount assertion carries through the rename unchanged — still `assertApproxEqAbs(..., 1)`, not widened — and passes on `make check` and `make fork-sovryn`. Mutating either handler's batch emit to half the measured amount fails `make moc-sovryn` and `make moc-tropykus`.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

Generated from `git diff <base> -- src | grep -E '^[-+] *(error|event) '`, not hand-maintained.

**Removed**

```
error PurchaseRbtc__RedeemedAmountBelowFee(uint256 stablecoinRedeemed, uint256 aggregatedFee);
error SovrynErc20Lending__RedeemUnderlyingFailed();
error TokenLending__BatchRedeemUnderlyingFailed();
error TropykusErc20Lending__RedeemUnderlyingFailed(uint256 errorCode);
error TropykusErc20Lending__ZeroStablecoinRedeemed(uint256 stablecoinRequested);
event TokenLending__UnderlyingRedeemed(address indexed user, uint256 indexed underlyingAmountRedeemed, uint256 indexed lendingTokenAmountRepayed);
event TokenLending__UnderlyingRedeemedBatch(uint256 indexed underlyingAmountRedeemed, uint256 indexed lendingTokenAmountRepayed);
```

**Added**

```
error PurchaseRbtc__StablecoinRetrievedBelowFee(uint256 stablecoinRetrieved, uint256 aggregatedFee);
error TokenLending__LendingProtocolRedeemFailed(uint256 errorCode);
error TokenLending__ZeroStablecoinReceived(uint256 stablecoinAttempted);
event TokenLending__LendingTokenRedeemed(address indexed user, uint256 indexed underlyingAmount, uint256 indexed lendingTokenAmountRedeemed);
event TokenLending__LendingTokenRedeemedBatch(uint256 indexed underlyingAmount, uint256 indexed lendingTokenAmountRedeemed);
```

Five errors become three: the two "redemption produced nothing" variants collapse into `TokenLending__ZeroStablecoinReceived`, and the two Compound-code failures into `TokenLending__LendingProtocolRedeemFailed`. So this is **not** a pure name swap — Sovryn's zero-received revert took no parameters on the base branch and its replacement takes one. Event parameter layout and indexing are unchanged. No external function selector changes (`buyRbtc`, `batchBuyRbtc`, `withdrawToken`), and `PurchaseRbtc__RbtcBought` is untouched. `ISovrynErc20Lending` and `ITropykusErc20Lending` are deleted; both were empty once their errors moved, and `TokenLending` already supplies `ITokenLending` to each handler.

- Scripts: none.
- Cutover: none for users. Indexers that filter old event names need the new signatures.
- Sibling specs keep their pre-rename symbol names on purpose: `R22-idle-handler.md` describes PR 12, which lands before this one, and `IMPLEMENTATION_ORDER.md`'s PR 14 entry is a plan for work that is not merged yet — that file flips an entry to **Merged.** and past tense at merge time (see its PR 1 entry).
