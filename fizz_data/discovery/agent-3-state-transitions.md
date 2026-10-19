# Agent 3 — State Transition Mapper: property list

Scope: operation postconditions and frame conditions, monotonicity, entity counts, state machines, and
temporal rules: cadence, the protected window, schedule pause, deposit pause, route and handler
assignment, swapper allowlist, Dex path state, and handler setting domains. Conservation identities
(CON-*, agent 1) and rounding or round trips (RT-*/RD-*, agent 2) are not repeated. Where a quantity
overlaps, this file checks *which* fields or flags an operation may touch and *when*, not the amounts.

Builds on `x-ray/invariants.md`: I-3, I-7, I-9, I-10, I-11, I-13 to I-19, G-1, G-2, G-3, G-4, G-5, G-10 to
G-16, G-21, G-33, G-34. These are excluded from SHOULD-HOLD, per section 5 of the context:
- I-4, I-6, I-8: a raised minimum, a raised minimum period or a lowered cap do not rewrite live schedules.
- I-12: a period cut can make a schedule due again.
- X-5: a revoked swapper's window and path survive the revocation.
- X-2/X-3: lending principal is nominal.

## Notation (reuses agent 1's: `routes[k]`, `ACCOUNTS`, `shares(a,h)`, `V(a,h)`, `claim(a,h)`, `rbtcAsset(h)`)

- `S(t,id)` = `dcaManager.getDcaSchedule(t,id)`. Read inside try/catch: it reverts `InexistentSchedule` for a dead key.
  Fields: `{tokenBalance, cadenceAnchor, paused, purchasePeriod, routeIndex, user, purchaseAmount}`.
- `dayStart(ts)` = `ts - ts % 1 days`. `today` = `dayStart(block.timestamp)`.
- `specDue(s)` = `s.cadenceAnchor == 0 || today >= s.cadenceAnchor + s.purchasePeriod`. This is AUDIT_GUIDE's rule
  ("Eligibility starts at 00:00 UTC on the due day"), restated from the spec and not copied from the code.
- `ids(a,t)` = `dcaManager.getDcaSchedules(a,t).scheduleIds`.
- `unlock` = `dcaManager.getUserMutationsAllowedFromBlock()`. `windowLive` = `block.number < unlock`.
- `GUARDED` = {updatePurchaseAmount, updatePurchasePeriod, setSchedulePaused, deleteDcaSchedule, withdrawToken,
  withdrawTokenAndInterest, withdrawAllAccumulatedInterest} (AGENTS.md invariant 10).
- `UNGUARDED_USER` = {createDcaSchedule, depositToken, topUpFromInterest, withdrawAllAccumulatedRbtc (incl. `_asCollector`)}.
- `path0` = `abi.encodePacked(token, uint24(3000), wrbtc)`; `path1` = `abi.encodePacked(token, uint24(500), usdt0, uint24(3000), wrbtc)`
  for the Dex handler's stablecoin `token` (= usdrif). The harness `_path(seed)` only ever produces these two.
- `sel(err)` = `bytes4(err)` of a caught revert.

## Harness additions these properties need

1. **try/catch wrappers.** Convert each unclamped `dcaManager_*` wrapper to `try … { post-checks } catch (bytes memory err)
   { _checkRevertScope(OP, err); }`. Do the same for the `vm.prank` collector claim and the Dex `setPurchasePath`
   wrapper. On success, run the SPECIFIC postconditions. On failure, run the selector checks of ST-10, ST-12 and ST-08.
   Keep the existing tracking updates (`_trackSchedule` / `_untrackSchedule`) in the success branch only.
2. **Batch pre-snapshot** inside `dcaManager_batchBuyRbtc` / `dcaManager_batchBuyRbtcAcrossHandlers` (agent 2 asks for
   the same funnel). Take a full `S(t,id)` copy for every row (and every tracked schedule), plus `today` and
   `block.number`.
3. **Single-row probe handler** `probe_buyOne(uint256 scheduleSeed)` (for ST-08). It picks any tracked schedule
   whose `specDue`, `!paused` and `purchaseAmount <= tokenBalance` hold, and sends a one-row batch with
   `minRbtcOut = 0`.
4. **Optional raw-governance handlers** (for ST-18). `operationsAdmin_assignHandler_raw(routeSeed, handlerSeed)` and
   `operationsAdmin_registerRoute_raw(index, lends)` run as admin and target existing pairs, existing indexes or
   other deployed handlers. Without them ST-18 is static in this harness.

## Ghosts needed (Base.sol `Ghosts`, storage struct)

```
// schedule lifecycle
uint64[]  deletedIds; address[] deletedTokens;                 // appended on successful delete
uint64    maxIdSeen;                                           // max id ever returned by a successful create
// cadence
mapping(address => mapping(uint64 => uint256)) buyDay;         // dayStart of the last successful buy
mapping(address => mapping(uint64 => uint256)) buysOnDay;      // buys on buyDay (reset to 0 when the day changes)
mapping(address => mapping(uint64 => uint256)) editDay;        // dayStart of the last successful updatePurchasePeriod
mapping(address => mapping(uint64 => uint256)) editsOnDay;     // period edits on editDay
// window
uint256 winUnlock;                                             // unlock value recorded at the last successful activation
DcaSchedule[] winSnap; address[] winSnapToken; uint64[] winSnapId;    // every tracked schedule at activation
mapping(address => mapping(uint64 => uint256)) winBatchDebit;  // Σ purchaseAmount debited by batches since activation
mapping(address => mapping(address => uint256)) winShareSnap; // shares(a,h) at activation, lending handlers
mapping(address => mapping(address => uint256)) winShareBatchDebit; // shares(a,h) drop inside batches since activation
// loss flag (shared with agent 1)
bool sovrynPriceEverFell;                                      // set in env_moveSovrynPrice when !up && delta>0
```

## Snapshot fields needed (Snapshots.sol `State`)

- A full `S(t,id)` for every tracked schedule, plus the tracked list itself (copied).
- `ids(a,t)` for every actor and both tokens.
- `getSchedulesCreatedCount()`, `unlock`, `block.number`, `block.timestamp`.
- `getMinPurchasePeriod()`, `getMaxSchedulesPerToken()`, `getTokenMinPurchaseAmount(doc|usdrif)`.
- `operationsAdmin.isSwapper(swappers[i])`, and `areDepositsPaused` / `getHandler` / `getRouteClass` for every `routes[k]`.
- Per Dex handler: `getSwapPath()`, `isPurchasePathAllowed(keccak(path0|path1))`, `getAmountOutMinimumPercent()`,
  `getAmountOutMinimumSafetyCheck()` and `getMocOracle()`.
