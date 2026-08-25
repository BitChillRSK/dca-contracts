# R28 — Extract `LendingErc20Handler`

Status: **not started** · Assigned: yes · Optional/further-review: no

PR 19 (promoted from optional late 2026-08-25). Stack on R27 (PR 18). Do **not** start this in the same chat as R27, R22 deploy/CI, R9, or R10. Requires [R27](./R27-tropykus-lending-guards.md) so Tropykus already matches the Sovryn/LayerBank guards. Land **before** R22 deploy/CI (PR 20) and R9 (PR 21) so `TokenLending__UserSharesUpdated` is emitted in one place and the harness split sees one lending base.

Write against the **R26 `shares` vocabulary**.

## Objective

Collapse the three lending `*Erc20Handler` twins into one abstract `LendingErc20Handler is TokenHandler, TokenLending` that owns per-user share accounting, the withdraw clamp, interest math, and the batch pro-rata loop. Protocol files become adapters over a small hook set. Idle stays out. No product behavior change beyond what R27 already aligned.

## Background

After R25 / R26, `withdrawInterest`, `getAccruedInterest`, `getUserShares`, `withdrawToken`’s clamp, the redeem clamp-and-measure body, and `_batchRetrieveStablecoin`’s pro-rata loop are the same algorithm in `SovrynErc20Handler`, `TropykusErc20Handler`, and `LayerBankErc20Handler`. R25 itself had to apply one naming decision three times. R9 will add `TokenLending__UserSharesUpdated` at every share mint/burn in all three — the next drift site.

Normalized (token noun and protocol name stripped, comments dropped): ~60 unique lines appear in all three files, against ~102 / 113 / 134 unique lines for Sovryn / Tropykus / LayerBank. The three `*DocHandlerMoc` diamond resolvers are a fourth copy.

That duplication already produced the R27 Tropykus gaps. Do not “fix Tropykus while extracting”; R27 owns those two guards.

### What is protocol-specific (the real seams)

| Seam | Tropykus | Sovryn | LayerBank |
| --- | --- | --- | --- |
| Exchange rate | `exchangeRateCurrent()` / `exchangeRateStored()` | `tokenPrice()` | `_normalizedIncome()` (RAY `1e27`) |
| Deposit | `mint(amount)` → Compound code | `mint(this, amount)` | `pool.supply(...)` |
| Share measurement | `kToken.balanceOf` | `iSusd.balanceOf` | `aToken.scaledBalanceOf` |
| Redeem | `redeemUnderlying` / `redeem`, no recipient | `burn(recipient, shares)` | `pool.withdraw(asset, amt, to)` |
| Failure convention | Compound return code | reverts | reverts; skip call if `amountOut == 0` (`InvalidAmount`) |
| Redeem sizing | two kToken methods | shares only (`burn`) | always `withdraw`; amount is underlying- or share-sized |

R25 kept Sovryn on one helper (`_redeemShares` after R26) on purpose. Do not invent a fake `_redeemByUnderlying` there.

### What does **not** fit four virtuals

- **`TokenLending` stays conversion math.** `AGENTS.md` layout: `TokenLending` does not inherit `TokenHandler`. Do **not** lift `depositToken` / `s_*Balances` into `TokenLending`. The new type is `LendingErc20Handler is TokenHandler, TokenLending`.
- **Idle is not a fourth sibling.** `IdleErc20Handler` has no shares, no exchange rate, and a batch that reverts instead of clamping. Leave it.
- **Recipient vs extra transfer.** Sovryn `burn(user, shares)` pays the user directly (SIP-0094: measure the user’s DOC delta). LayerBank’s spec still withdraws onto the handler, measures, then `safeTransfer`. Tropykus has no recipient and always `safeTransfer`s after. The hook must accept a recipient; do not force Sovryn through an extra hop.
- **LayerBank constructor.** Hardcodes `TokenLending(RAY)`; extra `UNDERLYING_ASSET_ADDRESS` / `POOL()` checks. Keep those in the LayerBank adapter.
- **Index 3 (future MoC lending)** is the payoff for doing this at all. If that handler is not on the horizon and this PR is after R9, the win is one emit site and one clamp implementation.

`IMPLEMENTATION_ORDER.md`’s idle-funds heads-up already asked to “consider making the base class enforce” the per-user withdraw clamp. This PR is that extract for **lending** handlers. Idle already has its own clamp.

## Open product decisions

**none** unless the human named this optional item (`IMPLEMENTATION_ORDER.md` Ask column). The layout (`LendingErc20Handler`, not a fatter `TokenLending`) and the Tropykus-in-the-base decision (yes: Compound codes live only in the Tropykus adapter) are recorded here. Implement without asking.

## Scope

