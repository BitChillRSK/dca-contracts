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

R77's storage-sentinel gas statement is also corrected in this stacked PR: the zero-to-nonzero
saving occurs once per buyer whose slot was cleared, not once per row when the same buyer appears
several times. The always-on encoding overhead must be recorded beside that conditional saving.

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
      R77 for representative one-row and multi-row batches.
- [x] Correct R77's economics from unconditional “per row” language to conditional per-buyer
      re-credit language, including the measured always-on cost.
- [x] Update `docs/relaunch/README.md` and `IMPLEMENTATION_ORDER.md` with R78.

## Out of scope

- [ ] Removing the linear fee model, its amount bounds, its setter, or any fee event.
- [ ] The deferred candidates below. They are recorded for future investigation, not assigned for
      implementation by this spec.

## Deferred optimization record

The estimates in this section are preliminary unless explicitly described as measured. They are
useful for ordering future work, but they are not promises of net transaction savings: compiler
output, Rootstock's gas schedule, token implementations, storage warmth, refunds, and real batch
composition can all change the result. A future item should add a same-build gas harness and test the
shipped `deploy` profile before accepting any candidate.

### Consolidate the two DcaManager per-row state events

**Candidate.** `_rBtcPurchaseChecksEffects` emits `DcaManager__TokenBalanceUpdated` and
`DcaManager__CadenceAnchorUpdated` after updating one schedule. Replace them with one purchase-state
event carrying both new values, or make one existing purchase event the canonical state-change
record.

**Potential upside.** Preliminary EVM log-cost arithmetic suggests roughly 1,500 gas per row from
removing one log and its duplicated topics/data; the exact amount depends on the final signature and
compiler-generated memory work. Unlike a storage sentinel, this would benefit every successful row.

**Why deferred.** This is a public event-schema change, not merely a local implementation cleanup.
Monitoring and indexers may replay the two existing events independently, and consolidating them can
alter ordering and backfill assumptions. It therefore requires a product choice about the canonical
event, an ABI diff, migration/backfill notes, and a `bitchill-monitoring` consumer issue.

**Evidence required.** Inventory all consumers of both events; design the replacement payload and
indexing; benchmark one- and multi-row purchases; test event ordering and values; and prove that a
consumer can reconstruct the same state from genesis or from the cutover block. **Recommendation:**
worth a dedicated PR if event consumers accept the migration, because the benefit scales per row.

### Retain or sentinel the Uniswap router allowance

**Candidate.** `PurchaseUniswap._purchaseRbtc` currently calls `forceApprove(router, exactAmount)` for
every batch. A residual nonzero allowance, a sentinel allowance, or a bounded reusable allowance
could avoid an allowance zero-to-nonzero write on later purchases.

**Potential upside.** For a standard ERC-20 allowance implementation, preliminary storage-cost
arithmetic puts the upper bound around 12,300 system gas per batch relative to repeatedly clearing
and recreating the allowance. This is not a measured USDRIF/USDT0 result. A token that requires the
USDT-style zero-first sequence can consume most or all of that gain through `forceApprove`'s fallback.

**Why deferred.** Unlimited approval is not acceptable as the default design: idle handlers also
custody pooled user deposits, so a compromised or upgraded router could reach more than the current
purchase. Even a bounded residual allowance changes the trust and revocation model. Token-specific
approval behavior also cannot safely be inferred from generic ERC-20 behavior.

**Evidence required.** Fork-test the deployed USDRIF and USDT0 contracts for exact-amount,
zero-first, allowance-decrement, and return-value behavior; benchmark the complete router call under
both routes; bound the maximum residual exposure; define owner revocation and router-change behavior;
and test that failed swaps cannot strand an unsafe approval. **Recommendation:** investigate because
the per-batch ceiling is meaningful, but ship only a bounded design with live-token evidence—never a
blanket unlimited allowance for a deposit-holding handler.

### Seed handler stablecoin or WRBTC balances

**Candidate.** Fund each handler with one atomic unit so recurring venue transfers do not repeatedly
create a zero balance slot. The same idea could apply to the input stablecoin, intermediate tokens,
or WRBTC depending on which route clears a handler balance.

**Potential upside.** A qualifying zero-to-nonzero recipient write can avoid the expensive storage
creation on later calls; the order of magnitude may resemble the R77 sentinel saving. It is not yet
benchmarked, and some routes may never clear the relevant balance or may perform an extra cleanup
write that erases the benefit.

**Why deferred.** The seed is permanently unowned dust unless a recovery lifecycle is designed. It
changes deployment funding and balance invariants, can interact with the exact input-consumption and
WRBTC-unwrapping checks, and must be reasoned about separately for every token/venue/handler pair.

**Evidence required.** Trace pre/post balances on all MoC and DEX routes; identify which slots truly
cycle through zero; benchmark with the deployed token implementations; specify who funds and owns the
seed; update deploy scripts and tests; and prove the seed cannot be withdrawn, allocated to a buyer,
or mistaken for venue proceeds. **Recommendation:** low priority unless route-level measurements show
a recurring material win that justifies permanent dust and deployment complexity.

### Coalesce repeated-buyer writes within one batch

**Candidate.** When the same buyer owns several rows in a batch, aggregate their rBTC allocations
before `_creditRbtc`, and/or aggregate their lending-share or idle-balance debits before storage is
updated. Continue calculating and emitting each schedule row independently.

