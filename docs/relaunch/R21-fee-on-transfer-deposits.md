# R21 — Fee-on-transfer deposits

Status: **in review** · Assigned: yes · Optional/further-review: no

PR 13. Stack on the idle handler PR. Land before LayerBank.

## Objective

Credit `DcaManager.tokenBalance` and handler per-user books with the stablecoin actually received on deposit, not the amount requested, so a fee-on-transfer token cannot desync the ledgers. Same composability hygiene as invariant 6 for tokens with transfer hooks. DOC and USDRIF are not FOT; BitChill must still not break if one is used.

## Background

R1 / R20 measure cash on lending redemptions, MoC, Uniswap, and withdrawals. Deposit was explicitly out of scope there: `DcaManager` credits `depositAmount` after `transferFrom(depositAmount)`. Idle already credits `s_idleBalances` from a handler `balanceOf` delta, so a FOT token would leave DcaManager ahead of idle.

Lending is worse: the handler then `mint`s the requested amount, which can exceed the DOC it actually holds.

**Do not delete the insufficient-balance guards on the way past.** Crediting received-on-deposit closes the last way to desync the books while `DcaManager` is correct, which will make `IdleErc20Handler__InsufficientIdleBalance` and `TokenLending__InsufficientLendingTokenBalance` (PR 12) read as dead code. They are not. Checked arithmetic reverts on those subtractions either way, so removing the `if` does not remove the revert — it only downgrades a named error carrying the offending user to a bare `Panic(0x11)` the swapper has to bisect a batch to interpret. Their job is to bound a `DcaManager` accounting bug to the user who caused it (the `updateDcaSchedule` stale-write-back class R6 analysed), which is the same reason the single-redeem clamps exist. FOT is not what they defend against. Keep both.

Withdrawals stay on the R20 rule: principal falls by the **requested** amount because a redemption fee consumes principal. Do not credit the difference back. Outbound FOT (user receives less than the handler sent) is the same shape: the handler spent the requested amount.

`createDcaSchedule` currently validates `purchaseAmount` against the requested `depositAmount` *before* the pull. After this PR it must validate against the credited `tokenBalance` (the received amount).

## Open product decisions

**none** — `IMPLEMENTATION_ORDER.md` lists no gates for PR 13. Implement without asking.

## Scope

- [x] `ITokenHandler.depositToken` returns `uint256` — the amount the handler actually received (balance delta of `address(this)` around `transferFrom`).
- [x] `TokenHandler.depositToken` measures that delta, reverts if a positive request received 0, returns it. Event reports received, not requested.
- [x] `IdleErc20Handler.depositToken` uses the base return (or the same delta) for `s_idleBalances`. Keep the zero-received revert.
- [x] Sovryn / Tropykus `depositToken`: pull via the base (received), then mint **received** into the lending token, then credit the share `balanceOf` delta as today.
- [x] `DcaManager.depositToken` / `createDcaSchedule` / `updateDcaSchedule`: credit `tokenBalance` with the handler return. `create` / `update` validate `purchaseAmount` against the post-deposit `tokenBalance`, not the requested deposit. Events that report the new balance use the credited amount.
- [x] `updateDcaSchedule`: pull then credit (do not add `depositAmount` to the memory copy before the handler returns).
- [x] Mock + tests in the same style as `MockReentrantStablecoin` / `test/unit/DepositSwapPopReentrancyTest.t.sol`: a dedicated mock that takes a fee on `transfer` / `transferFrom`, and tests that prove create / extra deposit / buy / withdraw keep `tokenBalance` equal to the handler book (idle mapping or underlying value of shares, modulo the existing 100-wei lending rounding slack). Another user's funds are untouched. A zero-received deposit reverts.

## Out of scope

- [ ] Changing the R20 withdraw rule (requested amount still leaves `tokenBalance`).
- [ ] Removing the batch-redeem insufficient-balance guards or the single-redeem clamps as newly-dead code. See **Background**.
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

## Required tests

Targeted (dedicated mock; do not go through `DeployMocSwaps`, same reason as the hook test):

```
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus EXPECTED_LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC \
  forge test --match-path "test/unit/FeeOnTransferDepositTest.t.sol" -j 1
```

Then `make check`.

Behaviors to assert:

- Create with requested 100, fee 1%: `tokenBalance == 99`, idle (or lending underlying) == 99, user spent 100, another user’s book unchanged.
- Extra `depositToken` / `updateDcaSchedule` credits received, not requested.
- `purchaseAmount` greater than received reverts at create/update; `purchaseAmount` equal to received is allowed (R11).
- Buy and withdraw after a FOT deposit succeed against the credited balance; handler book matches.
- Requested deposit that delivers 0 reverts.
- Existing DOC/USDRIF lanes in `make check` are unchanged (1:1 tokens still credit the requested amount).

Fork tests: not required.

## Success criteria

- [x] Handler `depositToken` returns the measured received amount; DcaManager credits that amount.
- [x] Lending mints from received, not requested.
- [x] FOT tests prove the books stay in lockstep; `make check` still passes on DOC/USDRIF.
- [x] Withdraw still debits requested principal (R20).

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec does not change them; it extends invariant 1 to deposits).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: `ITokenHandler.depositToken` returns `uint256`. `DcaManager` user-facing deposit/create/update signatures unchanged; events report credited (received) balances.
- Scripts: none.
- Cutover: none. Live tokens are not FOT.
