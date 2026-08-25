# R30 — Shared rBTC purchase pipeline

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 21, GitHub [#65](https://github.com/BitChillRSK/dca-contracts/pull/65). Stack on R29 (PR 20, GitHub [#64](https://github.com/BitChillRSK/dca-contracts/pull/64)). Land **before** the remaining R22 deploy/CI work (now PR 22) so the harness is split around the final purchase inheritance shape.

## Objective

Collapse the duplicated MoC/Uniswap single- and batch-purchase algorithm into `PurchaseRbtc`, and introduce one shared stablecoin-source declaration so the six concrete handlers no longer need twelve forwarding overrides. This is a behavior-preserving maintenance refactor: route-specific cash measurement, fees, allocation, events, errors, external ABI, and withdrawal behavior must remain unchanged.

## Background

`PurchaseMoc` and `PurchaseUniswap` currently repeat the same pipeline:

1. retrieve the stablecoin actually available;
2. calculate and transfer the fee;
3. spend the net amount through the route;
4. reject zero rBTC/WRBTC output;
5. credit accumulated rBTC and emit the single or pro-rata batch events.

The two purchase bases also declare the funding hooks independently of the funding branches that implement them. Each lending/idle + MoC/Uniswap leaf therefore forwards `_retrieveStablecoin` and `_batchRetrieveStablecoin` solely to resolve the inheritance graph. A small shared declaration seam removes that boilerplate; a forwarding bridge would merely move it.

This combines Candidates A and B from the post-R29 full-`src/` review. Candidates C–F remain unassigned in [`IMPLEMENTATION_ORDER.md`](./IMPLEMENTATION_ORDER.md).

R28's size snapshot put the Dex handlers close to EIP-170. Abstract extraction is a source-maintenance win and may be inlined rather than reducing runtime. Do not claim bytecode savings without measuring the concrete handlers on this branch.

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 21. Implement without asking.

## Scope

- [x] Add a state-free abstract `src/StablecoinSource.sol` that declares, and does not implement, the two funding hooks:
  - `_retrieveStablecoin(address buyer, uint256 amount) internal virtual returns (uint256)`
  - `_batchRetrieveStablecoin(address[] memory buyers, uint256[] memory purchaseAmounts, uint256 totalStablecoinToRetrieve) internal virtual returns (uint256)`
- [x] Make `PurchaseRbtc`, `LendingErc20Handler`, and `IdleErc20Handler` inherit the same `StablecoinSource` seam. `PurchaseRbtc` consumes the hooks without redeclaring them; the lending and idle bases mark their existing implementations `override`.
- [x] Delete the twelve forwarding resolvers and their now-unused imports from these six leaves:
  - `IdleDocHandlerMoc`
  - `SovrynDocHandlerMoc`
  - `SovrynErc20HandlerDex`
  - `TropykusDocHandlerMoc`
  - `TropykusErc20HandlerDex`
  - `LayerBankDocHandlerMoc`
- [x] Move the external `buyRbtc` and `batchBuyRbtc` implementations into `PurchaseRbtc`. Move `FeeHandler` inheritance with the common algorithm so `PurchaseMoc` and `PurchaseUniswap` no longer inherit it directly; keep constructor arguments and the resulting fee/ownership surface unchanged on concrete handlers.
- [x] Give the common pipeline two narrow route hooks (names may vary, semantics may not):
  - `_purchaseToken() internal view virtual returns (IERC20)` supplies the stablecoin used for fee transfer, errors, and events.
  - `_purchaseRbtc(uint256 stablecoinAmount) internal virtual returns (uint256 rbtcReceived)` spends the net stablecoin and returns only measured cash received.
- [x] Adapt MoC without changing behavior: `_purchaseToken` returns `i_docToken`; `_purchaseRbtc` preserves `redeemDocRequest` / `redeemFreeDoc`, the two existing custom catches, and the native balance delta around `redeemFreeDoc`.
- [x] Adapt Uniswap without changing behavior: `_purchaseToken` returns `i_purchasingToken`; `_purchaseRbtc` delegates to or absorbs `_swapStablecoinForWrbtc`, whose result remains the measured WRBTC balance delta. Keep Uniswap's withdrawal override unwrapping WRBTC before `_withdrawRbtc`.
- [x] Preserve the common single path exactly: use the amount actually returned by `_retrieveStablecoin`, calculate the fee from that amount, transfer the fee before the route call, purchase only the net amount, then credit and emit `PurchaseRbtc__RbtcBought`; zero output reverts `PurchaseRbtc__RbtcPurchaseFailed(buyer, token)`.
- [x] Preserve the common batch path exactly: calculate the planned per-user net amounts and aggregate fee first; retrieve the planned gross total; revert `PurchaseRbtc__StablecoinRetrievedBelowFee` when retrieved cash is not above the fee; transfer the fee before the route call; use planned net amounts only as allocation weights; allocate both measured rBTC and actually spent stablecoin pro rata; then emit the per-user events followed by `PurchaseRbtc__SuccessfulRbtcBatchPurchase`. Zero output reverts `PurchaseRbtc__RbtcBatchPurchaseFailed(token)`.
- [x] Add base-level tests with a stub funding source and purchase route so the shared algorithm is tested once independently of MoC/Uniswap, while the existing route tests continue to pin each adapter's cash measurement, external calls, errors, and withdrawal behavior.
- [x] Update `AGENTS.md`'s layout description after the Solidity inheritance changes are implemented.

## Out of scope

- [ ] Any external function, event, error, constructor, or storage-layout change.
- [ ] Candidate C selector/ABI pruning, including duplicate getters or the `FeeHandler` public surface.
- [ ] Candidate D `DcaManager` cleanup or schedule ABI decisions.
- [ ] Candidate E Uniswap slippage-validation changes; preserve the current setters and validation behavior, including known asymmetry.
- [ ] Candidate F / R13 `OperationsAdmin` registry, roles, handler-replacement, or migration policy.
- [ ] Fee formula, bounds, collector, or setter changes.
- [ ] R9 event indexing / `TokenLending__UserSharesUpdated`.
- [ ] Assembly, calldata rewrites, unchecked-loop changes, or product behavior disguised as a gas optimization.
- [ ] Deploy-script/index-map work from R22, deploy broadcasts, proxies, owner rescue, or a withdrawal `to` parameter.

## Files likely touched

- `src/StablecoinSource.sol` (new)
- `src/PurchaseRbtc.sol`
- `src/PurchaseMoc.sol`
- `src/PurchaseUniswap.sol`
- `src/LendingErc20Handler.sol`
- `src/idle/IdleErc20Handler.sol`
- `src/idle/IdleDocHandlerMoc.sol`
- `src/sovryn/SovrynDocHandlerMoc.sol`
- `src/sovryn/SovrynErc20HandlerDex.sol`
- `src/tropykus-legacy/TropykusDocHandlerMoc.sol`
- `src/tropykus-legacy/TropykusErc20HandlerDex.sol`
- `src/layerbank/LayerBankDocHandlerMoc.sol`
- `test/unit/PurchaseRbtcTest.t.sol` (new base-pipeline tests; exact name may vary)
- `test/unit/RbtcPurchaseTest.t.sol` and direct route/handler tests affected by the inheritance move
- `AGENTS.md` (layout/inheritance description only, after implementation)
- `docs/relaunch/README.md` Status after the PR opens

Interfaces and scripts are not expected to change. If a compiler error forces an interface, mock, harness, or constructor call-site update, name it in the PR and preserve the external ABI.

## Required tests

Target the shared algorithm first (adjust the match contract to the exact test name shipped):

```sh
forge test --match-contract PurchaseRbtcTest

SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-contract RbtcPurchaseTest

SWAP_TYPE=dexSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=USDRIF \
  forge test --match-contract RbtcPurchaseTest

forge build --sizes
make check
make fork-sovryn
make fork-tropykus
```

Base-level behaviors to assert:

- Single purchase uses actual retrieved stablecoin when it is below the request; fee and event `stablecoinSpent` use that actual amount/net.
- Fee transfer happens before the route hook, and the route receives exactly the net amount.
- Successful output credits the buyer and emits the existing event; zero output raises the existing token-specific error.
- Batch retrieval at or below the aggregate fee raises `PurchaseRbtc__StablecoinRetrievedBelowFee` before a route purchase.
- Batch allocation uses planned net amounts as weights but reports/credits shares of actual stablecoin spent and measured rBTC received, including existing integer-rounding behavior and repeated buyers.
- Batch emits the existing per-user events in order and the existing summary event last; zero output raises the existing batch error.

Adapter behaviors to retain in existing tests:

- MoC uses the handler's native-rBTC delta and preserves both named MoC failures.
- Uniswap uses the handler's WRBTC delta rather than the router return and still unwraps on withdrawal.
- Idle, Sovryn, Tropykus, and LayerBank single/batch funding behavior is unchanged after deleting the leaf resolvers.

Fork tests add no new fork-specific assertions; both still run before push per `AGENTS.md`.

## Success criteria

- [x] Exactly one `buyRbtc` implementation and one `batchBuyRbtc` implementation exist under `src/` outside `DcaManager`; MoC and Uniswap contain only route-specific purchase logic.
- [x] `StablecoinSource` owns the only abstract declarations of the funding hooks; `LendingErc20Handler` and `IdleErc20Handler` own the implementations; the six leaves contain no forwarding implementations.
- [x] No forwarding bridge or funding-source × purchase-route combination base was added.
- [x] Fee calculation/transfer order, actual-cash accounting, batch weights, accumulated balances, event names/parameters/order, and custom errors match the pre-R30 behavior.
- [x] External ABI, constructors, deploy scripts, and storage layout are unchanged.
- [x] `forge build --sizes` records the concrete handler sizes and both Dex handlers remain below EIP-170. No bytecode reduction is claimed unless the measurement demonstrates it.
- [x] Base, route, handler, done-gate, and both fork tests pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none).
- [ ] The common pipeline did not replace measured cash with an integrator return value or view.
- [ ] Tests independently pin the shared algorithm and both route adapters.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none. Existing concrete-handler functions, events, errors, getters, ownership, and constructor signatures remain unchanged.
- Scripts: none. Constructor call sites must not need changes.
- Cutover: none. Fresh relaunch deployments; no live migration or frontend/indexer action.
