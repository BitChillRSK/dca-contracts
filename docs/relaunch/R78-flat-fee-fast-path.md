# R78 — Flat-fee purchase fast path

Status: **in progress** · Assigned: yes · Optional/further-review: no · Order: stack on R77 ([#138](https://github.com/BitChillRSK/dca-contracts/pull/138))

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
- [ ] Consolidating DcaManager purchase events; that is an event/cutover decision despite its small
      source diff.
- [ ] Persistent or sentinel Uniswap allowances; live USDRIF and USDT0 approval behavior must be
      measured first, and unlimited approvals are not acceptable for idle handlers holding deposits.
- [ ] Seeding handler stablecoin/WRBTC balances or changing deployment funding; those create
      permanently unowned token dust and require route-by-route fork evidence.
- [ ] Coalescing repeated buyers' share/rBTC writes; the saving depends on production row ordering
      and needs a representative batch-distribution benchmark.
- [ ] Adding sentinels to lending-share or idle-balance mappings; those remove a refund from the
      operator purchase and move the later saving to a user-funded deposit.

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
