# R3 — FeeHandler linear-fee fixes (R3, R4, R5)

Status: **in progress** · Assigned: yes · Optional/further-review: no

## Objective

Keep the linear fee model. Make `setFeeRateParams` able to raise the rate band in one call, keep purchase-bound invariants on the individual setters, and load fee storage once per batch so interpolation math does not re-SLOAD on every purchase.

## Background

PR 5 bundles R3, R4, and R5 because they are isolated `FeeHandler` work and all apply only if the linear model stays. Product gate (this chat): **keep linear**. Do not flatten to one rate.

Linear means: `maxFeeRate` at or below `feePurchaseLowerBound`, `minFeeRate` at or above `feePurchaseUpperBound`, straight interpolation in between. Equal min and max is a valid flat rate (production is 100/100). There is no on-chain cap on `maxFeeRate`; do not add one.

**R3:** `setFeeRateParams` validates `newMin ≤ newMax`, then calls `setMinFeeRate` first. That setter compares against the **live** `s_maxFeeRate`, not the new max. Raising the band in one call (e.g. 100/200 → 250/400) reverts even though the new pair is valid. Individual min/max setters already keep `min ≤ max` against the other live rate (`f07c57b` / `eaca027`). Combined bound check is already `>=`.

**R4:** Combined setter requires `lower < upper`, but `setPurchaseLowerBound` / `setPurchaseUpperBound` still write without comparing to the other live bound, so `lower ≥ upper` can be stored.

**R5:** `_calculateFeeAndNetAmounts` calls `_calculateFee` per item. `_calculateFee` is `view` and SLOAD’s the four fee fields on every iteration. Those values do not change during the tx.

`PurchaseMoc` / `PurchaseUniswap` keep calling `_calculateFee` / `_calculateFeeAndNetAmounts`. Do not change fee rates, interpolation, or which path (`buyRbtc` vs batch) is used.

## Open product decisions

**none** — keep linear (answered this chat). Flatten is out of scope.

## Scope

- [x] **R3:** After validating the new pair, write rates and bounds in `setFeeRateParams` instead of routing through the individual setters. Keep the existing pair checks (`minFeeRate > maxFeeRate`, `feePurchaseLowerBound >= feePurchaseUpperBound`). Only write/emit a field when it changes (same as today’s `if (s_* != new)`). Individual setters stay for one-sided updates.

- [x] **R4:** On `setPurchaseLowerBound` / `setPurchaseUpperBound`, validate against the other live bound with the same `>=` error as the combined setter (`FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound`). Combined setter remains the way to move both bounds when the new pair would fail a one-sided check.

- [x] **R5:** Same math, fewer SLOADs in batch:

  ```solidity
  function _calculateFee(uint256 purchaseAmount) internal view returns (uint256) {
      return _calculateFeeWithParams(purchaseAmount, _feeSettings());
  }

  function _calculateFeeWithParams(uint256 purchaseAmount, FeeSettings memory feeSettings)
      internal
      pure
      returns (uint256);

  function _feeSettings() internal view returns (FeeSettings memory);
  ```

  `_calculateFeeAndNetAmounts` loads `FeeSettings` once before the loop and calls `_calculateFeeWithParams`. Linear formula stays identical to today’s `_calculateFee`. Do not add `getFeeSettings()` on `IFeeHandler`.

## Out of scope

- [ ] Flatten to one rate, new purchase bounds, or a `maxFeeRate` cap.
- [ ] `getFeeSettings()` on `IFeeHandler`.
- [ ] Constructor validation of fee settings.
- [ ] R18 packing, R19 pause, R12/R13/optionals (PR 2 / later PRs).
- [ ] R6 / R17 purchase-path / `nonReentrant` work.
- [ ] Event reshaping (R9); fee events keep today’s indexed uints.
- [ ] Handler / accounting / SIP-0094 (R1, R20).
- [ ] `forge fmt` of existing files.
- [ ] Deploy broadcasts or live addresses.
- [ ] `dca-out-contracts`.

## Files likely touched

- `src/FeeHandler.sol`
- `test/ai-generated/unit/FeeHandlerTest.t.sol`
- `test/mocks/FeeHandlerHarness.sol`
- `docs/relaunch/README.md` (assignment status)

`PurchaseMoc` / `PurchaseUniswap` keep calling `_calculateFee` / `_calculateFeeAndNetAmounts`; no change unless a compiler error forces it. Extra files belong in the PR write-up.

## Required tests

Commands (targeted first, then done-gate):

```bash
forge test --match-contract FeeHandlerTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus forge test --match-contract TropykusErc20HandlerTest --match-test modifyFeeSettings
make check
```

Behaviors to assert:

- Existing fee unit tests (below lower bound, above upper bound, interpolated, at bounds) still pass for `_calculateFee`.
- `minFeeRate == maxFeeRate` (flat) still charges `amount * minFeeRate / 10_000` regardless of purchase amount vs bounds.
- `setFeeRateParams` that raises min above the old max but below the new max (e.g. 100/200 → 250/400) succeeds and stores the new pair.
- `setFeeRateParams` that moves both bounds so the new lower is `>=` the old upper (e.g. 100/1000 ether → 2000/5000 ether) succeeds.
- Invalid combined pairs still revert (`min > max`, `lower >= upper`).
- `setPurchaseLowerBound` with `lower >=` current upper reverts; `setPurchaseUpperBound` with `upper <=` current lower reverts.
- One-sided bound updates that stay strictly inside the other live bound still succeed.
- `_calculateFeeAndNetAmounts` does not call a `view` helper that re-reads fee storage inside the loop (reviewer: inspect the loop).
- Batch of N purchases produces the same per-item fees (and nets) as N sequential `_calculateFee` calls with the same amounts.

Fork tests: not required.

## Success criteria

- [x] Raising the min/max band in one `setFeeRateParams` call succeeds when the new pair is valid.
- [x] Individual bound setters cannot store `lower >= upper`; combined setter still moves both.
- [x] Batch fee math matches sequential `_calculateFee`; four fee SLOADs happen once per `_calculateFeeAndNetAmounts` call, not per item.
- [x] Interpolation and flat (`min == max`) results are unchanged.
- [x] Targeted tests above pass; `make check` passes.
- [x] Protocol invariants in `AGENTS.md` unchanged.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec does not change them).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies / failing-test fallout and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.
- [ ] `_calculateFeeAndNetAmounts` loop uses `_calculateFeeWithParams` with a once-loaded `FeeSettings`, not `_calculateFee`.

## ABI / deploy / cutover impact

- ABI: none. Setter signatures and events unchanged. Individual bound setters revert in more cases (`FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound`). No `getFeeSettings`.
- Scripts: none. Production can keep `minFeeRate == maxFeeRate == 100` (flat 1%).
- Cutover: none. Owner can now raise the fee band in one `setFeeRateParams` call. Do not include broadcast steps.
