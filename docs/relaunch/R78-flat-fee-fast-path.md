# R78 — Flat-fee purchase fast path

Status: **implemented** · GitHub [#139](https://github.com/BitChillRSK/dca-contracts/pull/139) · Assigned: yes · Optional/further-review: no · Order: stack on R77 ([#138](https://github.com/BitChillRSK/dca-contracts/pull/138))

## Objective

Avoid loading and evaluating the linear fee curve when a handler is configured with the launch's
flat fee (`minFeeRate == maxFeeRate`). Preserve the existing variable-fee configuration and results.

## Background

R74 selects a flat 100-bps launch fee but deliberately keeps the existing owner-controlled linear
fee model available. `FeeHandler._calculateFeeAndNetAmounts` currently loads both packed fee-storage
words into a `FeeSettings` struct before it knows the rate is flat. The purchase then tests
`minFeeRate == maxFeeRate` again for every row in `_calculateFeeWithParams`; the amount bounds are
irrelevant in that configuration.

The rates and collector share one storage word. The two purchase bounds share a second word. A flat
fast path can load only the rate word, choose one loop for the complete batch, and leave the bounds
word cold. The variable path must continue to load the bounds and use the same interpolation math.

Foundry executes these tests on an Ethereum Cancun gas schedule, while production runs on Rootstock.
The fast path avoids exactly one storage read, so its production value must adjust Foundry's cold
`SLOAD` price to Rootstock's flat price; see
[`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md).

## Open product decisions

**none** — this is behavior-preserving execution work. The approved fee remains 100 bps at launch,
and governance retains the same atomic setter and variable-fee range.

## Scope

- [x] In `_calculateFeeAndNetAmounts`, load the packed min/max rates first and choose the flat path
      once per batch when they are equal.
- [x] On the flat path, do not load `s_feePurchaseLowerBound` or `s_feePurchaseUpperBound`; calculate
      every row as `amount * flatRate / BPS_DENOMINATOR` with the existing per-row rounding.
- [x] Preserve the variable path's `_calculateFeeWithParams` behavior, aggregation, checked
      overflows, and net-amount array exactly.
- [x] Add focused correctness coverage for flat and variable batches, including row-by-row rounding.
- [x] Add a gas harness and record default-profile and shipped `FOUNDRY_PROFILE=deploy` deltas against
      R77 for representative one-row and multi-row batches, labelled as Foundry / Cancun.
- [x] Derive the Rootstock production delta from the one avoided storage read and the unchanged
      memory/compute work, using the repository's Rootstock gas-schedule reference.
- [x] Update `docs/relaunch/README.md` and `IMPLEMENTATION_ORDER.md` with R78.

## Out of scope

- [ ] Removing the linear fee model, its amount bounds, its setter, or any fee event.
- [ ] The deferred candidates below. They are recorded for future investigation, not assigned for
      implementation by this spec.

## Deferred optimization record

This record uses Rootstock production economics, not Foundry's Ethereum Cancun prices. In particular,
Rootstock has no EIP-2200 net metering: every write to an already-nonzero slot costs 5,000 gas, even
when the same slot was written earlier in the transaction. Conversely, the identity
`SET − REFUND = RESET` makes every clear-and-later-set versus keep-nonzero proposal system-neutral.
See [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md) for the constants and sources.

### R79 survivor: coalesce repeated-buyer writes

**Candidate.** Have the swapper sort each handler batch by buyer. In the contract, accumulate one
contiguous buyer run and flush it once to `_creditRbtc`; do the same for `_setUserShares` on lending
handlers. Because `_setUserShares` currently couples the write with the canonical transition event,
R79 must separate those responsibilities: emit the same previous→new transition for every row while
persisting only the final balance at the run flush. Per-row fee/rBTC calculations and every existing
event remain in their current order and retain their current values. The idle-balance path can be
evaluated separately, but it must not use a sentinel (see the closed items below).

**Rootstock upside.** A five-row single-buyer batch currently writes the same accumulated-rBTC slot
five times and the same lending-share slot five times. Rootstock charges 5,000 for every nonzero-slot
write, including repeat writes within one transaction. Coalescing saves four writes per mapping:

```
4 avoided writes × 5,000 × 2 mappings = approximately 40,000 gas
```

That is about 5% of the 815,384-gas live tick recorded by R64. Foundry shows only approximately 800
gas for the same structural change because its warm dirty-slot writes cost approximately 100; using
that number ranked this candidate about 50 times too low.

**Why ordering is not a blocker.** Contiguous rows are a batch-construction choice, not a protocol
constraint: the swapper already constructs the array and can sort it by buyer for free off-chain. The
contract then needs only compare-with-previous-row and a run flush, not a general in-memory map. R79
must coordinate that ordering with the swapper team, but the contract ABI, events, and consumer
surface remain unchanged.

**Required proof.** Write a dedicated R79 spec when assigned. Differential fuzzing must prove
per-row outputs, reverts, rounding, totals, and event equivalence. Benchmark unique buyers,
clustered duplicates, and adversarial unsorted duplicates under both Foundry profiles, then derive
the Rootstock write delta explicitly. Include both rBTC credits and lending-share debits and ensure a
unique-buyer batch does not regress materially. **Priority:** largest surviving gas opportunity, but
not deployment-deadline-bound.

### R80 survivor: remove `DcaManager__CadenceAnchorUpdated`

**Candidate.** Remove the event declaration and its only emit, currently in
`DcaManager._rBtcPurchaseChecksEffects` at `DcaManager.sol:635`. Do not consolidate it with
`DcaManager__TokenBalanceUpdated`: that event is emitted from four sites and is the canonical
balance-change record, so changing only its purchase-path shape would break that property for
consumers.

**Rootstock upside.** Removing the cadence event saves **1,813 gas per purchased row under the deploy
(`via_ir`) profile** and **1,946 gas per row under the default legacy-codegen profile**. The pure LOG3
component is profile-invariant: `375 + 3 × 375 + 8 × 32 = 1,756`. Compiler-generated compute around
the emit accounts for the remaining 57 gas under deploy and 190 gas under default. Both components
transfer to current Rootstock because its LOG and ordinary compute prices match the measured EVM
schedule; this path changes no storage access whose price would need a Rootstock-specific conversion.

Reproduction method:

```bash
# Temporarily remove the event emit, then run each profile:
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn \
  STABLECOIN_TYPE=DOC forge test --match-path test/unit/RbtcPurchaseTest.t.sol --gas-report

FOUNDRY_PROFILE=deploy SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn \
  EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-path test/unit/RbtcPurchaseTest.t.sol --gas-report
```

Under default, the median `batchBuyRbtc` result moves **179,090 → 177,144** and the largest case moves
**365,143 → 353,467**, exactly `6 × 1,946`. Under deploy, the median moves
**173,704 → 171,891** and the largest case moves **352,573 → 341,695**, exactly `6 × 1,813`.
Only the test that expects this event fails in either profile.

**Information preservation.** `getDcaSchedule()` returns the current `cadenceAnchor`. An indexer that
holds the prior anchor and purchase period can reproduce the new anchor exactly with the formula in
`DcaManager._rBtcPurchaseChecksEffects` (currently `DcaManager.sol:608-620`): use the current UTC-day
start; on a subsequent purchase, advance the prior anchor by the whole number of elapsed periods.

**Required proof and cutover.** Write a dedicated R80 spec when assigned. It needs a product decision,
the measured gas test, the event expectation update, an ABI diff, migration/backfill guidance, and a
consumer wave across `front-end`, `swapper-bot`, `data-api`, `bitchill-monitoring`, and
`metrics-dashboard`, which are already mid-cutover for R75. **Priority:** smaller than R79, but it is
ABI-affecting and immutable/unproxied contracts cannot drop the event after relaunch deployment, so
R80 must be scheduled first.

### Closed: nonzero-slot retention has zero Rootstock system value

These five candidates are closed as chain-invalid gas optimizations:

| Candidate | Rootstock closure |
|---|---|
| Retain a finite residual/sentinel Uniswap router allowance | Its claimed storage win replaces `CLEAR` + `SET` with `RESET`; `SET − REFUND = RESET`, so system storage gas is zero. See [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md). |
| Seed handler stablecoin or WRBTC balances | The seed keeps a token balance nonzero, making the same `CLEAR` + `SET` → `RESET` substitution; `SET − REFUND = RESET`. See [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md). |
| Keep one atomic unit in the fee collector | The retained unit changes the next balance creation to a reset but forgoes the prior clear refund; `SET − REFUND = RESET`. See [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md). |
| Add sentinels to lending-share mappings | The encoded slot moves cost between the clearing purchase and later deposit but creates no system saving because `SET − REFUND = RESET`. See [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md). |
| Add sentinels to idle-balance mappings | The encoded slot has the same zero-sum storage substitution: `SET − REFUND = RESET`. See [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md). |

Some could move cost between the user, swapper, venue, or treasury as R77 intentionally does, but
none creates a saving. The allowance and seed variants also add approval exposure or permanently
unowned dust. Do not reopen them as gas optimizations unless Rootstock activates a proposal such as
RSKIP-243 and changes its storage schedule.

An unlimited router allowance could additionally skip later approval calls and their log/compute
cost, so it is not the same arithmetic claim. It remains rejected on security grounds: idle handlers
hold pooled deposits, and a compromised or changed router must not gain access beyond the exact
purchase. A bounded reusable allowance has the same residual-exposure problem and needs a separate
security design; it is not a resurrection of the invalid approximately-12,300-gas storage claim.

### Closed: repack all fee settings into one word

The four settings do not currently fit one word: two `uint16` rates plus two `uint128` bounds total
288 bits. Narrowing both bounds to `uint112` would fit exactly; `uint96` would match the maximum
purchase amount stored in a schedule. A dedicated storage struct would also be required so Solidity
starts the settings on a fresh word instead of using the 12 bytes left beside Ownable2Step's
`_pendingOwner`. The public `FeeSettings` struct could retain its `uint128` fields, but the setter
would then reject values above the narrower internal width, so this is still a configuration and
storage-layout change rather than a free reorder.

It does not improve the shipped flat-fee purchase path on Rootstock. Today fee calculation reads the
rate/collector word and `_transferFee` later reads that same word again. With one settings word, fee
calculation would read it and `_transferFee` would instead read a separate collector word. Rootstock
charges 200 gas for every `SLOAD`, including repeated reads, so both layouts cost two reads = 400 gas.
Materializing the complete settings struct would also restore fixed memory/unpacking work that the
flat path deliberately avoids. The repack would save one 200-gas read only on variable-fee batches,
and one read on the external view getter; neither is the launch hot path. A one-word struct could
also coalesce rare owner writes, but governance configuration is not frequent enough to justify the
layout and accepted-range change. Keep the present collector-plus-rates / bounds layout.

### Closed: remove the linear fee model

R78 already leaves the purchase-bound word unread and skips interpolation whenever the configured fee
is flat. Deleting the variable model therefore saves approximately **0 additional production gas** on
the shipped flat configuration while permanently removing governance's option to choose a variable
fee from immutable contracts. No proxy exists anywhere in `src/`. Keep the model.

### Closed: merge stablecoin and rBTC accounting

R50 already rejected combining these mappings. Idle balances and lending shares use different units
and lifecycle rules from accumulated rBTC, and the fields sit in separate inheritance responsibilities.
Packing would couple independent deposit/withdraw and purchase/claim paths, need different layouts
for idle and lending handlers, and pay masking/repacking costs. This is an architectural redesign, not
a local gas optimization; retain the current separation.

## Files likely touched

- `AGENTS.md`
- `src/FeeHandler.sol`
- `test/ai-generated/unit/FeeHandlerTest.t.sol`
- `test/gas/R78FlatFeeFastPathGas.t.sol`
- `docs/relaunch/R78-flat-fee-fast-path.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/README.md`

## Required tests

```bash
forge test --match-contract FeeHandlerTest
forge test --match-path test/gas/R78FlatFeeFastPathGas.t.sol -vv
FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R78FlatFeeFastPathGas.t.sol -vv
make check
make check-deploy
make fork-sovryn
make fork-tropykus
```

Assert that flat and variable batch results equal sequential `_calculateFeeWithParams` calls for
every row, including amounts that round down to zero fee. The gas harness compares the same flat-fee
batch before and after this PR under Foundry / Cancun; the storage-access test separately proves that
the optimized branch avoids exactly one word. This item adds no fork-only assertion.

Foundry / Cancun measurements in the same-build R77-reference/R78-fast-path harness:

| Foundry profile | One row | Five rows |
|---|---:|---:|
| default | 2,462 gas saved | 3,259 gas saved |
| deploy (`via_ir`) | 2,571 gas saved | 3,260 gas saved |

Rootstock production values are **derived**, not measured by Foundry. The access test proves one
avoided storage-word read. [`ROOTSTOCK-GAS-SCHEDULE.md`](./ROOTSTOCK-GAS-SCHEDULE.md) records a
2,100-gas first `SLOAD` in Foundry and a flat 200-gas `SLOAD` on Rootstock, so the adjustment is:

```
1 avoided read × (2,100 − 200) = −1,900 gas from the Foundry delta
```

The remaining avoided struct construction / memory work and per-row branch are pure compute and
transfer unchanged. Applying the same conversion to both compiler profiles makes the production
profile explicit:

| Profile | One row, Foundry → Rootstock | Five rows, Foundry → Rootstock |
|---|---:|---:|
| default | 2,462 → approximately 562 | 3,259 → approximately 1,359 |
| deploy (`via_ir`) | 2,571 → approximately 671 | 3,260 → approximately 1,360 |

Production ships the deploy (`via_ir`) profile, so approximately **671 / 1,360 gas** for one / five
rows is the relevant Rootstock estimate. Against R64's 815,384-gas five-row live tick, the larger
case is about 0.17%.

R78 remains worth keeping at the smaller Rootstock figure: it adds no state, ABI change, protocol
invariant, external call, or failure mode, and focused plus fuzz testing proves output equivalence on
both the flat and variable branches. The code is also simpler on the launch configuration's hot path.

## Success criteria

- [x] Flat-fee batches do not read the purchase-bound storage word.
- [x] Flat and variable fee outputs, aggregation, and rounding are unchanged.
- [x] Foundry measurements are labelled as Cancun regression pins; the production Rootstock saving
      is derived explicitly from the one avoided read and the Rootstock gas schedule.
- [x] No ABI, event, error, storage-layout, deploy-script, or consumer change.
- [x] Required tests pass and no open product decisions remain.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none.
- Scripts: none.
- Cutover: none. Fee settings, rounding, transfers, and events remain unchanged, so no consumer issue
  is required.
