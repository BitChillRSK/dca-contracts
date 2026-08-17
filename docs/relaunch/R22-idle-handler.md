# R22 — Idle DOC + MoC handler

Status: **not started** · Assigned: yes · Optional/further-review: no

PR 12 of R22. LayerBank, deploy/constants/harness/CI index-map work are later PRs.

## Objective

Ship an index-0 idle DOC + MoC handler so a schedule can hold DOC on the handler with no lending token. Deposits, buys, and withdrawals spend that idle DOC. Interest calls for index 0 keep reverting because no protocol name is registered.

## Background

`OperationsAdmin` already treats index 0 as “not lent”: `addOrUpdateLendingProtocol` cannot use 0, and `assignOrUpdateTokenHandler(..., 0, handler)` is allowed without a protocol name. `DcaManager._checkTokenYieldsInterest` reverts on an empty name. Live never assigned a handler at 0.

`TokenHandler.withdrawToken` is an uncapped `safeTransfer`. Lending handlers bound that with a per-user share mapping and a clamp. An idle handler that skipped its own per-user accounting would pay whatever `DcaManager` asked from the pooled DOC. See `IMPLEMENTATION_ORDER.md` “Heads-up for any future idle-funds handler”.

Do not add per-user balances to `TokenHandler` itself. Lending handlers already clamp via their share mappings, and the base `withdrawToken` is the transfer that runs *after* that clamp.

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 12. Implement without asking.

## Scope

- [ ] Add `IdleErc20Handler` (`TokenHandler` + per-user idle DOC mapping; no `TokenLending`) and `IdleDocHandlerMoc` (`IdleErc20Handler` + `PurchaseMoc`).
- [ ] `depositToken` pulls DOC onto the handler (balance-delta) and credits the user’s idle balance. Do not mint a lending token.
- [ ] `withdrawToken` clamps to the caller’s idle balance, debits that mapping, then transfers.
- [ ] `_redeemStablecoin` / `_batchRedeemStablecoin` debit the idle mapping and return the amount; DOC is already on the handler. Clamp each user to their own balance.
- [ ] Do not implement `ITokenLending`. Do not register a protocol name for index 0.
- [ ] Dedicated unit tests under `test/ai-generated/unit/idle/`, plus a standalone `DcaManager` path at index 0 (create / buy / withdraw / interest reverts).
- [ ] Skip `addOrUpdateLendingProtocol` in `HandlerTestHarness` when the index is 0 (that call reverts; assigning a handler at 0 does not need a name).
- [ ] Update `src/idle/README.md` and the `AGENTS.md` Layout line for `src/idle/`.

## Out of scope

- [ ] LayerBank handler (PR 13).
- [ ] `script/Constants.sol` index map, `DeployMocSwaps` / `DeployDexSwaps` registration, `DcaDappTest` split, `ILendingToken` deletion, CI matrix (`none` / `layerbank` / `sovryn`) — those are PR 14.
- [ ] Idle Uniswap / USDRIF handler. Dex sources stay where they are.
- [ ] Registering a name for index 0.
- [ ] Changing `TokenHandler` to own per-user accounting.
- [ ] Moving `PurchaseMoc.sol`. Relaxing invariant 6.

## Files likely touched

New:

- `src/idle/IIdleErc20Handler.sol`
- `src/idle/IdleErc20Handler.sol`
- `src/idle/IdleDocHandlerMoc.sol`
- `test/ai-generated/unit/idle/IdleErc20HandlerTest.t.sol`
- `test/ai-generated/unit/idle/IdleDocHandlerMocTest.t.sol`
- `test/ai-generated/unit/idle/IdleDcaManagerTest.t.sol`

Edit:

- `src/idle/README.md`
- `test/ai-generated/unit/HandlerTestHarness.t.sol` (skip protocol-name registration when index is 0)
- `AGENTS.md`
- `docs/relaunch/README.md`

## Required tests

Targeted:

```
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC \
  forge test --no-match-test invariant --no-match-contract ComparePurchaseMethods \
  --match-path "test/ai-generated/unit/idle/**" -j 1
```

Then the done-gate:

```
make check
```

Behaviors to assert:

- Deposit leaves DOC on the handler; no lending token is minted; `getUsersIdleTokenBalance` equals the received amount.
- Withdraw pays the user and debits that user’s idle balance only.
- `withdrawToken` for more than the user’s idle balance clamps; another user’s idle DOC is untouched.
- `buyRbtc` / `batchBuyRbtc` spend idle DOC via MoC and credit accumulated rBTC; idle balances fall by the spent DOC.
- `createDcaSchedule(..., 0)` works when the idle handler is assigned at index 0 with no protocol name.
- `getInterestAccrued` / `withdrawInterest` / `withdrawTokenAndInterest` at index 0 revert `DcaManager__TokenDoesNotYieldInterest`.
- Existing Tropykus and Sovryn lanes are unchanged.

Fork tests: not required.

## Success criteria

- [ ] `IdleDocHandlerMoc` is constructable without a lending-token address or `exchangeRateDecimals`.
- [ ] Deposits stay on the handler; buys and withdrawals spend idle DOC; per-user idle balances clamp `withdrawToken` and both redeem paths.
- [ ] Index 0 has no protocol name; interest calls revert.
- [ ] Deploy scripts, `Constants.sol` indexes, and the shared `DcaDappTest` harness are unchanged.
- [ ] Done-gate lanes pass.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec changes none). Invariant 6 stays load-bearing for pooled idle funds.
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: new contracts `IdleErc20Handler` / `IdleDocHandlerMoc`. No change to `DcaManager` / `OperationsAdmin` / existing handler ABIs.
- Scripts: none. Live registration of index 0 is PR 14.
- Cutover: none in this PR. Frontend can target index 0 only after PR 14 assigns the handler on the new admin.
