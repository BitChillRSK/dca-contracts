# R108 — Monotone purchase fees

Status: **in progress** · Assigned: yes · Optional/further-review: no

## Objective

Replace the linear variable fee rate with a smooth decreasing rate whose absolute fee never decreases with purchase size. Keep the minimum rate, maximum rate and lower purchase bound configurable.

## Background

The existing variable mode has an unintended income reduction: with 100/50 bps and bounds 100/1000, a purchase of 900 pays 5.04 while 1000 pays 5.00. Whole-bps interpolation also introduces downward fee jumps. Classified as a medium finding in the supported variable-fee logic; equal-rate configurations do not trigger it. Builds on R107's fee weights and rBTC credits.

## Open product decisions

**none** — formula approved 2026-10-01. Launch parameter selection is separate; retain existing equal-rate deployment defaults.

## Scope

- For x <= L, fee = floor(x * maxRate / 10000).
- Otherwise fee = floor((minRate*x*x + (maxRate-minRate)*L*(2*x-L)) / (x*10000)).
- Round once, at the final division; preserve the flat batch fast path and 500 bps cap.
- Remove the upper bound from storage, settings, setter, events, errors, deployment constructors and test fixtures. Keep the lower bound uint112 and rates uint16. Zero lower bound is valid and yields the minimum rate for positive amounts; zero minimum rate is valid.
- Document that the minimum is asymptotic, prove unchecked arithmetic and test fee monotonicity, boundary continuity up to token-unit rounding, rate bounds, conservation and decimals.
- Update consumer issues for the fee settings ABI and fee quotation semantics.

## Out of scope

Launch pricing selection, economic forecasts, custody or purchase allocation changes, broadcasts, unrelated optimizations.

## Files likely touched

- `src/PurchaseFees.sol`, `src/interfaces/IPurchaseFees.sol`
- `script/Constants.sol`, `script/DeployMocSwaps.s.sol`, `script/DeployDexSwaps.s.sol`, `script/DeployIdleHandler.s.sol`, `script/DeployLayerBankHandler.s.sol`, `script/DeployUsdrifHandler.s.sol`, `script/DeployFinal.s.sol`
- `test/mocks/PurchaseFeesHarness.sol`, `test/ai-generated/unit/PurchaseFeesTest.t.sol`, `test/ai-generated/unit/HandlerTestHarness.t.sol`, `test/unit/TestsHelper.t.sol`
- Direct FeeSettings constructor fixtures, setter callers and fee-setting assertions under `test/unit/`, `test/ai-generated/`, `test/gas/`; enumerate these mechanical ABI dependents in the PR.
- `test/gas/R78FlatFeeFastPathGas.t.sol` (reference curve used by equivalence checks)
- This spec, `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`; current fee ABI cutover documentation reached through those files.

## Required tests

- `forge test --match-contract PurchaseFeesTest -vv` and the same with `FOUNDRY_PROFILE=deploy`.
- Deterministic regressions for the former fee decrease, fixed reference amounts at 6/18 decimals, zero/flat rates, zero/uint112-max bound, uint96-max purchase, configuration authorization/casts/events, and batch conservation.
- Fuzz ordered and adjacent purchase amounts across supported parameter widths; absolute fee monotonicity, amount-minus-fee monotonicity, and rate bounds using exact floor arithmetic.
- `make check`, `make check-deploy`, `make fork-sovryn`, `make fork-layerbank`. No new fork-specific assertions.
- Run the existing R78 fee-loop gas suite under both profiles; label gas as Foundry/Cancun unless storage/opcode equivalence supports a Rootstock conversion.

## Success criteria

- Supported configurations cannot produce a decreasing absolute fee as the purchase grows.
- One final rounding, no arithmetic overflow on permitted inputs, and unchanged batch net/fee conservation.
- No obsolete upper-bound ABI/config references remain in executable consumers.
- Required gates pass and a stacked PR includes consumer issue links.

## Reviewer checklist

- Scope and invariants preserved; no pricing selection or private economic data committed.
- Tests cover the real purchase domain and integer rounding.
- Direct ABI dependents are identified in the PR.

## ABI / deploy / cutover impact

`setFeeRateParams(uint256,uint256,uint256,uint256)` becomes the three-argument version. `FeeSettings` loses its uint112 upper-bound field. Remove `PurchaseFees__PurchaseUpperBoundSet` and `PurchaseFees__FeeLowerBoundMustBeLowerThanUpperBound`. Fresh deployments only; refresh consumer ABIs and quote the new formula in token base units. Scripts retain the existing flat rates and lower bound.
