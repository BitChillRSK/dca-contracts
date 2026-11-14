# R6 — Purchase hot-path cleanup (R6, R17)

Status: **in progress** (GitHub #47, spec revision implemented) · Assigned: yes · Optional/further-review: no

## Objective

Trim `nonReentrant` and role-lookup overhead on the **purchase** hot path, without weakening diagnostic checks. Keep `nonReentrant` on every user-facing schedule mutator. Derive schedule ids from a monotonic nonce, not from array state. `depositToken` pulls before crediting. No post-pull id check.

## Revision note (supersedes the first pass)

PR #47 implemented the previous version of this spec. Review found the gas rationale was not measured and two of the arguments were wrong. This revision keeps the edits that pay, restores the ones that do not, and adds the fix the previous version believed it had already made.

### Third pass — what changed and why

The second pass tried to replace the guard on the deposit paths with a post-pull `scheduleId` re-validation. Two reviewers broke it:

1. **Ids are not unique.** `create,create,delete,create` inside one block reminted the survivor's id, so the post-pull check passed against a swap-popped schedule. `block.timestamp` is per *block*, so this needs no contract and no atomicity — four ordinary transactions in one RSK block suffice.
2. **The id check cannot see same-slot mutations.** A hook calling `withdrawToken` on the very slot being updated leaves the id unchanged, so no id check of any kind detects it. Demonstrated: balance 100 → user withdraws 100 mid-call → schedule still reports 125.
3. **A partial mutex protects nothing.** OZ's guard only blocks *other guarded* functions. Guarding `depositToken` and `deleteDcaSchedule` while leaving `updateDcaSchedule` unguarded left the original hole fully open, because entering an unguarded function engages no lock.

Chaining ids off the last element's id was also tried and also fails: swap-pop moves the last element into the deleted slot and makes the *second-to-last* element last again, rewinding the chain while the moved schedule stays live. `create A,B,C → delete index 0 → create D` reproduces C's id with C still in the array. **Any id derived from mutable array state is replayable.** Only a strictly increasing counter works.

Resolution: comprehensive mutex + monotonic nonce, and the post-pull id checks are removed as unreachable.

The gas case for keeping the user-path guards off never justified the analysis it required: ~2,300 gas ≈ 1.4 cents per user transaction, against three exploitable states found across three review rounds. The entire measured win — 3,437 gas — sits on `buyRbtc`/`batchBuyRbtc` and the `SWAPPER_ROLE` cache, which this decision does not touch.

An earlier pass also corrected that the swap-pop is self-desync / ledger mismatch on current lending handlers, not a live pool drain, and that a reentrancy test must delete the **same** slot being deposited into. The post-pull id check from that pass is gone (third pass).

### Measured cost of each edit

Method: cumulative single-edit builds off `fix/r3-fee-handling`, `SWAP_TYPE=mocSwaps LENDING_PROTOCOL=tropykus STABLECOIN_TYPE=DOC forge test --match-contract RbtcPurchaseTest --match-test testSinglePurchase`. Baseline 275,558 gas, full PR 272,078 gas — **3,480 gas total, 1.26%**.

| Edit | Gas / purchase | Share of total | Who pays |
|---|---:|---:|---|
| Drop `nonReentrant` on `buyRbtc` / `batchBuyRbtc` | 2,399 | 69% | protocol (bot) |
| Cache `SWAPPER_ROLE` | 1,038 | 30% | protocol (bot) |
| Drop `purchaseAmount > tokenBalance` check | 43 | 1.2% | protocol (bot) — **not taken**; diagnostic revert kept |
| Drop `numOfPurchases == 0` check | ~24 per batch tx | ~0% | protocol (bot) — **not taken**; diagnostic revert kept |
| Drop `nonReentrant` on user paths | ~2,300 per user tx | — | **not taken**; mutex stays |
| Reorder credit vs. pull | 0 | 0% | — |

The first two are **per transaction**, so in `batchBuyRbtc` they amortise across the batch: measured 1,038 per *batch call*, not per purchase. At batch size 50 the per-purchase saving falls to ~112 gas. Only the 43-gas balance check is per item.

At RSK ~0.06 gwei, 3,480 gas ≈ 2.1 × 10⁻⁷ rBTC per purchase. The two early-revert removals together are ≈ 2.6 × 10⁻⁹ rBTC per purchase.

### Two claims from the previous version that were wrong

**1. "`updateDcaSchedule` credits then pulls, same order as `depositToken`."** False. In `updateDcaSchedule`, `dcaSchedule` is a **memory** copy committed by `schedules[scheduleIndex] = dcaSchedule` at the end of the function. `dcaSchedule.tokenBalance += depositAmount` is a memory increment; the storage write was already after the interaction. Swapping those two lines is a no-op that no reentrant caller can observe. It is diff noise and is reverted below.

**2. "Pull-then-credit is the real defense, so the guard is not required."** Overstated. A *reverting* `transferFrom` rolls back a prior storage credit — that is ordinary CEI. A *succeeding* pull that fires a transfer hook can still observe mid-call state; CEI does not cover that. What actually stops a phantom credit from paying out **other users'** tokens today is that Tropykus and Sovryn **clamp** `withdrawToken` to the caller's lending position (`TropykusErc20Handler.sol:79-82`, `SovrynErc20Handler.sol:79-82`) instead of transferring the requested amount. Pull-then-credit on `depositToken` is still cheap and mildly preferable. It does not replace the user-path mutex.

### The defect the previous version missed

`updateDcaSchedule` takes a memory copy of the schedule **before** `handler.depositToken` and writes the whole struct back **after**. Neither it nor `createDcaSchedule` ever had `nonReentrant`, so this is pre-existing, not introduced by #47 — but #47 did not fix it either. With a callback-capable token:

1. User holds schedule A (index 0, balance 1000) and B (index 1).
2. `updateDcaSchedule(token, 0, idA, depositAmount = 1, …)` copies A into memory.
3. `handler.depositToken` pulls 1 token; a transfer hook fires.
4. The hook calls `deleteDcaSchedule(token, 0, idA)` — **the same index being updated**, not B. Delete pays out A's 1000 (`DcaManager.sol:270`), swap-pops B into index 0, and shortens the array.
5. The outer call resumes, sets the memory copy to 1001, and stamps A's stale struct over B. Index 0 is still in bounds, so nothing reverts.

What this does **not** do on current handlers: drain the pool. After the swap-pop, DcaManager shows 1001 while the user's lending shares still back B plus the 1 deposited — or, if the numbers do not line up, a later `withdrawToken` is clamped to the real position and the DcaManager ledger desyncs. That desync is **PR 8 / R20**, not R1. DOC and USDRIF have no transfer hooks, so this is not live.

It is still a stale write-back that can destroy B's identity and leave the caller's own schedules inconsistent. The third pass closes it with the comprehensive mutex (nested delete cannot run) and unique ids (even without a hook, `create,create,delete,create` no longer remints a live id). Post-pull id checks are not used. `updateDcaSchedule` keeps its memory-copy shape; do not refresh every field from storage.

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
| `buyRbtc` / `batchBuyRbtc` | **Drop.** `onlySwapper` + handler `onlyDcaManager`. Writes schedule state before the handler call. 69% of the saving. |
| `createDcaSchedule` / `depositToken` / `updateDcaSchedule` / `deleteDcaSchedule` / `withdrawToken` / `withdrawTokenAndInterest` / `withdrawAllAccumulatedInterest` / `setPurchaseAmount` / `setPurchasePeriod` | **Keep.** Comprehensive mutex (`AGENTS.md` invariant 6). A partial set protects nothing. |

## Open product decisions

**none**

## Scope

Items marked **(revert)** undo work already merged in #47.

- [x] **R6 (revert):** Restore `DcaManager__ScheduleBalanceNotEnoughForPurchase` and the `purchaseAmount > tokenBalance` comparison in `_rBtcPurchaseChecksEffects`, ahead of the subtraction. Restore the error to `IDcaManager`.

- [x] **R6 (revert):** Restore `DcaManager__EmptyBatchPurchaseArrays` and the `numOfPurchases == 0` check in `batchBuyRbtc`. Restore the error to `IDcaManager`.

- [x] **R6 (keep as implemented):** Cache `keccak256("SWAPPER")` in `DcaManager` so `onlySwapper` does not call `OperationsAdmin.SWAPPER_ROLE()` per purchase. Still call `hasRole` on `OperationsAdmin`. The hash must match `OperationsAdmin`.

- [x] **R6:** Do **not** remove period, scheduleId, amount, or lending-index checks. Keep `onlySwapper`.

- [x] **R17 (third pass):** Comprehensive mutex. `nonReentrant` on every external function that writes `s_dcaSchedules`: `createDcaSchedule`, `depositToken`, `updateDcaSchedule`, `deleteDcaSchedule`, `withdrawToken`, `withdrawTokenAndInterest`, `withdrawAllAccumulatedInterest`, `setPurchaseAmount`, `setPurchasePeriod` — plus the two rBTC withdraws. **Not** on `buyRbtc` / `batchBuyRbtc`: swapper-only, and verified to write nothing after their handler call. A partial set is worse than none, because OZ's guard only blocks other *guarded* functions.

- [x] **R17 (third pass):** Remove both post-pull `_validateScheduleId` calls. Unreachable under the mutex, and independently insufficient — blind to same-slot mutations that leave the id untouched.

- [x] **R17 (revert):** Restore the original line order in `updateDcaSchedule` — `dcaSchedule.tokenBalance += depositAmount;` before `_handler(...).depositToken(...)`. The storage commit was always after the interaction, so the reorder was unobservable.

- [x] **R17 (keep as implemented):** Leave `depositToken` pulling before it credits. Free, and it removes the phantom-credit window.

- [x] **New (third pass):** Derive schedule ids from a strictly increasing counter:

  ```solidity
  uint256 private s_scheduleNonce = 1;   // declaration initialiser: the 0 -> 1 SSTORE is paid at deploy
  ...
  bytes32 scheduleId = keccak256(abi.encodePacked(msg.sender, token, ++s_scheduleNonce));
  ```

  `block.timestamp` is constant within a block and every array-derived value is replayable through swap-pop, so a counter is the only sound source. Cost is one SSTORE on `createDcaSchedule`, which already exceeds 250k gas.

  Pre-increment saves 6 gas (251,303 vs 251,309). Nonce 1 is intentionally unused; `s_scheduleNonce - 1` remains the lifetime schedule count.

  `msg.sender` and `token` are not needed for uniqueness (the nonce alone is unique); they domain-separate ids and keep them opaque, so nothing downstream mistakes them for indices. They are **not** there for unpredictability: ids are consistency checks against `(index, id)`, never bearer capabilities, and every id is already public via `getDcaSchedules`. Do not start treating an id as an authorisation token.

- [x] **New (third pass):** `getSchedulesCreatedCount()` returning `s_scheduleNonce - 1` — the lifetime number of schedules created, never decremented by deletes. Intended use is an indexer cross-check: compare against the number of `DcaManager__DcaScheduleCreated` events ingested to detect missed events. Declared in `IDcaManager` alongside the other getters.

- [x] Tests: restore the two custom-error expectations; assert id uniqueness; add the swap-pop rewind regression; read ids from chain instead of recomputing the derivation.

- [x] `docs/relaunch/IMPLEMENTATION_ORDER.md`: PR 6 blurb, plus an idle-funds-handler heads-up under PR 8.

- [x] `AGENTS.md`: invariants 6 (comprehensive mutex) and 7 (nonce-derived ids).

## Out of scope

- [ ] R18 packing, handler `batchBuyRbtc` `memory` → `calldata`, assembly.
- [ ] R8 `withdrawStuckRbtc` / `to` parameter.
- [ ] R19 pause, R9 event reshaping, R12/R13/optionals.
- [ ] Handler / accounting / SIP-0094. The DcaManager-vs-handler ledger desync from the withdrawal **clamp** (DcaManager deducts the requested amount, handler pays `min(requested, lending position)`) is residual risk after this PR. It is **not** R1 (Sovryn `burn` return vs net payout). It belongs in **PR 8 / R20**: do not treat the requested withdraw amount as cash paid to the user; measure the user's token delta (or the handler's actual payout) and only then update `tokenBalance`. Named in `IMPLEMENTATION_ORDER.md` PR 8 so it cannot fall between R1 and R20.
- [ ] Refactoring `updateDcaSchedule` off its read-modify-write-back-whole-struct shape. The mutex closes the reachable damage; the shape itself is still fragile and is the reason the guard cannot be relaxed later without doing this first.
- [ ] Fee model / FeeHandler (R3–R5).
- [ ] Full natspec rewrite (R10). Opportunistic comment fixes on touched lines are fine.
- [ ] `forge fmt` of existing files.
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
- `docs/relaunch/IMPLEMENTATION_ORDER.md` (PR 6 blurb; PR 8 clamp-desync note; idle-handler heads-up)
- `AGENTS.md` (invariants 6 and 7)

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
- Wrong `scheduleId` on `depositToken` reverts with `DcaManager__ScheduleIdAndIndexMismatch`. That this check runs **before** `handler.depositToken` is inspection of source order (reverts are atomic). There is no post-pull id check.
- **Swap-pop, same index:** A mock token `transferFrom` re-enters `deleteDcaSchedule` on the **same** `scheduleIndex` being deposited into. Both `depositToken` and `updateDcaSchedule` revert `ReentrancyGuard: reentrant call`. No `tokenBalance` write-back. Last remaining schedule: same revert, both paths.
- **Unique ids:** `create,create,delete,create` in one block yields `idB != idC`. Swap-pop rewind (`create A,B,C`, delete index 0, create D) does not remint C's id.
- `nonReentrant` on every schedule mutator listed in Scope, plus both rBTC withdraws. Not on `buyRbtc` / `batchBuyRbtc` (reviewer: inspect modifiers).

