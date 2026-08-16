# R8 — Remove stuck-rBTC rescue

Status: **in progress** (GitHub #48) · Assigned: yes · Optional/further-review: no

## Objective

Delete the owner rescue that can send another account’s accumulated rBTC to a `rescueAddress`. Keep rBTC withdrawals paying the signer. Do not add a `to` parameter.

## Background

`PurchaseRbtc.withdrawStuckRbtc` (and the `PurchaseUniswap` override) lets the owner zero a user’s `s_usersAccumulatedRbtc` and send the native rBTC to an arbitrary `rescueAddress`. Be precise about what that grants: `_withdrawStuckRbtc` tries the user first and only falls through to `rescueAddress` when that call fails, so an EOA’s funds can never reach the rescue branch. What it actually grants is (a) a standing owner privilege to choose the destination for the funds of any account that cannot — or situationally does not — accept native rBTC, with the owner picking when to call (a paused or guarded smart account reverts on receive), and (b) a forced-withdrawal primitive against EOAs: the funds still reach the user, but the owner controls the timing and can drain the handler’s native balance on demand. Both are exceptions to `AGENTS.md` invariant 3 (rBTC pays the signer; no owner rescue of another account’s rBTC), and either alone justifies removal.

The same Notion bullet proposed a `to` on user withdraws so a contract account could name an EOA. Do not add it. `withdrawRbtcFromTokenHandler` / `withdrawAllAccumulatedRbtc` already pay `msg.sender`. A `to` would let a fake frontend encode `to = attacker` on a zero-value “Withdraw rBTC” tx; Rootstock wallets often do not surface that internal destination. Splitting `withdraw` / `withdrawTo` does not help: the phishing page just calls `withdrawTo`.

BitChill users come through the frontend as EOAs. Contract users who cannot receive native rBTC lose the owner rescue; that is the intended tradeoff. Fake sites can still steal via approvals or a fake deposit contract; forcing payout to `msg.sender` is the on-chain property that makes “Withdraw rBTC” on a clone UI fail to redirect funds.

`withdrawAccumulatedRbtc(address user)` stays. DcaManager passes `msg.sender`; that is not a user-facing `to`.

After removal the stuck state is non-destructive and self-announcing. `_withdrawRbtc` reverts on a failed native send, which rolls back the `s_usersAccumulatedRbtc[user] = 0` written by `_withdrawRbtcChecksEffects` in the same call: nothing is lost, the balance stays on the books, and a contract account that cannot receive rBTC learns this on its first withdrawal attempt rather than silently.

## Considered and rejected: a WRBTC withdrawal

The alternative to deleting the capability is to make it self-service instead of owner-driven: `DcaManager.withdrawWrbtcFromTokenHandler(token, lendingProtocolIndex)` (`nonReentrant`) → `handler.withdrawAccumulatedWrbtc(msg.sender)` (`onlyDcaManager`), reusing `_withdrawRbtcChecksEffects` so the zeroing stays in one place, and paying WRBTC instead of native. That keeps invariant 3 fully intact — the destination is still `msg.sender`, no `to`, no owner — and it is the blue-chip shape for this problem: Uniswap routers pay WETH unless the caller explicitly asks to unwrap, and Aave V3 keeps native out of the Pool entirely behind `WrappedTokenGatewayV3`. Wrapping is not the point; keeping the destination at `msg.sender` is.

Rejected for the relaunch. No contract account has ever deposited on BitChill, and the realistic smart-account case is unaffected anyway: Safe and typical ERC-4337 accounts implement `receive()`. The cost is real: the DEX handlers already hold `i_wrBtcToken` and would merely skip the unwrap, but `PurchaseMoc` has no WRBTC reference, so it needs a new immutable on `PurchaseRbtc`, a `wrbtcTokenAddress` in the MoC helper configs (mainnet / testnet / mock), and edits to `DeployMocSwaps` and `DeployMocAndUniswap`. Building it for one handler family only would make the capability depend on which swap route the user happened to pick.

Do not substitute an owner-called push variant. Sending WRBTC *to* the stuck contract fixes the destination but keeps an owner privilege over another account’s balance, which is exactly what this item removes.

Deadline, because it is not symmetric: handlers are immutable and unproxied, so adding this after the relaunch deployment means new handler contracts and a user migration. Reopen only with evidence of a real contract depositor, and only before the relaunch cutover.

## Open product decisions

**none**

## Scope

- [x] Delete `withdrawStuckRbtc`, `_withdrawStuckRbtc`, and `PurchaseRbtc__rBtcRescued` from `PurchaseRbtc`, the `PurchaseUniswap` override, and `IPurchaseRbtc`.
- [x] Keep `withdrawAccumulatedRbtc(user)`, `withdrawRbtcFromTokenHandler`, and `withdrawAllAccumulatedRbtc` sending native rBTC to `user` (`msg.sender` from DcaManager). No `to` on any withdraw ABI.
- [x] Drop `Ownable` from `PurchaseRbtc` if it is unused after this deletion and the handler inheritance graph still compiles. Keep it if C3 linearization requires it. `PurchaseUniswap` owner setters continue to use `onlyOwner` via `FeeHandler`.
- [x] Drop tests that exist only for the rescue. Keep and, if missing, add withdraw-to-signer coverage: a third party calling `withdrawRbtcFromTokenHandler` does not move another user’s accumulated rBTC; a successful user withdraw credits the signer only.
- [x] Remove `withdrawStuckRbtc` stubs from fuzz handler wrappers.

## Out of scope

- [ ] A `to` parameter or `withdrawTo`.
- [ ] R1 / R20 cash accounting (PR 8).
- [ ] R9 event indexing (`PurchaseRbtc__rBtcWithdrawn` still indexes `amount`).
- [ ] Fee model, R18 packing, R19 pause, R12/R13/optionals (PR 2 / later PRs).
- [ ] `forge fmt` of existing files.
- [ ] Deploy broadcasts or live addresses.
- [ ] `dca-out-contracts`.

## Files likely touched

- `src/PurchaseRbtc.sol`
- `src/PurchaseUniswap.sol`
- `src/interfaces/IPurchaseRbtc.sol`
- `test/unit/RbtcPurchaseTest.t.sol`
- `test/unit/RbtcWithdrawalTest.t.sol`
- `test/ai-generated/unit/EdgeCasesTest.t.sol`
- `test/ai-generated/fuzz/Invariants.t.sol`
- `test/ai-generated/fuzz/README_INVARIANTS.md`
- `docs/relaunch/README.md` (assignment status)

Implementer may follow compiler errors into fuzz wrappers and unused helper contracts (`NonPayableReceiver`). Extra files belong in the PR write-up.

## Required tests

Commands (targeted first, then done-gate):

```bash
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC forge test --match-contract RbtcPurchaseTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC forge test --match-contract RbtcWithdrawalTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus forge test --match-contract EdgeCasesTest
LENDING_PROTOCOL=tropykus SWAP_TYPE=mocSwaps forge test --match-contract InvariantTest
make check
```

Behaviors to assert:

- `withdrawStuckRbtc` is gone from `src/` and `src/interfaces/`.
- Owner (or any other account) cannot move another user’s accumulated rBTC.
- `withdrawRbtcFromTokenHandler` / `withdrawAllAccumulatedRbtc` credit `msg.sender` only. A second account with its own accrued rBTC receives exactly that amount; the first user’s accrued balance is unchanged. Existing `RbtcWithdrawalTest` cases keep passing.
- `testOnlyUserCanWithdrawRbtc` still reverts for a non-manager caller.
- Rescue-only tests are deleted, not rewritten to expect a revert on a removed function.

Fork tests: not required.

## Success criteria

- [x] `withdrawStuckRbtc` / `_withdrawStuckRbtc` / `PurchaseRbtc__rBtcRescued` are gone.
- [x] No owner path can move another account’s rBTC.
- [x] Stronger property now statable for audit: **no owner path in any handler can move a user’s funds.** After this change the only `onlyOwner` surface across `TokenHandler`, `TokenLending`, `TropykusErc20Handler`, `SovrynErc20Handler`, `PurchaseMoc` and `PurchaseUniswap` is `FeeHandler`’s bounded fee setters and the Uniswap swap parameters.
- [x] User withdraws still credit the signer only. No `to` on the ABI.
- [x] Targeted tests above pass; `make check` passes.
- [x] Protocol invariants in `AGENTS.md` unchanged (invariant 3 now matches the code).

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec does not change them; it removes the rescue that contradicted invariant 3).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies / failing-test fallout and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: remove `withdrawStuckRbtc(address,address)` and `PurchaseRbtc__rBtcRescued`. No new functions. Do not add `to`.
- Scripts: none.
- Cutover: applies **from the relaunch deployment forward**. The currently deployed handlers keep their own code and their own rescue, so no existing user loses a capability and no live balance is affected. On the new deployment: frontend / ops must not call `withdrawStuckRbtc` (it no longer exists); a contract account that cannot receive native rBTC has no owner redirect, and its withdrawal attempt reverts without loss (see **Background**). Users must withdraw to an address that can receive value. Do not include broadcast steps.