- Per handler: `getFeeSettings()` and `getFeeCollector()`.
- Per lending handler: `shares(a,h)` for `ACCOUNTS`. Per handler: `claim(a,h)` for `ACCOUNTS`.

---

## State transitions and postconditions

PROPERTY_ID: [ST-01]
TYPE: SPECIFIC (after a successful `createDcaSchedule`, clamped or raw)
ENGLISH: Creation assigns the next nonce as the id and nothing else moves the nonce. The new key was empty before the call. The stored schedule equals the arguments, with anchor 0 and not paused. The id is appended to the end of the caller's list for that token, and no other schedule or list changes.
SOLIDITY_SKETCH:
```
uint64 id = uint64(dcaManager.getSchedulesCreatedCount());
assertEq(id, before.nonce + 1);
assertGt(id, ghosts.maxIdSeen); ghosts.maxIdSeen = id;
// key empty before: id was never tracked or deleted (true by construction because id > maxIdSeen)
DcaSchedule s = S(token,id);
assertEq(s.tokenBalance, depositAmount); assertEq(s.purchaseAmount, purchaseAmount);
assertEq(s.purchasePeriod, purchasePeriod); assertEq(s.routeIndex, routeIndex);
assertEq(s.user, actor); assertEq(s.cadenceAnchor, 0); assertFalse(s.paused);
uint64[] L = ids(actor,token); assertEq(L.length, before.ids(actor,token).length + 1); assertEq(L[L.length-1], id);
for i < L.length-1: assertEq(L[i], before.ids(actor,token)[i]);          // prefix unchanged
for every other (a,t) list and every other tracked schedule: unchanged (full struct)
// nonce frame (GLOBAL edge): after any non-create call, getSchedulesCreatedCount() == before.nonce
```
GHOST_NEEDS: maxIdSeen
SNAPSHOT_NEEDS: nonce; ids(a,t) for all a,t; full S for every tracked schedule
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: IDcaManager.createDcaSchedule: "Ids are the creation nonce, starting at 1". AGENTS.md inv. 7: "`createDcaSchedule` pre-increments `scheduleNonce` … Only a strictly increasing counter is safe". DcaManager.sol:157: "A new id addresses empty storage, so the zero cadence anchor and paused flag are left unset". x-ray I-9.
RATIONALE: Catches a nonce that skips, repeats or moves on another path. Also catches a new schedule inheriting stale anchor or pause state, and a push that lands anywhere but the end.

PROPERTY_ID: [ST-02]
TYPE: SPECIFIC (after a successful `deleteDcaSchedule`)
ENGLISH: Deletion makes the key read as nonexistent and swap-pops the caller's list. The id at `scheduleIdIndex` is replaced by the former last id (unless it was last) and the length falls by one. No other list position, schedule, nonce, rBTC claim or other user's state changes.
SOLIDITY_SKETCH:
```
try dcaManager.getDcaSchedule(token,id) { fail("ST-02 deleted key still live"); } catch (bytes memory e) { assertEq(sel(e), InexistentSchedule.selector); }
uint64[] B = before.ids(actor,token); uint64[] A = ids(actor,token);
assertEq(A.length, B.length - 1);
for i < A.length: assertEq(A[i], i == idx ? B[B.length-1] : B[i]);
assertEq(getSchedulesCreatedCount(), before.nonce);
for every other tracked schedule: full struct unchanged;
for h: assertEq(claim(actor,h), before.claim(actor,h));      // NatSpec: rBTC is not claimed by delete
ghosts.deletedIds.push(id); ghosts.deletedTokens.push(token);
```
GHOST_NEEDS: deletedIds, deletedTokens
SNAPSHOT_NEEDS: ids(a,t); nonce; full S of tracked schedules; claim(actor,h)
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: IDcaManager.deleteDcaSchedule: "Clears the schedule and swap-pops its id out of the owner's list … the id is retired rather than reused … Accumulated rBTC and lending interest are not claimed here". G-20.
RATIONALE: Swap-pop is the only list mutation. If the wrong slot moves, `_lockedPrincipal` (interest) and the per-user cap read a corrupted set. A partial `delete` would leave a resurrectable record.

PROPERTY_ID: [ST-03]
TYPE: GLOBAL + SPECIFIC (after every successful raw schedule mutator or batch)
ENGLISH: A retired id never comes back. Every deleted `(token,id)` still reads as nonexistent, and no list holds an id above the nonce or an id that was deleted. No user mutator or batch row ever succeeds on a key that is not a live schedule. Mutators additionally require that key to be owned by the caller.
SOLIDITY_SKETCH:
```
// GLOBAL
for k in deletedIds: try getDcaSchedule(deletedTokens[k], deletedIds[k]) { fail("ST-03 resurrected"); } catch {}
for a, t: for id in ids(a,t): assertLte(id, getSchedulesCreatedCount()); assertTrue(!isDeleted(t,id));
// SPECIFIC: raw depositToken / update* / setSchedulePaused / withdraw* / topUp success
assertTrue(isTracked(token,id) && trackedOwner(token,id) == actor, "ST-03 mutated foreign or dead key");
// SPECIFIC: successful batch (raw batches can name arbitrary ids and tokens)
for row in batch: assertTrue(isTracked(batch.token,row));
```
GHOST_NEEDS: deletedIds, deletedTokens
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: G-4 (`_callersSchedule` reverts on zero owner or non-owner). DcaManager.sol:531 (batch reverts on a zero buyer). IDcaManager.deleteDcaSchedule: "the id is retired rather than reused". AGENTS.md inv. 7 and 8.
RATIONALE: The raw handlers feed arbitrary `(token,id)` pairs, including ids of the other stablecoin and deleted ids. This is the state-machine edge "Deleted → anything" and it must not exist.

PROPERTY_ID: [ST-04]
TYPE: SPECIFIC (after each successful user mutator)
ENGLISH: Each user mutator writes only the field it names, on the one schedule it names.
- `depositToken`, `withdrawToken`, `withdrawTokenAndInterest`, `topUpFromInterest`: `tokenBalance` only.
- `updatePurchaseAmount`: `purchaseAmount` only. The value written is within [token minimum, `tokenBalance`].
- `updatePurchasePeriod`: `purchasePeriod` only, and `cadenceAnchor` is unchanged. The value written is a whole number of days and at least the current minimum.
- `setSchedulePaused`: `paused` only.

