# R22 — LayerBank DOC + MoC handler

Status: **in review** · Assigned: yes · Optional/further-review: no

PR 15 of R22. Deploy/constants/harness/CI index-map work is PR 16.

## Objective

Ship a LayerBank lending handler for DOC + MoC as the index-1 twin of Tropykus and Sovryn: per-user virtual lToken balances, balance-delta cash from day one (including R21 deposit returns), and `getUsersLendingTokenBalance(user)`. Do not remap the live index map or rewrite the shared test harness in this PR.

## Background

LayerBank on Rootstock is a Compound-style money market. Users do **not** call the lToken. `LToken.supply` / `redeemToken` / `redeemUnderlying` are `onlyCore`. The handler must go through Core:

| Motion | Tropykus kToken | Sovryn iToken | LayerBank |
| --- | --- | --- | --- |
| Deposit underlying, receive shares | `mint(uAmount)` → error code | `mint(receiver, uAmount)` | `Core.supply(lToken, uAmount)` → lToken.supply(handler, uAmount); lToken `transferFrom`s the handler |
| Redeem by underlying | `redeemUnderlying(uAmount)` | (sized as shares, then `burn`) | `Core.redeemUnderlying(lToken, uAmount)` |
| Redeem by shares | `redeem(kAmount)` | `burn(receiver, iAmount)` | `Core.redeemToken(lToken, lAmount)` |
| Rate (mutating) | `exchangeRateCurrent()` | `tokenPrice()` (view) | `accruedExchangeRate()` |
| Rate (view) | `exchangeRateStored()` | `tokenPrice()` | `exchangeRate()` |
| Failure mode | `uint` error code, 0 = success | revert | revert; returns are amounts, not error codes |

Cash rule (R1/R20): measure `lToken.balanceOf(handler)` after supply and `DOC.balanceOf(recipient)` after redeem. Do not credit Core's return. Do not cap redemptions with `underlyingBalanceOf` or any other LayerBank view.

R21: `super.depositToken` already returns hop-1 received; mint that amount into LayerBank, then credit the lToken balance delta.

R16: hook names are `_retrieveStablecoin` / `_redeemLendingToken`. Do not reintroduce `_redeemStablecoin`.

External incentives are out of scope (`EXTERNAL_REWARDS.md`). Core still calls `labDistributor.notifySupplyUpdated` on the live protocol; the handler must not `claimLab`, harvest, or unwrap rewards. R9 later emits `TokenLending__UserSharesUpdated` on this handler — every share mint/burn site must be a single, complete update to `s_lTokenBalances[user]` so that event can cover deposits, withdrawals, interest, and single/batch purchases.

**Rootstock listing (2026-08-24, LayerBank v2-contracts README):** Core `0xc30991623fb2a63E6e1B59A29987E1EEE57447bF`. Markets: lRBTC, lRIF, lUSDCe, lUSDT, lWETH. **No lDOC yet.** This PR still ships a DOC-parameterized handler (lToken address in the constructor, same as kDOC / iSUSD). Live lDOC wiring is PR 16, if and when LayerBank lists DOC. Unit tests use mocks of the Rootstock ABI.

Constructor: same shape as `TropykusErc20Handler` (dcaManager, stable, lToken, feeCollector, feeSettings, exchangeRateDecimals). Read Core from `lToken.core()`; revert if it is unset. Revert if `lToken.underlying()` is not the stablecoin — PR 16 will pick a live lToken and a mismatch would otherwise construct cleanly then fail on first deposit. Do not add a second Core constructor arg. Do not copy the unused `minPurchaseAmount` leftover on `TropykusDocHandlerMoc` / `SovrynDocHandlerMoc`.

Redeem-to-user: LayerBank always pays the Core caller (the handler). Interest withdrawals follow Tropykus: redeem onto the handler, then `safeTransfer` to the user. Do not invent a `to` parameter.

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 15. Implement without asking.

## Scope

- [x] `LayerBankErc20Handler` (`TokenHandler` + `TokenLending`) with per-user `s_lTokenBalances` and `getUsersLendingTokenBalance`.
- [x] `LayerBankDocHandlerMoc` (`LayerBankErc20Handler` + `PurchaseMoc`).
- [x] Slim `ILToken` / `ILayerBankCore` next to the handler (only the functions this handler calls). Constructor checks `underlying()` matches the stablecoin. Do not add an empty `ILayerBankErc20Handler`.
- [x] Deposit: hop-1 via `super.depositToken`; approve the **lToken** (it pulls from the handler); `Core.supply`; credit lToken `balanceOf` delta; revert `TokenLending__LendingProtocolDepositFailed` if the delta is 0.
- [x] Withdraw / single retrieve: clamp to the user's converted lToken balance (same events as Tropykus/Sovryn), then `Core.redeemUnderlying`. Pay the measured DOC delta.
- [x] Interest: size with `accruedExchangeRate`, redeem by shares via `Core.redeemToken` (Tropykus `_burnKtoken` analogue), transfer the measured DOC to the user.
- [x] Batch retrieve: debit each buyer's rounded-up share of the total lToken burn or revert `TokenLending__InsufficientLendingTokenBalance`; one `Core.redeemUnderlying`; revert `TokenLending__ZeroStablecoinReceived` if the DOC delta is 0 (Sovryn/R20, not Tropykus's emit-on-zero).
- [x] Dedicated unit tests under `test/ai-generated/unit/layerbank/` plus mocks of Core + lToken. Add-on `script/DeployLayerBankHandler.s.sol` (local/fork tests deploy the mocks). A deployment test and a standalone DcaManager path go through that script.
- [x] Update `src/layerbank/README.md` and the `AGENTS.md` Layout line for `src/layerbank/`.

