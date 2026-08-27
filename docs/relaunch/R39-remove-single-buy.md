# R39 — Remove `buyRbtc`

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 30 of the relaunch stack. Stack on the planning PR, GitHub [#74](https://github.com/BitChillRSK/dca-contracts/pull/74). **Must land before R43, R36, and R9 (ABI freeze).**

## Objective

Delete the single-schedule `buyRbtc` entry points on `DcaManager` and `PurchaseRbtc`. Production already uses `batchBuyRbtc`; a batch of length 1 is the remaining one-schedule path.

## Background

`DcaManager.buyRbtc` and `PurchaseRbtc.buyRbtc` are swapper-only. The bot always builds batches. Keeping both paths doubles the purchase pipeline, the tests, and Dex bytecode (R31 left a few hundred bytes of EIP-170 margin before R9 adds share-transition events).

A length-1 `batchBuyRbtc` is not a perfect clone of the old single path (array checks, aggregated fee, `PurchaseRbtc__SuccessfulRbtcBatchPurchase`), but it is the same cash motion: one retrieve, one fee transfer, one MoC/Uniswap spend, one `PurchaseRbtc__RbtcBought`. That is enough for debug and retries.

**Gas tradeoff:** the old single selector is cheaper for exactly one schedule. A length-1 batch pays for larger dynamic-array calldata, DcaManager length/amount/route checks and a loop, handler-side array allocation/allocation math, and the batch-total event. This PR does not claim otherwise. The decision accepts that rare bot-paid overhead because production normally groups schedules, while retaining the single path would permanently spend handler/manager bytecode and maintain a second cash-moving implementation.

This is first in the remaining queue so R43 reviews the purchase path after the dead branch is gone and R36 measures the new LayerBank Dex handler against the reduced runtime.

Decided 2026-08-27: **delete**. Do not keep it as a hidden debug selector.

## Open product decisions

**none** — delete; length-1 batch remains.

## Scope

- [x] Remove `DcaManager.buyRbtc` and `IDcaManager.buyRbtc`.
- [x] Remove `PurchaseRbtc.buyRbtc` and `IPurchaseRbtc.buyRbtc`.
- [x] Convert every test that called the single path to `batchBuyRbtc` of length 1 (or drop it if it only existed to compare the two). `ComparePurchaseMethods` is mainnet-only and already excluded from CI; delete its single-path arm or the file if nothing remains.
- [x] Re-measure Dex handler runtime sizes vs EIP-170. Record before/after in the PR. This is the bytecode that R9 spends.
- [x] Before deleting the selector, record an apples-to-apples gas comparison between `buyRbtc` and a length-1 `batchBuyRbtc` on the same lane/setup. Preserve the number in the PR as the explicit cost of the simplification; it is not a gate to keeping the selector.

## Out of scope

- [ ] Changing `batchBuyRbtc` semantics, fee aggregation, or events.
- [ ] The swapper batcher (R42).
- [ ] R9 indexing / share events / fee-transfer event.

## Files likely touched

- `src/DcaManager.sol`, `src/interfaces/IDcaManager.sol`
- `src/PurchaseRbtc.sol`, `src/interfaces/IPurchaseRbtc.sol`
- Tests and fuzz wrappers that call `buyRbtc` (compiler will list them)

## Required tests

Targeted first, then `make check`.

- A length-1 `batchBuyRbtc` still purchases, credits rBTC, emits `PurchaseRbtc__RbtcBought`, and deducts the schedule.
- The PR records the measured one-schedule gas premium of the batch path; do not compare the existing five-schedule batch test to the single test.
- `dcaManager.buyRbtc` / `handler.buyRbtc` are gone (no selector).
- Existing batch tests unchanged.
- Fork: no new assertions. Still run `make fork-sovryn` and `make fork-tropykus` before push.

## Success criteria

- [x] No first-party `buyRbtc` selector remains.
- [x] Length-1 batch covers the old single-schedule happy path.
- [x] Dex runtime sizes recorded; still under EIP-170.
- [x] The length-1 batch gas premium is measured and accepted explicitly.
- [x] No open product decisions.

## Measured results

**Gas (length-1 batch vs the removed single selector, same lane and setup, snapshot-reverted between arms):**

| lane | `buyRbtc` | length-1 `batchBuyRbtc` | premium |
|---|---|---|---|
| idle (none) / MoC / DOC | 182,797 | 195,973 | +13,176 |
| LayerBank / MoC / DOC | 255,924 | 270,833 | +14,909 |
| Sovryn / MoC / DOC | 245,825 | 260,734 | +14,909 |
| Tropykus / MoC / DOC | 241,537 | 256,446 | +14,909 |
| Tropykus / Dex / USDRIF | 308,585 | 323,517 | +14,932 |

Accepted per the decision above: ~13–15k gas on the rare one-schedule tick, paid by the bot.

**Runtime bytecode (EIP-170 limit 24,576):**

| contract | before | after | freed | margin after |
|---|---|---|---|---|
| `DcaManager` | 17,098 | 16,547 | 551 | 8,029 |
| `SovrynErc20HandlerDex` | 22,833 | 22,173 | 660 | 2,403 |
| `TropykusErc20HandlerDex` | 23,089 | 22,429 | 660 | 2,147 |
| `LayerBankDocHandlerMoc` | 17,771 | 17,111 | 660 | 7,465 |
| `SovrynDocHandlerMoc` | 17,298 | 16,638 | 660 | 7,938 |
| `TropykusDocHandlerMoc` | 17,554 | 16,894 | 660 | 7,682 |
| `IdleDocHandlerMoc` | 12,910 | 12,219 | 691 | 12,357 |

Dex margin grows ~38–44%; that is the headroom R9 spends on share-transition events.

## Behavioral difference found while converting the tests

The length-1 batch is **not** a clamping equivalent of the removed single path on lending routes:

- `_retrieveStablecoin` → `_redeemShares` (single) **clamped** a share shortfall down to the shares held and emitted `TokenLending__AmountToRedeemAdjusted`.
- `_batchRetrieveStablecoin` (batch) debits each buyer's shares **rounded up** and **reverts** with `TokenLending__InsufficientShares` on any shortfall.

On a live lending fork with a static exchange rate the round-up costs ~1 wei of shares per purchase, so a schedule drained purchase-by-purchase can be a few wei of shares short on its final purchase while its token balance is still non-zero. This is the behavior production already had — the bot has always used `batchBuyRbtc` — so R39 does not change it; it only removes the lenient path nobody called. `testRevertPurchasetIfStablecoinRunsOut` was written against the single path and now withdraws the tail instead of spending it, so it still asserts the `DcaManager` balance guard on every lane. Whether the batch path should clamp is left to R43 (shared purchase path review); changing `batchBuyRbtc` semantics is out of scope here.

Left orphaned by this deletion and deliberately **not** removed (no ABI effect; unreachable internals are stripped from runtime bytecode by the compiler, and both are still exercised by handler-level tests): the single `_retrieveStablecoin` seam on `StablecoinSource` / `LendingErc20Handler` / `IdleErc20Handler`, and `FeeHandler._calculateFee`. Flagged for R43.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: remove `buyRbtc` on `DcaManager` and every purchase handler. Frontend follow-up only if the app ever sent it (it should not). Search `bitChillRSK/front-end` and comment if a call site exists; otherwise no issue.
- Scripts: none unless a script called `buyRbtc`.
- Cutover: swapper must use `batchBuyRbtc` even for one schedule.
