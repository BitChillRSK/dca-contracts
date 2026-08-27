# R21 — Fee-on-transfer deposits

Status: **in review** · Assigned: yes · Optional/further-review: no

PR 13. Stack on the idle handler PR. Land before LayerBank.

## Objective

Credit hop-1 cash: `DcaManager.tokenBalance` (and idle’s mapping) with the stablecoin the handler actually received on `transferFrom`, not the amount requested, so a listed token that suddenly turns on a transfer fee cannot mint more than the handler holds and cannot freeze withdrawals.

Fee-on-transfer is **not** a supported token class. DOC and USDRIF are 1:1. This PR is hop-1 hygiene, not “BitChill is FOT-proof.” Purchases after a surprise fee are not guaranteed.

**Superseded in part by [R41](./R41-reject-fot-deposits.md):** measurement and the zero-received revert stay; crediting a *partial* hop-1 shortfall is replaced by `TokenHandler__DepositAmountMismatch` (fail closed). Do not re-teach the short-credit path when implementing after R41.

## Background

R1 / R20 measure cash on lending redemptions, MoC, Uniswap, and withdrawals. Deposit was explicitly out of scope there: `DcaManager` credits `depositAmount` after `transferFrom(depositAmount)`. Idle already credits `s_idleBalances` from a handler `balanceOf` delta, so a FOT token would leave DcaManager ahead of idle.

Lending hop 1 is the same pull. The handler then `mint`s that received amount into the lending token — a second `transferFrom`. Compound-style kTokens mint shares from **their** cash delta, so a 1% fee on both hops leaves `tokenBalance` at 99 and share-underlying at ~98.01. Withdraw still works: Tropykus/Sovryn clamp the redeem to shares held.

A batch buy of the overstated `tokenBalance` reverts `TokenLending__InsufficientLendingTokenBalance` with that user's address and aborts the rest of the batch until the swapper drops the row. Same blast radius as any share or idle shortfall: PurchaseMoc splits rBTC by planned weights, so skip-and-continue would dilute everyone else. That is acceptable — the swapper controls composition and would delist a proxy that turned on a fee. Isolating buyers inside a batch is out of scope. Supporting FOT as a product (return hop-2 cash, MoC/Uniswap FOT accounting) is also out of scope.

**Do not delete the insufficient-balance guards on the way past.** Crediting received-on-deposit closes the last way to desync the books while `DcaManager` is correct, which will make `IdleErc20Handler__InsufficientIdleBalance` and `TokenLending__InsufficientLendingTokenBalance` (PR 12) read as dead code. They are not. Checked arithmetic reverts on those subtractions either way, so removing the `if` does not remove the revert — it only downgrades a named error carrying the offending user to a bare `Panic(0x11)` the swapper has to bisect a batch to interpret. Their job is to bound a `DcaManager` accounting bug to the user who caused it (the `updateDcaSchedule` stale-write-back class R6 analysed), which is the same reason the single-redeem clamps exist. FOT is not what they defend against. Keep both.

Withdrawals stay on the R20 rule: principal falls by the **requested** amount because a redemption fee consumes principal. Do not credit the difference back. Outbound FOT (user receives less than the handler sent) is the same shape: the handler spent the requested amount.

Do not revert withdraw because `balanceOf(user)` did not rise. Invariant 1 is handler cash. Recipient-side measurement would brick live 1:1 withdraws for any recipient whose balance does not increase in the same call, for a token class we do not support. A 100% outbound fee would in isolation be better served by reverting (the schedule stays funded until the fee is turned off); we are not taking that revert, because it requires that measurement. `IdleErc20Handler__ZeroStablecoinPaid` still fires when `_debitIdleBalance` clamps to 0 because the user has no idle balance — it does not mean the transfer paid the user nothing.

`createDcaSchedule` currently validates `purchaseAmount` against the requested `depositAmount` *before* the pull. After this PR it must validate against the credited `tokenBalance` (the received amount).

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 13. Implement without asking.

## Scope

- [x] `ITokenHandler.depositToken` returns `uint256` — the amount the handler actually received (balance delta of `address(this)` around `transferFrom`).
- [x] `TokenHandler.depositToken` measures that delta, reverts if a positive request received 0, returns it. Event reports received, not requested.
- [x] `IdleErc20Handler.depositToken` uses the base return (or the same delta) for `s_idleBalances`. The zero-received revert lives in `TokenHandler` now that the base owns the measurement, so the idle-level copy (and `IdleErc20Handler__ZeroStablecoinReceived`) was dropped as unreachable — `TokenHandler__ZeroStablecoinReceived` is the live guard.
- [x] Sovryn / Tropykus `depositToken`: pull via the base (received), then mint **received** into the lending token, then credit the share `balanceOf` delta as today.
- [x] `DcaManager.depositToken` / `createDcaSchedule` / `updateDcaSchedule`: credit `tokenBalance` with the handler return. `create` / `update` validate `purchaseAmount` against the post-deposit `tokenBalance`, not the requested deposit. Events that report the new balance use the credited amount.
- [x] `updateDcaSchedule`: pull then credit (do not add `depositAmount` to the memory copy before the handler returns).
- [x] Mock + tests in the same style as `MockReentrantStablecoin` / `test/unit/DepositSwapPopReentrancyTest.t.sol`: a dedicated mock that takes a fee on `transfer` / `transferFrom`. Idle: create / extra deposit / buy / withdraw keep `tokenBalance` equal to the idle mapping. Lending: hop-1 credits `tokenBalance`; share-underlying is strictly less (second hop); withdraw of the credited balance still zeros the schedule (clamp). Another user's funds are untouched. A zero-received deposit reverts. Do not revert withdraw when the user received 0 — that would need recipient-side measurement (see **Background**).
- [x] `TokenHandler.withdrawToken` measures `i_stableToken.balanceOf(address(this))` around `safeTransfer`, returns that, event uses that. Do not measure the user: invariant 1 is handler cash. Idle debits the mapping then `return super.withdrawToken(...)`. Sovryn/Tropykus keep returning `super.withdrawToken(...)` after `_redeemStablecoin`. `DcaManager.withdrawToken` still ignores the return and subtracts the requested amount. `deleteDcaSchedule` keeps using the handler return for the event.