## Out of scope

- [ ] `script/Constants.sol` index remap (`LAYERBANK_INDEX = 1` replacing Tropykus), `DeployMocSwaps` / `DeployDexSwaps` registration, `MocHelperConfig` live lDOC/Core fields, `DcaDappTest` split, `ILendingToken` deletion, CI matrix (`none` / `layerbank` / `sovryn`) — those are PR 16. This PR may register LayerBank at index 1 **inside dedicated tests** on that test's `OperationsAdmin` (overwriting Tropykus there is fine).
- [ ] LayerBank Uniswap / USDRIF handler.
- [ ] Merkl / LAB / `claimLab` / harvest / reward-debt / unwrap.
- [ ] R9 `TokenLending__UserSharesUpdated`.
- [ ] Renaming Tropykus in place. Creating `src/moc-lending/`.
- [ ] Adapting the shared `DcaDappTest` / Makefile / CI matrix so `LENDING_PROTOCOL=layerbank` is a first-class lane.

## Files likely touched

New:

- `src/layerbank/ILToken.sol`
- `src/layerbank/ILayerBankCore.sol`
- `src/layerbank/LayerBankErc20Handler.sol`
- `src/layerbank/LayerBankDocHandlerMoc.sol`
- `test/mocks/MockLayerBank.sol`
- `test/ai-generated/unit/layerbank/LayerBankErc20HandlerTest.t.sol`
- `test/ai-generated/unit/layerbank/LayerBankDocHandlerMocTest.t.sol`
- `test/ai-generated/unit/layerbank/LayerBankDcaManagerTest.t.sol`
- `script/DeployLayerBankHandler.s.sol`
- `test/unit/deployment/LayerBankHandlerDeploymentTest.t.sol`

Edit:

- `src/layerbank/README.md`
- `AGENTS.md`
- `docs/relaunch/README.md`

## Required tests

Targeted:

```
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC \
  forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods \
  --match-path "test/ai-generated/unit/layerbank/**" -j 1

SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC \
  forge test --match-contract LayerBankHandlerDeploymentTest -j 1
```

Then the done-gate and the pre-push fork lanes (see `AGENTS.md`):

```
make check
make fork-sovryn
make fork-tropykus
```

Behaviors to assert:

- Deposit mints lTokens to the handler (not the user); `getUsersLendingTokenBalance` equals the measured mint, not Core's return (mock may lie about the return).
- Withdraw pays the user and debits only that user's virtual lToken balance. Oversize withdraw clamps.
- Zero-payout redeem (shares burnt, no DOC) reverts `TokenLending__ZeroStablecoinReceived` and leaves the virtual balance intact. Same for the batch path (Sovryn/R20).
- Deposit with a successful Core.supply that mints 0 lTokens reverts `TokenLending__LendingProtocolDepositFailed`.
- Withdraw pays the measured DOC delta when the market pays a shortfall.
- Interest accrues with the exchange rate; `withdrawInterest` pays the user; no-interest is a no-op.
- `buyRbtc` / `batchBuyRbtc` spend DOC via MoC and credit accumulated rBTC; virtual lToken balances fall.
- `batchBuyRbtc` / `_batchRetrieveStablecoin` revert `TokenLending__InsufficientLendingTokenBalance` if any buyer cannot cover their share.
- Dedicated DcaManager path: create / buy / withdraw at the test's index 1 against this handler.
- Existing Tropykus and Sovryn lanes in `make check` are unchanged.

Fork tests: `make fork-sovryn` and `make fork-tropykus` before push (`AGENTS.md`). This PR does not add a LayerBank fork lane (no lDOC market to exercise).

## Success criteria

- [x] `LayerBankDocHandlerMoc` is constructable with an lToken whose `core()` is set and whose `underlying()` matches the stablecoin; it reverts if Core is unset or the underlying mismatches.
- [x] Deposits, withdrawals, interest, and MoC purchases use balance-delta cash and exact per-user virtual lToken balances. Batch redeem reverts on insufficient shares or zero DOC received.
- [x] No Merkl/LAB claim path. No empty per-protocol lending interface.
- [x] `DeployLayerBankHandler` deploys `LayerBankDocHandlerMoc` via mocks on local and fork tests and can register it. `DeployMocSwaps` / `DeployDexSwaps` / `DcaDappTest` / `Constants.sol` indexes are unchanged (PR 16).
- [x] Done-gate lanes pass. `make fork-sovryn` and `make fork-tropykus` pass before push.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none). Invariant 1 applies to Core supply/redeem. Invariant 2: no `underlyingBalanceOf` redeem ceiling.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: new contracts `LayerBankErc20Handler` / `LayerBankDocHandlerMoc`. Constructor takes the lToken, not Core. Reuses `ITokenLending` events/errors. No change to existing handler ABIs.
- Scripts: add-on `DeployLayerBankHandler` (not wired into `DeployMocSwaps`). Live Core / lDOC addresses and index-1 registration on the main deploy path are PR 16.
- Cutover: none in this PR. Frontend cannot target LayerBank until PR 16 assigns the handler on the new admin **and** LayerBank lists DOC (or product picks another listed stable).
