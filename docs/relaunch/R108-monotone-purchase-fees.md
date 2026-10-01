# R108 — Monotone purchase fees

Status: **implemented** · Assigned: yes · Optional/further-review: no

## Objective

Replace the linear variable fee rate with a smooth decreasing rate whose absolute fee never decreases with purchase size. Keep the minimum rate, maximum rate and lower purchase bound configurable.

## Background

The existing variable mode has an unintended income reduction: with 100/50 bps and bounds 100/1000, a purchase of 900 pays 5.04 while 1000 pays 5.00. Whole-bps interpolation also introduces downward fee jumps. Classified as a medium finding in the supported variable-fee logic; equal-rate configurations do not trigger it. Builds on R107's fee weights and rBTC credits.

## Open product decisions

**none** — formula approved 2026-10-01. Launch defaults approved in the follow-up: maximum 100 bps, minimum 20 bps, lower bound 250 tokens. Retain the configurable equal-rate flat option.

## Scope

- For x <= L, fee = floor(x * maxRate / 10000).
- Otherwise fee = floor((minRate*x*x + (maxRate-minRate)*L*(2*x-L)) / (x*10000)).
- Round once, at the final division; preserve the flat batch fast path and 500 bps cap.
- Remove the upper bound from storage, settings, setter, events, errors, deployment constructors and test fixtures. Keep the lower bound uint112 and rates uint16. Zero lower bound is valid and yields the minimum rate for positive amounts; zero minimum rate is valid.
- Document that the minimum is asymptotic, prove unchecked arithmetic and test fee monotonicity, boundary continuity up to token-unit rounding, rate bounds, conservation and decimals.
- Update consumer issues for the fee settings ABI and fee quotation semantics.
- Configure launch defaults at 100/20 bps and a 250-token lower bound, scaled to each token's decimals; retain the $25 minimum and test-only 200 bps maximum. Verify all seven canonical handlers receive these settings.

## Out of scope

Private pricing research and economic forecasts, custody or purchase allocation changes, broadcasts, unrelated optimizations.

## Files likely touched

- `src/PurchaseFees.sol`, `src/interfaces/IPurchaseFees.sol`
- Constructor NatSpec in `src/PurchaseRbtc.sol`, `src/PurchaseMoc.sol`, `src/PurchaseUniswap.sol` and the eight handler leaves under `src/idle/`, `src/layerbank/`, `src/sovryn/`, `src/tropykus-legacy/` (describe purchase-fee parameters without obsolete linear/interpolation wording).
- `script/Constants.sol`, `script/DeployMocSwaps.s.sol`, `script/DeployDexSwaps.s.sol`, `script/DeployIdleHandler.s.sol`, `script/DeployLayerBankHandler.s.sol`, `script/DeployUsdrifHandler.s.sol`, `script/DeployFinal.s.sol`
- `script/DeployBase.s.sol` (maximum-rate documentation); `test/unit/deployment/FinalDeploymentTest.t.sol` and `test/unit/deployment/Usdt0DexDeploymentTest.t.sol` (launch settings and token-unit wiring).
- `test/mocks/PurchaseFeesHarness.sol`, `test/ai-generated/unit/PurchaseFeesTest.t.sol`, `test/ai-generated/unit/HandlerTestHarness.t.sol`, `test/unit/TestsHelper.t.sol`
- Direct FeeSettings constructor fixtures, setter callers and fee-setting assertions under `test/unit/`, `test/ai-generated/`, `test/gas/`; enumerate these mechanical ABI dependents in the PR.
- `test/gas/R78FlatFeeFastPathGas.t.sol` (reference curve used by equivalence checks)
- `README.md`, `docs/PURCHASE_FEES.md` (durable fee math and rounding reference).
- `test/mainnet-debug/dex-quote-floor/DexQuoteFloorProbe.t.sol` (label its fixed 1% input deduction as a historical benchmark, rather than the current production fee).
- This spec, `docs/relaunch/README.md`, `docs/relaunch/IMPLEMENTATION_ORDER.md`; `docs/relaunch/ROOTSTOCK-GAS-AUDIT.md` (current setter field count and historical measurement context); current fee ABI cutover documentation reached through those files.

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

- Scope and invariants preserved; selected launch defaults documented without private economic data.
- Tests cover the real purchase domain and integer rounding.
- Direct ABI dependents are identified in the PR.

## ABI / deploy / cutover impact