`user` and `routeIndex` never change for any live schedule. `topUpFromInterest` and `withdrawTokenAndInterest` succeed only on lending routes.
SOLIDITY_SKETCH:
```
DcaSchedule b = before.S(token,id), a = S(token,id);
assertEq(a.user, b.user); assertEq(a.routeIndex, b.routeIndex);
if (op ∈ {deposit, withdraw, withdrawTokenAndInterest, topUp}):
    assertEq(a.cadenceAnchor,b.cadenceAnchor); assertEq(a.paused,b.paused); assertEq(a.purchasePeriod,b.purchasePeriod); assertEq(a.purchaseAmount,b.purchaseAmount);
    if (op ∈ {topUp, withdrawTokenAndInterest}) assertTrue(_routeOf(token, b.routeIndex).lending);
if (op == updatePurchaseAmount):
    assertEq(a.purchaseAmount, newAmount); assertGe(newAmount, getTokenMinPurchaseAmount(token)); assertLe(newAmount, a.tokenBalance);
    other 6 fields equal b
if (op == updatePurchasePeriod):
    assertEq(a.purchasePeriod, newPeriod); assertEq(newPeriod % 1 days, 0); assertGe(newPeriod, getMinPurchasePeriod());
    assertEq(a.cadenceAnchor, b.cadenceAnchor, "ST-04 period edit moved the anchor"); other fields equal b
    // ghost: if (editDay != today) { editDay = today; editsOnDay = 0; } editsOnDay++
if (op == setSchedulePaused): assertEq(a.paused, requested); other fields equal b
for every other tracked schedule (same owner included): full struct unchanged
```
GHOST_NEEDS: editDay, editsOnDay (consumed by ST-07)
SNAPSHOT_NEEDS: full S of every tracked schedule; token minimum; min period
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE:
- IDcaManager: "Replace the periodic purchase amount", "Replace the purchase period", "Pause or resume rBTC purchases".
- AUDIT_GUIDE: "A period edit does not move the anchor".
- AGENTS.md inv. 9: "no setter can change a schedule's route".
- G-7, G-8, G-21.
RATIONALE: These frame conditions are the state-machine half of agent 1's amount checks. One field written by the wrong mutator would make an edit silently change cadence, pause state or route. A period edit that rebased the anchor would change the documented re-due semantics.

PROPERTY_ID: [ST-05]
TYPE: SPECIFIC (after every successful non-schedule call)
ENGLISH: Calls that do not name a schedule change no schedule field and no id list. These calls are:
- the DcaManager governance setters (`dcaManager_secondary`);
- every OperationsAdmin call;
- every handler setter (`layerBankHandlerDex_secondary`);
- every `env_*` call;
- `activateProtectedPurchaseWindow`;
- `withdrawAllAccumulatedRbtc` (both wrappers);
- `withdrawAllAccumulatedInterest`.
SOLIDITY_SKETCH:
```
for every tracked schedule: assertEq(abi.encode(S_after), abi.encode(S_before), "ST-05 schedule rewritten");
for a, t: assertEq(keccak(abi.encode(ids_after(a,t))), keccak(abi.encode(ids_before(a,t))));
assertEq(getSchedulesCreatedCount(), before.nonce);
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: full S of tracked schedules; ids(a,t); nonce
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: Context §5 and x-ray I-4/I-6/I-8: governance changes "do not rewrite existing schedules". Context §4: `tokenBalance` is "written by create, deposit, purchase debit, withdraw, top-up" only. IDcaManager.topUpFromInterest NatSpec contrasts it with interest withdrawal, which only touches the handler.
RATIONALE: Governance and environment moves (cap to 0, min-period raise, price crashes, deposit pause) must not reach into schedules. An interest withdrawal must not lower principal: X-6 depends on it.

PROPERTY_ID: [ST-06]
TYPE: SPECIFIC (after a successful `batchBuyRbtc` / `batchBuyRbtcAcrossHandlers`, every variant including raw)
ENGLISH: A successful batch only ever buys rows that exist under `batch.token`, belong to `batch.routeIndex`, are not paused, were due by the spec rule, and appear once. For each row, the anchor moves to the newest due slot on the existing grid: today if it was 0, otherwise `old + k*period` with `k >= 1`. After the buy the row is not due again today. Only `tokenBalance` and `cadenceAnchor` change, and only for rows of this batch.
SOLIDITY_SKETCH:
```
for each Batch bt, for row id (pre-snapshot b = S(bt.token,id) before the call, a = S after):
  assertTrue(isTracked(bt.token,id)); assertEq(b.routeIndex, bt.routeIndex); assertFalse(b.paused);
  assertTrue(specDue(b)); assertTrue(id appears once in bt.scheduleIds);
  if (b.cadenceAnchor == 0) assertEq(a.cadenceAnchor, today);
  else { assertGt(a.cadenceAnchor, b.cadenceAnchor); assertEq((a.cadenceAnchor - b.cadenceAnchor) % b.purchasePeriod, 0); }
  assertLe(a.cadenceAnchor, today); assertGt(a.cadenceAnchor + b.purchasePeriod, today);   // newest slot, not due again
  assertEq(a.purchaseAmount,b.purchaseAmount); assertEq(a.purchasePeriod,b.purchasePeriod); assertEq(a.paused,b.paused);
  assertEq(a.user,b.user); assertEq(a.routeIndex,b.routeIndex);
  // ghost (ST-07): if (buyDay != today) { buyDay = today; buysOnDay = 0; } buysOnDay++
  // ghost (ST-11): if (windowLive at call) winBatchDebit[token][id] += b.purchaseAmount
for tracked schedules not in any row: cadenceAnchor, paused, purchaseAmount, purchasePeriod unchanged
```
GHOST_NEEDS: buyDay, buysOnDay, winBatchDebit
SNAPSHOT_NEEDS: batch pre-snapshot (full S per row and per tracked schedule), block.timestamp
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE:
- AUDIT_GUIDE §Scheduling: "that purchase establishes the cadence at the current UTC midnight … A successful purchase consumes the newest due slot and all earlier missed slots. Missed purchases are not caught up".
- IDcaManager.batchBuyRbtc: "Any paused row fails the whole batch … rows cannot cross handlers".
- G-12, G-13, G-15; x-ray I-10.
RATIONALE: This is the core state-machine edge of a schedule. It catches an off-by-one on the due day, a rebased grid, catch-up buying, a paused or cross-route row that slips through, and a duplicate row in a raw batch.

PROPERTY_ID: [ST-07]
TYPE: GLOBAL (via ghosts updated in ST-04 and ST-06)
ENGLISH: A schedule buys at most once per UTC day, plus at most one extra buy for each period edit made on it that same day. With no period edit that day the bound is exactly one.
SOLIDITY_SKETCH:
```
for every tracked (t,id) with ghosts.buyDay[t][id] == today:
  uint edits = ghosts.editDay[t][id] == today ? ghosts.editsOnDay[t][id] : 0;
  assertLe(ghosts.buysOnDay[t][id], 1 + edits, "ST-07 extra same-day purchase");
