# R6 — Purchase hot-path cleanup (R6, R17)

Status: **not started** · Assigned: yes · Optional/further-review: no

## Objective

Trim gas-only early reverts on swapper purchase paths and drop `nonReentrant` where it is not protecting a native rBTC payout. Keep period, schedule-id, amount, lending-index, access-control, and malformed-calldata checks. Make `depositToken` / `updateDcaSchedule` pull tokens before crediting `tokenBalance`.

## Background

PR 6 bundles R6 and R17 because both are `DcaManager` hot-path / CEI cleanups. No product gates.

**R6:** `buyRbtc` / `batchBuyRbtc` are only called by the BitChill bot. Happy-path txs are well-formed, so checks that exist only to fail cheap before expensive handler work still cost gas on every successful purchase. Keep checks that revert when the bot’s calldata does not match the schedule it pointed at.

Do **not** skip scheduleId or period checks for gas. Without the period check, `periodsElapsed` can be 0 and a swapper can buy repeatedly in one block until the schedule is empty. R2 only changed *how* elapsed is computed.

| Check | Verdict |
|---|---|
| `onlySwapper` / `ReentrancyGuard` on rBTC withdraws | **Keep.** Access control / native payout. |
| Array length match (`buyers` / indexes / ids / amounts) | **Keep.** Calldata not constructed correctly. |
| `validateScheduleIndex` + `_validateScheduleId` | **Keep.** Index/id do not name the same schedule. |
| `purchaseAmounts[i] == schedule.purchaseAmount` | **Keep.** Swapper-supplied amount must match storage. |
| `lendingProtocolIndex == schedule.lendingProtocolIndex` | **Keep.** Wrong protocol would redeem the wrong handler. |
| Period elapsed | **Keep.** Protocol business logic. |
| `purchaseAmount > tokenBalance` before `tokenBalance -= purchaseAmount` | **Drop.** Solidity 0.8 already reverts on underflow. Extra comparison on every happy-path buy; only buys a custom error on the sad path. |
| `numOfPurchases == 0` | **Drop.** Bot never sends an empty batch; length-mismatch still covers malformed calldata. |
| Mixed tokens/lending protocols in one batch | **Already unchecked** as a batch-level rule. Per-item lending-index match (keep) is the real guard. Token is a single argument. |

**R17:** `nonReentrant` is not all needed and not all consistent. Handlers have no `ReentrancyGuard`. Only `DcaManager` does. OZ v4 costs about one extra SLOAD + two SSTOREs per call, once per tx.

| Function | Keep `nonReentrant`? |
|---|---|
| `withdrawRbtcFromTokenHandler` / `withdrawAllAccumulatedRbtc` | **Keep.** Native `user.call{value}`. Mapping is zeroed first (CEI); the guard still stops messy cross-function work during `receive`. |
| `buyRbtc` / `batchBuyRbtc` | **Drop.** `onlySwapper` + handler `onlyDcaManager`. Hottest path. |
| `depositToken` / `withdrawToken` / `deleteDcaSchedule` / interest withdraws | **Drop.** Listed stables are hookless (DOC, USDRIF). CEI already deducts before transfer on withdraw/delete. |
| `setPurchaseAmount` / `setPurchasePeriod` / owner setters | Already unguarded. |
| `createDcaSchedule` / `updateDcaSchedule` | **Already unguarded.** If the guard were required for deposits, create/update would be the hole. |

`depositToken` / `updateDcaSchedule` currently credit `tokenBalance` then `transferFrom`. `createDcaSchedule` already pulls then credits. `nonReentrant` on `depositToken` papers over that; `updateDcaSchedule` has the same order and no guard. Pull-then-credit is the real defense; listing a hook token is an admin decision.

## Open product decisions

**none**

## Scope

- [ ] **R6:** Remove `DcaManager__ScheduleBalanceNotEnoughForPurchase` and the explicit `purchaseAmount > tokenBalance` comparison in `_rBtcPurchaseChecksEffects`. Keep the subtraction (underflow reverts if the bot is wrong).

- [ ] **R6:** Remove `DcaManager__EmptyBatchPurchaseArrays` and the `numOfPurchases == 0` check. Keep `DcaManager__BatchPurchaseArraysLengthMismatch`.

- [ ] **R6:** Do **not** remove period, scheduleId, amount, or lending-index checks. Keep `onlySwapper`.

- [ ] **R6:** Cache `keccak256("SWAPPER")` in `DcaManager` so `onlySwapper` does not call `OperationsAdmin.SWAPPER_ROLE()` on every purchase. Still call `hasRole` on `OperationsAdmin`. The hash must match `OperationsAdmin` (`keccak256("SWAPPER")`).

- [ ] **R17:** Keep `nonReentrant` only on `withdrawRbtcFromTokenHandler` and `withdrawAllAccumulatedRbtc`. Remove it from `buyRbtc`, `batchBuyRbtc`, `depositToken`, `withdrawToken`, `deleteDcaSchedule`, `withdrawTokenAndInterest`, `withdrawAllAccumulatedInterest`. Keep `ReentrancyGuard` inheritance.

