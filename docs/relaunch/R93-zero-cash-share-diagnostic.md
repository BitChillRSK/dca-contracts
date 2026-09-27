# R93 — Report redeemed shares on zero-cash failures

Status: **implemented** · GitHub [#159](https://github.com/BitChillRSK/dca-contracts/pull/159) · Assigned: yes · Optional/further-review: no · Stack on: [#157](https://github.com/BitChillRSK/dca-contracts/pull/157)

## Objective

Delete the second batch loop that re-sums stablecoin purchase amounts only to populate
`TokenLending__ZeroStablecoinReceived`. Keep the existing error signature, but make its `uint256`
diagnostic report the exact receipt-share count the protocol consumed before the transaction rolls
back.

## Background

R90 made the batch diagnostic sum unchecked, saving 8 runtime bytes per lending leaf without changing
successful-path gas. Review of [#155](https://github.com/BitChillRSK/dca-contracts/pull/155) found that
the better boundary is to remove the diagnostic-only loop altogether.

`_measuredProtocolRedeem` already proves that the external receipt-share balance fell by exactly the
share count BitChill debited before returning zero cash. That count is the directly measured cause of
the error and is already available as `sharesToRedeem` on a single redemption and
`totalSharesToRedeem` on a batch. By contrast, the current `stablecoinAttempted` value is reconstructed
bookkeeping. It can even be zero after the single-user clamp when one positive receipt share converts
to less than one stablecoin base unit, so the error currently reports `0` for a positive share
redemption.

The custom-error selector remains
`TokenLending__ZeroStablecoinReceived(uint256)`. Only the parameter name and meaning change from
attempted stablecoin to receipt shares redeemed before rollback.

## Open product decisions

**none.** Human approved the receipt-share diagnostic during PR 155 review on 2026-09-27.

## Scope

- [x] Rename the error parameter to `sharesRedeemed` and document that the whole call rolls back.
- [x] Single-user zero-cash reverts report `sharesToRedeem`.
- [x] Batch zero-cash reverts report the already-available `totalSharesToRedeem` and delete the
      diagnostic-only stablecoin sum and its second loop.
- [x] Pin the new meaning at a non-1:1 exchange rate, including the positive-share / zero-stablecoin
      dust case and a multi-row batch whose purchase-amount sum differs from its share sum.
- [x] Record the deployed-runtime delta against the R92 head under both default and deploy profiles.

## Out of scope

- [ ] Changing the error name or parameter type, adding a second batch-only error, or changing any
      external function/event selector.
- [ ] Passing an aggregate stablecoin total through `StablecoinSource` or accumulating one on the
      successful batch path.
- [ ] Changing share sizing, redemption behavior, zero-cash rollback, or exact-consumption checks.
- [ ] Adapter, deployment-script, fee, schedule, or purchase-allocation changes.
- [ ] Deploy broadcasts or live contract interaction.

## Files likely touched

- `src/interfaces/ITokenLending.sol`
- `src/LendingErc20Handler.sol`
- `test/unit/LendingErc20HandlerRedeemTest.t.sol`
- Dedicated LayerBank and Tropykus handler tests only where their explicit error payload expectations
  must follow the shared semantic.
- `docs/relaunch/R93-zero-cash-share-diagnostic.md`
- `docs/relaunch/IMPLEMENTATION_ORDER.md`
- `docs/relaunch/README.md`

## Required tests

Run the focused shared-base suite first:

```text
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn STABLECOIN_TYPE=DOC \
  forge test --match-contract LendingErc20HandlerRedeemTest -vvv
```

- The dust-share case reports one redeemed share rather than zero attempted stablecoin and rolls back
  both virtual and protocol balances.
- A multi-row zero-cash batch at a non-1:1 rate reports the exact sum of per-row receipt shares, not
  the sum of purchase amounts, and rolls back every debit.
- Existing LayerBank and Tropykus zero-payout tests express their expected payload in receipt-share
  units even where the current mock rate makes the number equal to the stablecoin amount.

Then run:

```text
make check
make check-deploy
make fork-sovryn
make fork-layerbank
make fork-tropykus
```

Fork tests add no R93-specific failure assertion; they verify that the shared-base edit leaves every
live adapter's successful redemption path unchanged.

## Success criteria

- [x] No loop exists solely to construct `TokenLending__ZeroStablecoinReceived` revert data.
- [x] Both single and batch errors report the exact receipt shares consumed before rollback.
- [x] The error selector and encoded parameter type remain unchanged.
- [x] Successful-path storage access, arithmetic, and behavior remain unchanged.
- [x] Focused, full default/deploy, and fork gates pass.

## Reviewer checklist

- [x] Matches **Scope**; nothing from **Out of scope**.
- [x] Protocol invariants in `AGENTS.md` still hold; exact external share consumption is what makes
      the diagnostic authoritative.
- [x] Tests use a non-1:1 rate so stablecoin and share units cannot be confused.
- [x] Files beyond this list are limited to direct dependencies and are named in the PR.
- [x] No unrelated refactors; history is reviewable.

## Results

The diagnostic-only batch loop is gone. Single and batch zero-cash failures now encode the exact
receipt-share debit that `_measuredProtocolRedeem` observed, while the revert restores both the
virtual books and the protocol balance. The selector and its single `uint256` parameter type are
unchanged.

Against R92 head `b5a598d`, the lending MoC leaves changed as follows:

| Handler | Default runtime | Delta | Deploy runtime | Delta |
|---|---:|---:|---:|---:|
| `SovrynDocHandlerMoc` | 10,867 bytes | -52 | 8,485 bytes | -39 |
| `LayerBankDocHandlerMoc` | 11,135 bytes | -52 | 8,741 bytes | -39 |
| `TropykusDocHandlerMoc` | 11,007 bytes | -52 | 8,717 bytes | -39 |

The focused shared-base suite passed 21 tests, the dedicated LayerBank suite passed 47, and the
dedicated Tropykus suite passed 43. `make check` and `make check-deploy` each passed 940 tests plus the
13-test invariant suite. `make fork-sovryn`, `make fork-layerbank`, and the pinned
`make fork-tropykus` gate all passed.

## ABI / deploy / cutover impact

- ABI: the error selector and encoded type stay unchanged; the ABI parameter name and semantic change
  from `stablecoinAttempted` to `sharesRedeemed`.
- Scripts: none.
- Cutover: repository-wide GitHub search found no BitChill consumer decoding this error. Operator and
  bot diagnostics generated from the new ABI should label the value as receipt shares; no consumer
  issue is required unless review identifies a decoder outside the public organization repositories.
