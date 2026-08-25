# R28 — Extract `LendingErc20Handler`

Status: **PR open** · Assigned: yes · Optional/further-review: no

PR 19 (promoted from optional late 2026-08-25), GitHub [#63](https://github.com/BitChillRSK/dca-contracts/pull/63). Stack on R27 (PR 18). Do **not** start this in the same chat as R27, R22 deploy/CI, R9, or R10. Requires [R27](./R27-tropykus-lending-guards.md) so Tropykus already matches the Sovryn/LayerBank guards. Land **before** R22 deploy/CI (PR 20) and R9 (PR 21) so `TokenLending__UserSharesUpdated` is emitted in one place and the harness split sees one lending base.

Write against the **R26 `shares` vocabulary**.

## Objective

Collapse the three lending `*Erc20Handler` twins into one abstract `LendingErc20Handler is TokenHandler, TokenLending` that owns per-user share accounting, the withdraw clamp, interest math, and the batch pro-rata loop. Protocol files become adapters over a small hook set. Idle stays out. Interest always redeems onto the handler then `safeTransfer`s to the user, and **every** redemption is sized by the share count the base debits (human named both on PR 19: drop Sovryn `burn(user)` so `_protocolRedeem` needs no recipient, then drop `sizeByUnderlying` so it needs no sizing flag either). No other product behavior change beyond what R27 already aligned.

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
| Redeem | `redeem(shares)`, always to handler | `burn(this, shares)` | `pool.withdraw(..., this)` |
| Failure convention | Compound return code | reverts | skip call if `amountOut == 0` (`InvalidAmount`) |
| Redeem sizing | share count (`redeemUnderlying` unused) | share count (`burn`) | share count converted to underlying — Aave has no share-sized withdraw |

R25 kept Sovryn on one helper (`_redeemShares` after R26) on purpose. That helper's name is now the *only* one: R28 collapses `_redeemByUnderlying` / `_redeemByShares` / `_redeemInternal` into it.

### What does **not** fit four virtuals

- **`TokenLending` stays conversion math.** `AGENTS.md` layout: `TokenLending` does not inherit `TokenHandler`. Do **not** lift `depositToken` / `s_*Balances` into `TokenLending`. The new type is `LendingErc20Handler is TokenHandler, TokenLending`.
- **Idle is not a fourth sibling.** `IdleErc20Handler` has no shares, no exchange rate, and a batch that reverts instead of clamping. Leave it.
- **Always redeem onto the handler.** Human named this on PR 19: Sovryn `burn(user)` is not worth a `recipient` parameter on the shared hook. All three adapters redeem to `address(this)` and measure this contract’s stablecoin delta (SIP-0094 still holds: never trust `burn`’s return). `withdrawInterest` in the base then `safeTransfer`s to the user when `received > 0`. Principal withdraw and purchases already worked that way. Do not add `withdraw(..., user)` on LayerBank.
- **Size every redeem by shares.** Human named this on PR 19 after the recipient removal. The base already computes a matched pair (`sharesToRedeem`, `stablecoinAmount`) that differ by under one rate-unit, so the flag only ever chose between outcomes at most 1 wei apart — while Sovryn ignored it outright and LayerBank used it to pick between two numbers it derived from the same pair. Sizing by the debited share count also states the solvency invariant directly: the number booked out of `s_shares` *is* the number handed to the protocol to burn, so Tropykus and Sovryn burn it exactly and the books cannot drift above the shares held even if a protocol's internal rate disagrees with the one read here. What comes back is protocol-chosen and always measured, which every path already did. Unification had to go this way — Sovryn has no underlying-sized redeem, and inventing one stays forbidden. LayerBank is the exception that proves it: Aave has no share-sized withdraw, so it converts the debited count back to underlying and floors, keeping Aave's `rayDiv` burn at or below the debit.
- **Measurement and the zero-payout verdict are the base's, not the adapter's.** Adapters move funds and nothing else: `_protocolRedeem` returns `void`. The base brackets the call with one `balanceOf` pair (`_measuredProtocolRedeem`) and decides what a zero delta means. `AGENTS.md` invariant 1 then has exactly one implementation instead of three, and an adapter cannot accidentally report an integrator's claim as cash. What stays adapter-side is only what its own protocol dictates: Tropykus's Compound return code, and LayerBank skipping a zero `Pool.withdraw` that live Aave would reject with `InvalidAmount`.
- **Zero-payout predicate (PR 63 review).** After the per-user share clamp: if `sharesToRedeem == 0`, return 0 without storage writes, protocol calls, or `TokenLending__SharesRedeemed`. Otherwise debit, measure, and **unconditionally** revert `TokenLending__ZeroStablecoinReceived` when the measured payout is 0. That revert rolls back the virtual debit and any protocol-side burn. This supersedes the earlier Tropykus-derived `stablecoinAmount > 0 &&` conjunct, which treated sub-wei positions as “must stay exitable.” That claim contradicts [R15](./R15-withdraw-all-sentinel.md) (**Decision — lending-share dust deferred**): this PR does **not** sweep or fix lending dust. The `sharesToRedeem > usersShares` clamp stays — it is a per-user solvency boundary (R21: `DcaManager` can sit ahead of share-backed underlying; `_retrieveStablecoin` has no `withdrawToken` outer clamp), not a rounding workaround, and it never uses the handler's pooled protocol balance as the ceiling.
- **LayerBank constructor.** Hardcodes `TokenLending(RAY)`; extra `UNDERLYING_ASSET_ADDRESS` / `POOL()` checks. Keep those in the LayerBank adapter.
- **Index 3 (future MoC lending)** is the payoff for doing this at all. If that handler is not on the horizon and this PR is after R9, the win is one emit site and one clamp implementation.

`IMPLEMENTATION_ORDER.md`’s idle-funds heads-up already asked to “consider making the base class enforce” the per-user withdraw clamp. This PR is that extract for **lending** handlers. Idle already has its own clamp.

## Open product decisions

**none** remaining. `IMPLEMENTATION_ORDER.md` Ask column is empty. Layout (`LendingErc20Handler`, not a fatter `TokenLending`) and Tropykus-in-the-base (Compound codes stay in the Tropykus adapter) were recorded here. Human named three on PR 19: (1) Sovryn interest uses the same handler-then-`safeTransfer` path as Tropykus/LayerBank, so `_protocolRedeem` has no `recipient`; (2) every redeem is sized by the debited share count, so it has no `sizeByUnderlying` either and Tropykus drops `redeemUnderlying`; (3) the balance-delta measurement and the zero-payout revert move into the base, so `_protocolRedeem` returns `void` and takes no `stablecoinAmount`. **PR 63 review supersedes (3)'s Tropykus-derived `stablecoinAmount > 0 &&` conjunct:** a positive share redemption that pays nothing always reverts; a zero-share result is a no-op. R15 lending-share dust remains deferred.

## Scope

- [x] Add `src/LendingErc20Handler.sol` (name may be `LendingHandler`; do not call it `TokenLending`). Owns:
  - `mapping(address => uint256) internal s_shares`
  - `getUserShares`
  - `depositToken` template: `super.depositToken`, approve, `_protocolDeposit`, revert `TokenLending__LendingProtocolDepositFailed` if minted == 0, credit `s_shares[user]`
  - `withdrawToken` clamp + `_redeemShares` + `super.withdrawToken`
  - `withdrawInterest` / `getAccruedInterest`
  - `_retrieveStablecoin` / `_batchRetrieveStablecoin` (pro-rata `Math.mulDiv` round-up, insufficient-shares revert, one protocol redeem, zero-received revert)
  - Shared redeem clamp-and-measure (`TokenLending__AmountToRedeemAdjusted`) before the protocol call
- [x] Virtual hooks (signatures may vary; this is the required surface):
  - `_exchangeRate()` (mutating-ok) and `_viewExchangeRate()`
  - `_protocolDeposit(uint256 stablecoinAmount) returns (uint256 mintedShares)` — adapter measures the right balance (`balanceOf` vs `scaledBalanceOf`) and talks to the protocol
  - `_protocolRedeem(uint256 sharesAmount, uint256 exchangeRate)` — returns nothing; always credits this contract; always sized by `sharesAmount`. Tropykus `redeem(sharesAmount)` + the Compound code; Sovryn `burn(address(this), sharesAmount)`; LayerBank derives `amountOut` from `sharesAmount` at the caller-supplied rate (do not re-query the Pool), skips the Pool call if 0, otherwise `withdraw`s to the handler. Measurement, the zero-payout revert, and the interest `safeTransfer` are all the base's. Adapter hook impls are `override` not `virtual`: Moc/Dex leaves do not specialize them; a test that needs to stub `_protocolRedeem` should subclass `LendingErc20Handler` directly.
- [x] `TropykusErc20Handler`, `SovrynErc20Handler`, `LayerBankErc20Handler` become thin adapters (immutables, constructor checks, hook impls). Keep protocol-specific interfaces next to each handler.
- [x] `*DocHandlerMoc` (and Sovryn/Tropykus Dex) diamond resolvers: change the parent name to `LendingErc20Handler`; do not try to delete the three resolver files.
- [x] If R9 has already landed, move `TokenLending__UserSharesUpdated` emits into `LendingErc20Handler` (do not leave copies in the adapters). If R9 has not landed, emit nothing new here — R9 adds the event once in the base.
- [x] Collapse `_redeemByUnderlying` / `_redeemByShares` / `_redeemInternal` into one `_redeemShares(user, stablecoinAmount, exchangeRate)`; drop `redeemUnderlying` from `IkToken` once nothing calls it (mocks keep it — they model the live kToken ABI).
- [x] One `balanceOf` bracket in the base (`_measuredProtocolRedeem`) feeding both `_redeemShares` and `_batchRetrieveStablecoin`; no adapter measures or raises `TokenLending__ZeroStablecoinReceived`.
- [x] After the per-user share clamp: `sharesToRedeem == 0` returns 0 with no protocol call and no `SharesRedeemed`; any positive share burn that pays 0 reverts `TokenLending__ZeroStablecoinReceived` and rolls back. This does not sweep R15 dust.
- [x] Existing unit tests for all three handlers keep passing. The sizing change does move Tropykus behavior, so pin the new invariant: book debit equals the protocol burn on Tropykus and Sovryn, and never falls below it on LayerBank.

## Out of scope

- [ ] R27 Tropykus guard alignment (must already be merged, or this extract copies the *wrong* Tropykus batch/deposit policy into the base).
- [ ] Absorbing `IdleErc20Handler`.
- [ ] Making `TokenLending` inherit `TokenHandler`.
- [ ] Handler replacement in `OperationsAdmin` (still unassigned).
- [ ] LayerBank interest to `withdraw(..., user)` without a handler-side measure.
- [ ] Inventing an underlying-sized redeem on Sovryn, or re-deriving one anywhere else.
- [ ] Sweeping or promising to zero leftover lending-share dust (R15 deferred).
- [ ] R10 natspec rewrite beyond the new base and moved declarations.
- [ ] Deploy/CI index map.

## Files likely touched

- `src/LendingErc20Handler.sol` (new)
- `src/TokenLending.sol` — conversion only; no new user-facing functions
- `src/tropykus-legacy/TropykusErc20Handler.sol` and Moc/Dex leaves
- `src/sovryn/SovrynErc20Handler.sol` and Moc/Dex leaves
- `src/layerbank/LayerBankErc20Handler.sol` and Moc leaf
- `src/tropykus-legacy/IkToken.sol` — `redeemUnderlying` declaration removed
- Matching handler unit tests if imports / inheritance names break
- `test/ai-generated/unit/HandlerTestHarness.t.sol` — `handlerShareBalance()` hook + the shared book-debit-covers-burn test
- Per-adapter book-debit tests in the Tropykus / Sovryn / LayerBank suites
- `test/ai-generated/unit/HandlerTestHarness.t.sol` — shared `withdrawInterest` assertion is `assertGt`, not a no-op `assertGe`
- `test/mocks/MockIsusdToken.sol` — `setSilentZeroPayout` so Sovryn’s interest path can be mutated the same way as kDOC / aToken
- `test/ai-generated/unit/sovryn/SovrynErc20HandlerTest.t.sol` — drop the dead `burnToSpecificRecipient` test; give `withdrawInterest` a real payout assertion; add the sibling zero-payout revert
- Dex copies of the same dead-name test renamed and given teeth (`SovrynErc20HandlerDexTest`, `TropykusErc20HandlerDexTest`)
- `test/unit/LendingErc20HandlerRedeemTest.t.sol` — base-level clamp + zero-share no-op + dust-share zero-payout rollback
- `src/interfaces/ITokenLending.sol` — `TokenLending__ZeroStablecoinReceived` natspec (error ABI unchanged)

## Required tests

No new product behavior beyond the extract. The extract did change Sovryn interest (redeem onto handler, then `safeTransfer`), so that suite must actually catch a broken payout. Full matrix, because all three lending handlers change shape:

```
make check
make moc-tropykus
make fork-sovryn
make fork-tropykus
```

R22 deploy/CI (PR 20) has not landed yet when this PR runs, so the LayerBank lane may still be add-on-only; `make check` / `make moc-tropykus` / both forks are the gate. If PR 20 somehow merges first, also run that CI lane.

Fork tests: no new fork-specific assertions; run before push per `AGENTS.md`.

## Success criteria

- [x] One implementation of the withdraw clamp, interest math, batch pro-rata loop, and zero-mint / zero-received guards.
- [x] `TokenLending.sol` still has no `TokenHandler` inherit and no `s_shares` mapping.
- [x] Idle handler untouched.
- [x] Tropykus Compound return codes exist only in the Tropykus adapter.
- [x] All three adapters redeem onto the handler and measure this contract’s delta. Interest `safeTransfer` lives in `LendingErc20Handler.withdrawInterest`. SIP-0094 still measures the burn recipient (now always the handler).
- [x] One redeem helper and one sizing rule: `_protocolRedeem` takes no `bool`, and no adapter calls an underlying-sized protocol method. `s_shares` debit == protocol burn on Tropykus and Sovryn, `>=` on LayerBank, pinned by tests.
- [x] One measurement site. `grep -r i_stableToken.balanceOf src/sovryn src/tropykus-legacy src/layerbank` is empty — no adapter touches the stablecoin balance at all (they still measure their own **share** balance in `_protocolDeposit`, which is protocol-specific and stays). `TokenLending__ZeroStablecoinReceived` is raised only by `LendingErc20Handler`. After the per-user clamp, a zero-share result is a no-op; a positive share redemption that pays nothing always reverts and rolls back. This does not fix or sweep R15 lending-share dust. The existing per-protocol `zeroPayout*Reverts` tests still fire from the guard's new home.
- [x] `make check` and both fork targets pass. Behavior matches post-R27 except the named Tropykus share-sizing and the PR 63 review zero-payout predicate.

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
