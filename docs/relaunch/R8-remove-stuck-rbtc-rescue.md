# R8 — Remove stuck-rBTC rescue

Status: **not started** · Assigned: yes · Optional/further-review: no

## Objective

Delete the owner rescue that can send another account’s accumulated rBTC to a `rescueAddress`. Keep rBTC withdrawals paying the signer. Do not add a `to` parameter.

## Background

`PurchaseRbtc.withdrawStuckRbtc` (and the `PurchaseUniswap` override) lets the owner zero a user’s `s_usersAccumulatedRbtc` and send the native rBTC to an arbitrary `rescueAddress` if the user address cannot receive value. That is an exception to `AGENTS.md` invariant 3 (rBTC pays the signer; no owner rescue of another account’s rBTC).

The same Notion bullet proposed a `to` on user withdraws so a contract account could name an EOA. Do not add it. `withdrawRbtcFromTokenHandler` / `withdrawAllAccumulatedRbtc` already pay `msg.sender`. A `to` would let a fake frontend encode `to = attacker` on a zero-value “Withdraw rBTC” tx; Rootstock wallets often do not surface that internal destination. Splitting `withdraw` / `withdrawTo` does not help: the phishing page just calls `withdrawTo`.

BitChill users come through the frontend as EOAs. Contract users who cannot receive native rBTC lose the owner rescue; that is the intended tradeoff. Fake sites can still steal via approvals or a fake deposit contract; forcing payout to `msg.sender` is the on-chain property that makes “Withdraw rBTC” on a clone UI fail to redirect funds.

`withdrawAccumulatedRbtc(address user)` stays. DcaManager passes `msg.sender`; that is not a user-facing `to`.

## Open product decisions

**none**

## Scope

- [ ] Delete `withdrawStuckRbtc`, `_withdrawStuckRbtc`, and `PurchaseRbtc__rBtcRescued` from `PurchaseRbtc`, the `PurchaseUniswap` override, and `IPurchaseRbtc`.
- [ ] Keep `withdrawAccumulatedRbtc(user)`, `withdrawRbtcFromTokenHandler`, and `withdrawAllAccumulatedRbtc` sending native rBTC to `user` (`msg.sender` from DcaManager). No `to` on any withdraw ABI.
- [ ] Drop `Ownable` from `PurchaseRbtc` if it is unused after this deletion and the handler inheritance graph still compiles. Keep it if C3 linearization requires it. `PurchaseUniswap` owner setters continue to use `onlyOwner` via `FeeHandler`.
- [ ] Drop tests that exist only for the rescue. Keep and, if missing, add withdraw-to-signer coverage: a third party calling `withdrawRbtcFromTokenHandler` does not move another user’s accumulated rBTC; a successful user withdraw credits the signer only.
- [ ] Remove `withdrawStuckRbtc` stubs from fuzz handler wrappers.

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
- `docs/relaunch/README.md` (assignment status)

Implementer may follow compiler errors into fuzz wrappers and unused helper contracts (`NonPayableReceiver`). Extra files belong in the PR write-up.

## Required tests

Commands (targeted first, then done-gate):

```bash
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus forge test --match-path test/unit/RbtcPurchaseTest.t.sol --match-path test/unit/RbtcWithdrawalTest.t.sol
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus forge test --match-contract EdgeCasesTest
LENDING_PROTOCOL=tropykus SWAP_TYPE=mocSwaps forge test --match-contract InvariantTest
make check
```

Behaviors to assert:

- `withdrawStuckRbtc` is gone from `src/` and `src/interfaces/`.
- Owner (or any other account) cannot move another user’s accumulated rBTC.
- `withdrawRbtcFromTokenHandler` / `withdrawAllAccumulatedRbtc` credit `msg.sender` only. Existing `RbtcWithdrawalTest` cases keep passing.
- `testOnlyUserCanWithdrawRbtc` still reverts for a non-manager caller.
- Rescue-only tests are deleted, not rewritten to expect a revert on a removed function.

Fork tests: not required.

## Success criteria

- [ ] `withdrawStuckRbtc` / `_withdrawStuckRbtc` / `PurchaseRbtc__rBtcRescued` are gone.
- [ ] No owner path can move another account’s rBTC.
- [ ] User withdraws still credit the signer only. No `to` on the ABI.
- [ ] Targeted tests above pass; `make check` passes.
- [ ] Protocol invariants in `AGENTS.md` unchanged (invariant 3 now matches the code).

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec does not change them; it removes the rescue that contradicted invariant 3).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies / failing-test fallout and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.

## ABI / deploy / cutover impact

- ABI: remove `withdrawStuckRbtc(address,address)` and `PurchaseRbtc__rBtcRescued`. No new functions. Do not add `to`.
- Scripts: none.
- Cutover: frontend / ops must not call `withdrawStuckRbtc`. Users who interacted from a contract that cannot receive native rBTC cannot have the owner redirect their accumulated rBTC; they must use an address that can receive value. Do not include broadcast steps.