Fork tests: not required.

## Success criteria

- [x] Both custom errors are present and asserted again.
- [x] `onlySwapper` uses the cached `keccak256("SWAPPER")`.
- [x] `nonReentrant` on every external `s_dcaSchedules` writer plus both rBTC withdraws; absent from `buyRbtc` / `batchBuyRbtc`. `ReentrancyGuard` inheritance stays.
- [x] No post-pull `_validateScheduleId` remains.
- [x] `updateDcaSchedule`'s memory increment still happens before `handler.depositToken` (same order as `fix/r3-fee-handling`).
- [x] Nested delete during `depositToken` and during `updateDcaSchedule` both revert `"ReentrancyGuard: reentrant call"`, in the same-index, last-index and reused-slot setups.
- [x] Schedule ids come from `s_scheduleNonce`; `create,create,delete,create` in one block yields distinct ids, and the swap-pop rewind sequence does not remint a live id.
- [x] Existing CEI on withdraw unchanged; delete still pops then withdraws.
- [x] Purchase-path gas preserved: `testSinglePurchase` 275,558 on `fix/r3-fee-handling` → 272,121 here (3,437 saved); `buyRbtc` max 244,164 → 240,727.
- [x] `make check` passes on all three lanes (405 tests each).
- [x] `AGENTS.md` invariants 1–5 unchanged; 6 and 7 added by this PR.