```
GHOST_NEEDS: buyDay, buysOnDay, editDay, editsOnDay
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE: "While its period is unchanged, a schedule cannot purchase twice in one UTC day, even after a long gap … That second purchase re-anchors on today, so the edit yields one extra purchase, not a loop." x-ray I-11. The accepted I-12 re-due is allowed for by the `+ edits` term, so this does not contradict §5.
RATIONALE: This is the temporal rule that bounds how fast a swapper can spend a schedule. The `+edits` slack accepts I-12 exactly and no more, so a re-due loop without new edits would still fail.

PROPERTY_ID: [ST-08]
TYPE: SPECIFIC (failure branch of every batch wrapper, and `probe_buyOne`)
ENGLISH: The contract's cadence, pause and balance refusals agree exactly with the spec predicate.
- A `CannotBuyIfPurchasePeriodHasNotElapsed(token,id,timeRemaining)` revert names a row that is not due by the spec, and `0 < timeRemaining <= period`.
- `SchedulePaused` names a paused row, and `ScheduleBalanceNotEnoughForPurchase` names a row with `purchaseAmount > tokenBalance`.
- A single-row batch of a spec-due, unpaused, funded schedule never fails with any of those three errors, nor with `InexistentSchedule` or `RouteIndexMismatch`.
SOLIDITY_SKETCH:
```
catch (bytes memory err):
  if (sel(err) == CannotBuy.selector) { (t,id,rem) = decode(err); b = pre.S(t,id);
      assertFalse(specDue(b)); assertGt(rem, 0); assertLe(rem, b.purchasePeriod); }
  if (sel(err) == SchedulePaused.selector)   { (t,id) = decode(err); assertTrue(pre.S(t,id).paused); }
  if (sel(err) == BalanceNotEnough.selector) { (t,id,bal) = decode(err); assertGt(pre.S(t,id).purchaseAmount, bal); }
// probe_buyOne: row r with specDue && !paused && purchaseAmount <= tokenBalance, minRbtcOut 0
  catch (err): assertTrue(sel(err) ∉ {CannotBuy, SchedulePaused, BalanceNotEnough, InexistentSchedule, RouteIndexMismatch},
                          "ST-08 due schedule refused by DcaManager");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: batch pre-snapshot
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: IDcaManager.batchBuyRbtc: "Eligibility starts at 00:00 UTC on the due day, leaving that day for retries." AUDIT_GUIDE: "All transactions included within a due UTC day are equivalent for cadence". G-12, G-13, G-14.
RATIONALE: ST-06 shows that every buy was allowed. This property shows the converse, liveness: a due schedule is never refused at any second of its due day. `timeRemaining` is computed `unchecked`, so an anchor off the midnight grid would show up as an underflowed value.

PROPERTY_ID: [ST-09]
TYPE: SPECIFIC (after a successful `activateProtectedPurchaseWindow`; failure branch too)
ENGLISH: Activation succeeds only when no window is live. It sets the unlock block to exactly `block.number + 5`. A failed activation while a window is live leaves the unlock block unchanged and reverts with `ProtectedPurchaseWindowStillActive`, so a live window can never be extended or renewed early.
SOLIDITY_SKETCH:
```
success: assertGe(block.number, before.unlock, "ST-09 extended a live window");
         assertEq(unlock, block.number + 5); assertFalse(dcaManager.canActivateProtectedPurchaseWindow());
         ghosts.winUnlock = unlock; snapshot every tracked schedule into winSnap; winShareSnap = shares(a,h); clear winBatchDebit / winShareBatchDebit
failure: if (block.number < before.unlock && isSwapper(swapper)) assertEq(sel(err), ProtectedPurchaseWindowStillActive.selector);
         assertEq(unlock, before.unlock);
```
GHOST_NEEDS: winUnlock, winSnap*, winShareSnap, winBatchDebit, winShareBatchDebit
SNAPSHOT_NEEDS: unlock, block.number
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AGENTS.md inv. 10: "An active window cannot be extended or renewed early"; IDcaManager.activateProtectedPurchaseWindow: "A live window cannot be extended; after expiry another may begin." G-3, x-ray I-13.
RATIONALE: A renewable window would let a swapper hold user exits locked indefinitely without fresh activations.

PROPERTY_ID: [ST-10]
TYPE: SPECIFIC (every GUARDED and UNGUARDED_USER wrapper, success and failure branches)
ENGLISH: The window gates exactly the seven guarded calls, and only between activation block N and block N+4.
- A successful guarded call happens only at `block.number >= unlock`.
- A guarded call at `block.number < unlock` reverts with `UserMutationsLocked`.
- Neither guarded calls at `block.number >= unlock` nor any unguarded user call, batch or governance setter ever revert with `UserMutationsLocked`.
SOLIDITY_SKETCH:
```
if (op ∈ GUARDED) {
  success: assertGe(block.number, unlock, "ST-10 guarded call inside window");
  failure: if (block.number < unlock) assertEq(sel(err), UserMutationsLocked.selector);   // lock is checked first (modifier order)
           else assertNotEq(sel(err), UserMutationsLocked.selector);
} else {
  failure: assertNotEq(sel(err), UserMutationsLocked.selector, "ST-10 window blocks an open call");
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: unlock, block.number
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AGENTS.md inv. 10: "Activation in block `N` blocks exactly `updatePurchaseAmount`, … and `withdrawAllAccumulatedInterest` through `N + 4`; those calls resume at `N + 5`. Deposits, creation, interest top-ups, accumulated-rBTC withdrawals, purchases, reads, and governance setters stay open, and purchases never require activation." AUDIT_GUIDE repeats it.
RATIONALE: Both directions matter. A missing guard lets users invalidate a refreshed batch. A guard on an open call (for example purchases or rBTC claims) is a liveness bug. The assertion that the guarded call reverts with `UserMutationsLocked` first relies on `whenUserMutationsAllowed` running before ownership checks (DcaManager.sol:182).

PROPERTY_ID: [ST-11]
TYPE: GLOBAL (checked while `windowLive && ghosts.winUnlock == unlock`)
ENGLISH: While a window is live, the batch-relevant state captured at activation is frozen except for purchases.
- Every schedule that existed at activation still exists, with the same `purchaseAmount`, `purchasePeriod`, `paused`, `user` and `routeIndex`.
- Its `tokenBalance` is at least its activation value minus what batches debited from it in the window.
- On lending handlers, every account's virtual shares are at least their activation value minus what batches burned from it.

Deposits, creations and top-ups may only add.
SOLIDITY_SKETCH:
```
if (block.number < unlock && unlock == ghosts.winUnlock):
  for k in winSnap: DcaSchedule a = S(winSnapToken[k], winSnapId[k]);   // must not revert
     assertEq(a.purchaseAmount, winSnap[k].purchaseAmount); assertEq(a.purchasePeriod, winSnap[k].purchasePeriod);
     assertEq(a.paused, winSnap[k].paused); assertEq(a.user, winSnap[k].user); assertEq(a.routeIndex, winSnap[k].routeIndex);
     assertGe(a.tokenBalance + ghosts.winBatchDebit[t][id], winSnap[k].tokenBalance);
  for a ∈ ACCOUNTS, lending h: assertGe(shares(a,h) + ghosts.winShareBatchDebit[a][h], ghosts.winShareSnap[a][h]);