`setFeeRateParams(uint256,uint256,uint256,uint256)` becomes the three-argument version. `FeeSettings` loses its uint112 upper-bound field. Remove `PurchaseFees__PurchaseUpperBoundSet` and `PurchaseFees__FeeLowerBoundMustBeLowerThanUpperBound`. Fresh deployments only; refresh consumer ABIs and quote the new formula in token base units. Launch defaults are maximum 100 bps, minimum 20 bps and lower bound 250 tokens (`250e18` for DOC/USDRIF, `250e6` for USDT0). Local/fork fixtures retain the 200 bps testing maximum; the shared minimum and lower bound follow the launch defaults.

## Arithmetic argument

For x>L and d=maxRate-minRate, the unrounded fee derivative is
`(minRate + d*L*L/(x*x))/10000`, between zero and 0.05. At L, fee and slope
match the flat segment. Flooring therefore preserves nondecreasing fees and
nondecreasing net amounts, although sub-unit changes can be rounded away.
For valid rates, `L*(2*x-L) <= x*x`, so the full numerator is at most
`maxRate*x*x < 2^201` for uint96 purchases. The curved branch implies L<x
regardless of the wider stored bound; its denominator is positive and below 2^110.
An independent checked test oracle uses the equivalent maximum fee minus
`ceil(d*(x-L)^2/x)` in the numerator, followed by division by 10000.

## Fee-loop measurements

Foundry/Cancun regression figures only, solc 0.8.36 / optimizer 200. Compared
`ad16af3b` (#173) with this change using `R78FlatFeeFastPathGas.t.sol` in isolated
source snapshots with the same dependencies. The normal suite uses x=550e18,
L=100e18, min/max=100/200 bps, and the parent's upper bound=1000e18. For the
large-purchase comparison, change only `_logActivationPremium`'s row amount to
2000e18 in each temporary snapshot. No gas claim here is a Rootstock bill or an
end-to-end purchase benchmark.

| Profile / fee path | Rows | Parent | R108 | Delta |
|---|---:|---:|---:|---:|
| Default / flat | 5 | 4,027 | 4,027 | 0 |
| Default / variable, x=550e18 | 5 | 5,090 | 4,744 | -346 |
| Deploy / flat | 5 | 3,886 | 3,895 | +9 |
| Deploy / variable, x=550e18 | 1 | 3,024 | 3,010 | -14 |
| Deploy / variable, x=550e18 | 5 | 4,680 | 4,654 | -26 |
| Deploy / variable, x=550e18 | 100 | 44,031 | 43,720 | -311 |
| Deploy / variable, x=2000e18 | 1 | 2,950 | 3,010 | +60 |
| Deploy / variable, x=2000e18 | 5 | 4,310 | 4,654 | +344 |
| Deploy / variable, x=2000e18 | 100 | 36,631 | 43,720 | +7,089 |

The new curve has no upper-bound shortcut: it trades a small amount of arithmetic
at larger sizes for the monotonic-fee guarantee. This is a correctness change,
not a universal gas optimization. Both layouts keep fee settings in one word;
these figures have not been converted using opcode traces to Rootstock pricing.

## Validation

Passed on 2026-10-01:

- `forge test --match-path 'test/{ai-generated/unit/PurchaseFeesTest,unit/PurchaseRbtcTest,gas/R78FlatFeeFastPathGas}.t.sol' -vv`
- `FOUNDRY_PROFILE=deploy forge test --match-path 'test/{ai-generated/unit/PurchaseFeesTest,unit/PurchaseRbtcTest,gas/R78FlatFeeFastPathGas}.t.sol' -vv`
- `make check`
- `make check-deploy`
- `make fork-sovryn` — 477 passed, zero failed, 36 skipped.
- `make fork-layerbank` — 477 passed, zero failed, 36 skipped.

The targeted suites pass 65 tests under each profile, including 1,000 fuzz cases
per fuzz test. These results predate the launch-parameter follow-up. No broadcasts were performed.

## Launch configuration follow-up — 2026-10-01

Selected defaults: maximum 100 bps, minimum 20 bps, lower bound 250 tokens.
The purchase minimum stays 25 tokens and equal min/max rates retain flat mode.
Canonical deployment tests verify the settings on all seven handlers, including
six-decimal USDT0 units. Local/fork fixtures keep their 200 bps testing maximum.

Passed after changing the defaults:

```sh
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=none STABLECOIN_TYPE=DOC forge test --match-path 'test/unit/deployment/*.t.sol' -vv
make check
make check-deploy
make fork-sovryn
make fork-layerbank
```

Targeted deployment suites: 33 passed, zero failed, five skipped. Default and
deploy matrices each pass all eight unit lanes and 17 invariant tests. Each
lending fork: 477 passed, zero failed, 36 skipped. Forks used isolated Foundry
output/cache directories while the deployment-profile build ran. No broadcasts.