## Out of scope

- [ ] Changing the R20 withdraw rule (requested amount still leaves `tokenBalance`).
- [ ] Removing the batch-redeem insufficient-balance guards or the single-redeem clamps as newly-dead code. See **Background**.
- [ ] Supporting FOT as a product: hop-2 / MoC / Uniswap FOT accounting, or encoding return types into ERC165.
- [ ] Reverting withdraw when the user received 0 (requires recipient-side measurement; see **Background**).
- [ ] Isolating one underfunded buyer inside `batchBuyRbtc` so the rest of the batch still runs.
- [ ] LayerBank (PR 15). LayerBank must copy this deposit pattern; do not implement LayerBank here.
- [ ] R16 redeem glossary.
- [ ] Registering a FOT token in `DeployMocSwaps` / production constants. DOC/USDRIF stay the live tokens.
- [ ] Fee-model, packing, pause, event re-indexing.

## Files likely touched

- `src/interfaces/ITokenHandler.sol`
- `src/interfaces/IDcaManager.sol` (comments / create-deposit natspec if they claim the requested amount is credited)
- `src/TokenHandler.sol`
- `src/DcaManager.sol`
- `src/idle/IdleErc20Handler.sol`
- `src/sovryn/SovrynErc20Handler.sol`
- `src/tropykus-legacy/TropykusErc20Handler.sol`
- `test/mocks/MockFeeOnTransferStablecoin.sol`
- `test/unit/FeeOnTransferDepositTest.t.sol` (name can match neighboring unit tests)
- `test/mocks/MockKdocToken.sol` / `test/mocks/MockIsusdToken.sol` — mint shares from cash received (Compound-style), so 1:1 lanes stay unchanged and FOT tests cannot fake hop-2 lockstep
- `test/mocks/MockMocProxy.sol` — burn the DOC actually received so a FOT buy-after-deposit does not revert; 1:1 unchanged

## Required tests

Targeted (dedicated mock; do not go through `DeployMocSwaps`, same reason as the hook test):

```
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC \
  forge test --match-path "test/unit/FeeOnTransferDepositTest.t.sol" -j 1
```

Then `make check`.

Behaviors to assert:

- Idle create with requested 100, fee 1%: `tokenBalance == 99`, idle mapping == 99, user spent 100, another user’s book unchanged.
- Extra `depositToken` / `updateDcaSchedule` credits hop-1 received, not requested.
- `purchaseAmount` greater than received reverts at create/update; `purchaseAmount` equal to received is allowed (R11).
- Idle buy and withdraw after a FOT deposit succeed against the credited balance; handler book matches.
- Tropykus: `tokenBalance == 99`, share-underlying `< 99` (~98.01 on a second 1% hop). Extra deposits sum hop-1 on the schedule and leave underlying strictly less. Withdraw of the credited 99 still zeros the schedule (clamp); user receives something. Batch buy of the overstated 99 reverts `TokenLending__InsufficientLendingTokenBalance` (named user; rest of the batch aborted until that row is dropped).
- Requested deposit that delivers 0 reverts.
- Existing DOC/USDRIF lanes in `make check` are unchanged (1:1 tokens still credit the requested amount).

Fork tests: not required.

## Success criteria

- [x] Handler `depositToken` returns the measured hop-1 received amount; DcaManager credits that amount.
- [x] Lending mints from hop-1 received, not requested.
- [x] Idle FOT tests prove hop-1 lockstep. Lending FOT tests prove hop-1 credit, hop-2 lag, and withdraw survival. `make check` still passes on DOC/USDRIF.
- [x] Withdraw still debits requested principal (R20). Do not revert when the user received 0 (no recipient-side measurement).

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec does not change them; it extends invariant 1 to deposits).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: `ITokenHandler.depositToken` returns `uint256` (hop-1 received). `ITokenHandler.withdrawToken` still returns `uint256`, now the handler `balanceOf` delta rather than echoing the argument. `DcaManager` user-facing deposit/create/update signatures unchanged; events report credited (received) balances. `deleteDcaSchedule` still reports the handler withdraw return.
- ERC165: `type(ITokenHandler).interfaceId` **does not change**. Function selectors omit return types (`depositToken(address,uint256)`). Do not invent ERC165 tricks to encode the new return.
- Scripts: none.
- Cutover: full protocol redeploy (new `DcaManager` + all handlers together). No mixed-generation handlers on a live manager. A stale handler that still `supportsInterface` would fail closed on deposit (empty returndata). Live tokens are not FOT; 1:1 deposits still credit the requested amount.