```
GHOST_NEEDS: winUnlock, winSnap*, winBatchDebit, winShareSnap, winShareBatchDebit (updated in batch wrappers from pre/post shares)
SNAPSHOT_NEEDS: none (ghost-based)
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: DcaManager header: "A swapper can open a self-expiring five-block window that blocks only user mutations capable of invalidating a batch refreshed after activation." AGENTS.md inv. 10 (the bot "refreshes or simulates from the locked state"). AUDIT_GUIDE: the window "blocks only schedule edits/deletion and stablecoin/interest withdrawals".
RATIONALE: This is the whole point of the window, stated as a state property rather than per-call. It catches any unguarded path that can delete, pause, edit or drain a schedule or its shares mid-window, such as a reentrant path, a topUp side effect or an interest path reachable from an unguarded call.

PROPERTY_ID: [ST-12]
TYPE: SPECIFIC (failure branch of every wrapper)
ENGLISH: Each refusal is raised only by the operations documented to raise it.
- `SchedulePaused` comes only from batches.
- `DepositsPaused` comes only from create and deposit.
- `UnauthorizedSwapper` comes only from window activation and batches.
- `ProtectedPurchaseWindowStillActive` comes only from activation.
- `withdrawAllAccumulatedInterest` never reverts with `TokenIsNotLent` or `TokenNotAccepted`: idle and unassigned pairs are skipped.
- `withdrawAllAccumulatedRbtc` never reverts with `NoAccumulatedRbtcToWithdraw`: zero-balance pairs are skipped.
SOLIDITY_SKETCH:
```
bytes4 s = sel(err);
if (s == SchedulePaused.selector)   assertTrue(op ∈ {batch, batchAcross, probe_buyOne});
if (s == DepositsPaused.selector)   assertTrue(op ∈ {create, deposit});
if (s == UnauthorizedSwapper.selector) assertTrue(op ∈ {activate, batch, batchAcross});
if (s == WindowStillActive.selector) assertTrue(op == activate);
if (op == withdrawAllAccumulatedInterest) assertTrue(s != TokenIsNotLent.selector && s != TokenNotAccepted.selector);
if (op ∈ {withdrawAllAccumulatedRbtc, _asCollector}) assertTrue(s != PurchaseRbtc__NoAccumulatedRbtcToWithdraw.selector);
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE:
- IDcaManager.setSchedulePaused: "A paused schedule … stays open to deposits, amount and period edits, withdrawals, interest and rBTC claims, and deletion".
- IOperationsAdmin.setDepositsPaused: "Purchases, edits, deletion, and every withdrawal remain available".
- IDcaManager.withdrawAllAccumulated*: "an unassigned or non-lending pair is skipped" / "an unassigned or zero-balance pair is skipped".
RATIONALE: These are the "pause blocks X only" transitions, stated as revert scoping so that a fuzzed failure on the wrong path is caught. Unassigned pairs need the raw wrappers with fuzzed token and route arrays.