- [ ] **R17:** Make `depositToken` and `updateDcaSchedule` call `handler.depositToken` **before** increasing `tokenBalance`, same as `createDcaSchedule`. Do not add `nonReentrant` to create/update.

- [ ] Update tests that expect the custom balance/empty-batch errors (expect underflow / Panic(0x11) for oversize buys; drop dedicated empty-batch tests).

## Out of scope

- [ ] R18 packing, handler `batchBuyRbtc` `memory` → `calldata`, assembly.
- [ ] R8 `withdrawStuckRbtc` / `to` parameter.
- [ ] R19 pause, R9 event reshaping, R12/R13/optionals.
- [ ] Handler / accounting / SIP-0094 (R1, R20).
- [ ] Fee model / FeeHandler (R3–R5).
- [ ] Full natspec rewrite (R10). Opportunistic comment fixes on lines this PR already touches are fine.
- [ ] `forge fmt` of existing files.
- [ ] Deploy broadcasts or live addresses.
- [ ] `dca-out-contracts`.

## Files likely touched

- `src/DcaManager.sol`
- `src/interfaces/IDcaManager.sol`
- `test/unit/RbtcPurchaseTest.t.sol`
- `test/unit/StablecoinDepositTest.t.sol`
- `test/unit/DcaScheduleTest.t.sol`
- `test/ai-generated/unit/DcaManagerEdgeCasesTest.t.sol`
- `docs/relaunch/README.md` (assignment status)

Implementer may follow failing tests into `test/ai-generated/unit/RoleSecurityTest.t.sol`. Extra files belong in the PR write-up.

## Required tests

Commands (targeted first, then done-gate):

```bash
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus forge test --match-contract RbtcPurchaseTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus forge test --match-contract DcaManagerEdgeCasesTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus forge test --match-contract StablecoinDepositTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus forge test --match-contract DcaScheduleTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus forge test --match-contract RoleSecurityTest
make check
```

Behaviors to assert:

- Period / scheduleId / amount / lending-index mismatch still revert with the current custom errors (`testCannotBuyIfPeriodNotElapsed`, `testCannotBuyIfScheduleIdAndIndexMismatch`, purchase-amount mismatch, lending-index mismatch).
- Buying with `purchaseAmount > tokenBalance` still reverts (Solidity 0.8 underflow / Panic(0x11)); no `ScheduleBalanceNotEnoughForPurchase`.
- Empty `batchBuyRbtc` is no longer a dedicated `DcaManager` revert (delete or stop expecting `EmptyBatchPurchaseArrays`).
- Same-period second buy still reverts (`testCannotBuyIfPeriodNotElapsed`).
- `onlySwapper` still rejects non-swappers (`testOnlySwapperCanCallDcaManagerToPurchase` / RoleSecurity equivalents).
- `depositToken` / `updateDcaSchedule` still credit after a successful handler pull; a failed pull (no approval) still reverts without a lasting credit.
- `nonReentrant` remains only on the two rBTC withdraw functions (reviewer: inspect modifiers). `buyRbtc` / `batchBuyRbtc` have no reentrancy SSTOREs.

Fork tests: not required.

## Success criteria

- [ ] Period / scheduleId / amount / lending-index mismatch still revert with the current custom errors.
- [ ] Buying with `purchaseAmount > tokenBalance` still reverts (underflow); `DcaManager__ScheduleBalanceNotEnoughForPurchase` is gone.
- [ ] `DcaManager__EmptyBatchPurchaseArrays` is gone.
- [ ] `onlySwapper` uses a cached `keccak256("SWAPPER")` and still gates purchases.
- [ ] `nonReentrant` remains only on rBTC withdraws; `ReentrancyGuard` inheritance stays.
- [ ] `depositToken` / `updateDcaSchedule` call `handler.depositToken` before increasing `tokenBalance`.
- [ ] Existing CEI on withdraw/delete (deduct/pop, then transfer) unchanged.
- [ ] Targeted tests above pass; `make check` passes.
- [ ] Protocol invariants in `AGENTS.md` unchanged.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold (this spec does not change them).
- [ ] Tests in the PR match **Required tests**.
- [ ] Files beyond this list are limited to direct dependencies / failing-test fallout and are named in the PR.
- [ ] No unrelated refactors; history is reviewable.
- [ ] `_rBtcPurchaseChecksEffects` still enforces period, scheduleId, and the subtraction; it does not compare `purchaseAmount > tokenBalance`.
- [ ] `batchBuyRbtc` still checks array-length match, per-item amount, and per-item lending index.
- [ ] `buyRbtc` / `batchBuyRbtc` have no `nonReentrant`.

## ABI / deploy / cutover impact

- ABI: remove errors `DcaManager__ScheduleBalanceNotEnoughForPurchase` and `DcaManager__EmptyBatchPurchaseArrays`. Function selectors unchanged. Oversize buys revert with Panic(0x11) instead of the custom error. Empty batches no longer have a dedicated `DcaManager` error (handler may still revert if called).
- Scripts: none.
- Cutover: bot should not submit empty batches or empty schedules (already true). Frontends/indexers that keyed off the two removed errors should treat underflow / handler revert instead. Do not include broadcast steps.
