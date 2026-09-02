# R59 — Enforce complete Uniswap input consumption

Status: **implemented** · PR: [#112](https://github.com/BitChillRSK/dca-contracts/pull/112) (PR 57) · Assigned: yes · Optional/further-review: no · Order: before R55 (next unassigned)

## Objective

Make every successful `PurchaseUniswap` swap consume the complete stablecoin amount and leave no
new intermediate-token balance in SwapRouter02. A partial Uniswap V3 fill must revert the whole
purchase instead of silently crediting rBTC while stablecoin remains in the handler or an
intermediate token remains in the shared router.

## Background

`IV3SwapRouter.exactInput` describes the caller's requested input, but it does not guarantee that
every pool consumes all of it. Uniswap V3's pool loop stops when either the amount is exhausted or
the swap reaches that pool's terminal square-root-price limit. SwapRouter02 passes the requested
amount into the first hop and chains each hop's output into the next; it checks aggregate output
against `amountOutMinimum`, but does not separately require every requested input unit to be spent.

This is rare on a healthy, sensibly sized route. It requires a pool to run out of reachable
liquidity before the input is exhausted, so the usual causes are a drained or extremely thin pool,
an oversized batch, or a path that has become economically non-viable. The R51 fork probe observed
the condition on the starved DOC path and on a $100,000 USDRIF quote. That rarity does not remove the
accounting edge for immutable handlers:

- if the first (or only) hop partially fills, SwapRouter02 pulls only the amount the pool consumed,
  leaving stablecoin in the handler after the DCA schedules and fees have already been debited;
- if a later hop partially fills, the unused input to that hop is an intermediate token held by
  the public SwapRouter02 contract, outside BitChill's custody.

The existing measured WRBTC balance delta remains correct for what was received, but output-only
accounting cannot prove that all intended input was consumed. `amountOutMinimum` is also not that
proof: a partial fill can still produce enough output to clear a loose aggregate minimum.

The implementation deliberately uses balance deltas, matching the protocol's integration-cash
invariant. It does not trust the router return value, decode packed path bytes, or attempt a refund
or sweep. A revert rolls back the router, pools, handler accounting, fees, and schedule effects in
the same transaction.

Official implementation references:

- [Uniswap V3 pool swap loop](https://github.com/Uniswap/v3-core/blob/main/contracts/UniswapV3Pool.sol)
- [SwapRouter02 V3 exact-input implementation](https://github.com/Uniswap/swap-router-contracts/blob/main/contracts/V3SwapRouter.sol)

## Open product decisions

**none.** Ship the fail-closed checks below only if they remain within the explicit hot-path gas and
runtime-size ceilings. If either ceiling cannot be met, stop and report the measurements instead of
silently accepting a more expensive design.

## Scope

- [x] Store the active path's `intermediateTokens` beside `s_swapPath`. The constructor and every
      successful `_setPurchasePath` call must replace both together, so path failover cannot leave
      stale accounting metadata.
- [x] Immediately before `exactInput`, snapshot:
      - the handler's purchase-token balance; and
      - SwapRouter02's balance of every active intermediate token.
- [x] Immediately after `exactInput`, require the handler's purchase-token balance to have fallen by
      exactly `stablecoinAmount`. Revert if it fell by less, did not fall, or increased.
- [x] Require SwapRouter02's balance of every active intermediate token to equal its pre-swap
      balance. Compare before versus after, not against zero, so unrelated pre-existing router dust
      cannot grief BitChill purchases.
- [x] Keep measuring the handler's WRBTC balance delta as the purchased output. The router's return
      value remains ignored.
- [x] Add two diagnostic custom errors to `IPurchaseUniswap`:
      - `PurchaseUniswap__InputAmountNotFullySpent(uint256 expectedAmount, uint256 balanceBefore,
        uint256 balanceAfter)`; and
      - `PurchaseUniswap__IntermediateTokenBalanceChanged(address token, uint256 balanceBefore,
        uint256 balanceAfter)`.
- [x] Add deterministic router mocks and unit coverage for first-hop and later-hop partial fills.
- [x] Measure incremental hot-path gas and runtime size against this PR's base commit, under the
      `#104` pin (`optimizer = true`, `optimizer_runs = 200`, `via_ir = false`). Record both commits,
      exact commands, and results in the PR.

### Suggested code shape

This is guidance for the later implementer, not code to paste without compiling. Preserve the
current ordering around allowance, min-out construction, and the WRBTC delta.

```solidity
// State: metadata for the currently active s_swapPath.
address[] internal s_swapIntermediateTokens;

function _setPurchasePath(
    address[] memory intermediateTokens,
    uint24[] memory poolFeeRates,
    bytes memory newPath
) internal {
    s_swapPath = newPath;
    s_swapIntermediateTokens = intermediateTokens;
    emit PurchaseUniswap_NewPathSet(intermediateTokens, poolFeeRates, newPath);
}
```

In `_purchaseRbtc`, after the existing allowance/min-out/params setup and before the router call:

```solidity
IERC20 purchaseToken = _purchaseToken();
uint256 inputBalanceBefore = purchaseToken.balanceOf(address(this));

address[] memory intermediateTokens = s_swapIntermediateTokens;
uint256 intermediateCount = intermediateTokens.length;
uint256[] memory routerBalancesBefore = new uint256[](intermediateCount);
for (uint256 i; i < intermediateCount; ++i) {
    routerBalancesBefore[i] = IERC20(intermediateTokens[i]).balanceOf(address(i_swapRouter02));
}

uint256 wrBtcBalanceBefore = i_wrBtcToken.balanceOf(address(this));
i_swapRouter02.exactInput(params);

uint256 inputBalanceAfter = purchaseToken.balanceOf(address(this));
if (
    inputBalanceAfter > inputBalanceBefore
        || inputBalanceBefore - inputBalanceAfter != stablecoinAmount
) {
    revert PurchaseUniswap__InputAmountNotFullySpent(
        stablecoinAmount, inputBalanceBefore, inputBalanceAfter
    );
}

for (uint256 i; i < intermediateCount; ++i) {
    uint256 routerBalanceAfter =
        IERC20(intermediateTokens[i]).balanceOf(address(i_swapRouter02));
    if (routerBalanceAfter != routerBalancesBefore[i]) {
        revert PurchaseUniswap__IntermediateTokenBalanceChanged(
            intermediateTokens[i], routerBalancesBefore[i], routerBalanceAfter
        );
    }
}

amountOut = i_wrBtcToken.balanceOf(address(this)) - wrBtcBalanceBefore;
```

Import `IERC20` explicitly rather than relying on a transitive type import. Cache the active array
in memory once; do not re-read its storage length or elements in both loops. Small refactorings are
fine if measurements show a cheaper equally legible form, but the observable checks and error data
above are fixed.

**What shipped** ([#112](https://github.com/BitChillRSK/dca-contracts/pull/112)) follows this shape
except that the purchase's six balance reads share one private `_balanceOf(address,address)`. That is
not a preference: written with six inline `balanceOf` sites the change costs +1,163 bytes per Dex leaf,
363 over the ceiling below, and sharing them is worth 508 of that for a JUMP per read. Nothing fixed
above moves. The measurements and the full ablation are in the PR and in
[`IMPLEMENTATION_ORDER.md`](./IMPLEMENTATION_ORDER.md).

### Cost acceptance gates

Measure equivalent successful purchases before and after the change. The implementation passes only
if the incremental cost is no more than:

| Path | Maximum added gas per handler batch |
| --- | ---: |
| Direct stablecoin → WRBTC | 8,000 gas |
| One intermediate token | 15,000 gas |

Also require no Dex leaf's deployed runtime to grow by more than **800 bytes**. These are ceilings,
not targets: keep the implementation smaller when straightforward. Record all three compiled Dex
leaf sizes even though only LayerBank USDRIF and USDT0 are live Dex deployments.

The checks run once per handler batch, not once per buyer, so the incremental cost is amortized over
all schedules grouped into that handler call. Do not add an unbounded generic token-accounting
framework in order to support exotic paths; the current path length is already owner-controlled and
allowlisted.

## Out of scope

- [ ] A deadline parameter or any `DcaManager` / swapper selector change.
- [ ] Per-stablecoin USD oracles, oracle-age policy, or changes to the existing min-out floors.
- [ ] Refund, sweep, rescue, or router-custody recovery logic. Reverting is the recovery mechanism.
- [ ] Decoding `s_swapPath`, using assembly in the purchase path, or trusting `exactInput`'s return
      value as evidence of input consumption.
- [ ] Rejecting repeated/cyclic intermediate tokens or otherwise expanding path policy beyond R52's
      exact-path owner allowlist.
- [ ] Changing purchase pauses, swapper revocation authority, or batch atomicity.
- [ ] Compiler adoption work owned by R55 (R55 follows this item and still changes no setting itself).

## Files likely touched

- `src/PurchaseUniswap.sol`
- `src/interfaces/IPurchaseUniswap.sol`
- `test/mocks/MockSwapRouter02.sol` or one purpose-built partial-fill router mock
- `test/unit/PurchaseUniswapExactConsumptionTest.t.sol`
- `test/unit/DexPathFailoverTest.t.sol`

The implementer may follow direct imports, inheritance, mocks, failing tests, and compiler errors
from this list. Extra files must be named in the PR write-up.

## Required tests

- Run focused unit coverage on both production path shapes:
  `STABLECOIN_TYPE=USDT0 LENDING_PROTOCOL=layerbank SWAP_TYPE=dexSwaps forge test
  --match-path test/unit/PurchaseUniswapExactConsumptionTest.t.sol -vvv` and
  `STABLECOIN_TYPE=USDRIF LENDING_PROTOCOL=layerbank SWAP_TYPE=dexSwaps forge test
  --match-path test/unit/PurchaseUniswapExactConsumptionTest.t.sol -vvv`.
- A direct full fill succeeds, spends exactly the requested stablecoin, and credits the measured
  WRBTC delta.
- A one-intermediate full fill succeeds, spends exactly the requested stablecoin, and leaves the
  router's intermediate-token balance unchanged.
- A first-hop/direct partial fill that still clears `amountOutMinimum` reverts with
  `PurchaseUniswap__InputAmountNotFullySpent`. Assert rollback of schedule balances, handler token
  balances, fee transfer, buyer rBTC credit, and pool/router token movement.
- A later-hop partial fill that still clears `amountOutMinimum` reverts with
  `PurchaseUniswap__IntermediateTokenBalanceChanged`. Assert the same full rollback and no stranded
  router balance.
- Seed pre-existing intermediate-token dust in the router; a full fill succeeds when the balance is
  unchanged. This proves an unsolicited token transfer to the public router cannot grief the check.
- Activate a second allowlisted path with a different intermediate-token set; prove the next
  purchase checks the new set, not the constructor set. Extend `DexPathFailoverTest` rather than
  duplicating R52's authorization matrix.
- Run the full `AGENTS.md` done-gate: `make check`, `make fork-sovryn`, and
  `make fork-tropykus`. This item adds no live-liquidity fork assertion; deterministic mocks own the
  partial-fill cases, which must not become dependent on a pool remaining thin.
- Run `make fork-dex-path` because the change extends R52's active-path state, even though the fork
  test need not manufacture a partial fill.
- Record exact gas-report and `forge build --sizes` commands for the before/after acceptance table.

## Success criteria

- [x] A successful Dex purchase consumed exactly `stablecoinAmount` from the handler.
- [x] A successful multihop purchase caused no net balance change for any active intermediate token
      on SwapRouter02.
- [x] Either mismatch reverts the complete purchase, including DCA schedule and fee effects.
- [x] Active-path bytes and active intermediate-token metadata change atomically on construction and
      every later path activation.
- [x] Router dust present before the call does not cause a revert when it is unchanged afterward.
- [x] The router return value is still not an accounting input, and WRBTC credit still uses the
      handler's balance delta.
- [x] Added gas is at most 8,000 for a direct path and 15,000 for one intermediate token.
- [x] Every Dex leaf grows by at most 800 bytes and remains below EIP-170.
- [x] Full local, invariant, and mandatory fork gates pass under the `#104` pin.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold; this strengthens balance-delta cash accounting.
- [ ] Tests in the PR match **Required tests**, including full transaction rollback.
- [ ] The first-hop check compares the handler balance delta with the requested amount.
- [ ] The later-hop check compares each router balance with its own pre-swap value, not zero.
- [ ] Path failover replaces `s_swapPath` and `s_swapIntermediateTokens` together.
- [ ] Gas and runtime-size deltas are measured against the named base commit and clear the ceilings.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: additive custom errors only. No function, event, argument, return value, or selector changes.
  Internal storage grows by one dynamic address array; handlers are immutable and not proxied, so no
  deployed storage layout is migrated.
- Scripts: none. Constructor arguments and encoded path configuration are unchanged.
- Cutover: no frontend, data-api, metrics-dashboard, or swapper-bot code change. The implementation
  PR must update or open a `bitchill-monitoring` issue to regenerate `abi.json` for the two new errors
  and paste that URL in its **Cutover / frontend note**, per `AGENTS.md`.
