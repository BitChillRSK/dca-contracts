# R26 — Share terminology for the lending receipt token

Status: **not started** · Assigned: yes · Optional/further-review: no

PR 17. Stack on R25 ([#59](https://github.com/BitChillRSK/dca-contracts/pull/59)). Land **before** R22 deploy/CI (PR 18) and well before R9 (PR 19).

## Objective

Replace the non-standard noun "lending token" with **shares** for the receipt token a handler holds inside a lending protocol. Rename-only: no logic, rounding, access-control, or call-target changes.

## Background

"Lending token" is not DeFi nomenclature and it is ambiguous in the wrong direction. Aave calls its receipt an `aToken`; Compound — which Tropykus forks — calls it a `cToken`; neither ships a shared generic. The recognized generic vocabulary is ERC-4626's **shares / assets**, and it maps directly onto this repo's two conversion helpers. Worse, `_stablecoinToLendingToken` reads naturally as "the token being lent", which is the *stablecoin* — the opposite of what it returns.

This repo has already picked "shares" without saying so:

- `TokenLending.sol`'s solvency `@dev` note: "keeps sum of per-user **shares** ≤ shares the handler actually holds".
- R25 (PR 16) shipped `_redeemByShares` on Tropykus and LayerBank.
- LayerBank's deposit comment: "the **shares** we credit are the scaled aTokens we actually gained".

**The forcing function is R9.** [`IMPLEMENTATION_ORDER.md`](./IMPLEMENTATION_ORDER.md) specifies R9's event as `TokenLending__UserSharesUpdated(address indexed user, uint256 previousShares, uint256 newShares)` *and* requires "tests must show each `newShares` equals `getUsersLendingTokenBalance(user)`" — a test asserting that two differently-named things are the same quantity. R9 is also the ABI freeze. Settle the noun before that PR writes it into the frozen surface.

**Why before PR 18 rather than after.** PR 18 splits the shared test harness and rewires constants, deploy scripts, and the CI matrix; `getUsersLendingTokenBalance` alone has ~75 call sites concentrated in exactly that harness. Landing R26 after PR 18 means writing those call sites twice. This is the same ordering argument that put R25 ahead of PR 18.

Keep **stablecoin** as the asset noun. Do not adopt ERC-4626's `assets` — that would introduce a third word for something this repo already names consistently.

## Open product decisions

**none** — the generic term was decided during PR 16 review: **shares**, not "receipt token" or 4626's "assets". Implement without asking.

## Scope

- [ ] **Shared getter:** `getUsersLendingTokenBalance(address)` → `getUserShares(address)` in `ITokenLending` and every implementing handler (Tropykus, Sovryn, LayerBank, and any test double).
- [ ] **Conversion helpers** on `TokenLending`: `_stablecoinToLendingToken` → `_stablecoinToShares`; `_lendingTokenToStablecoin` → `_sharesToStablecoin`.
- [ ] **Events / errors** on `ITokenLending`:
  - `TokenLending__LendingTokenRedeemed` → `TokenLending__SharesRedeemed`
  - `TokenLending__LendingTokenRedeemedBatch` → `TokenLending__SharesRedeemedBatch`
  - `TokenLending__InsufficientLendingTokenBalance` → `TokenLending__InsufficientShares`
- [ ] **Event parameter names** carrying the same noun: `originalLendingTokenAmount` / `adjustedLendingTokenAmount` on `TokenLending__AmountToRedeemAdjusted`, and `lendingTokenAmount` / `lendingTokenAmountRedeemed`, → the `*Shares` forms. Parameter **order and indexing stay exactly as they are.**
- [ ] **Sovryn's redeem helper:** `_redeemLendingToken` → `_redeemShares` (both overloads). Sovryn has one sizing path, so it keeps a plain name rather than a `_redeemBy*` contrast — see R25's reasoning. Tropykus/LayerBank's `_redeemByUnderlying` / `_redeemByShares` / `_redeemInternal` are already correct and must not change.
- [ ] **Test and script identifiers** carrying the noun: `prevLendingTokenBalance` / `postLendingTokenBalance`, `tropykusLendingToken` / `sovrynLendingToken`, `mockLendingToken*`, `getLendingToken` / `getLendingTokenAddress`, `lendingTokenAddress` config fields, `HelperConfig__CreatedMockLendingToken`, and test names such as `testStablecoinWithdrawalBurnsLendingToken`.
- [ ] **Asset noun: `underlying` → `stablecoin` where it names the same unit.** `TokenLending._stablecoinToLendingToken` takes `underlyingAmount` and `_lendingTokenToStablecoin` returns `underlyingAmount` — the function name says stablecoin, the parameter says underlying, in one declaration. Normalize the converter parameters and returns.
- [ ] **Revisit R16's event-parameter decision explicitly.** [R16-redeem-glossary.md](./R16-redeem-glossary.md) deliberately kept `underlyingAmount` on `TokenLending__LendingTokenRedeemed(Batch)` as "the neutral" name, because inside a batch it fires per user with a *planned* share rather than a measured receipt. That rationale is about planned-vs-measured, not about the asset noun, so it survives renaming the noun — but it is a recorded decision: state in the PR that you are overriding or preserving it, do not silently flip it. `TokenLending__InterestWithdrawn.underlyingAmountWithdrawn` is the same call.
- [ ] **One name per expression.** `_lendingTokenToStablecoin(s_*Balances[user], exchangeRate)` is `stablecoinInTropykus` / `stablecoinInSovryn` / `stablecoinInLayerBank` inside `withdrawToken`, but `totalStablecoinInLending` inside `withdrawInterest` and `getAccruedInterest` — same quantity, two names, in all three handlers. Pick one (`totalStablecoinInLending` is protocol-agnostic and already used at two of the three sites, which would make the three files read identically) and apply it to all six call sites.
- [ ] **LayerBank `prevScaledBalance`** (deposit side): the only balance local in that file without the file's token noun, against `usersAtokenBalance` / `aTokenToRedeem` / `s_aTokenBalances`. Note the counter-argument before changing it — that local reads `i_aToken.scaledBalanceOf()`, and an aToken *also* has a rebasing `balanceOf()`, so "scaled" is doing real disambiguation Sovryn/Tropykus do not need. If you want both, `prevScaledAtokenBalance`; if you want the file rule, `prevAtokenBalance`. Decide and say which in the PR.
- [ ] Natspec and comments on every touched declaration say "shares" (or the handler's own `kToken` / `iSusd` / `aToken` noun where the sentence is protocol-specific — R25's rule).

**Explicitly keep** — "lending" is a fine domain word; only "lending *token*" is wrong:

- `ITokenLending`, `TokenLending`, `TokenLending__` event prefix
- `TokenLending__LendingProtocolDepositFailed` / `…RedeemFailed`
- `LENDING_PROTOCOL`, `EXPECTED_LENDING_PROTOCOL`, `lendingProtocolIndex`, `s_lendingProtocolIndex`, `make moc-*` / `fork-*` lane names

## Out of scope

- [ ] Deleting the `ILendingToken` test interface — R22 specs assign that to PR 18 ([R22-deploy-ci.md](./R22-deploy-ci.md)). If PR 18 lands first it is already gone; if not, rename it in place to `IShareToken` and let PR 18 delete it.
- [ ] Adding `TokenLending__UserSharesUpdated` or any R9 event (PR 19).
- [ ] Index-map, harness split, constants, CI matrix (PR 18).
- [ ] Any behavior, rounding, access-control, or call-target change.
- [ ] Third-party ABI names (`redeem`, `redeemUnderlying`, `burn`, `withdraw`, `scaledBalanceOf`, `exchangeRateCurrent`, `tokenPrice`).
- [ ] R10 natspec rewrite beyond the touched declarations.

## Files likely touched

- `src/interfaces/ITokenLending.sol` — getter, three events/errors, parameter names
- `src/TokenLending.sol` — both conversion helpers
- `src/tropykus-legacy/TropykusErc20Handler.sol`, `src/sovryn/SovrynErc20Handler.sol`, `src/layerbank/LayerBankErc20Handler.sol`
- `src/idle/IdleErc20Handler.sol` if it implements the getter
- `script/` helper configs and deploy scripts that expose `lendingToken*` fields
- `test/unit/`, `test/ai-generated/`, `test/interfaces/`, `test/mocks/` — the bulk of the ~370 references

Roughly 370 references across ~33 files; ~75 are `getUsersLendingTokenBalance`.

## Required tests

Rename-only; no new behavior tests. The existing suites are the regression, and the full matrix must run because the getter is on the shared interface:

```
make check
make fork-sovryn
make fork-tropykus
```

Plus the three lending lanes used by R25:

```
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC \
  forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods \
  --match-path "test/ai-generated/unit/tropykus-legacy/**" -j 1
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn EXPECTED_LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods \
  --match-path "test/ai-generated/unit/sovryn/**" -j 1
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC \
  forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods \
  --match-path "test/ai-generated/unit/layerbank/**" -j 1
```

Fork tests: no new fork-specific assertions; run before push per `AGENTS.md`.

## Success criteria

- [ ] `grep -rn "[Ll]ending[Tt]oken" src/ test/ script/` returns only the deliberate keeps listed in **Scope** (protocol names, `ITokenLending` / `TokenLending`, `LendingProtocol*Failed`).
- [ ] No `underlyingAmount` remains where the unit is the stablecoin, except any event parameter the PR explicitly argues to keep (R16 decision).
- [ ] `_lendingTokenToStablecoin(s_*Balances[user], …)` has one name across all six call sites in the three handlers.
- [ ] `getUserShares` is the only per-user share getter; no `getUsersLendingTokenBalance` remains.
- [ ] Conversion helpers are `_stablecoinToShares` / `_sharesToStablecoin`.
- [ ] The three renamed events/errors keep their original parameter order and indexed fields.
- [ ] Sovryn exposes `_redeemShares` (+ recipient overload); Tropykus/LayerBank keep `_redeemByUnderlying` / `_redeemByShares` / `_redeemInternal` unchanged.
- [ ] `make check`, `make fork-sovryn`, and `make fork-tropykus` pass.
- [ ] No behavior diff intentional; PR is reviewable as rename-only.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: **yes, deliberately.** Possibly some event *parameter* names too (`underlyingAmount`), which change the ABI JSON but not `topic0`. One external view (`getUsersLendingTokenBalance` → `getUserShares`), two event names, one error name, and several event parameter names. New `topic0` for the two renamed events; parameter order and indexing unchanged. This is pre-freeze by design — R9 (PR 19) is the freeze, and the relaunch deploys fresh with no live log consumer, so the rename is free now and expensive afterwards.
- Scripts: helper-config field names only; local/test. Do not `--broadcast`.
- Cutover: none — new deployments only. Any frontend or indexer built against the pre-relaunch ABI must target `getUserShares` and the new event names; flag it to whoever wires the live market.
