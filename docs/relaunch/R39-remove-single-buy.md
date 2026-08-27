# R39 — Remove `buyRbtc`

Status: **not started** · Assigned: no · Optional/further-review: no

**Must land before R9 (ABI freeze).**

## Objective

Delete the single-schedule `buyRbtc` entry points on `DcaManager` and `PurchaseRbtc`. Production already uses `batchBuyRbtc`; a batch of length 1 is the remaining one-schedule path.

## Background

`DcaManager.buyRbtc` and `PurchaseRbtc.buyRbtc` are swapper-only. The bot always builds batches. Keeping both paths doubles the purchase pipeline, the tests, and Dex bytecode (R31 left a few hundred bytes of EIP-170 margin before R9 adds share-transition events).

A length-1 `batchBuyRbtc` is not a perfect clone of the old single path (array checks, aggregated fee, `PurchaseRbtc__SuccessfulRbtcBatchPurchase`), but it is the same cash motion: one retrieve, one fee transfer, one MoC/Uniswap spend, one `PurchaseRbtc__RbtcBought`. That is enough for debug and retries.

Decided 2026-08-27: **delete**. Do not keep it as a hidden debug selector.

## Open product decisions

**none** — delete; length-1 batch remains.

## Scope

- [ ] Remove `DcaManager.buyRbtc` and `IDcaManager.buyRbtc`.
- [ ] Remove `PurchaseRbtc.buyRbtc` and `IPurchaseRbtc.buyRbtc`.
- [ ] Convert every test that called the single path to `batchBuyRbtc` of length 1 (or drop it if it only existed to compare the two). `ComparePurchaseMethods` is mainnet-only and already excluded from CI; delete its single-path arm or the file if nothing remains.
- [ ] Re-measure Dex handler runtime sizes vs EIP-170. Record before/after in the PR. This is the bytecode that R9 spends.

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
- `dcaManager.buyRbtc` / `handler.buyRbtc` are gone (no selector).
- Existing batch tests unchanged.
- Fork: no new assertions. Still run `make fork-sovryn` and `make fork-tropykus` before push.

## Success criteria

- [ ] No first-party `buyRbtc` selector remains.
- [ ] Length-1 batch covers the old single-schedule happy path.
- [ ] Dex runtime sizes recorded; still under EIP-170.
- [ ] No open product decisions.

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