**Potential upside.** Each avoided update to an already-warm mapping slot is likely only a few
hundred gas after accounting for the additional comparison/aggregation logic. The gain exists only
for duplicate buyers and depends heavily on row ordering; an auxiliary in-memory map can cost more
than it saves on ordinary batches.

**Why deferred.** The current loops apply rows sequentially. Coalescing must preserve per-row fee and
rBTC rounding, insufficient-balance failure behavior, checked totals, and the exact order and meaning
of schedule-level events. The optimal algorithm depends on whether the swapper already groups a
buyer's rows contiguously and on the real duplicate-buyer distribution.

**Evidence required.** Obtain representative production batch histograms (row count, duplicate rate,
and ordering); compare contiguous-run aggregation with a general in-memory scheme; benchmark unique,
clustered-duplicate, and adversarial ordering; and prove output, revert, and event equivalence with
differential fuzz tests. **Recommendation:** consider only if telemetry shows common contiguous
duplicates; otherwise the complexity and regressions on unique-buyer batches are unlikely to pay.

### Add sentinels to lending-share or idle-balance mappings

**Candidate.** Encode per-user shares or idle stablecoin balances as `claimable + 1`, mirroring R77's
accumulated-rBTC sentinel, so a purchase that spends a user's full balance leaves a nonzero slot.

**Potential upside.** It can avoid a later zero-to-nonzero refill, but adds decode/encode work to
every balance access and intentionally gives up the clear-to-zero refund on the purchase that empties
the balance.

**Why not recommended.** The operator pays for the hot purchase while the user pays for the later
deposit. Here the sentinel removes an operator-side clear/refund and moves the possible later saving
to a user-funded transaction—the opposite of the useful R77 cost shift, where users occasionally
withdraw and the swapper commonly re-credits. It also expands a delicate accounting encoding across
deposit, withdrawal, interest, and lending-share conversion paths.

**Evidence required before reconsideration.** A full lifecycle benchmark separated by fee payer,
plus evidence that user refills dominate full-balance purchases enough to overcome the always-on
encoding cost and lost operator refund. **Recommendation:** reject under the current payer model.

### Keep one atomic unit in the fee collector

**Candidate.** Operationally avoid withdrawing a fee token's collector balance completely, leaving
one atomic unit so the next fee transfer credits a nonzero recipient balance. No contract change is
required if treasury operations already permit a retained minimum.

**Potential upside.** For a conventional ERC-20 balance mapping this avoids the next recipient
zero-to-nonzero storage creation; gross storage arithmetic can be material (roughly 15,000 gas before
transaction-level refund effects), but the actual result is token-implementation and withdrawal-flow
dependent. The benefit occurs once after each collector drain, not on every batch while its balance
is already nonzero.

**Why deferred.** This is treasury policy rather than protocol code. The contracts cannot guarantee
that the collector retains dust, and documenting the tactic as a contract invariant would be false.

**Evidence required.** Confirm how each fee token implements balances, benchmark the first transfer
after an empty versus one-unit collector, and decide whether treasury accounting and sweeping tools
can intentionally retain dust. **Recommendation:** adopt as an optional runbook practice if measured;
do not add contract machinery to enforce it.

### Merge per-user stablecoin and rBTC accounting into one slot

**Candidate.** Pack or otherwise combine the handler's stablecoin-side user accounting with the
accumulated-rBTC balance so a purchase touches fewer storage words.

**Why not recommended.** These balances have different owners, widths, lifecycle rules, and—in the
lending handlers—different units because stablecoin claims are represented by protocol shares. The
fields also live across separate inheritance responsibilities. R50 previously rejected this shape:
the packing would couple otherwise independent deposit/withdraw and purchase/claim paths, complicate
upgrades and auditing, and still would not provide one uniform slot across idle and lending handlers.
Any apparent SLOAD/SSTORE saving must also pay for masking and repacking.

**Evidence required before reconsideration.** A new storage architecture proposal covering every
handler family, migration/layout safety, bit-width bounds, and lifecycle benchmarks. **Recommendation:**
retain the current separation; do not pursue as a local gas optimization.

## Files likely touched

- `src/FeeHandler.sol`
- `test/ai-generated/unit/FeeHandlerTest.t.sol`
- `test/gas/R77AccumulatedRbtcSentinelGas.t.sol`
- `test/gas/R78FlatFeeFastPathGas.t.sol`
- `docs/relaunch/R77-accumulated-rbtc-storage-sentinel.md`
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
batch before and after this PR; the implementation must materially save a cold storage read per
handler batch under the shipped profile. This item adds no fork-only assertion.

Measured in the same-build R77-reference/R78-fast-path harness:

| Profile | One row | Five rows |
|---|---:|---:|
| default | 2,450 gas saved | 3,247 gas saved |
| deploy (`via_ir`) | 2,547 gas saved | 3,236 gas saved |

## Success criteria

- [x] Flat-fee batches do not read the purchase-bound storage word.
- [x] Flat and variable fee outputs, aggregation, and rounding are unchanged.
- [x] The measured saving is recorded under both compiler profiles and is meaningful on a one-row
      batch, rather than existing only at unrealistic batch sizes.
- [x] No ABI, event, error, storage-layout, deploy-script, or consumer change.
- [x] R77's gas statement names its real trigger and includes the always-on cost.
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
