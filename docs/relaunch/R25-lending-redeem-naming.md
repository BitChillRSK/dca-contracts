# R25 — Lending redeem helper naming

Status: **not started** · Assigned: yes · Optional/further-review: no

PR 16. Stack on R22 LayerBank ([#58](https://github.com/BitChillRSK/dca-contracts/pull/58)). Land **before** R22 deploy/CI so LayerBank ships with the same names as Tropykus/Sovryn.

## Objective

Rename first-party lending redeem helpers and share-amount locals so names match the motion: both paths **redeem** the receipt token; one sizes by underlying, one by shares. Drop leftover “repay” / `_burn*` wording from when redeem direction was misunderstood. No behavior change.

## Background

R16 set the glossary **redeem = asset given up** and kept `_burnKtoken` plus a “repay” alias for share amounts (`kTokenToRepay`, `TokenLending__AmountToRepayAdjusted`). After LayerBank (PR 15), the three handlers still read inconsistently:

| Protocol | Sizing APIs | Current BitChill helpers |
| --- | --- | --- |
| Sovryn | shares only (`burn`) | `_redeemLendingToken` (+ recipient overload) |
| Tropykus | shares (`redeem`) and underlying (`redeemUnderlying`) | `_redeemLendingToken` / `_burnKtoken` |
| LayerBank | underlying only (`Pool.withdraw`); share path is “withdraw DOC of debited scaled shares” | `_redeemLendingToken` / `_burnAtoken` |

`_burnKtoken` and `_redeemLendingToken` both redeem the share token. “Repay” suggests a loan. Fix names only; do not change which protocol call each path uses.

Related: [R16-redeem-glossary.md](./R16-redeem-glossary.md) (PR 14). This PR **supersedes** R16’s sanction of the “repay” alias for share-amount **locals and internal helpers**. It does **not** rename the shared event `TokenLending__AmountToRepayAdjusted` (ABI).

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 16. Implement without asking.

## Scope

- [ ] **Locals / parameters** in Tropykus, Sovryn, and LayerBank (and matching test strings only if they assert symbol names): `*ToRepay` → `*ToRedeem` (e.g. `kTokensToRedeem`, `iTokensToRedeem`, `scaledATokensToRedeem`, `total*ToRedeem`, `buyerSharesToRedeem`, `old*ToRedeem`).
- [ ] **Tropykus / LayerBank helpers** (symmetric pair):
  - `_redeemLendingToken` (3-arg, underlying-sized) → `_redeemByUnderlying`
  - `_burnKtoken` / `_burnAtoken` → `_redeemByShares`
  - `_redeemLendingTokenInternal(..., redeemUnderlying)` → keep one shared internal; rename the bool to `sizeByUnderlying` (or equivalent) so LayerBank’s “both call `withdraw`” case stays honest
- [ ] **Sovryn**: keep a **single** redeem helper (always share-sized). Keep the recipient overload (`address(this)` vs `user`). Rename locals only; do not invent a fake `_redeemByUnderlying`.
- [ ] Comments / natspec on touched functions: say redeem/sizing clearly; LayerBank `_redeemByShares` notes that Aave has no share withdraw — the helper sizes `Pool.withdraw` from the debited scaled amount.
- [ ] No logic, rounding, access-control, or call-target changes.

## Out of scope

- [ ] Renaming `TokenLending__AmountToRepayAdjusted` (or any other `ITokenLending` event/error ABI).
- [ ] R22 deploy/CI index map, harness, CI matrix (now PR 17).
- [ ] R10 natspec rewrite beyond the touched helpers.
- [ ] R9 share events.
- [ ] Third-party ABI names (`redeem`, `redeemUnderlying`, `burn`, `withdraw`, …).

## Files likely touched

- `src/tropykus-legacy/TropykusErc20Handler.sol` (and Moc/Dex subclasses only if they call renamed internals)
- `src/sovryn/SovrynErc20Handler.sol` (and subclasses if needed)
- `src/layerbank/LayerBankErc20Handler.sol`
- Matching tests that reference renamed symbols (compile fixes only)
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

- [ ] Tropykus/LayerBank expose `_redeemByUnderlying` and `_redeemByShares`; no `_burnKtoken` / `_burnAtoken`.
- [ ] Sovryn still has one redeem helper with recipient overload; share locals use `*ToRedeem`.
- [ ] No `*ToRepay` locals remain in the three lending ERC20 handlers.
- [ ] `TokenLending__AmountToRepayAdjusted` unchanged.
- [ ] `make check`, `make fork-sovryn`, and `make fork-tropykus` pass.
- [ ] No behavior diff intentional; PR is reviewable as rename-only.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: none (internal + local renames only; shared events/errors untouched).
- Scripts: none.
- Cutover: none.
