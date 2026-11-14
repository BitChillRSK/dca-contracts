# R27 — Align Tropykus lending cash guards

Status: **PR open** · Assigned: yes · Optional/further-review: no

PR 18 (reordered 2026-08-25 ahead of R22 deploy/CI), GitHub [#62](https://github.com/BitChillRSK/dca-contracts/pull/62). Stack on R26 (PR 17). Land **before** R28 (PR 19), R30 (PR 21), R22 deploy/CI (now PR 28), and R9 (now PR 29) so the shared-base, purchase-pipeline, and ABI-freeze tests cover the corrected Tropykus paths. Tropykus is **not** in the new deploy map (PR 28); this PR exists because the legacy handler must still obey invariant 1.

Write this spec against the **R26 `shares` vocabulary** (`getUserShares`, `TokenLending__SharesRedeemed(Batch)`, …).

## Objective

Make `TropykusErc20Handler` treat a zero measured share mint and a zero measured batch redemption as failure, matching Sovryn and LayerBank. Do not extract a shared base (that is [R28](./R28-lending-erc20-handler.md)).

## Background

R1/R20 and `AGENTS.md` invariant 1: after a call that should move tokens to us, measure `balanceOf`. Do not treat an integrator success code as cash.

Sovryn and LayerBank already do this on deposit and on batch redeem. Tropykus does not, even though its **single** redeem path already reverts `TokenLending__ZeroStablecoinReceived` (`test_tropykus_zeroPayoutRedeemReverts`). LayerBank’s spec called the batch hole out as “Sovryn/R20, not Tropykus's emit-on-zero.”

Two copy-paste gaps, both in `src/tropykus-legacy/TropykusErc20Handler.sol`:

1. **Deposit credits a zero mint.** `depositToken` reverts if `kToken.mint` returns a non-zero Compound code, then credits `postKtokenBalance - prevKtokenBalance` with no `== 0` check (`:62-65`). Sovryn (`:66`) and LayerBank (`:80`) revert `TokenLending__LendingProtocolDepositFailed` when the measured share delta is 0. A success code with no shares minted would credit nothing and leave the user’s `DcaManager.tokenBalance` raised against an empty position.
2. **Batch redeem has no zero-received guard.** `_batchRetrieveStablecoin` (`:246-255`) on Compound code 0 emits `TokenLending__LendingTokenRedeemedBatch` (R26: `…SharesRedeemedBatch`) and returns whatever it measured, including 0. Sovryn `:226` and LayerBank `:284` revert `TokenLending__ZeroStablecoinReceived`. PurchaseMoc would then try to spend 0 DOC. The per-user share debits in the loop have already happened; the revert must roll them back (same as LayerBank `test_layerbank_batchRetrieveStablecoin_zeroPayout_reverts`).

A third difference is **not** a bug. Tropykus’s single-redeem guard is `stablecoinAmount > 0 && stablecoinReceived == 0`. Sovryn reverts on `stablecoinReceived == 0` alone. LayerBank skips the Pool call when `amountOut == 0` because live Aave reverts `InvalidAmount`. Tropykus’s extra conjunct is the Compound analogue of that skip (`redeemUnderlying(0)` / `redeem(0)` can succeed and pay 0). Keep it. Do not copy Sovryn’s unconditional revert, and do not change Sovryn or LayerBank.

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 18. The single-redeem keep is decided above. Implement without asking.

## Scope

- [x] **`depositToken`:** after a 0 Compound mint code, if the measured kToken `balanceOf(handler)` delta is 0, revert `TokenLending__LendingProtocolDepositFailed` and do not credit `s_kTokenBalances[user]`. Keep the existing non-zero-code revert.
- [x] **`_batchRetrieveStablecoin`:** after a 0 Compound `redeemUnderlying` code, if the measured stablecoin delta is 0, revert `TokenLending__ZeroStablecoinReceived(totalStablecoinAmount)`. Do not emit the batch event on that path. Non-zero-code still reverts `TokenLending__LendingProtocolRedeemFailed`.
- [x] **`MockKdocToken`:** add a `setForceZeroMint` (or equivalent) that makes `mint` return 0 and mint no kDOC, matching `MockLayerBank.setForceZeroMint`. Reuse `setSilentZeroPayout` for the batch test.
- [x] Port LayerBank’s two tests onto Tropykus (`test/ai-generated/unit/tropykus-legacy/TropykusErc20HandlerTest.t.sol`):
  - `test_tropykus_zeroMintReverts` ← `test_layerbank_zeroMintReverts`
  - `test_tropykus_batchRetrieveStablecoin_zeroPayout_reverts` ← `test_layerbank_batchRetrieveStablecoin_zeroPayout_reverts` (the test subclass already exposes `testBatchRetrieveStablecoin`)
- [x] Assert the revert leaves `getUserShares` unchanged.

## Out of scope

- [ ] Shared `LendingErc20Handler` / lifting `s_*Balances` into `TokenLending` ([R28](./R28-lending-erc20-handler.md)).
- [ ] Changing Sovryn or LayerBank guards, including Sovryn’s `stablecoinReceived == 0` single-redeem revert.
- [ ] Changing Tropykus’s single-redeem `stablecoinAmount > 0 &&` conjunct.
- [ ] R9 `TokenLending__UserSharesUpdated`.
- [ ] Deploy-map / CI changes (Tropykus stays off the new index map; `make moc-tropykus` remains the local lane).
- [ ] Dex vs MoC leaves, except they inherit the Erc20Handler fix automatically.

## Files likely touched

- `src/tropykus-legacy/TropykusErc20Handler.sol`
- `test/mocks/MockKdocToken.sol`
- `test/ai-generated/unit/tropykus-legacy/TropykusErc20HandlerTest.t.sol`

## Required tests

New Tropykus unit tests above, plus the existing zero-payout single-redeem / interest tests must still pass.

```
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC \
  forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods \
  --match-path "test/ai-generated/unit/tropykus-legacy/**" -j 1
make moc-tropykus
make check
make fork-sovryn
make fork-tropykus
```

Fork tests: no new fork-specific assertions. `make fork-tropykus` still pins block `8700000`. Run before push per `AGENTS.md`.

## Success criteria

- [x] Tropykus `depositToken` reverts `TokenLending__LendingProtocolDepositFailed` on a successful mint code with a 0 share delta; mapping unchanged.
- [x] Tropykus `_batchRetrieveStablecoin` reverts `TokenLending__ZeroStablecoinReceived` on a successful redeem code with a 0 DOC delta; mapping unchanged; no batch-redeem event.
- [x] Single-redeem still uses `stablecoinAmount > 0 && stablecoinReceived == 0`.
- [x] Sovryn and LayerBank diffs are empty.
- [x] `make check`, `make fork-sovryn`, and `make fork-tropykus` pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec applies invariant 1 to two Tropykus paths; it changes none of the invariant text).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable. This is not the DRY PR.

## ABI / deploy / cutover impact

- ABI: none. Existing errors, already on `ITokenLending`.
- Scripts: none.
- Cutover: none. Tropykus is not registered after R22 deploy/CI (now PR 28). Local `make moc-tropykus` / `make fork-tropykus` are the consumers.