PROPERTY_ID: [ST-13]
TYPE: SPECIFIC (after `setSchedulePaused`) + GLOBAL (paused schedules are never bought)
ENGLISH: `setSchedulePaused(p)` leaves the flag equal to `p`. Setting the current value is a no-op that changes no field. A schedule paused before a batch is never one of its successfully bought rows, so its `tokenBalance` and anchor never move in a purchase. Unpausing restores eligibility without moving the anchor.
SOLIDITY_SKETCH:
```
after setSchedulePaused(t,id,p): assertEq(S(t,id).paused, p); if (before.S.paused == p) full struct unchanged; assertEq(S.cadenceAnchor, before.S.cadenceAnchor);
after successful batch: for tracked s with pre.S(s).paused: assertEq(S(s).tokenBalance, pre.S(s).tokenBalance); assertEq(S(s).cadenceAnchor, pre.S(s).cadenceAnchor);
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: full S of tracked schedules (batch pre-snapshot)
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: IDcaManager.setSchedulePaused: "Setting the state it already holds is a no-op and emits nothing … A paused row in `batchBuyRbtc` reverts that handler's batch." G-12.
RATIONALE: The user-pause state machine `{active ⇄ paused}`. Also catches an unpause that rebases or clears the anchor.

PROPERTY_ID: [ST-14]
TYPE: SPECIFIC (after `setDepositsPaused`, create, deposit) + GLOBAL
ENGLISH: `setDepositsPaused(t,r,p)` flips exactly that pair's flag to `p` and leaves every other pair's flag and handler unchanged. A create or deposit succeeds only on an unpaused pair, so a paused pair's handler takes no new user cash or receipt shares. The flag exists only on assigned pairs.
SOLIDITY_SKETCH:
```
after setDepositsPaused(t,r,p): assertEq(areDepositsPaused(t,r), p); for other routes k: flag unchanged; getHandler unchanged;
after successful create/deposit on (t,r): assertFalse(areDepositsPaused(t,r), "ST-14 deposit through paused pair");
GLOBAL: for routes k: if (areDepositsPaused(k)) assertTrue(getHandler(k) != address(0));
// optional: while paused (ghost pausedSince[k]), receipt(h) and Σ shares(a,h) never rise; idle cash rises only by donations
```
GHOST_NEEDS: none (optional pausedSince per route)
SNAPSHOT_NEEDS: areDepositsPaused and getHandler for all routes
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: IOperationsAdmin.setDepositsPaused: "The pair must be assigned and the flag must change; each pair is updated separately." IDcaManager.createDcaSchedule: "Reverts `DcaManager__DepositsPaused` before any transfer". G-10.
RATIONALE: This is the governance circuit breaker. A pause leaking to another pair, or bypassed through one of the two inflow paths, defeats its purpose of isolating a bad lending market.

PROPERTY_ID: [ST-15]
TYPE: SPECIFIC (after add/revoke swapper, activation, batch, `setPurchasePath`) + GLOBAL edge
ENGLISH: `addSwapper(x)` / `revokeSwapper(x)` set `isSwapper(x)` to true/false and leave the other swapper untouched. A successful window activation or batch implies the calling swapper was allowlisted at that moment. A successful `setPurchasePath` implies the caller is the handler owner or an allowlisted swapper. The unlock block changes only through a successful activation by an allowlisted swapper.
SOLIDITY_SKETCH:
```
after add/revoke(x): assertEq(isSwapper(x), isAdd); assertEq(isSwapper(other), before.isSwapper(other));
after successful activate/batch: assertTrue(operationsAdmin.isSwapper(swapper));
after successful setPurchasePath(caller): assertTrue(caller == admin || operationsAdmin.isSwapper(caller));
after any op != successful activate: assertEq(unlock, before.unlock, "ST-15 window moved off the activation path");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: isSwapper(swappers[i]), unlock
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: IOperationsAdmin.addSwapper: "Idempotent; does not replace other swappers". G-1, G-33. AUDIT_GUIDE authority table (swapper may only "Activate the five-block protected window; execute due batches; switch a Dex handler among paths governance already allowlisted"). X-5 (a revoked swapper's live window and path persist) is *not* asserted against.
RATIONALE: Allowlist transitions and the "who may move this state" edges for the two pieces of swapper-written state: the unlock block and the active path.

PROPERTY_ID: [ST-16]
TYPE: SPECIFIC (after `setPurchasePath`, `setPurchasePathAllowed`) + GLOBAL edge
ENGLISH: `setPurchasePath(tokens,fees)` makes `getSwapPath()` equal the canonical encoding of the arguments, only on the target Dex handler, and only if that hash was already allowed. `setPurchasePathAllowed(p,allowed)` flips exactly one hash's flag. A call that would revoke the active path reverts. No other operation changes any handler's active path or allowlist.
SOLIDITY_SKETCH:
```
after setPurchasePath on h: assertEq(keccak(h.getSwapPath()), keccak(encode(tokens,fees))); assertTrue(before.allowed[h][hash]);
                            other Dex handler path unchanged; allowlist flags unchanged
after setPurchasePathAllowed(h,p,allowed): assertEq(h.isPurchasePathAllowed(hash(p)), allowed); other hash flag unchanged; path unchanged;
                            if (!allowed) assertTrue(keccak(before.path[h]) != hash(p));
failure of setPurchasePathAllowed(h,p,false) with hash(p)==keccak(path[h]): assertEq(sel(err), CannotRevokeActivePurchasePath.selector);
any other op: for Dex h: path and both allowlist flags unchanged
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: per Dex handler: getSwapPath, isPurchasePathAllowed(path0), isPurchasePathAllowed(path1)
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: IPurchaseUniswap.setPurchasePath: "Builds the canonical path from this handler's pinned stablecoin and WRBTC … the derived path must already be allowlisted." G-33, G-34, x-ray I-19.
RATIONALE: This is the path state machine (allowlisted ⇄ not allowlisted, active ∈ allowlisted). AGENTS.md inv. 14 keeps the path and its intermediate-token list private and updated together. A divergence would show up as a path change without the matching setter.

PROPERTY_ID: [ST-17]
TYPE: SPECIFIC (after successful create; after `setMaxSchedulesPerToken`)
ENGLISH: A successful create leaves the caller's list for that token at or below the cap in force at that moment. Lowering the cap (even to 0 or below live counts) removes no schedule and no id.
SOLIDITY_SKETCH:
```
after create: assertLe(ids(actor,token).length, dcaManager.getMaxSchedulesPerToken(), "ST-17 cap bypassed");
after setMaxSchedulesPerToken: for a,t: assertEq(ids(a,t).length, before.ids(a,t).length);
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: ids(a,t)
PRIORITY: LOW
GUARANTEE: SHOULD-HOLD
EVIDENCE: G-5 (checked beside the only push, DcaManager.sol:154). §5 / x-ray I-8: a lowered cap is not retroactive. The global "count ≤ cap" form is deliberately *not* asserted.
RATIONALE: Entity-count guard at the transition. The global form is accepted as violable, so only the postcondition is checked.

PROPERTY_ID: [ST-18]
TYPE: GLOBAL
ENGLISH: Route classes and handler assignments never change after setup.
- For each harness route, `getHandler(token, routeIndex)` is still the deployed handler.
- `getRouteClass` is Lending for indexes 1 and 2 and Idle for index 0.
- Each handler's `i_stablecoin` is its token and its `i_dcaManager` is the manager.
- Every live schedule's `(token, routeIndex)` resolves to an assigned handler.
SOLIDITY_SKETCH:
```
for k: assertEq(operationsAdmin.getHandler(routes[k].token, routes[k].routeIndex), routes[k].handler);
       assertEq(uint(operationsAdmin.getRouteClass(routes[k].routeIndex)), routes[k].lending ? 2 : 1);
       assertEq(address(ITokenHandler(routes[k].handler).i_stablecoin()), routes[k].token);
       assertEq(IDcaManagerAccessControl(routes[k].handler).i_dcaManager(), address(dcaManager));
assertEq(uint(operationsAdmin.getRouteClass(0)), 1);
for tracked s: assertTrue(operationsAdmin.getHandler(s.token, S(s).routeIndex) != address(0));
// with the optional raw handlers: every assignHandler on an assigned pair / used handler, and every registerRoute
// on a registered index, must revert (HandlerAlreadyAssigned / HandlerAddressAlreadyInUse / RouteAlreadyRegistered).
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: LOW (MEDIUM if the raw governance handlers are added)
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE authority table: governance "Cannot … Replace an assigned handler, reclassify a route". OperationsAdmin header: "neither can be remapped". x-ray I-15, I-16, G-11, G-37.
RATIONALE: Add-only assignment is what keeps live schedules bound to the handler holding their funds. In the current harness nothing can call these setters, so the property is only meaningful with the optional raw handlers.

PROPERTY_ID: [ST-19]
TYPE: GLOBAL (while `windowLive`)
ENGLISH: A row that was batch-eligible at window activation stays purchasable for the rest of that window, unless a batch has already bought it. "Batch-eligible" means spec-due, unpaused, funded, and on a lending route with non-zero share value for its owner. In other words, no user or governance action, and no lending clamp, can push a row that was prepared at activation into a refusal during the window.
SOLIDITY_SKETCH:
```
// at activation: record eligibleAtWin[k] for winSnap rows (specDue && !paused && purchaseAmount <= tokenBalance && (!lending || V(owner,h) > 0))
// in probe_buyOne restricted to eligibleAtWin rows not yet bought (winBatchDebit == 0) while windowLive:
catch (err): assertTrue(sel(err) ∉ {CannotBuy, SchedulePaused, BalanceNotEnough, InexistentSchedule, LendingHandler__ZeroShareValue},
                        "ST-19 prepared row invalidated inside window");
```
GHOST_NEEDS: eligibleAtWin[] (parallel to winSnap)
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none. Inferred from the window's stated purpose. ZeroShareValue can still be reached through `env_moveSovrynPrice` (bounded at 0.5, so not for a non-zero position) or a same-user row earlier in the same batch. A violation needs review against the "bad row reverts the batch" trade-off.
RATIONALE: This targets the open lead that the window does not block `depositToken`, `createDcaSchedule` or `topUpFromInterest` (§6). It checks that those open calls cannot invalidate a prepared row. For example, a top-up adds principal without shares, so a same-user row could later clamp to zero.

## Monotonicity

PROPERTY_ID: [VT-01]
TYPE: GLOBAL (before/after every call)
ENGLISH: For every live schedule, `cadenceAnchor` never decreases. It changes only in a successful batch that names the schedule, and once non-zero it never returns to 0.
SOLIDITY_SKETCH:
```
for tracked s (present before and after):
  assertGe(S_after(s).cadenceAnchor, S_before(s).cadenceAnchor);
  if (S_before(s).cadenceAnchor != 0) assertNotEq(S_after(s).cadenceAnchor, 0);
  if (op is not a successful batch naming s) assertEq(S_after(s).cadenceAnchor, S_before(s).cadenceAnchor);
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: cadenceAnchor of every tracked schedule
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: x-ray I-10: "`cadenceAnchor` is 0 or a UTC midnight ≤ the current day start, and it never moves backwards"; the only write is DcaManager.sol:585. AUDIT_GUIDE: "A period edit does not move the anchor".
RATIONALE: A backwards anchor reopens slots that were already consumed, which is unbounded catch-up buying.

PROPERTY_ID: [VT-02]
TYPE: GLOBAL
ENGLISH: The unlock block never decreases. Each change raises it to at least the previous value plus 5. `canActivateProtectedPurchaseWindow()` always equals `block.number >= unlock`.
SOLIDITY_SKETCH:
```
assertGe(unlock_after, unlock_before);
if (unlock_after != unlock_before) assertGe(unlock_after, unlock_before + 5);
assertEq(dcaManager.canActivateProtectedPurchaseWindow(), block.number >= unlock);
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: unlock
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: x-ray I-13 (only write DcaManager.sol:351, after the `block.number < unlock` refusal). AGENTS.md inv. 10.
RATIONALE: A state-machine summary of the window: idle → live (5 blocks) → idle, never live → longer live. The view sync matters because the bot schedules activation from it.

PROPERTY_ID: [VT-03]
TYPE: SPECIFIC (before/after every call)
ENGLISH: Changes to an account's virtual shares on a lending handler are attributed to that account's own operations on that handler.
- Shares rise only through that account's create or deposit on the handler.
- Shares fall only through that account's `withdrawToken`, `withdrawTokenAndInterest`, `deleteDcaSchedule` or `withdrawAllAccumulatedInterest`, or through a batch on that handler with a row bought for the account.
- Edits, pause, top-up, rBTC claims, window activation, governance and environment calls leave every share balance unchanged.
SOLIDITY_SKETCH:
```
for a ∈ ACCOUNTS, lending h:
  Δ = shares_after(a,h) - shares_before(a,h);
  if (Δ > 0) assertTrue(caller == a && op ∈ {create, deposit} && opHandler == h);
  if (Δ < 0) assertTrue((caller == a && op ∈ {withdrawToken, withdrawTokenAndInterest, delete, withdrawAllAccumulatedInterest} && opHandler(s) ∋ h)
                        || (op ∈ {batch, batchAcross} && h ∈ batchHandlers && a ∈ buyersOn(h)));
  if (op ∈ {updatePurchaseAmount, updatePurchasePeriod, setSchedulePaused, topUp, withdrawAllAccumulatedRbtc, activate, admin, env}) assertEq(Δ, 0);
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: shares(a,h) for ACCOUNTS × lending handlers; batch buyers per handler
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none, inferred from code structure: every `s_shares` write goes through `_setUserShares` from three call sites (x-ray I-1 derivation). One part has documentary backing: the topUp NatSpec says the top-up "never redeems, mints, or transfers".
RATIONALE: Agent 1's CON-23 and CON-21 cover other users and non-buyers during user calls and batches. This property adds the per-operation edges, including environment and governance calls, and the "own operation on *this* handler" binding.

PROPERTY_ID: [VT-04]
TYPE: SPECIFIC (after batches and rBTC claims) — needs `vm.load`
ENGLISH: Each account's raw `s_accumulatedRbtc` slot on each handler follows the documented state machine: 0 (never credited) → `claimable + 1` (≥ 2) on first credit → 1 after a full claim → ≥ 2 on a later credit. Once non-zero it never returns to 0. After a claim it is exactly 1. It always equals `getAccumulatedRbtcBalance + 1` once non-zero.
SOLIDITY_SKETCH:
```
// slot index from `forge inspect <Leaf> storageLayout` (s_accumulatedRbtc lives in PurchaseRbtc, same base slot across leaves of one inheritance shape)
raw(a,h) = uint256(vm.load(h, keccak256(abi.encode(a, SLOT_ACC_RBTC[h]))));
if (raw_before != 0) assertNotEq(raw_after, 0);
if (raw_after != 0) assertEq(raw_after, claim(a,h) + 1); else assertEq(claim(a,h), 0);
after a successful claim by a on h with claim_before > 0: assertEq(raw_after, 1);
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: raw(a,h) for ACCOUNTS × handlers
PRIORITY: LOW
GUARANTEE: SHOULD-HOLD
EVIDENCE: AGENTS.md inv. 13: "`s_accumulatedRbtc` … stores `claimable + 1` when live (`0` = never credited; `1` = post-withdraw sentinel)". x-ray I-14.
RATIONALE: Only the raw slot shows the sentinel. CON-07/CON-08 see the decoded value only. A slot reset to 0 (instead of 1) would cost one extra cold write per credit on Rootstock and break the documented encoding. Drop this property if the leaf storage layouts differ and the per-handler slot is not worth computing.

## State sync and domains

PROPERTY_ID: [VS-01]
TYPE: GLOBAL
ENGLISH: Every live schedule's anchor is 0 or a UTC midnight no later than today, and a non-zero anchor is never later than `today`.
SOLIDITY_SKETCH:
```
for tracked s: uint A = S(s).cadenceAnchor;
  if (A != 0) { assertEq(A % 1 days, 0, "VS-01 anchor off midnight grid"); assertLe(A, today); }
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: x-ray I-10; DcaManager.sol:538: "The first buy anchors today; whole-day periods keep every later due date on that midnight grid." AUDIT_GUIDE: "that purchase establishes the cadence at the current UTC midnight".
RATIONALE: A future or off-grid anchor makes `nextDue - block.timestamp` (unchecked) underflow in the refusal and shifts every later due day.

PROPERTY_ID: [VS-02]
TYPE: GLOBAL
ENGLISH: Field and setting domains always hold.
- Every live schedule has `purchaseAmount > 0`, a period that is a positive whole number of days of at least 1 day, a non-zero `user`, and a `routeIndex` that is one of the token's assigned routes.
- `minPurchasePeriod` is a whole number of days of at least 1 day.
- The token minimum for DOC and USDRIF is never 0.
- Deliberately not asserted: `purchaseAmount >= current min`, `period >= current min period`, `count <= cap` (I-4, I-6, I-8), and `purchaseAmount <= tokenBalance` (I-5, not enforced on-chain).
SOLIDITY_SKETCH:
```
for tracked s: d = S(s); assertGt(d.purchaseAmount, 0); assertGe(d.purchasePeriod, 1 days); assertEq(d.purchasePeriod % 1 days, 0);
               assertTrue(d.user != address(0)); assertTrue(_routeOf(s.token, d.routeIndex).handler != address(0));
uint m = dcaManager.getMinPurchasePeriod(); assertGe(m, 1 days); assertEq(m % 1 days, 0);
assertGt(dcaManager.getTokenMinPurchaseAmount(address(doc)), 0); assertGt(dcaManager.getTokenMinPurchaseAmount(address(usdrif)), 0);
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: x-ray I-3 and I-7 (on-chain: yes); G-6, G-8, G-9; DcaManager.sol:295: "`purchaseAmount` is never zero: every write meets the token minimum".
RATIONALE: `topUpFromInterest` and the cadence division (`periodsElapsed`) divide by these fields. A zero value would brick a schedule or make it due forever.

PROPERTY_ID: [VS-03]
TYPE: GLOBAL
ENGLISH: On every Dex handler the active path is allowlisted, is one of the two paths the harness can set, starts with the handler's stablecoin and ends with WRBTC. At least one path is always allowlisted.
SOLIDITY_SKETCH:
```
for h in dexHandlers: bytes p = IPurchaseUniswap(h).getSwapPath();
  assertTrue(IPurchaseUniswap(h).isPurchasePathAllowed(keccak256(p)), "VS-03 active path not allowlisted");
  assertTrue(keccak256(p) == keccak256(path0(h)) || keccak256(p) == keccak256(path1(h)));
  assertEq(address(bytes20(p[0:20])), address(ITokenHandler(h).i_stablecoin())); assertEq(address(bytes20(p[p.length-20:])), address(wrbtc));
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: x-ray I-19 ("The active Uniswap path is always allowlisted"; guard G-34); IPurchaseUniswap.setPurchasePath ("canonical path from this handler's pinned stablecoin and WRBTC").
RATIONALE: This is the flag-data sync between `s_swapPath` and `s_purchasePathAllowed`. Purchases must never run on a path that governance has revoked.

PROPERTY_ID: [VS-04]
TYPE: GLOBAL
ENGLISH: Handler settings stay in their documented domains on every handler.
- `minFeeRate <= maxFeeRate <= 500` and the fee collector is non-zero.
- On Dex handlers, `safetyCheck <= percent <= 1e18` and the oracle is non-zero.
SOLIDITY_SKETCH:
```
for k: fs = IPurchaseFees(routes[k].handler).getFeeSettings(); assertLe(fs.minFeeRate, fs.maxFeeRate); assertLe(fs.maxFeeRate, 500);
       assertTrue(IPurchaseFees(routes[k].handler).getFeeCollector() != address(0));
for h in dexHandlers: u = IPurchaseUniswap(h); assertLe(u.getAmountOutMinimumSafetyCheck(), u.getAmountOutMinimumPercent());
       assertLe(u.getAmountOutMinimumPercent(), 1e18); assertTrue(address(u.getMocOracle()) != address(0));
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: LOW
GUARANTEE: SHOULD-HOLD
EVIDENCE: x-ray I-17, I-18; G-35, G-36; PurchaseFees.sol:42/79 and PurchaseUniswap.sol:93/180 reject zero addresses.
RATIONALE: These cheap domain checks catch a setter that writes before validating, or validates against the stale counterpart value.

PROPERTY_ID: [VS-05]
TYPE: GLOBAL
ENGLISH: While no loss has occurred on a lending route, an account that still holds live principal there also holds virtual shares there. "No loss" means LayerBank always, and Sovryn only while its price has never fallen and its exit fee is 0. A schedule with positive nominal principal backed by zero shares is reachable only after a loss.
SOLIDITY_SKETCH:
```
for a ∈ actors, lending route r (h = r.handler):
  bool noLoss = isLB(h) || (!ghosts.sovrynPriceEverFell && sovrynIToken.getExitFeeBps() == 0);
  if (noLoss && L(a,r) > 0) assertGt(shares(a,h), 0, "VS-05 principal with no shares, no loss");
```
GHOST_NEEDS: sovrynPriceEverFell (shared with agent 1)
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none. Inferred: AUDIT_GUIDE allows "Nominal principal can still exceed share value by rounding dust", and a dust gap could in theory leave tiny principal with zero shares. That outcome is a "stuck schedule" lead, not a confirmed spec breach. §5 (X-2/X-3) accepts the post-loss case, so the property is gated on `noLoss`.
RATIONALE: This entity-level sync (principal ⇒ shares) complements CON-15's value bound. A zero-share live schedule makes every batch containing it revert with `ZeroShareValue`, which is a liveness failure for the whole handler batch.
