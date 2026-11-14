# R81 — one storage write per packed slot

Status: **implemented** · GitHub [#142](https://github.com/BitChillRSK/dca-contracts/pull/142) · Assigned: yes · Optional/further-review: no

## Objective

Stop the compiler from writing the same packed storage word several times in one call on the purchase
row's `DcaSchedule` slot 0 in `_rBtcPurchaseChecksEffects` and the new schedule in `createDcaSchedule`.
Rootstock charges every extra write a full `RESET` (5,000). Foundry charges a warm rewrite about 100,
so the waste never showed up in review. No behavior, ABI, event, event-order, or storage-layout change,
and no assembly. The fee-word path in `setFeeRateParams` was measured and declined: owner-only and
rare (at most yearly); the per-field if/write/emit shape is clearer.

## Background

Found by the [Rootstock gas audit of `src/`](./ROOTSTOCK-GAS-AUDIT.md). Pricing is from
[`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md#packed-field-writes).

Solidity writes a packed struct field as a read, a mask, and an `SSTORE` of the whole word. Both
codegens (legacy and via-IR) merge two such writes to one word only when they are adjacent and nothing
that can revert, log, or call sits between them. A `SafeCast` call, an `emit`, or a struct literal that
assigns every field one at a time is enough to keep them apart.

On Ethereum/Cancun the second write to a dirty slot costs ~100 gas, so a Foundry diff reports the merge
as ~200 gas. On Rootstock every write to a non-empty slot is `RESET_SSTORE` = 5,000.

### Measured (audit harness, commit `8d07bf9`, stub handler — see the audit record for method)

"Cancun" is execution gas on the same schedule Foundry uses. "RSK storage" is every traced `SLOAD` /
`SSTORE` in the call, priced with rskj constants. Only the storage part differs between the two
schedules; compute, memory, and logs price the same.

**Purchase row** (`batchBuyRbtc`, later purchase, anchor non-zero → non-zero). Today slot 0 is written
twice per row: `tokenBalance` at `DcaManager.sol:631`, then `cadenceAnchor` at `:634`. The two writes are
separated by an `emit` and by `newAnchor.toUint48()`. Hoisting the cast above both writes and making
the writes adjacent, with both emits after them in the same order, merges them into one write on both
profiles:

| Profile | Cancun 1 row | RSK storage 1 row | RSK storage 4 rows |
|---|---:|---:|---:|
| default | 19,223 → 19,008 (−215) | 17,200 → 12,000 (**−5,200**) | 52,000 → 31,200 (−20,800) |
| deploy (`via_ir`) | 18,322 → 18,107 (−215) | 16,600 → 11,400 (**−5,200**) | 49,600 → 28,800 (−20,800) |

The saving is paid by the protocol on every row of every tick: about 520,000 gas on a 100-row batch.
Just making the writes adjacent while leaving the cast between them does **not** merge them; that
variant was measured and still writes the slot twice.

This table is the audit at `8d07bf9`, before the cadence event was removed. The shipped purchase path
saves **−5,200** Rootstock gas per row on the default profile and **−5,400** under deploy: the same
removed `RESET`, plus one removed slot-0 `SLOAD` on default and two under deploy.

**`createDcaSchedule`.** The struct literal at `DcaManager.sol:151` writes slot 0 once per field,
five times in all, including the zero `cadenceAnchor` and `paused`. That is a `SET` (20,000) followed by
four `RESET`s (5,000 each). Measured variants:

| Variant | default slot writes (0+1) | deploy slot writes (0+1) | RSK storage default | RSK storage deploy |
|---|---:|---:|---:|---:|
| struct literal (today) | 5+2 | 5+1 | 128,600 | 123,400 |
| memory struct, then one assignment | 5+2 | 5+1 | 128,600 | 123,400 |
| storage pointer, non-zero fields in declaration order | **3+2** | **2+1** | **118,200** (−10,400) | **107,800** (−15,600) |
| storage pointer, non-zero fields in reverse order | 3+2 | 2+2 | 118,200 | 113,200 |

Cancun reports only −926 (default) and −1,052 (deploy) for the winning variant in that table.
Skipping the two zero fields is sound because a new `(token, scheduleId)` key always addresses two
empty slots: ids come from a strictly increasing nonce and are never reissued (invariant 7).

The table stops at declaration order inside the create function. Assigning from a small helper, with
`routeIndex` before `purchasePeriod`, stores each slot once on both profiles. Against the struct
literal that is Foundry **−2,178 / −1,273** and Rootstock **−26,200 / −20,800**. Declaration order
inside the helper still stores slot 0 twice under deploy.

**`FeeHandler.setFeeRateParams`.** Since R78 all four fee fields share one word. The setter compares,
casts, writes, and emits per field, so changing all four writes the word four times: 21,000 RSK
storage under deploy vs 9,104 Cancun. Merging the writes was measured (Foundry **−782 / −496**,
Rootstock **−16,200 / −15,600**) and **declined**: the path is owner-only and at most yearly, and the
per-field if/write/emit shape is easier to read. R81 does not change `FeeHandler.sol`.

## Open product decisions

**none**

## Scope

- [x] `_rBtcPurchaseChecksEffects`: compute `newAnchor.toUint48()` before either field write, then
      write `tokenBalance` and `cadenceAnchor` back to back, then emit `TokenBalanceUpdated`. R80
      already removed `CadenceAnchorUpdated`. The two assignments live in `_storePurchaseProgress`:
      the same statements inside `_rBtcPurchaseChecksEffects` compile to two `SSTORE`s (the frame is
      too deep for the legacy combiner). The helper is one store per row on both profiles.
- [x] `createDcaSchedule`: a storage pointer assigns only `tokenBalance`, `routeIndex`,
      `purchasePeriod`, `user`, and `purchaseAmount`, in that order, from `_storeNewSchedule`.
      `routeIndex` precedes `purchasePeriod` because declaration order still stores slot 0 twice
      under deploy. Zero `cadenceAnchor` and `paused` stay unset because a new id addresses empty
      storage. Both profiles store slots 0 and 1 once each.
- [x] `setFeeRateParams`: **declined.** Measured, then left as the per-field if/write/emit shape.
      See Background.
- [x] Add `test/gas/R81PackedSlotWritesGas.t.sol`, which counts writes per slot with
      `vm.startStateDiffRecording()` / `vm.stopAndReturnStateDiff()` (the `isWrite` storage accesses).
- [x] Existing Foundry gas pins (`test/gas/R64*`, `R77*`, `R78*`) did not move. R77 and R78 were re-run.
- [x] Update `docs/relaunch/README.md` Status and `IMPLEMENTATION_ORDER.md`.

## Out of scope

- [ ] Assembly on any path (invariant 5). If a word cannot be merged in Solidity, record the count;
      do not reach for `sstore`.
- [ ] R80 (removing the cadence event) and R79 (coalescing writes for a repeated buyer across rows).
- [ ] The swap-and-pop double write in `deleteDcaSchedule` (closed in the audit record).
- [ ] Any change to `DcaSchedule` field order or width, `ProtocolSettings`, or the fee layout.
- [ ] Merging `setFeeRateParams` into one fee-word write (measured and declined; owner-rare).
- [ ] The reentrancy guard (R82).

## Files likely touched

- `src/DcaManager.sol`
- `test/gas/R81PackedSlotWritesGas.t.sol` (new)
- `test/gas/R64BatchGasBenchmark.t.sol`, `test/gas/R77AccumulatedRbtcSentinelGas.t.sol`,
  `test/gas/R78FlatFeeFastPathGas.t.sol` (only pins that move)

## Required tests

- `forge test --match-path test/gas/R81PackedSlotWritesGas.t.sol -vv` and the same command with
  `FOUNDRY_PROFILE=deploy`.
- Assert **exactly one** write to the schedule's slot 0 per row for a 1-row and a 5-row
  `batchBuyRbtc`, on both profiles, for both a first purchase (anchor 0) and a later one.
- Assert that `createDcaSchedule` writes fewer times to slots 0 and 1 than today on both profiles.
  Record the exact per-profile counts in the PR.
- Behavior must not change: `getDcaSchedule` after create returns `cadenceAnchor == 0` and
  `paused == false`; events and their order are unchanged on purchase and create. The existing
  suites cover this and must stay green.
- `make check`, `make check-deploy`; fork lanes per `AGENTS.md`. No fork-specific assertions.

## Success criteria

- [x] One `SSTORE` to slot 0 per purchase row on both profiles.
- [x] `createDcaSchedule` write counts are pinned exactly on both profiles (slots 0 and 1 once each).
- [x] `setFeeRateParams` left readable; merge measured and declined (see Background).
- [x] Each saving is stated on both schedules: Foundry/Cancun measured, Rootstock derived as
      5,000 per removed `RESET` plus 200 per removed `SLOAD`. See the R81 entry in
      `IMPLEMENTATION_ORDER.md`.
- [x] No ABI, event, or storage-layout change.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (5: no assembly; 7: ids never reissued, which is
      what makes skipping the zero fields safe).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none.
- Cutover: none. Events, their arguments, and their order are unchanged.
