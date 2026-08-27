# R9 — Event indexing, share transitions, and fee transfer

Status: **not started** · Assigned: no · Optional/further-review: no

PR 38 of the relaunch stack. **ABI freeze** for events, errors, and remaining indexed fields. Stack on R42 (PR 37), after the final production handlers/routes and batcher exist. See [`EXTERNAL_REWARDS.md`](./EXTERNAL_REWARDS.md).

## Objective

Index only addresses and `scheduleId`. Emit a canonical per-user lending-share balance transition after every virtual share mint or burn. Emit when a purchase fee actually moves. Do not shrink diagnostic custom-error argument lists.

## Background

Several events still index amounts, timestamps, or periods (`TokenBalanceUpdated.amount`, `PurchasePeriod` / `PurchaseAmount` payloads, `SuccessfulRbtcBatchPurchase` totals, `rBtcWithdrawn.amount`, fee-setter rates). That wastes topic slots and is the original Notion item. R40 already ships `PurchasePeriodUpdated` with unindexed previous/new; do not re-index those.

Lending handlers need `TokenLending__UserSharesUpdated` so an off-chain forwarder can reconstruct time-weighted virtual shares without traces. Shape and emit sites are decided in `EXTERNAL_REWARDS.md`. R26 renamed the getter to `getUserShares`.

`_transferFee` is a silent `safeTransfer`. Ops cannot tell a purchase fee from any other collector inbound transfer without decoding the inner ERC20 log against a known collector. Add `FeeHandler__FeeTransferred`.

Per-user rBTC bought in a batch is already `PurchaseRbtc__RbtcBought` (one log per buyer). Telegram/monitoring that only read the batch-total event is a consumer fix, not a contracts gap — **do not** add a second per-user purchase event for that.

Diagnostic errors such as `DcaManager__PurchaseAmountMismatch` (six args) stay. R6 kept them so a bad batch row is named. Long error *names* are a 4-byte selector. Verbose *indexing* is this PR.

## Open product decisions

Ask before implementing:

1. **R18 packing / R19 pause** if PR 2 has not recorded them. Extra pause/compound events only if those items were approved for this freeze. Default: no pause/compound events.
2. **Any extra purchase-event fields for ops?** Default **none**. `RbtcBought` already has user, token, rBTC, scheduleId, stablecoin spent. Do not add remaining balance, route index, or per-buyer fee unless the human names the field. Per-buyer fee is not even exact after batch rounding.

Fee-transfer event: **yes**, decided 2026-08-27. Shape below.

## Scope

- [ ] First-party events: `indexed` only on `address` and `bytes32 scheduleId` (and the `user` on `UserSharesUpdated`). Un-index amounts, timestamps, periods, rates, token amounts, and totals. Do not index strings, bytes, or arrays (none should be indexed today).
- [ ] Add to `ITokenLending` and emit after every successful per-user virtual share mutation in `LendingErc20Handler` (and any leftover override):

      ```solidity
      event TokenLending__UserSharesUpdated(
          address indexed user,
          uint256 previousShares,
          uint256 newShares
      );
      ```

      Deposits: measured share mint, not stablecoin in. Withdrawals, interest, every buyer in a batch, sequential updates when the same user appears twice. `newShares == getUserShares(user)`. Reverts emit nothing lasting. Idle has no shares — do not emit there. Cover both deployments of the LayerBank Dex handler added by R36.
- [ ] Tests: each emit site; replay from a fresh deploy reconstructs balances from the event stream.
- [ ] `FeeHandler__FeeTransferred(address indexed token, address indexed collector, uint256 amount)` from `_transferFee` when `fee > 0`. Skip a zero-fee transfer if `_transferFee` is not called; if it is called with 0, do not emit. Batch = one event for the aggregated fee. Do not index `amount`.
- [ ] Do not shorten custom-error argument lists. Do not rename errors for brevity.

## Out of scope

- [ ] On-chain Merkl / harvest / reward index (`EXTERNAL_REWARDS.md`).
- [ ] Telegram, monitoring, or frontend copy. Wire consumers to existing `RbtcBought` + the new fee event.
- [ ] R39/R40/R41 behavior (already landed).
- [ ] Changing R42 batcher behavior. Its first-party ABI already exists and is included in the freeze audit.
- [ ] License / SPDX.
- [ ] Packing, pause, compound (unless decision 1 says they ship in this freeze — then their events are in scope here and nowhere else).

## Files likely touched

- `src/interfaces/ITokenLending.sol`, `src/LendingErc20Handler.sol`
- `src/interfaces/IFeeHandler.sol`, `src/FeeHandler.sol`
- `src/interfaces/IDcaManager.sol`, `src/interfaces/IPurchaseRbtc.sol`, `src/interfaces/ITokenHandler.sol`, and any other first-party event file
- Tests that `vm.expectEmit` indexed fields

## Required tests

Share-event coverage on a lending lane (`make moc-sovryn` and `make moc-layerbank` paths that mutate shares). Fee-event on a purchase that charges a non-zero fee and on a zero-fee path (no emit). Indexing: a test or documented `cast sig` / forge inspect that indexed positions match the rule.

Then `make check`. Fork: no new assertions beyond what `EXTERNAL_REWARDS.md` needs; still run both fork lanes before push.

## Success criteria

- [ ] No first-party event indexes a non-address, non-`scheduleId` field.
- [ ] `UserSharesUpdated` covers every lending share mutation; replay matches `getUserShares`.
- [ ] `FeeTransferred` fires on non-zero `_transferFee`.
- [ ] Diagnostic error args unchanged.
- [ ] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Invariant 1–7 unchanged.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: freeze. Topic0 changes wherever `indexed` moves. New `UserSharesUpdated` and `FeeTransferred`. Indexers must resubscribe.
- Scripts: none.
- Cutover: **Frontend follow-up** if the app decodes these logs (likely monitoring more than the UI). Search `bitChillRSK/front-end` and the monitoring repo; comment or open issues. Do not implement Telegram here.