- [ ] Add `src/LendingErc20Handler.sol` (name may be `LendingHandler`; do not call it `TokenLending`). Owns:
  - `mapping(address => uint256) internal s_shares`
  - `getUserShares`
  - `depositToken` template: `super.depositToken`, approve, `_protocolDeposit`, revert `TokenLending__LendingProtocolDepositFailed` if minted == 0, credit `s_shares[user]`
  - `withdrawToken` clamp + `_redeemByUnderlying` / Sovryn `_redeemShares` + `super.withdrawToken`
  - `withdrawInterest` / `getAccruedInterest`
  - `_retrieveStablecoin` / `_batchRetrieveStablecoin` (pro-rata `Math.mulDiv` round-up, insufficient-shares revert, one protocol redeem, zero-received revert)
  - Shared redeem clamp-and-measure (`TokenLending__AmountToRedeemAdjusted`) before the protocol call
- [ ] Virtual hooks (signatures may vary; this is the required surface):
  - `_exchangeRate()` (mutating-ok) and `_viewExchangeRate()`
  - `_protocolDeposit(uint256 stablecoinAmount) returns (uint256 mintedShares)` — adapter measures the right balance (`balanceOf` vs `scaledBalanceOf`) and talks to the protocol
  - `_protocolRedeem(uint256 stablecoinAmount, uint256 sharesAmount, bool sizeByUnderlying, address recipient) returns (uint256 received)` — Tropykus uses the Compound code + extra `safeTransfer` when `recipient != address(this)`; Sovryn ignores `sizeByUnderlying` and `burn`s to `recipient`; LayerBank computes `amountOut`, skips the Pool call if 0, otherwise `withdraw` to `recipient` (today: handler, then the base transfers)
- [ ] `TropykusErc20Handler`, `SovrynErc20Handler`, `LayerBankErc20Handler` become thin adapters (immutables, constructor checks, hook impls). Keep protocol-specific interfaces next to each handler.
- [ ] `*DocHandlerMoc` (and Sovryn/Tropykus Dex) diamond resolvers: change the parent name to `LendingErc20Handler`; do not try to delete the three resolver files.
- [ ] If R9 has already landed, move `TokenLending__UserSharesUpdated` emits into `LendingErc20Handler` (do not leave copies in the adapters). If R9 has not landed, emit nothing new here — R9 adds the event once in the base.
- [ ] Existing unit tests for all three handlers keep passing with no behavior change vs post-R27 Tropykus. Add no new product tests beyond whatever the extract breaks.

## Out of scope

- [ ] R27 Tropykus guard alignment (must already be merged, or this extract copies the *wrong* Tropykus batch/deposit policy into the base).
- [ ] Absorbing `IdleErc20Handler`.
- [ ] Making `TokenLending` inherit `TokenHandler`.
- [ ] Handler replacement in `OperationsAdmin` (still unassigned).
- [ ] Changing Sovryn interest to an extra `safeTransfer` hop, or LayerBank interest to `withdraw(..., user)` without a handler-side measure.
- [ ] Inventing `_redeemByUnderlying` on Sovryn.
- [ ] R10 natspec rewrite beyond the new base and moved declarations.
- [ ] Deploy/CI index map.

## Files likely touched

- `src/LendingErc20Handler.sol` (new)
- `src/TokenLending.sol` — conversion only; no new user-facing functions
- `src/tropykus-legacy/TropykusErc20Handler.sol` and Moc/Dex leaves
- `src/sovryn/SovrynErc20Handler.sol` and Moc/Dex leaves
- `src/layerbank/LayerBankErc20Handler.sol` and Moc leaf
- Matching handler unit tests if imports / inheritance names break

## Required tests

No new product behavior. Full matrix, because all three lending handlers change shape:

```
make check
make moc-tropykus
make fork-sovryn
make fork-tropykus
```

R22 deploy/CI (PR 20) has not landed yet when this PR runs, so the LayerBank lane may still be add-on-only; `make check` / `make moc-tropykus` / both forks are the gate. If PR 20 somehow merges first, also run that CI lane.

Fork tests: no new fork-specific assertions; run before push per `AGENTS.md`.

## Success criteria

- [ ] One implementation of the withdraw clamp, interest math, batch pro-rata loop, and zero-mint / zero-received guards.
- [ ] `TokenLending.sol` still has no `TokenHandler` inherit and no `s_shares` mapping.
- [ ] Idle handler untouched.
- [ ] Tropykus Compound return codes exist only in the Tropykus adapter.
- [ ] Sovryn still redeems to a recipient; LayerBank still measures on the handler then transfers (unless a later spec says otherwise).
- [ ] `make check` and both fork targets pass. Behavior matches post-R27.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable. Do not bundle R12/R13/R18/R19 or natspec.

## ABI / deploy / cutover impact

- ABI: none expected. External `ITokenLending` / `ITokenHandler` surface stays; internals move. If R9 landed first, event `topic0` and emit sites stay the same, only the declaring contract changes.
- Scripts: none, unless a test deploy constructs `new Handler` and the constructor arg list changes — keep constructor args identical at the leaf contracts.
- Cutover: none. Fresh relaunch deployments. Tropykus still not in the live index map.
