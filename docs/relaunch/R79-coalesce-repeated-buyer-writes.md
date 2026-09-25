# R79 — coalesce repeated-buyer writes

Status: **closed without implementation** (2026-09-25) · [#148](https://github.com/BitChillRSK/dca-contracts/pull/148) ·
Assigned: yes · Optional/further-review: no

The optimization was implemented, fuzzed, and measured, then withdrawn. It saves about 1% of a
batch's gas, a couple of dollars a year at current activity, and it would move balance accounting in
three immutable loops from per-row writes to deferred run-level state. This record keeps the
measurements so the question is not reopened without new data. The implementation is preserved at
the tag [`archive/r79-coalesced-writes`](https://github.com/BitChillRSK/dca-contracts/tree/archive/r79-coalesced-writes).

## What was proposed

When consecutive rows of one handler batch belong to the same buyer, write that buyer's balance slot
once per run instead of once per row. This covers the accumulated-rBTC credit in `PurchaseRbtc`, the
lending-share debit in `LendingErc20Handler`, and the idle-balance debit in `IdleErc20Handler`. Every
row would still compute, check, revert, and emit exactly as before. Only the storage writes collapse.
The swapper would sort each batch by buyer. The contract would compare each row with the previous one
and flush when the buyer changes, with no in-memory map.

It came from [R78's deferred record](./R78-flat-fee-fast-path.md#r79-survivor-coalesce-repeated-buyer-writes),
which ranked it the largest surviving gas opportunity, and the [gas audit](./ROOTSTOCK-GAS-AUDIT.md)
kept it on that basis.

## Why Rootstock makes it look attractive

Rootstock has no net metering. A write to a slot that is already nonzero costs `RESET` = 5,000, even
if the same transaction wrote that slot a moment earlier, and every `SLOAD` costs a flat 200
([`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md)). For a run of `k` rows by one buyer,
coalescing removes `k − 1` reads and `k − 1` writes on each mapping:

```
(k − 1) × (200 + 5,000) = (k − 1) × 5,200 Rootstock gas per mapping
```

Each row touches two mappings: the stablecoin side (shares or idle balance) and accumulated rBTC.
Foundry charges a warm dirty rewrite about 100, so it shows only a few hundred gas for the same
change.

## What was measured

The implementation ([`10e94a5`](https://github.com/BitChillRSK/dca-contracts/commit/10e94a571bb275465f3118678017d1f3d88b578b) on the
archive tag) passed `make check`, `make check-deploy`, `make fork-sovryn`, and `make fork-tropykus`.
A differential fuzz suite compared it against a copy of the per-row loop, over 1,000 runs per test
on both profiles: identical revert data, return data, logs in order, and per-buyer slots. A
state-diff gas test pinned one write per contiguous run on each slot.

Five rows, Foundry `deploy` profile (execution before refunds, a same-build regression figure):

| Five rows | before → after |
|---|---:|
| lending, one buyer | 182,575 → 180,102 |
| lending, five buyers | 220,967 → 221,990 |
| idle, one buyer | 113,284 → 110,864 |
| idle, five buyers | 151,688 → 152,772 |

Derived for Rootstock from exact read and write counts (only storage prices differ between the
schedules):

- **Each repeated adjacent row saves about 10,670** (10,400 storage plus about 270 compute).
- **Each row that starts a run costs about +210** in compute. The loop sits at the legacy profile's
  stack limit, and five loop shapes were measured; this was the cheapest.
- A five-row single-buyer batch saves about 42,470. A unique-buyer batch gets slightly more
  expensive.
- Break-even is a repeat rate of about **1.9%**.

## What live batches look like

Every `PurchaseRbtc__RbtcBought` the deployed handlers emitted, read from Rootstock's Blockscout on
2026-09-25 (blocks 7,783,853 to 9,265,925), grouped by transaction and handler:

| | |
|---|---:|
| batches | 100 |
| rows | 1,014 |
| rows whose buyer already has a row in the same batch | 118 (11.6%) |
| of those, already next to that buyer's previous row | 118 (all) |
| batches with at least one repeated buyer | 47 |

Over that history the change would have saved `118 × 10,670 − 896 × 210 ≈ 1.07 million` gas, about
**10,700 gas per batch**. The 53 batches with no repeated buyer would each have cost slightly more:
about 210 gas per row, so about 2,000 for a 10-row batch, roughly 0.2% of a batch.

## Why it was not implemented

The saving is real and above break-even, but it does not pay for itself:

- **It is about 1% of a batch.** The swapper's 98 successful `batchBuyRbtc` transactions
  (2025-07-16 to 2026-09-23) used a median 1,051,292 gas and a mean 1,153,103. 10,700 is about 0.9–1.0%
  of that. The 42,000 figure that made R78 rank it first is the dense five-row single-buyer case,
  measured against a small five-schedule tick, not the average.
- **It is worth a few cents per batch.** Those transactions paid 0.026–0.030 gwei. At 0.03 gwei and
  BTC at $83,489 (CoinGecko, 2026-09-25), 10,700 gas is about **$0.027 per batch**, and a whole batch
  about $2.90. The swapper sent 61–90 batches a year (last 90 days annualised, and last 365 days), so
  R79 would save about **$1.60–$2.40 a year** out of roughly $180–$260 of swapper gas. Even 100 times
  today's activity puts it near $200 a year.
- **It saves operator cost, not user cost.** Batch gas is paid by BitChill's swapper. No user call
  gets cheaper.
- **It depends on off-chain ordering.** The saving needs the swapper to keep each buyer's rows
  adjacent. Every live batch so far did, but the bot's gas split sorts by `nextPurchaseTime` and can
  interleave buyers. The +210 per run-start is paid on every batch whether or not the ordering holds.
- **It costs audit and maintenance surface in immutable balance accounting.** Three core loops would
  change (+84 / −25 in `src/`). Balances would be carried as running values on the stack and written
  at run boundaries, which is harder to audit than one write per row, and the correctness argument
  depends on flush placement before external calls. The 632 lines of specialized tests that justify it
  would also have to be maintained.

There is also no batch-capacity problem for it to solve. No live batch has approached a gas or size
limit, and if one did, the swapper could split it into smaller batches with no contract change.

## When to reopen

The contracts are immutable, so R79 can only come back as part of a redeploy already planned for
other reasons. Nothing below is grounds to redeploy for R79 alone. At such a redeploy, reconsider it
only with new data showing one of these:

- batches regularly near a block gas or size limit, where splitting them into more transactions has
  become materially expensive and per-row storage is the binding cost;
- a sustained repeat rate and batch volume large enough that the yearly saving becomes material
  against the audit cost, at the gas and BTC prices of that time.

Start from the archive tag. Its spec (the version on the tag) has the full scope, the required tests,
the measured loop shapes, and the reviewer checklist.

## Consumer impact

None. Nothing shipped. The `swapper-bot` request to group each batch by buyer
([swapper-bot#5](https://github.com/BitChillRSK/swapper-bot/issues/5#issuecomment-5823311821)) is
withdrawn.
