# R78 — Flat-fee purchase fast path

Status: **implemented** · GitHub [#139](https://github.com/BitChillRSK/dca-contracts/pull/139) · Assigned: yes · Optional/further-review: no · Order: stack on R77 ([#138](https://github.com/BitChillRSK/dca-contracts/pull/138))

## Objective

Avoid evaluating the linear fee curve for every row when a handler is configured with the launch's
flat fee (`minFeeRate == maxFeeRate`). Single-source the fee-at-rate formula, and pack all four fee
settings into one storage word with the public `FeeSettings` bounds matching their stored width.

## Background

R74 selects a flat 100-bps launch fee but deliberately keeps the existing owner-controlled linear
fee model available. R77's `FeeHandler._calculateFeeAndNetAmounts` materializes all settings and then
tests `minFeeRate == maxFeeRate` again for every row in `_calculateFeeWithParams`; the curve is
irrelevant in that configuration. R78 hoists that decision once per batch. Its flat loop and the
variable curve both call `_calculateFeeAtRate`, so `amount * rate / BPS_DENOMINATOR` exists once.
The variable loop keeps the four already-loaded parameters as stack scalars instead of materializing
a `FeeSettings memory` value and loading its four words again for every row. The external getter
constructs that boundary struct directly; no internal struct-producing helper remains. Because the
dispatcher has already proved unequal rates before entering the variable loop, the private curve
helper does not repeat that test per row.

Only `_calculateFeeAndNetAmounts` and `_transferFee` are production inheritance hooks:
`PurchaseRbtc` calls both. The two specialized loops, one-row curve, shared rate arithmetic, and
validation are private implementation details. Their order follows the purchase calculation from
dispatch through each loop to the arithmetic leaves, with validation last as the separate
configuration path.

R77 stores the collector plus rates in one word and both `uint128` bounds in another. R78 narrows the
public struct and internal bounds to `uint112`: collector alone in slot 2, then both bounds and both
`uint16` rates exactly fill slot 3. A schedule purchase is only `uint96`, so each bound remains 65,536
times wider than any reachable purchase amount. Both the
generic gas baseline and fast path therefore read the same single settings word. Their measured delta
is compute and memory only and transfers directly from Foundry to Rootstock; the packing itself saves
one additional Rootstock `SLOAD` (200 gas) per batch relative to R77.

## Open product decisions

**none** — the approved fee remains 100 bps at launch and governance retains the same atomic setter
and variable curve. Before deployment, the public constructor/getter struct is narrowed from
`uint128` to its real `uint112` storage constraint, still wider than the `uint96` amount that can reach
the curve.

## Scope

- [x] In `_calculateFeeAndNetAmounts`, load the packed min/max rates first and choose the flat path
      once per batch when they are equal.
- [x] Single-source `amount * rate / BPS_DENOMINATOR` in `_calculateFeeAtRate`; both the flat loop and
      variable curve call it with the existing per-row rounding.
- [x] Preserve the variable curve's behavior, aggregation, checked
      overflows, and net-amount array exactly.
- [x] Pass the variable curve's four parameters as stack scalars; do not build or read a
      `FeeSettings memory` value on the batch hot path.
- [x] Do not repeat the already-proved unequal-rate test inside the variable loop; keep the one-row
      curve private so callers cannot bypass the batch dispatch precondition.
- [x] Keep only the two operations used by derived purchase contracts `internal`; inline the getter's
      struct construction and keep every other helper private in call-flow order.
- [x] Pack both bounds and both rates into one word; declare the `FeeSettings` bounds as `uint112` so
      the constructor type matches storage, while the `uint256` owner setter retains checked casts.
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

Two `uint16` rates plus two `uint112` bounds total exactly 256 bits. No storage struct is needed: the
collector starts slot 2; the first 14-byte bound cannot fit in its 12-byte remainder and therefore
starts slot 3, followed by the other bound and both rates. Derived state still starts at slot 4.

This changes the storage and public constructor/getter struct before deployment and narrows the
theoretical setting range. It does not narrow any reachable purchase: `uint112` is 65,536 times wider
than the schedule's `uint96` purchase amount. The constructor now expresses that limit in its type
instead of accepting `uint128` and failing later with a raw SafeCast error. The owner setter remains
`uint256`, validates first, and rejects an uncastable bound with the existing SafeCast error. Its
selector and all event fields stay unchanged. `getFeeSettings()` also keeps its selector and word-for-
word return encoding, although its ABI component metadata narrows to `uint112`.

Compared with R77, `getFeeSettings()` reads one word instead of two. Rootstock charges 200 gas per
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
- `script/Constants.sol`
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

Assert that flat and variable batch results equal an independent reference curve for every row,
including amounts that round down to zero fee. The differential fuzz bounds every generated amount to
1 wei–2,000 ether so its variable configuration exercises the below-bound, interpolation, and
above-bound branches; focused unit tests cover both exact knees. Separate baseline and optimized
harness contracts use the same packed storage layout, so test-only reference code cannot perturb
optimized code generation and the measured delta contains only compute and memory. This item adds no
fork-only assertion.

Same-build flat fast-path measurements after single-sourcing the formula and changing the variable
helper to stack scalars:

| Foundry profile | One row | Five rows | 100 rows |
|---|---:|---:|---:|
| default | 222 gas saved | 1,089 gas saved | 20,224 gas saved |
| deploy (`via_ir`) | 280 gas saved | 1,091 gas saved | 18,995 gas saved |

These deltas contain no changed storage access: both variants load the same packed settings word.
Compute and memory pricing is the same on current Rootstock, so the production fast-path figures are
the shipped deploy-profile measurements directly: **280 / 1,091 / 18,995 gas** for one / five / 100
rows. Packing adds one avoided Rootstock `SLOAD`, exactly **200 gas per batch**, making the complete
PR approximately **480 / 1,291 / 19,195 gas** cheaper than R77 at those sizes. Against R64's
815,384-gas five-row live tick, the complete five-row saving is about 0.16%.

The earlier duplicated-formula deploy build measured 671 / 1,359 gas for one / five rows with the
reference and optimized paths compiled into one derived harness. That historical result established
the upper bound but is not subtracted from the isolated-harness result: unrelated reference code can
change optimizer decisions in the contract being measured. The final table above keeps the paths in
separate harnesses and is authoritative. These Rootstock figures use the production deploy profile;
the default-profile values are not substituted for shipped code.

The variable-path scalar change was also measured directly at 100 rows with a cold packed settings
slot. The before measurement is commit `6abc630`; the after measurement uses the same amounts and
harness entry point:

| Foundry profile | `FeeSettings memory` before | Stack scalars after | Saving |
|---|---:|---:|---:|
| default | 83,945 gas | 75,369 gas | 8,576 gas |
| deploy (`via_ir`) | 71,711 gas | 68,285 gas | 3,426 gas |

The absolute costs include Foundry's cold-read schedule, but the before/after storage access is
identical. The delta is memory and compute only and therefore transfers directly to Rootstock. It is
gas-neutral on the shipped flat configuration because that branch never constructs the memory struct;
it pays only if governance selects variable rates. Focused plus fuzz testing proves output equivalence
on both the flat and variable branches.

The remaining equal-rate test inside the one-row curve helper was then measured separately with
every row at 550 ether, between the harness's 100- and 1,000-ether bounds so every row executes the
full interpolation. The dispatcher proves unequal rates before the variable loop, making the test
redundant on that hot path:

| Foundry profile | Rows | With repeated test | Without repeated test | Saving |
|---|---:|---:|---:|---:|
| default | 1 | 3,493 gas | 3,459 gas | 34 gas |
| default | 5 | 6,633 gas | 6,463 gas | 170 gas |
| default | 100 | 81,269 gas | 77,869 gas | 3,400 gas |
| deploy (`via_ir`) | 1 | 3,335 gas | 3,292 gas | 43 gas |
| deploy (`via_ir`) | 5 | 6,179 gas | 5,964 gas | 215 gas |
| deploy (`via_ir`) | 100 | 73,785 gas | 69,485 gas | 4,300 gas |

The shipped build therefore avoids **43 gas per variable-fee row**. Removing the test does not add a
flat-fee special case elsewhere: the batch dispatcher owns that decision and the curve helper is now
private, so no derived caller can bypass the precondition. The committed flat/variable differential
fuzz test keeps output equivalence reproducible.

## Success criteria

- [x] Flat-fee batches choose their loop once; the fee-at-rate formula exists once.
- [x] Flat and variable fee outputs, aggregation, and rounding are unchanged.
- [x] The batch hot path does not materialize a `FeeSettings memory` value.
- [x] The variable loop does not repeat the dispatcher's unequal-rate test per row.
- [x] Only the batch calculator and fee transfer are inherited operations; calculation details are
      private and ordered by call flow.
- [x] All settings occupy one word; the public struct declares the stored widths and setter overflow reverts.
- [x] Compute-only measurements transfer directly; the separate Rootstock storage saving is explicit.
- [x] Constructor/getter ABI metadata and deploy constants use `uint112`; runtime values, selectors,
      return encoding, events, errors, and fee behavior are unchanged.
- [x] Required tests pass and no open product decisions remain.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: `FeeSettings.feePurchaseLowerBound` and `feePurchaseUpperBound` narrow from `uint128` to
  `uint112`. This changes constructor and getter ABI metadata, but no function selector or runtime
  word encoding.
- Scripts: the four fee-bound constants match the struct at `uint112`; their values are unchanged.
- Storage: predeployment-only encoding change; total fee-state slot count remains two and derived
  storage does not move.
- Cutover: clients that carry handler ABI metadata should regenerate it for the two narrower getter
  components. Existing decoders remain wire-compatible because each value is still one ABI word.