## Reviewer checklist

- [ ] Matches **Scope**; nothing from **Out of scope**.
- [ ] Protocol invariants in `AGENTS.md` still hold.
- [ ] Tests in the PR match **Required tests**, including same-index swap-pop (both deposit paths revert `ReentrancyGuard`), unique ids, and swap-pop rewind.
- [ ] No unrelated refactors; no line reordering without a stated, observable reason.
- [ ] `_rBtcPurchaseChecksEffects` enforces period, scheduleId, the balance comparison, and the subtraction.
- [ ] Every external function writing `s_dcaSchedules` has `nonReentrant`; `buyRbtc` / `batchBuyRbtc` do not (`AGENTS.md` invariant 6).
- [ ] No schedule id is derived from `block.timestamp` or array state anywhere in `src/` (`AGENTS.md` invariant 7).
- [ ] No post-pull `_validateScheduleId` remains — the mutex is the control, not an id check.
- [ ] `batchBuyRbtc` checks non-empty, array-length match, per-item amount, and per-item lending index.
- [ ] Does not claim this bug drains other users' principal on Tropykus/Sovryn (clamp).

## ABI / deploy / cutover impact

- ABI: add `getSchedulesCreatedCount() view returns (uint256)`. Both diagnostic errors stay; existing function selectors and event signatures unchanged. Schedule **id values** change (new derivation); they remain `bytes32`.
- Scripts: none — no script reconstructs a schedule id.
- **Cutover — schedule id derivation changed.** Ids are now `keccak256(user, token, nonce)` instead of `keccak256(user, token, block.timestamp, arrayLength)`. Any off-chain consumer that *recomputes* an id must instead read it from `getDcaSchedule` / `getDcaSchedules` or from the `DcaManager__DcaScheduleCreated` event. Consumers that already treat the id as an opaque value from events or getters need no change. No migration: fresh relaunch deployment, no existing schedules to re-key. This is the cheapest point to make this change — post-launch it would be a state migration.
- Frontends/indexers keyed on the two restored errors keep working. Do not include broadcast steps.
