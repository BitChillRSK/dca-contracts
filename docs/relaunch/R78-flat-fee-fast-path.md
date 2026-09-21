# R78 — Flat-fee purchase fast path

Status: **implemented** · GitHub [#139](https://github.com/BitChillRSK/dca-contracts/pull/139) · Assigned: yes · Optional/further-review: no · Order: stack on R77 ([#138](https://github.com/BitChillRSK/dca-contracts/pull/138))

## Objective

Avoid evaluating the linear fee curve for every row when a handler is configured with the launch's
flat fee (`minFeeRate == maxFeeRate`). Single-source the fee-at-rate formula, and pack all four fee
settings into one storage word without changing the public `FeeSettings` ABI.

## Background

R74 selects a flat 100-bps launch fee but deliberately keeps the existing owner-controlled linear
fee model available. R77's `FeeHandler._calculateFeeAndNetAmounts` materializes all settings and then
tests `minFeeRate == maxFeeRate` again for every row in `_calculateFeeWithParams`; the curve is
irrelevant in that configuration. R78 hoists that decision once per batch. Its flat loop and the
variable curve both call `_calculateFeeAtRate`, so `amount * rate / BPS_DENOMINATOR` exists once.

R77 stores the collector plus rates in one word and both `uint128` bounds in another. R78 keeps the
public struct at those ABI widths but checked-casts the internal bounds to `uint112`: collector alone
in slot 2, then both bounds and both `uint16` rates exactly fill slot 3. A schedule purchase is only
`uint96`, so each bound remains 65,536 times wider than any reachable purchase amount. Both the
generic gas baseline and fast path therefore read the same single settings word. Their measured delta
is compute and memory only and transfers directly from Foundry to Rootstock; the packing itself saves
one additional Rootstock `SLOAD` (200 gas) per batch relative to R77.

## Open product decisions

**none** — the approved fee remains 100 bps at launch and governance retains the same atomic setter,
variable curve, and public ABI. The accepted internal bound range narrows from `uint128` to `uint112`,
still wider than the `uint96` amount that can reach the curve.

## Scope

- [x] In `_calculateFeeAndNetAmounts`, load the packed min/max rates first and choose the flat path
      once per batch when they are equal.
- [x] Single-source `amount * rate / BPS_DENOMINATOR` in `_calculateFeeAtRate`; both the flat loop and
      variable curve call it with the existing per-row rounding.
- [x] Preserve the variable path's `_calculateFeeWithParams` behavior, aggregation, checked
      overflows, and net-amount array exactly.
- [x] Pack both internal bounds and both rates into one word with `uint112` checked casts; retain the
      external `FeeSettings` component types and the two-slot total including the collector.
- [x] Add focused correctness coverage for flat and variable batches, including row-by-row rounding.
- [x] Add a gas harness and record default-profile and shipped `FOUNDRY_PROFILE=deploy` deltas against
      the generic loop for one, five, and 100 rows.
- [x] Price the compute-only fast-path delta directly on Rootstock and add the packing's exact
      one-read / 200-gas saving separately.
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

### Implemented: pack all fee settings into one word

Two `uint16` rates plus two `uint128` bounds total 288 bits. R78 retains those public ABI types but
checked-casts the internal bounds to `uint112`, making the stored settings exactly 256 bits. No
storage struct is needed: the collector starts slot 2; the first 14-byte bound cannot fit in its
12-byte remainder and therefore starts slot 3, followed by the other bound and both rates. Derived
state still starts at slot 4.

This changes the internal storage encoding before deployment and narrows the theoretical setting
range. It does not narrow any reachable purchase: `uint112` is 65,536 times wider than the schedule's
`uint96` purchase amount. The public struct, getter, setter arguments, selectors, and event fields stay
unchanged; constructor and setter reject an uncastable bound with the existing SafeCast error.

Compared with R77, `_feeSettings` reads one word instead of two. Rootstock charges 200 gas per
`SLOAD`, so packing saves exactly **200 gas per batch** on either fee branch and 200 gas on the
external settings getter. The fast-path harness compiles its generic and optimized variants against
this same packed layout, deliberately excluding that storage saving from the compute comparison.

### Closed: remove the linear fee model

R78 already skips interpolation whenever the configured fee is flat; packing puts the bounds and rates
in the same word, so there is no separate bounds read left to remove. Deleting the variable model
therefore saves approximately **0 additional production gas** on the shipped flat configuration while
permanently removing governance's option to choose a variable fee from immutable contracts. No proxy
exists anywhere in `src/`. Keep the model.

### Closed: merge stablecoin and rBTC accounting

R50 already rejected combining these mappings. Idle balances and lending shares use different units
and lifecycle rules from accumulated rBTC, and the fields sit in separate inheritance responsibilities.
Packing would couple independent deposit/withdraw and purchase/claim paths, need different layouts
for idle and lending handlers, and pay masking/repacking costs. This is an architectural redesign, not
a local gas optimization; retain the current separation.

## Files likely touched

- `AGENTS.md`
- `src/FeeHandler.sol`
- `src/interfaces/IFeeHandler.sol`
- `test/mocks/FeeHandlerHarness.sol`
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
every row, including amounts that round down to zero fee. The gas harness compares the generic and
flat loops against the same packed storage layout, so only compute and memory differ. This item adds
no fork-only assertion.

Same-build fast-path measurements after single-sourcing the formula:

| Foundry profile | One row | Five rows | 100 rows |
|---|---:|---:|---:|
| default | 362 gas saved | 1,183 gas saved | 20,664 gas saved |
| deploy (`via_ir`) | 466 gas saved | 1,143 gas saved | 17,204 gas saved |

These deltas contain no changed storage access: both variants load the same packed settings word.
Compute and memory pricing is the same on current Rootstock, so the production fast-path figures are
the shipped deploy-profile measurements directly: **466 / 1,143 / 17,204 gas** for one / five / 100
rows. Packing adds one avoided Rootstock `SLOAD`, exactly **200 gas per batch**, making the complete
PR approximately **666 / 1,343 / 17,404 gas** cheaper than R77 at those sizes. Against R64's
815,384-gas five-row live tick, the complete five-row saving is about 0.16%.

The shared helper costs 205 gas at one row and 217 gas at five rows relative to the earlier
duplicated-formula deploy measurement, while retaining about 84% of that version's five-row saving.
Focused plus fuzz testing proves output equivalence on both the flat and variable branches.

## Success criteria

- [x] Flat-fee batches choose their loop once; the fee-at-rate formula exists once.
- [x] Flat and variable fee outputs, aggregation, and rounding are unchanged.
- [x] All settings occupy one word; the public ABI is unchanged and uncastable bounds revert.
- [x] Compute-only measurements transfer directly; the separate Rootstock storage saving is explicit.
- [x] No ABI, event, error, deploy-script, or consumer change.
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
- Storage: predeployment-only encoding change; total fee-state slot count remains two and derived
  storage does not move.
- Cutover: none. Public fee settings, rounding, transfers, and events remain unchanged, so no consumer
  issue is required.
