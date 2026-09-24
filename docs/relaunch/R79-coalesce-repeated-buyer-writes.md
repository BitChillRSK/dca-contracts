# R79 — coalesce repeated-buyer writes

Status: **implemented** · [#148](https://github.com/BitChillRSK/dca-contracts/pull/148) · Assigned: yes · Optional/further-review: no

## Objective

When consecutive rows of one handler batch belong to the same buyer, write that buyer's balance slot
once per run instead of once per row. This applies to the accumulated-rBTC credit in `PurchaseRbtc`,
the lending-share debit in `LendingErc20Handler`, and the idle-balance debit in `IdleErc20Handler`.
Every row still computes, checks, reverts, and emits exactly as it does today, in the same order and
with the same values. Only the storage writes collapse. No ABI, event, storage-layout, or `DcaManager`
change. Rows are made contiguous by the swapper sorting each batch by buyer. The contract works for
any order and saves only on contiguous runs.

## Background

Deferred from [R78](./R78-flat-fee-fast-path.md#r79-survivor-coalesce-repeated-buyer-writes), priced
on Rootstock there and in the [gas audit](./ROOTSTOCK-GAS-AUDIT.md). Constants are from
[`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md).

A batch is one handler's rows. `DcaManager._batchBuyRbtc` reads each row's buyer and amount from the
schedule, then hands the handler parallel `buyers` / `purchaseAmounts` arrays. A user with several
schedules on one stablecoin and route shows up once per schedule. Today the handler touches that
user's slots once per row:

| Loop | Slot | Per row today |
|---|---|---|
| `LendingErc20Handler._batchRetrieveStablecoin` | `s_shares[user]` | `SLOAD` + `SSTORE` (through `_setUserShares`, which also emits `UserSharesUpdated`) |
| `IdleErc20Handler._batchRetrieveStablecoin` | `s_idleBalances[user]` | `SLOAD` + `SSTORE` |
| `PurchaseRbtc.batchBuyRbtc` credit loop | `s_usersAccumulatedRbtc[buyer]` | `SLOAD` + `SSTORE` in `_creditRbtc`, skipped for a zero floor allocation |

Rootstock has no net metering. A write to a slot that is already nonzero costs `RESET` = 5,000, even
if the same transaction wrote that slot a moment ago. An `SLOAD` costs a flat 200. For a run of `k`
rows by one buyer, coalescing removes `k − 1` reads and `k − 1` writes on each mapping it touches:

```
(k − 1) × (200 + 5,000) = (k − 1) × 5,200 Rootstock gas per mapping
five same-buyer rows on a lending route: 4 × 5,200 × 2 mappings = 41,600
```

On an idle route the pair is idle balance plus rBTC, so the figure is the same. Foundry charges a warm
dirty rewrite about 100, so it shows only a few hundred gas for the same change. Per `AGENTS.md`,
Foundry numbers here are regression pins, and the Rootstock figure is derived from write counts
measured per slot.

The final write per run is exactly the write the last row makes today, `CLEAR` + refund included when
a debit empties the slot. Debits only go down, and a positive purchase amount rounds up to at least
one share, so no run can go to zero partway and then come back.

**Why order stays the swapper's choice.** The contract compares each row with the one before it and
flushes the run when the buyer changes. It keeps no in-memory map. Unsorted duplicates (`A, B, A`)
behave exactly as today, with one read and one write per run. So correctness never depends on order,
and the saving depends only on whether same-buyer rows sit next to each other. The swapper already
builds the array, so sorting by buyer costs nothing on chain.

### What live batches look like

Every `PurchaseRbtc__RbtcBought` the deployed handlers have emitted, read from Rootstock's public
Blockscout API on 2026-09-25 (blocks 7,783,853 to 9,265,925), grouped by transaction and handler:

| | |
|---|---:|
| batches | 100 |
| rows | 1,014 |
| rows whose buyer already has a row in the same batch | **118 (11.6%)** |
| of those, already next to that buyer's previous row | **118 (all)** |
| batches with at least one repeated buyer | 47 |

Every live batch so far kept each buyer's rows together, but the bot does not guarantee it: when it
splits a batch by gas, it sorts candidates by `nextPurchaseTime`, which can interleave buyers. The
swapper-bot follow-up asks for an explicit group-by-buyer on each final batch. The last live tick R64 replayed (`0xa6ac747a…`) happens to have
five different buyers, so it is not typical.

### Measured

`test/gas/R79RepeatedBuyerWritesGas.t.sol`: five rows, 20 tokens each, every buyer already holding live
rBTC, slots cooled. "Before" is the same harness run on this branch's base commit (`f2f8b00`). Foundry
gas is execution before refunds, a same-build regression figure.

| Five rows, Foundry | default before → after | deploy (`via_ir`) before → after |
|---|---:|---:|
| lending, one buyer | 189,230 → 185,960 (−3,270) | 182,575 → 180,102 (−2,473) |
| lending, five buyers | 227,617 → 228,375 (+758) | 220,967 → 221,990 (+1,023) |
| idle, one buyer | 115,547 → 112,145 (−3,402) | 113,284 → 110,864 (−2,420) |
| idle, five buyers | 153,947 → 154,573 (+626) | 151,688 → 152,772 (+1,084) |

Per buyer slot (shares or idle balance, and accumulated rBTC), both profiles: one buyer goes from 5
reads + 5 writes to 1 + 1. `A,A,B,B,B` goes from 2 + 3 to 1 + 1. Five unique buyers and `A,B,A,B,A`
keep one read and one write per run, which is what they had.

**Rootstock, derived.** Only storage prices differ between the schedules, and the write counts above
are exact. A five-buyer batch makes the same reads and writes as before, so its whole Foundry delta is
compute, which Rootstock prices the same way: **+205 per row (lending) and +217 (idle) under deploy**.
For the one-buyer batch, each mapping drops 4 reads (200 each on Rootstock) and 4 `RESET`s (5,000 each).
Foundry charged those as warm reads and dirty writes (100 each), so the compute part of its delta is the
total plus 1,600:

```
lending, deploy: 4 × (200 + 5,000) × 2 mappings + (−2,473 + 1,600) = −41,600 − 873 = −42,473
idle,    deploy:                                   −41,600 − 820            = −42,420
```

Each repeated row in a run therefore saves about **10,670** Rootstock gas under deploy (10,400 storage
plus about 270 compute). Each row that starts a run costs about **+210** in compute. Break-even is a
repeat rate of about 1.9%. At the historical 11.6%, the 1,014 rows would have saved about
118 × 10,670 − 896 × 210 ≈ **1.07 million gas**, about 10,700 per batch.

**Why the per-row overhead is ~210, not a few dozen.** `batchBuyRbtc` sits at the legacy profile's
stack limit: every variant that carried the run needed its two input-balance locals scoped to compile
there. Under via-IR, an opcode histogram of a ten-row unique-buyer batch (Foundry's debug-trace
cheatcode, handler frames only) shows no stack-to-memory spill: `MSTORE` is unchanged and there is one
extra `MLOAD` per row. The cost is ordinary stack traffic: per row, about 3 extra `JUMP`s, 11
`PUSH1`s, 14 `SWAP`s, and address masking for the compare. Five loop shapes were measured (compare with
previous buyer, look-ahead to next buyer, a private helper, a sentinel iteration, fewer live locals).
The shipped shape was the cheapest. In the handler loops, starting the run at the zero address instead
of testing `i == 0` saved about 57 per row.

## Open product decisions

**none**

## Scope

- [x] `LendingErc20Handler._batchRetrieveStablecoin`: carry the current buyer and their running share
      balance on the stack. When the buyer changes, store the previous buyer's running balance and
      load the new buyer's. The run starts at the zero address, which never holds shares, so its
      store is skipped rather than guarded by an index test. Each row still sizes its debit with the same ceil, reverts with
      `TokenLending__InsufficientShares(user, needed, running)` against the running balance (the same
      value storage would hold today), and emits `TokenLending__UserSharesUpdated(user, previous,
      new)` for its own transition. After the loop, store the last run before the protocol redeem.
- [x] Split `_setUserShares` into a write and a transition-log helper, so the batch path can log per
      row and write per run. Deposit and single redeem keep write + log together, unchanged.
- [x] `IdleErc20Handler._batchRetrieveStablecoin`: the same run logic for `s_idleBalances`, with
      `IdleErc20Handler__InsufficientIdleBalance` checked against the running balance. No storage
      sentinel (R78 closed idle sentinels as zero-sum on Rootstock); the zero-address start of a run
      is a stack value, not stored state.
- [x] `PurchaseRbtc.batchBuyRbtc`: sum each contiguous buyer run's floor allocations and call
      `_creditRbtc` once per run when the sum is nonzero. A run of only zero allocations still leaves
      a never-credited user at `0`, as today. Every `PurchaseRbtc__RbtcBought` is emitted per row with
      its current value, in its current order. `_creditRbtc` stays the only writer (invariant 13).
      To fit the legacy profile's stack, the two input-balance locals move into a block, and the loop
      reads `_purchaseToken()` (an immutable) and `buyers.length` instead of holding them.
- [x] Add `test/gas/R79RepeatedBuyerWritesGas.t.sol`. Count writes per buyer slot with
      `vm.startStateDiffRecording` for single-buyer, clustered, unique, and unsorted-duplicate
      batches, on a lending handler and an idle handler. Log Foundry gas before and after on both
      profiles.
- [x] Add a differential fuzz test. It compares the new batch retrieval against a copy of today's
      per-row loop kept in the test, and the new rBTC credits against a per-row replay of today's
      credit rule, on the same fuzzed state and rows.
- [x] Open a `swapper-bot` issue: within each `Batch`, place one buyer's rows next to each other
      ([swapper-bot#5](https://github.com/BitChillRSK/swapper-bot/issues/5#issuecomment-5823311821)).
- [x] Update `docs/relaunch/README.md` Status and `IMPLEMENTATION_ORDER.md`.

## Out of scope

- [ ] Any `DcaManager` change, including sorting or grouping rows on chain. The array order is the
      swapper's.
- [ ] Coalescing non-contiguous duplicates (an in-memory map). It costs every batch a lookup to save
      only badly ordered ones.
- [ ] Changing any event, its fields, or its order, including folding per-row `UserSharesUpdated`
      or `RbtcBought` into one per run.
- [ ] Sentinels on share or idle mappings (closed in R78 as `SET − REFUND = RESET`).
- [ ] Assembly (invariant 5).
- [ ] `TokenLending__SharesRedeemedBatch`, the protocol redeem, fee math, or the allocation formula.

## Files likely touched

- `src/PurchaseRbtc.sol`
- `src/LendingErc20Handler.sol`
- `src/idle/IdleErc20Handler.sol`
- `test/gas/R79RepeatedBuyerWritesGas.t.sol` (new)
- `test/unit/R79CoalescedWritesDifferential.t.sol` (new)
- `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`

## Required tests

- `forge test --match-path test/gas/R79RepeatedBuyerWritesGas.t.sol -vv`, and the same with
  `FOUNDRY_PROFILE=deploy`. Assert exactly one write per contiguous run on each buyer slot:
  five same-buyer rows → 1, `A,A,B,B,B` → 1 each, five unique buyers → 1 each, `A,B,A,B,A` → 3 for
  `A` and 2 for `B`. Record Foundry gas for five same-buyer and five unique-buyer rows, before and
  after, on both profiles.
- `forge test --match-path test/unit/R79CoalescedWritesDifferential.t.sol` on both profiles. Fuzz
  over up to 12 rows drawn from a pool of three buyers, so single-buyer, clustered, and unsorted
  runs all come up, with fuzzed deposits, amounts, and rBTC out (including outputs small enough to
  floor rows to zero), and pre-existing rBTC states of never credited, sentinel `1`, and live. Assert
  both variants succeed or revert with the same data. On success, assert the handler's logs are
  equal and in the same order, every pool buyer's final share / idle balance is equal, the batch
  total is equal, and the raw accumulated-rBTC slot equals the per-row replay. Mutation-checked: the
  suite fails if the last run's idle store or rBTC credit is dropped, or if the lending revert reports
  the stored balance instead of the running one.
- Existing suites stay green unchanged, including the invariant suite and every
  `batchRetrieveStablecoin` revert test.
- `make check`, `make check-deploy`, `make fork-sovryn`, `make fork-tropykus`. No fork-specific
  assertions.

## Success criteria

- [x] One write per contiguous buyer run on each of the three mappings, on both profiles.
- [x] Differential fuzz green: per-row events, reverts, rounding, totals, and final state identical to
      today's per-row behavior.
- [x] A unique-buyer batch's regression is recorded and justified. **Revised during
      implementation:** the first draft asked for no more than a few dozen gas per row. Measured, it
      is +205 / +217 per row under deploy (lending / idle) and +152 / +125 on default, after trying five
      loop shapes. It is kept because the historical repeat rate (11.6%) is six times the ~1.9%
      break-even. See **Measured**.
- [x] Rootstock delta derived from measured write and read counts, labelled as such.
- [x] `make check`, `make check-deploy`, and both fork lanes green.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants still hold. 5: no assembly. 11: the external share burn still equals the sum
      of per-row virtual debits. 12: purchase-input consumption is unchanged. 13: `_creditRbtc` is
      still the only writer of accumulated rBTC.
- [ ] Every run is flushed before any external call reads or moves value: the lending flush happens
      before `_measuredProtocolRedeem`, and the rBTC flush happens before the batch event and the
      function's return.
- [ ] Tests match **Required tests**.
- [ ] Files beyond this list are direct dependencies and are named in the PR.

## ABI / deploy / cutover impact

- ABI: none. Selectors, events, errors, and storage layout are unchanged.
- Scripts: none.
- Cutover: `swapper-bot` must keep each buyer's rows adjacent within a `Batch`
  ([swapper-bot#5](https://github.com/BitChillRSK/swapper-bot/issues/5#issuecomment-5823311821)). Every
  historical batch already does, but the gas split's sort can interleave buyers, so the bot should group
  explicitly. A batch that splits a buyer's rows stays correct but saves nothing on the split rows.
  No other consumer is affected: events and their order are unchanged.
