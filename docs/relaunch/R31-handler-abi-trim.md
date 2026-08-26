# R31 — Trim the handler ABI before the event freeze

Status: **not started** · Assigned: yes · Optional/further-review: no

PR 25. Stack on R33 (PR 24). Land before R9: R30 left only 329–452 bytes of EIP-170 margin on the two Dex handlers, and R9 must add share-transition emissions to the shared lending path.

## Objective

Remove redundant concrete-handler selectors and duplicate immutable aliases so the relaunch exposes one canonical API for each piece of state and reserves bytecode headroom for required observability.

## Background

R30 made the handler's `i_stableToken` the canonical purchase token, but the route bases still expose `i_docToken()` or `i_purchasingToken()`. Uniswap exposes both the automatic `s_mocOracle()` getter and `getMocOracle()`. `PurchaseRbtc` exposes both address-taking and caller-only accumulated-balance getters. `FeeHandler` exposes aggregate settings alongside four individual getters, four individual setters, and a public constant getter.

This is a fresh relaunch, so the ABI should be settled before R9 rather than carrying aliases indefinitely. R3 intentionally retained the individual fee setters; removing them requires an explicit decision, not an incidental cleanup.

## Open product decisions

- **Fee mutation surface:** keep the four individual setters, or remove them and make `setFeeRateParams` the only fee-band mutation. Recommended: atomic-only mutation, because it cannot pass through an invalid intermediate band and creates the most bytecode headroom.

The duplicate route-token getters, automatic oracle getter, caller-only accumulated-rBTC getter, individual fee getters, and public fee-cap getter are assigned for removal.

## Scope

- [ ] Remove `i_docToken` and `i_purchasingToken`; use inherited `i_stableToken` in MoC/Uniswap route logic and keep constructor signatures unchanged.
- [ ] Make the Uniswap oracle storage non-public and retain `getMocOracle()` as the canonical getter.
- [ ] Remove `IPurchaseRbtc.getAccumulatedRbtcBalance()` with no arguments; retain `getAccumulatedRbtcBalance(address)` and DcaManager's user-facing getter.
- [ ] Remove the four individual fee getters in favor of `getFeeSettings()`.
- [ ] Make `MAX_FEE_RATE_CAP` non-public while retaining the 5% cap and every validation path.
- [ ] Apply the recorded fee-setter decision. Keep `setFeeCollectorAddress` and `getFeeCollectorAddress`, because the collector is not part of `FeeSettings`.
- [ ] Update first-party interfaces, scripts, deployment assertions, handler tests, fuzz wrappers, and any checked-in consumer to the canonical APIs.
- [ ] Record before/after ABI selector lists and runtime sizes for all six concrete handlers.

## Out of scope

- [ ] Fee formula, bounds, collector policy, cap value, or event semantics.
- [ ] R33 slippage behavior, R34 DcaManager ABI, R9 event indexing, or further code-size work.
- [ ] Constructor changes, storage-layout changes, protocol adapters, deploy-index changes, or live broadcasts.

## Files likely touched

- `src/PurchaseMoc.sol`
- `src/PurchaseUniswap.sol`
- `src/PurchaseRbtc.sol`
- `src/FeeHandler.sol`
- `src/interfaces/IPurchaseUniswap.sol`
- `src/interfaces/IPurchaseRbtc.sol`
- `src/interfaces/IFeeHandler.sol`
- Matching deployment, unit, fuzz-wrapper, and handler tests named by compiler errors or direct selector usage

## Required tests

```sh
forge test --match-contract PurchaseRbtcTest
forge test --match-contract PurchaseUniswapSettingsTest
forge test --match-contract "HandlerTestHarness|RoleSecurityTest"
forge build --sizes
for handler in SovrynDocHandlerMoc SovrynErc20HandlerDex TropykusDocHandlerMoc TropykusErc20HandlerDex IdleDocHandlerMoc LayerBankDocHandlerMoc; do
  forge inspect "$handler" methodIdentifiers
  forge inspect "$handler" storageLayout
done
make check
make fork-sovryn
make fork-tropykus
```

Run the inspection loop against the actual base and head. Assert that only assigned selectors disappear, constructor ABIs and storage slots remain unchanged, fee validation is identical, and all concrete handlers stay below EIP-170 with increased margin.

## Success criteria

- [ ] Each exposed value has one canonical getter.
- [ ] Purchase routes use `i_stableToken`; no duplicate route-token immutable remains.
- [ ] Fee behavior and the 5% cap are unchanged.
- [ ] The decided fee mutation surface is reflected consistently in implementation, interface, tests, and docs.
- [ ] Constructor ABI and storage layout are unchanged.
- [ ] Concrete-handler runtime margins are measured and improve.
- [ ] Targeted, done-gate, and both fork tests pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Removed selectors have canonical replacements and checked-in consumers were migrated.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No fee or purchase behavior is disguised as ABI cleanup.

## ABI / deploy / cutover impact

- ABI: intentional selector removal before R9; exact list recorded in the PR. No constructor/event/storage change.
- Scripts: local/test call sites move to canonical getters; deployment behavior is unchanged.
- Cutover: frontend/backend/indexer consumers must use canonical getters and the recorded fee mutation API before relaunch.
