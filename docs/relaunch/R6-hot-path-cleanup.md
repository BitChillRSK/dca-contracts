# R6 — Purchase hot-path cleanup (R6, R17)

Status: **in progress** (GitHub #47, spec revision implemented) · Assigned: yes · Optional/further-review: no

## Objective

Trim `nonReentrant` and role-lookup overhead that costs gas on every purchase and every user deposit/withdrawal, without weakening any check that has diagnostic or safety value. Close the stale write-back on `updateDcaSchedule` (and the post-#47 storage-pointer window on `depositToken`) with a targeted schedule-id re-validation, not a blanket guard.

## Revision note (supersedes the first pass)

PR #47 implemented the previous version of this spec. Review found the gas rationale was not measured and two of the arguments were wrong. This revision keeps the edits that pay, restores the ones that do not, and adds the fix the previous version believed it had already made.

A second pass (Cursor, this file) corrected three things in the first revision: the swap-pop is self-desync / ledger mismatch, not a live pool drain; the reentrancy test must delete the **same** slot being deposited into, not the “other” schedule; `depositToken` keeps the cheap pre-pull id check **and** re-validates after the pull.

### Measured cost of each edit

Method: cumulative single-edit builds off `fix/r3-fee-handling`, `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC forge test --match-contract RbtcPurchaseTest --match-test testSinglePurchase`. Baseline 275,558 gas, full PR 272,078 gas — **3,480 gas total, 1.26%**.

| Edit | Gas / purchase | Share of total | Who pays |
|---|---:|---:|---|
| Drop `nonReentrant` on `buyRbtc` / `batchBuyRbtc` | 2,399 | 69% | protocol (bot) |
| Cache `SWAPPER_ROLE` | 1,038 | 30% | protocol (bot) |
| Drop `purchaseAmount > tokenBalance` check | 43 | 1.2% | protocol (bot) |
| Drop `numOfPurchases == 0` check | ~24 per batch tx | ~0% | protocol (bot) |
| Drop `nonReentrant` on deposit / withdraw / delete / interest | ~2,300 per user tx | — | **users** |
| Reorder credit vs. pull | 0 | 0% | — |

The first two are **per transaction**, so in `batchBuyRbtc` they amortise across the batch: measured 1,038 per *batch call*, not per purchase. At batch size 50 the per-purchase saving falls to ~112 gas. Only the 43-gas balance check is per item.

At RSK ~0.06 gwei, 3,480 gas ≈ 2.1 × 10⁻⁷ rBTC per purchase. The two early-revert removals together are ≈ 2.6 × 10⁻⁹ rBTC per purchase.

### Two claims from the previous version that were wrong

**1. "`updateDcaSchedule` credits then pulls, same order as `depositToken`."** False. In `updateDcaSchedule`, `dcaSchedule` is a **memory** copy committed by `schedules[scheduleIndex] = dcaSchedule` at the end of the function. `dcaSchedule.tokenBalance += depositAmount` is a memory increment; the storage write was already after the interaction. Swapping those two lines is a no-op that no reentrant caller can observe. It is diff noise and is reverted below.

**2. "Pull-then-credit is the real defense, so the guard is not required."** Overstated. A *reverting* `transferFrom` rolls back a prior storage credit — that is ordinary CEI. A *succeeding* pull that fires a transfer hook can still observe mid-call state; CEI does not cover that. What actually stops a phantom credit from paying out **other users'** tokens today is that Tropykus and Sovryn **clamp** `withdrawToken` to the caller's lending position (`TropykusErc20Handler.sol:79-82`, `SovrynErc20Handler.sol:79-82`) instead of transferring the requested amount. Pull-then-credit on `depositToken` is still cheap and mildly preferable (no phantom credit, no clamp-induced DcaManager-vs-handler desync on that path). It cannot carry the weight of justifying the guard removals. The guard removals are justified separately: withdraw/delete are already CEI-clean, and deposit paths get the targeted id re-validation below.

### The defect the previous version missed

`updateDcaSchedule` takes a memory copy of the schedule **before** `handler.depositToken` and writes the whole struct back **after**. Neither it nor `createDcaSchedule` ever had `nonReentrant`, so this is pre-existing, not introduced by #47 — but #47 did not fix it either. With a callback-capable token:

1. User holds schedule A (index 0, balance 1000) and B (index 1).
2. `updateDcaSchedule(token, 0, idA, depositAmount = 1, …)` copies A into memory.
3. `handler.depositToken` pulls 1 token; a transfer hook fires.
4. The hook calls `deleteDcaSchedule(token, 0, idA)` — **the same index being updated**, not B. Delete pays out A's 1000 (`DcaManager.sol:270`), swap-pops B into index 0, and shortens the array.
5. The outer call resumes, sets the memory copy to 1001, and stamps A's stale struct over B. Index 0 is still in bounds, so nothing reverts.

What this does **not** do on current handlers: drain the pool. After the swap-pop, DcaManager shows 1001 while the user's lending shares still back B plus the 1 deposited — or, if the numbers do not line up, a later `withdrawToken` is clamped to the real position and the DcaManager ledger desyncs. That desync is **PR 8 / R20**, not R1. DOC and USDRIF have no transfer hooks, so this is not live.

It is still a stale write-back that can destroy B's identity and leave the caller's own schedules inconsistent. Fix it here because the extra array read is a few hundred gas on a non-hot path (measured ~281 on `updateDcaSchedule`, not ~100), and because leaving it makes "never list a hook-capable token" a security-critical invariant rather than a preference.

`depositToken` after #47 holds a **storage pointer** across the pull, then credits. The same swap-pop misattributes the deposit onto whichever schedule now sits in that slot (still the caller's). Re-validating `scheduleId` after the pull reverts instead.

`createDcaSchedule` pulls then pushes a **new** row. It has no write-back of a pre-call copy of an existing slot. No extra check there.

Same-id re-entrancy that does *not* change `scheduleId` (e.g. a hook `depositToken` or `setPurchaseAmount` on the same schedule) can still be clobbered by `updateDcaSchedule`'s stale memory copy. That is obscure self-grief. Out of scope: do not refresh every field from storage. The id check closes **swap-pop** (and the last-index shrink), not the stale-copy class as a whole.

## Background

PR 6 bundles R6 and R17 because both are `DcaManager` hot-path cleanups. No product gates.

`buyRbtc` / `batchBuyRbtc` are only called by the BitChill bot. Happy-path txs are well-formed, so checks that exist only to fail cheap still cost gas on every successful purchase — but only where that cost is real. A 43-gas check is not a hot-path cost; it is insurance that names the offending row when the bot is wrong, which is exactly the situation it exists for. Underfunding is also user-triggerable: any user can `withdrawToken` between the bot's off-chain read and execution.

Do **not** skip scheduleId or period checks for gas. Without the period check, `periodsElapsed` can be 0 and a swapper can buy repeatedly in one block until the schedule is empty.

| Check | Verdict |
|---|---|
| `onlySwapper` / `ReentrancyGuard` on rBTC withdraws | **Keep.** Access control / native payout. |
| Array length match (`buyers` / indexes / ids / amounts) | **Keep.** Calldata not constructed correctly. |
| `validateScheduleIndex` + `_validateScheduleId` | **Keep.** Index/id do not name the same schedule. |
| `purchaseAmounts[i] == schedule.purchaseAmount` | **Keep.** Swapper-supplied amount must match storage. |
| `lendingProtocolIndex == schedule.lendingProtocolIndex` | **Keep.** Wrong protocol would redeem the wrong handler. |
| Period elapsed | **Keep.** Protocol business logic. |
| `purchaseAmount > tokenBalance` before the subtraction | **Keep — reversal of previous verdict.** 43 gas (1.2%). Panic(0x11) names no buyer, scheduleId, or index, so a failed batch cannot be triaged without binary-searching it during an incident. |
| `numOfPurchases == 0` | **Keep — reversal of previous verdict.** ~24 gas per batch tx. Without it an empty batch reaches the handler and reverts `PurchaseRbtc__RbtcBatchPurchaseFailed`, reporting a swap failure for bad input. |
| Mixed tokens/lending protocols in one batch | **Already unchecked** as a batch-level rule. Per-item lending-index match is the real guard. |

**R17:** OZ v4 `nonReentrant` costs a measured 2,399 gas on `buyRbtc`. Handlers have no `ReentrancyGuard`; only `DcaManager` does.

| Function | Keep `nonReentrant`? |
|---|---|
| `withdrawRbtcFromTokenHandler` / `withdrawAllAccumulatedRbtc` | **Keep.** Native `user.call{value}`. |
| `buyRbtc` / `batchBuyRbtc` | **Drop.** `onlySwapper` + handler `onlyDcaManager`. 69% of the saving. |
| `withdrawToken` / `deleteDcaSchedule` / interest withdraws | **Drop.** Verified CEI-clean: each writes or pops its state before the handler call and holds no storage pointer or stale copy across it; `_withdrawInterest` writes no `DcaManager` state at all. |
| `depositToken` | **Drop, conditional on the re-validation scope item below.** |
| `createDcaSchedule` / `updateDcaSchedule` | **Already unguarded.** Fixed by the re-validation scope item, not by a new guard. |

## Open product decisions

**none**

## Scope

Items marked **(revert)** undo work already merged in #47.

- [x] **R6 (revert):** Restore `DcaManager__ScheduleBalanceNotEnoughForPurchase` and the `purchaseAmount > tokenBalance` comparison in `_rBtcPurchaseChecksEffects`, ahead of the subtraction. Restore the error to `IDcaManager`.

- [x] **R6 (revert):** Restore `DcaManager__EmptyBatchPurchaseArrays` and the `numOfPurchases == 0` check in `batchBuyRbtc`. Restore the error to `IDcaManager`.

- [x] **R6 (keep as implemented):** Cache `keccak256("SWAPPER")` in `DcaManager` so `onlySwapper` does not call `OperationsAdmin.SWAPPER_ROLE()` per purchase. Still call `hasRole` on `OperationsAdmin`. The hash must match `OperationsAdmin`.

- [x] **R6:** Do **not** remove period, scheduleId, amount, or lending-index checks. Keep `onlySwapper`.

- [x] **R17 (keep as implemented):** Keep `nonReentrant` only on `withdrawRbtcFromTokenHandler` and `withdrawAllAccumulatedRbtc`. Keep `ReentrancyGuard` inheritance. Do not add the modifier to create/update.

- [x] **R17 (revert):** Restore the original line order in `updateDcaSchedule` — `dcaSchedule.tokenBalance += depositAmount;` before `_handler(...).depositToken(...)`. Proven unobservable; reverting keeps the diff honest.

- [x] **R17 (keep as implemented):** Leave `depositToken` pulling before it credits. Free, and it removes the phantom-credit window.

- [x] **R17 (new — replaces the guard):** Re-validate the schedule id after every `handler.depositToken` call, so a swap-pop re-entrancy reverts instead of writing through a stale reference.

  In `depositToken`, **keep** the existing `_validateScheduleId` before the pull **and** re-validate after, through the same storage pointer, before crediting. Reverts are atomic, so post-pull-only would leave the same end state on a wrong-id call. Keeping both preserves today's cheap user-error path (fail before the handler) and keeps the post-pull check as the reentrancy guard. Extra SLOAD is on a user path, not the purchase hot path:

  ```solidity
  _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
  _handler(token, dcaSchedule.lendingProtocolIndex).depositToken(msg.sender, depositAmount);
  _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
  uint256 newTokenBalance = dcaSchedule.tokenBalance + depositAmount;
  dcaSchedule.tokenBalance = newTokenBalance;
  ```

  In `updateDcaSchedule` the memory copy predates the call, so after the pull read storage at `scheduleIndex` (measured ~281 gas for the length load + bounds check + SLOAD, only when `depositAmount > 0`):

  ```solidity
  if (depositAmount > 0) {
      dcaSchedule.tokenBalance += depositAmount;
      _handler(token, dcaSchedule.lendingProtocolIndex).depositToken(msg.sender, depositAmount);
      _validateScheduleId(scheduleId, schedules[scheduleIndex].scheduleId);
  }
  ```

  If the array shrank past `scheduleIndex`, the index read reverts on its own with Panic(0x32). If swap-pop placed another schedule in that slot, its `scheduleId` does not match and `_validateScheduleId` reverts. Either way the later `schedules[scheduleIndex] = dcaSchedule` must not run.

- [x] Tests: restore the two custom-error expectations; add coverage for the swap-pop re-validation (below).

- [x] `docs/relaunch/IMPLEMENTATION_ORDER.md` PR 6 blurb: match this revision (keep diagnostic purchase reverts; pull-then-credit on `depositToken` only; post-pull id check).

## Out of scope

- [ ] R18 packing, handler `batchBuyRbtc` `memory` → `calldata`, assembly.
- [ ] R8 `withdrawStuckRbtc` / `to` parameter.
- [ ] R19 pause, R9 event reshaping, R12/R13/optionals.
- [ ] Handler / accounting / SIP-0094. The DcaManager-vs-handler ledger desync from the withdrawal **clamp** (DcaManager deducts the requested amount, handler pays `min(requested, lending position)`) is residual risk after this PR. It is **not** R1 (Sovryn `burn` return vs net payout). It belongs in **PR 8 / R20**: do not treat the requested withdraw amount as cash paid to the user; measure the user's token delta (or the handler's actual payout) and only then update `tokenBalance`. Named in `IMPLEMENTATION_ORDER.md` PR 8 so it cannot fall between R1 and R20.
- [ ] Refreshing every `updateDcaSchedule` field from storage after the pull (same-id hook that changes amount/period). Id re-validation is the minimum that closes swap-pop.
- [ ] Fee model / FeeHandler (R3–R5).
- [ ] Full natspec rewrite (R10). Opportunistic comment fixes on touched lines are fine.
- [ ] `forge fmt` of existing files.
- [ ] Adding `nonReentrant` anywhere it is not already present.
- [ ] Asserting the cached `SWAPPER_ROLE` against `OperationsAdmin.SWAPPER_ROLE()`. A mismatch reverts every purchase loudly; both contracts are first-party.
- [ ] Deploy broadcasts or live addresses.
- [ ] `dca-out-contracts`.

## Files likely touched

- `src/DcaManager.sol`
- `src/interfaces/IDcaManager.sol`
- `test/mocks/MockReentrantStablecoin.sol` (new; hook-capable `transferFrom`. Existing mocks including `MockStablecoin` are hookless.)
- `test/unit/DepositSwapPopReentrancyTest.t.sol` (new; swap-pop coverage for `depositToken` and `updateDcaSchedule`)
- `test/unit/RbtcPurchaseTest.t.sol`
- `test/unit/StablecoinDepositTest.t.sol`
- `test/unit/DcaScheduleTest.t.sol`
- `test/ai-generated/unit/DcaManagerEdgeCasesTest.t.sol`
- `docs/relaunch/README.md` (assignment status)
- `docs/relaunch/IMPLEMENTATION_ORDER.md` (PR 6 blurb; PR 8 clamp-desync note)

## Required tests

```bash
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC forge test --match-contract RbtcPurchaseTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC forge test --match-contract DcaManagerEdgeCasesTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC forge test --match-contract StablecoinDepositTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC forge test --match-contract DcaScheduleTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC forge test --match-contract RoleSecurityTest
SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC forge test --match-contract DepositSwapPopReentrancyTest
make check
```

Behaviors to assert:

- Period / scheduleId / amount / lending-index mismatch still revert with their custom errors.
- Buying with `purchaseAmount > tokenBalance` reverts with `DcaManager__ScheduleBalanceNotEnoughForPurchase` carrying index, id, token, and balance — **not** Panic(0x11).
- Empty `batchBuyRbtc` reverts with `DcaManager__EmptyBatchPurchaseArrays`, not a handler error.
- Same-period second buy still reverts.
- `onlySwapper` still rejects non-swappers.
- `depositToken` / `updateDcaSchedule` still credit after a successful pull; a failed pull (no approval) reverts with no lasting credit.
- Wrong `scheduleId` on `depositToken` reverts with `DcaManager__ScheduleIdAndIndexMismatch`. Tests cannot tell pre-pull from post-pull-only (reverts are atomic). That the first check still runs **before** `handler.depositToken` is inspection of source order, not a test.
- **New — swap-pop, not “the other schedule”:** User has two schedules. A mock token `transferFrom` re-enters `deleteDcaSchedule` on the **same** `scheduleIndex` being deposited into (so delete swap-pops the other schedule into that slot). Both `depositToken` and `updateDcaSchedule` must revert on `_validateScheduleId`. No `tokenBalance` write-back. A test that deletes the *other* (last) schedule does **not** count: that pop leaves index 0 unchanged and would pass against #47 without the fix.
- **New — last remaining schedule:** User has one schedule. The hook deletes that same index (array length becomes 0). `depositToken` reverts `ScheduleIdAndIndexMismatch` (storage pointer reads a zeroed `scheduleId`). `updateDcaSchedule` reverts Panic(0x32) on `schedules[scheduleIndex]`. No write-back in either case.
- `nonReentrant` remains only on the two rBTC withdraw functions (reviewer: inspect modifiers).
- `depositToken` still has `_validateScheduleId` both before and after the pull (reviewer: inspect; not test-distinguishable from post-pull-only).

Fork tests: not required.

## Success criteria

- [x] Both custom errors are present and asserted again.
- [x] `onlySwapper` uses the cached `keccak256("SWAPPER")`.
- [x] `nonReentrant` remains only on rBTC withdraws; `ReentrancyGuard` inheritance stays.
- [x] `depositToken` validates the schedule id **before and after** the pull (inspection of source order for “before”); `updateDcaSchedule` re-reads storage and validates id after the pull.
- [x] `updateDcaSchedule`'s memory increment still happens before `handler.depositToken` (same order as `fix/r3-fee-handling`).
- [x] The swap-pop reentrancy test above fails against #47 as merged and passes after this change.
- [x] Last-index shrink: `depositToken` → `ScheduleIdAndIndexMismatch`; `updateDcaSchedule` → Panic(0x32).
- [x] Existing CEI on withdraw/delete unchanged.
- [x] Targeted tests pass; `make check` passes.
- [x] Protocol invariants in `AGENTS.md` unchanged.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**, including swap-pop of the **same** index (not delete-the-other-schedule) and last-index shrink.
- [ ] No unrelated refactors; no line reordering without a stated, observable reason.
- [ ] `_rBtcPurchaseChecksEffects` enforces period, scheduleId, the balance comparison, and the subtraction.
- [ ] `batchBuyRbtc` checks non-empty, array-length match, per-item amount, and per-item lending index.
- [ ] `buyRbtc` / `batchBuyRbtc` have no `nonReentrant`.
- [ ] No `handler.depositToken` call site writes through a reference obtained before it without re-validating the id.
- [ ] Does not claim this bug drains other users' principal on Tropykus/Sovryn (clamp).
- [ ] Pre-pull id check on `depositToken` is confirmed by reading the function, not by a test that cannot distinguish it from post-pull-only.

## ABI / deploy / cutover impact

- ABI: unchanged from `fix/r3-fee-handling`. Both errors stay; function selectors unchanged. (Relative to #47 as merged, this restores two errors.)
- Scripts: none.
- Cutover: none. Frontends/indexers keyed on the two errors keep working. Do not include broadcast steps.
