# R25 — Lending redeem helper naming

Status: **in review** · Assigned: yes · Optional/further-review: no

PR 16. Stack on R22 LayerBank ([#58](https://github.com/BitChillRSK/dca-contracts/pull/58)). Land **before** R22 deploy/CI so LayerBank ships with the same names as Tropykus/Sovryn.

## Objective

Finish the R16 redeem-glossary pass that left lending internals half-renamed. Rename first-party lending redeem helpers and share-amount locals so names match the motion: both paths **redeem** the receipt token; one sizes by underlying, one by shares. Drop leftover “repay” / `_burn*` wording. No behavior change.

## Background

This is leftover from PR 14 ([R16-redeem-glossary.md](./R16-redeem-glossary.md)), not new LayerBank design. R16 set **redeem = asset given up** but still sanctioned `_burnKtoken` and a “repay” alias for share amounts (`kTokenToRepay`, `TokenLending__AmountToRepayAdjusted`). That PR landed before LayerBank, so the new handler copied the incomplete names. Fix all three handlers together.

R16 also left interest helpers inconsistent across the three handlers:

- Sovryn overwrites `stablecoinInterestAmount` with the redeem return; Tropykus/LayerBank keep planned interest and `stablecoinReceived` separate. Align Sovryn to the two-name form (still emit the measured amount).
- Sovryn uses `totalErc20InLending` where Tropykus/LayerBank use `totalStablecoinInLending`. Prefer **stablecoin** — the value is already converted underlying, not an ERC20 token id.
- Sovryn’s `getAccruedInterest` has full `@notice` / `@param` / `@return` natspec; Tropykus and LayerBank omit it. Copy Sovryn’s block onto the other two (same signature).

Small leaf-contract nits (same PR; match LayerBank’s cleaner shape):

- `TropykusDocHandlerMoc` / `SovrynDocHandlerMoc` / `*Erc20HandlerDex` still take an unused `minPurchaseAmount` constructor arg that is never forwarded (mins live on `DcaManager`). LayerBank correctly omitted it — drop it from the Tropykus/Sovryn leaves and update call sites (scripts/tests).
- `SovrynDocHandlerMoc` natspec still says “Tropykus' iSUSD” for `iSusdTokenAddress` — fix to Sovryn.

| Protocol | Sizing APIs | Current BitChill helpers |
| --- | --- | --- |
| Sovryn | shares only (`burn`) | `_redeemLendingToken` (+ recipient overload) |
| Tropykus | shares (`redeem`) and underlying (`redeemUnderlying`) | `_redeemLendingToken` / `_burnKtoken` |
| LayerBank | underlying only (`Pool.withdraw`); share path is “withdraw DOC of debited scaled shares” | `_redeemLendingToken` / `_burnAtoken` |

`_burnKtoken` and `_redeemLendingToken` both redeem the share token. “Repay” suggests a loan. Fix names only; do not change which protocol call each path uses.

This PR **supersedes** R16’s sanction of the “repay” alias for share-amount **locals and internal helpers** *and* for the shared event. `TokenLending__AmountToRepayAdjusted` → `TokenLending__AmountToRedeemAdjusted`.

**Decision revised during PR 16** (human call, recorded here so the history is honest): the spec originally held the event back as ABI. That reasoning does not apply to this relaunch — every handler is a fresh deployment with no live log consumer, so `topic0` stability is protecting nothing today. R9 (PR 20) is where the event surface gets **frozen**, which makes it the deadline for this rename, not the venue. Renaming after the freeze is the expensive version of the same change. Parameter list, order, and indexing are untouched; only the name changes.

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 16. Implement without asking.

## Scope

- [ ] **Locals / parameters** in Tropykus, Sovryn, and LayerBank (and matching test strings only if they assert symbol names): `*ToRepay` → `*ToRedeem`. **Keep each file's own token noun and capitalization — change only `Repay` → `Redeem`.** Sovryn's locals say `iSusd` (`s_iSusdBalances`, `usersIsusdBalance`), so they become `iSusdToRedeem` / `oldIsusdToRedeem` / `totalIsusdToRedeem`, **not** `iTokens*`; likewise `kTokenToRedeem` and `aTokenToRedeem`. The per-buyer batch local matches its neighbouring balance local (`usersKtokenToRedeem` beside `usersKtokenBalance`), not a generic `buyerShares*` — the loop already calls that actor `users[i]`.
- [ ] **Tropykus / LayerBank helpers** (symmetric pair):
  - `_redeemLendingToken` (3-arg, underlying-sized) → `_redeemByUnderlying`
  - `_burnKtoken` / `_burnAtoken` → `_redeemByShares`
  - `_redeemLendingTokenInternal(..., redeemUnderlying)` → keep one shared internal, renamed `_redeemInternal`; rename the bool to `sizeByUnderlying` (or equivalent) so LayerBank’s “both call `withdraw`” case stays honest. Dropping “LendingToken” avoids a near-collision with Sovryn’s `_redeemLendingToken`, which is a different thing (that handler’s only redeem path, share-sized, with a recipient overload).
- [ ] **Sovryn**: keep a **single** redeem helper (always share-sized). Keep the recipient overload (`address(this)` vs `user`). Rename locals only; do not invent a fake `_redeemByUnderlying`. Stop overwriting `stablecoinInterestAmount` with the redeem return — use `stablecoinReceived` like Tropykus/LayerBank (`withdrawInterest` planned vs measured). Rename `totalErc20InLending` → `totalStablecoinInLending` in `withdrawInterest` and `getAccruedInterest`.
- [ ] **Interest natspec**: give Tropykus and LayerBank the same `getAccruedInterest` `@notice` / `@param` / `@return` block Sovryn already has. Do not rewrite other natspec (R10).
- [ ] **Leaf constructor cleanup (match LayerBank):** remove the unused `minPurchaseAmount` parameter from `TropykusDocHandlerMoc`, `SovrynDocHandlerMoc`, `TropykusErc20HandlerDex`, and `SovrynErc20HandlerDex` (and any matching `@param`). Update deploy scripts and tests that still pass it. Do not touch `DcaManager` min-purchase logic.
- [ ] **Shared event rename:** `TokenLending__AmountToRepayAdjusted` → `TokenLending__AmountToRedeemAdjusted` in `ITokenLending` and the three emit sites. Name only — do not touch the parameter list, order, or which three are indexed.
- [ ] **SovrynDocHandlerMoc natspec:** `iSusdTokenAddress` must not say “Tropykus' iSUSD”.
- [ ] Comments / natspec on touched redeem helpers: say redeem/sizing clearly; LayerBank `_redeemByShares` notes that Aave has no share withdraw — the helper sizes `Pool.withdraw` from the debited scaled amount.
- [ ] No logic, rounding, access-control, or call-target changes beyond dropping the unused constructor arg.

## Out of scope

- [ ] Any other `ITokenLending` event/error ABI (parameters, order, indexing, error names). Only the one event **name** above changes.
- [ ] R22 deploy/CI index map, harness, CI matrix (now PR 18, [R22-deploy-ci.md](./R22-deploy-ci.md)). That PR also owns the LayerBank round-up solvency regression (virtual scaled sum ≤ handler `scaledBalanceOf`); do not leave it to a later “someday” test.
- [ ] R10 natspec rewrite beyond the touched helpers.
- [ ] R9 share events.
- [ ] Third-party ABI names (`redeem`, `redeemUnderlying`, `burn`, `withdraw`, …).

## Files likely touched

- `src/tropykus-legacy/TropykusErc20Handler.sol` (and Moc/Dex subclasses)
- `src/sovryn/SovrynErc20Handler.sol` (and Moc/Dex subclasses)
- `src/layerbank/LayerBankErc20Handler.sol`
- `src/tropykus-legacy/TropykusDocHandlerMoc.sol`, `TropykusErc20HandlerDex.sol`
- `src/sovryn/SovrynDocHandlerMoc.sol`, `SovrynErc20HandlerDex.sol`
- Matching tests / `script/` call sites that pass the unused `minPurchaseAmount`
- `src/interfaces/ITokenLending.sol` — the shared event declaration
- `docs/relaunch/R16-redeem-glossary.md` — one-line pointer that R25 supersedes the “repay” local alias (optional, keep short)

## Required tests

Rename-only; no new behavior tests. Re-run the lanes that compile the three handlers:

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

make check
make fork-sovryn
make fork-tropykus
```

Fork tests: no new fork-specific assertions; run before push per `AGENTS.md`.

## Success criteria

- [ ] Tropykus/LayerBank expose `_redeemByUnderlying` and `_redeemByShares` over a shared `_redeemInternal`; no `_burnKtoken` / `_burnAtoken`, and no `_redeemLendingToken*` outside Sovryn.
- [ ] Sovryn still has one redeem helper with recipient overload; share locals use `*ToRedeem`. `withdrawInterest` uses `stablecoinReceived` for the measured payout (does not overwrite `stablecoinInterestAmount`). No `totalErc20InLending` remains.
- [ ] Tropykus and LayerBank `getAccruedInterest` carry the same natspec as Sovryn.
- [ ] Tropykus/Sovryn MoC and Dex leaves no longer take unused `minPurchaseAmount`; call sites updated. `SovrynDocHandlerMoc` natspec names Sovryn’s iToken correctly.
- [ ] No `*ToRepay` locals remain in the three lending ERC20 handlers.
- [ ] `TokenLending__AmountToRedeemAdjusted` carries R16's parameter list unchanged — name only.
- [ ] `make check`, `make fork-sovryn`, and `make fork-tropykus` pass.
- [ ] No behavior diff intentional; PR is reviewable as rename-only.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: **constructor only** for Tropykus/Sovryn `*DocHandlerMoc` and `*Erc20HandlerDex` — drop unused `minPurchaseAmount` (same shape as LayerBank). One event **rename**: `TokenLending__AmountToRepayAdjusted` → `TokenLending__AmountToRedeemAdjusted` (new `topic0`; parameters, order, and indexing unchanged). Deliberate — see the decision note under **Background**. No external function ABI changes. Internal renames only otherwise.
- Scripts: update any `script/` that still passes the dummy min arg (e.g. USDRIF / dex deploy helpers). Local/test only; do not `--broadcast`.
- Cutover: none (new deployments only; no live handler migration).
