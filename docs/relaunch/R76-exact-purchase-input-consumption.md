# R76 — Exact stablecoin consumption on every purchase venue

Status: **implemented** · GitHub [#135](https://github.com/BitChillRSK/dca-contracts/pull/135) · Assigned: yes · Optional/further-review: no · Order: stack on R75 before any deployment

## Objective

Require every successful rBTC purchase to consume exactly the net stablecoin amount the shared pipeline
gave its venue. Enforce the invariant once in `PurchaseRbtc`, so both Money on Chain and Uniswap fail
closed instead of leaving debited stablecoin in a handler, and reject a zero MoC oracle at Dex-handler
construction.

## Background

`PurchaseUniswap` already proves that `exactInput` removed the complete requested input from the handler,
but the property belongs to the shared purchase pipeline. Money on Chain's `redeemFreeDoc` may redeem the
minimum of the request, the caller's balance, and the protocol's current free-DOC capacity. A positive
partial redemption therefore produces rBTC while consuming less DOC than `PurchaseRbtc` has already
debited from schedules and handler books. A loose `minRbtcOut` can let that purchase commit and leave the
unconsumed DOC without a corresponding user claim.

The shared check must measure the purchase token around `_purchaseRbtc`, require an exact decrease, and
revert the whole transaction on a short, flat, or rising balance. It must not preflight with `freeDoc()` or
another venue view: only the balance delta after the venue call is authoritative. Uniswap's intermediate-
token router check remains venue-specific and stays in `PurchaseUniswap`.

`PurchaseUniswap`'s update setter already rejects a zero oracle, and the canonical deployment script also
rejects one. Applying the same check in its constructor makes the handler itself fail closed when deployed
through any path.

## Open product decisions

**none** — the human chose the shared `PurchaseRbtc` check, removal of the Uniswap-specific input check,
and constructor oracle validation on 2026-09-13.

## Scope

- [x] In `PurchaseRbtc.batchBuyRbtc`, snapshot `_purchaseToken()` immediately before `_purchaseRbtc` and
      require the handler's balance to decrease by exactly the net stablecoin amount passed to the venue.
- [x] Declare the generic exact-consumption error on `IPurchaseRbtc`, with expected amount and before/after
      balances for diagnosis.
- [x] Remove the now-duplicated handler-input snapshot/check and its Uniswap-specific error from
      `PurchaseUniswap` / `IPurchaseUniswap`; retain measured WRBTC output and the router intermediate-token
      balance checks.
- [x] Reject `address(0)` for `uniswapSettings.mocOracle` in the `PurchaseUniswap` constructor using the
      existing invalid-oracle error.
- [x] Extend the MoC mock and focused tests to prove a positive partial redemption reverts and rolls back
      the buyer's idle balance, fee payment, token movement, and accumulated rBTC.
- [x] Update the Uniswap exact-consumption tests to assert the shared error, and add constructor-zero-oracle
      coverage.
- [x] Record the shared invariant and update current audit/release guidance where it describes exact input
      consumption as Uniswap-only.
- [x] Update the existing matching consumer issues for the handler custom-error change and MoC failure mode.

## Out of scope

- [ ] Fee arithmetic or naming changes, including `BPS_DENOMINATOR`.
- [ ] `minRbtcOut` semantics, MoC `freeDoc()` preflights, partial-redeem retries, batch splitting, or a new
      purchase pause.
- [ ] Uniswap path, oracle-floor, intermediate-token, or output-delta behavior beyond relocating the common
      input-consumption check.
- [ ] Constructor validation for unrelated immutable addresses or any deployment broadcast.
- [ ] R74 launch economics.

## Files likely touched

- `AGENTS.md`
- `AUDIT_GUIDE.md`
- `src/PurchaseRbtc.sol`
- `src/PurchaseUniswap.sol`
- `src/interfaces/IPurchaseRbtc.sol`
- `src/interfaces/IPurchaseUniswap.sol`
- `test/mocks/MockMocProxy.sol`
- `test/unit/PurchaseMocBehaviorTest.t.sol`
- `test/unit/PurchaseUniswapExactConsumptionTest.t.sol`
- `test/unit/PurchaseUniswapSettingsTest.sol`
- `docs/relaunch/R76-exact-purchase-input-consumption.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/README.md`

## Required tests

```bash
forge test --match-contract PurchaseMocBehaviorTest
SWAP_TYPE=dexSwaps LENDING_PROTOCOL=none STABLECOIN_TYPE=USDT0 \
  forge test --match-contract PurchaseUniswapExactConsumptionTest
SWAP_TYPE=dexSwaps LENDING_PROTOCOL=none STABLECOIN_TYPE=USDT0 \
  forge test --match-contract PurchaseUniswapSettingsTest
make slither
make aderyn
make check
make check-deploy
make fork-sovryn
make fork-tropykus
make fork-dex-path
```

The MoC regression must return positive rBTC while consuming less DOC than requested and still revert with
the shared exact-consumption error. State before and after the reverted purchase must match. Existing
Uniswap first-hop partial-fill and later-hop intermediate-balance tests must retain their behavior; only the
first-hop error's declaring interface changes. Fork tests add no new fork-only assertion but remain required
before push.

## Success criteria

- [x] No successful `PurchaseRbtc` venue can consume less or more stablecoin than the net amount passed to it.
- [x] A partial MoC free-DOC redemption cannot strand stablecoin after BitChill accounting was debited.
- [x] Uniswap retains its exact-input and intermediate-token guarantees without duplicating the common check.
- [x] A Dex handler cannot be constructed with a zero MoC oracle.
- [x] No open product decisions remain and every required gate passes.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] The balance delta is measured in the shared pipeline after the fee transfer and immediately around the
      venue call; it does not trust a return value or venue view.
- [ ] Reverting the shared check rolls back schedule, handler-book, fee, venue, and rBTC-accounting effects.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: remove `PurchaseUniswap__InputAmountNotFullySpent(uint256,uint256,uint256)` from
  `IPurchaseUniswap`; add the equivalent shared `PurchaseRbtc__InputAmountNotFullySpent` error to
  `IPurchaseRbtc`. Function selectors, events, storage, and constructor arguments are unchanged.
- Scripts: none. Existing `DeployFinal` zero-oracle validation remains.
- Cutover: monitoring must regenerate handler ABIs for the moved error. The swapper must treat exact-input
  failures on MoC as a failed batch to re-quote, split, or retry rather than assuming any positive redemption
  succeeded. Update matching issues instead of opening duplicates.
