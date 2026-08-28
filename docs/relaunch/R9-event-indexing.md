# R9 — Event indexing, share transitions, and fee transfer

Status: **implemented** · Assigned: yes · Optional/further-review: no

PR 47 of the relaunch stack. **ABI freeze** for events, errors, and remaining indexed fields. Stack on R42 (PR 46), after the final production handlers/routes, pause/packing work, and batcher exist. See [`EXTERNAL_REWARDS.md`](./EXTERNAL_REWARDS.md).

## Objective

Index only addresses and `scheduleId`. Emit a canonical per-user lending-share balance transition after every virtual share mint or burn. Emit when a purchase fee actually moves. Do not shrink diagnostic custom-error argument lists.

## Background

Several events still index amounts, timestamps, or periods (`TokenBalanceUpdated.amount`, `PurchasePeriod` / `PurchaseAmount` payloads, `SuccessfulRbtcBatchPurchase` totals, `rBtcWithdrawn.amount`, fee-setter rates). That wastes topic slots and is the original Notion item. R40 already ships `PurchaseAmountUpdated` and `PurchasePeriodUpdated` with unindexed previous/new; do not re-index those.

Lending handlers need `TokenLending__UserSharesUpdated` so an off-chain forwarder can reconstruct time-weighted virtual shares without traces. Shape and emit sites are decided in `EXTERNAL_REWARDS.md`. R26 renamed the getter to `getUserShares`.

`_transferFee` is a silent `safeTransfer`. Ops cannot tell a purchase fee from any other collector inbound transfer without decoding the inner ERC20 log against a known collector. Add `FeeHandler__FeeTransferred`.

Per-user rBTC bought in a batch is already `PurchaseRbtc__RbtcBought` (one log per buyer). Telegram/monitoring that only read the batch-total event is a consumer fix, not a contracts gap — **do not** add a second per-user purchase event for that.

Diagnostic errors such as `DcaManager__PurchaseAmountMismatch` (six args) stay. R6 kept them so a bad batch row is named. Long error *names* are a 4-byte selector. Verbose *indexing* is this PR.

## Open product decisions

**none** — R19 pause, R18 packing, and R50’s `uint64` scheduleId / fee-struct widths land before this PR; their events/tuple are part of this audit. R12 compound is rejected. Add **no** extra purchase-event fields: `RbtcBought` already has user, token, rBTC, scheduleId, and stablecoin spent, while a per-buyer fee is not exact after batch rounding. Fee-transfer event remains required with the shape below.

## Scope

- [x] First-party events: `indexed` only on `address` and `scheduleId` (`uint64` after R50; still one topic, zero-padded) and the `user` on `UserSharesUpdated`. Un-index amounts, timestamps, periods, rates, token amounts, and totals. Do not index strings, bytes, or arrays (`PurchaseUniswap_NewPathSet` had all three indexed; they are data now).
- [x] Add to `ITokenLending` and emit after every successful per-user virtual share mutation in `LendingErc20Handler` (and any leftover override):

      ```solidity
      event TokenLending__UserSharesUpdated(
          address indexed user,
          uint256 previousShares,
          uint256 newShares
      );
      ```

      Deposits: measured share mint, not stablecoin in. Withdrawals, interest, every buyer in a batch, sequential updates when the same user appears twice. `newShares == getUserShares(user)`. Reverts emit nothing lasting. Idle has no shares — do not emit there. Cover both deployments of the LayerBank Dex handler added by R36.
- [x] Tests: each emit site; replay from a fresh deploy reconstructs balances from the event stream.
- [x] `FeeHandler__FeeTransferred(address indexed token, address indexed collector, uint256 amount)` from `_transferFee` when `fee > 0`. Skip a zero-fee transfer if `_transferFee` is not called; if it is called with 0, do not emit. Batch = one event for the aggregated fee. Do not index `amount`.
- [x] Do not shorten custom-error argument lists. Do not rename errors for brevity.
- [x] Keep `DcaManager__SchedulePauseSet(address indexed user, uint64 indexed scheduleId, bool paused)` without `token`. It matches `PurchaseAmountUpdated` / `PurchasePeriodUpdated`: filter by user and scheduleId, join on `scheduleId` for the token. Adding `token` would spend the last topic and break that family for a filter that indexers already perform off-chain.

## Out of scope

- [x] On-chain Merkl / harvest / reward index (`EXTERNAL_REWARDS.md`).
- [x] Telegram, monitoring, or frontend copy. Wire consumers to existing `RbtcBought` + the new fee event.
- [x] R39/R40/R41 behavior (already landed).
- [x] Changing R42 batcher behavior. Its first-party ABI already exists and is included in the freeze audit.
- [x] License / SPDX.
- [x] Packing/pause behavior (already landed in R18/R19/R50) or compound (rejected). This PR only audits their final ABI/events.

## Files likely touched

- `src/interfaces/ITokenLending.sol`, `src/LendingErc20Handler.sol`
- `src/interfaces/IFeeHandler.sol`, `src/FeeHandler.sol`
- `src/interfaces/IDcaManager.sol`, `src/interfaces/IPurchaseRbtc.sol`, `src/interfaces/ITokenHandler.sol`, and any other first-party event file
- Tests that `vm.expectEmit` indexed fields

## Required tests

Share-event coverage on a lending lane (`make moc-sovryn` and `make moc-layerbank` paths that mutate shares). Fee-event on a purchase that charges a non-zero fee and on a zero-fee path (no emit). Indexing: a test or documented `cast sig` / forge inspect that indexed positions match the rule.

Then `make check`. Fork: no new assertions beyond what `EXTERNAL_REWARDS.md` needs; still run both fork lanes before push.

## Success criteria

- [x] No first-party event indexes a non-address, non-`scheduleId` field.
- [x] `UserSharesUpdated` covers every lending share mutation; replay matches `getUserShares`.
- [x] `FeeTransferred` fires on non-zero `_transferFee`.
- [x] Diagnostic error args unchanged.
- [x] No open product decisions.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Invariant 1–7 unchanged.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: freeze. Topic0 changes wherever `indexed` moves. New `UserSharesUpdated` and `FeeTransferred`. Indexers must resubscribe.
- Scripts: none.
- Runtime (no IR): `DcaManager` 22,647 (margin 1,929); `SovrynErc20HandlerDex` 22,925 (margin 1,651); `LayerBankErc20HandlerDex` 23,385 (margin 1,191). The new logs live on the shared lending/fee bases, so every lending handler grew; Dex remains under EIP-170.
- Cutover: **Frontend follow-up** if the app decodes these logs (likely monitoring more than the UI). Search `bitChillRSK/front-end` and the monitoring repo; comment or open issues. Do not implement Telegram here.
