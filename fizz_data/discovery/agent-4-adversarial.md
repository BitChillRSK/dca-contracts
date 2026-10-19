# Agent 4 — Adversarial Profit Maximizer: property list

Scope: attacker profit, cross-user value extraction, DoS and griefing that block other users' purchases or
exits, edge states an attacker can force, and what the swapper key or the environment (prices, oracle, rates,
donations, time) can do. Here an "attacker" is any actor, the current swapper, a revoked swapper, the fee
collector, or `EnvironmentHandler` moving the world within its bounds.

Not repeated here (already written by agents 1–3, and checked against their files):
- cross-user isolation of a user's own call: CON-23;
- exact amounts of each operation: CON-16..22, RD-01..05;
- lending redeems never failing the exact-burn check: RD-07;
- the Dex oracle floor on Q: RD-12;
- splitting rows to save fees: RD-11;
- window frame conditions and per-row survival inside a window: ST-10, ST-11, ST-19;
- refusal attribution, including `DepositsPaused` raised only by create/deposit: ST-12;
- allowlist and path state: ST-15, ST-16.

This file adds the attacker's view on top of those: liveness under any reachable environment, the batch
*input* and `minRbtcOut` dimension of Finding 1, active attack handlers for access control, and a per-call
no-profit bound.

## Notation (reuses agent 1's)

`ACCOUNTS`, `routes[k]`, `rate(h)`, `D(h)`, `shares(a,h)`, `V(a,h)`, `claim(a,h)` and `receipt(h)` are as defined
in agent-1-conservation.md. `unlock` = `dcaManager.getUserMutationsAllowedFromBlock()`;
`windowLive` = `block.number < unlock`. `isLB(h)` = h is a LayerBank handler. `BTC_PRICE` = 50_000
(script/Constants.sol, used by MockMocProxy). `sel(err)` = `bytes4(err)`.

`cleanRows(r, mask)` is the row simulator that ADV-06, -07 and -08 use. Take the harness's `_eligibleRows(r, mask)`.
On a lending route, walk the rows in order with `rem[buyer]` initialised to `shares(buyer,h)`:
```
need = ceilDiv(pa*D, rate)
if need > rem[buyer]:
    w = rem[buyer]*rate/D
    if w == 0: drop row
    srRow = rem[buyer]; rem[buyer] = 0
else:
    w = pa; srRow = need; rem[buyer] -= need
```
Return `ids`, `G = Σw`, `SR = Σ srRow`, and `cashIn`, the stablecoin the venue will receive:
- idle routes: `G`;
- Sovryn: `floor(SR*p/1e18)` minus the exit fee, the same formula as FizzIToken.burn;
- LayerBank: `floor(SR*idx/RAY)`, plus 1 when `rayDiv(floor, idx) < SR`.

`venueOut(r, x)` = MoC: `x / BTC_PRICE`; Dex: `x*997/(1000*dexRouterPrice)`.
`dexFloor(h, x)` = `x * percent(h) / oraclePrice(h)`. The scale is 1 because USDRIF has 18 decimals. `percent(h)` =
`getAmountOutMinimumPercent()`, and `oraclePrice` comes from `getMocOracle().getPriceInfo()`.
`venueOk(r, x)` = `venueOut(r,x) > 0`, and, on Dex routes, also: oracle valid, and `venueOut(r,x) >= dexFloor(h,x)`.

## Harness additions these properties need

1. **Attack and probe handlers** (new file `handlers/AdversarialHandler.sol`, inheriting `Properties`). Each
   one uses `vm.prank` + `try/catch` and asserts on the outcome. The fuzzer ignores ordinary reverts, so a
   liveness property needs this form: `catch { assertWithMsg(false, ...) }`. Handlers that succeed keep the
   tracking lists in step (`_untrackSchedule` on a successful delete, `_trackSchedule` on a successful create).
2. **Plan/execute pair** for ADV-07/08 (`adv_planProtectedBatch`, `adv_executeProtectedBatch`) with a `Plan`
   ghost.
3. **Intermediate-token donation** `env_donateIntermediateToRouter(amount)`: `usdt0.mint(address(swapRouter), amount)`.
   Optional, for ADV-17.
4. **Reentrant claimant** for ADV-19 (optional): one `ReentrantActor` in place of `actors[2]`, whose `receive()`
   runs a configured re-entry inside `try/catch` and records the outcome.
5. Every non-actor wrapper (swapper, admin, `layerBankHandlerDex_secondary`, `operationsAdmin_secondary`,
   `dcaManager_secondary`, `env_*` other than the two donation handlers) calls `snapshotBefore()` /
   `snapshotAfter()` so that ADV-09/10 can compare.

## Ghosts needed (Base.sol `Ghosts`)

```
// ADV-07/08 planned protected batch
struct Plan { bool live; uint256 routeK; uint64[] ids; address swapper; uint256 unlock;
              uint256 G; uint256 SR; uint256 cashIn; uint256 rate; uint256 exitFeeBps;
              uint256 dexPrice; uint256 oraclePrice; bool oracleValid; uint256 minOut;
              uint48[] anchors; }                 // anchors of the planned rows, to detect "already bought"
Plan plan;
// ADV-09 baselines, fixed at the end of setup()
mapping(address => mapping(address => uint256)) privBaseline;   // [account][token] for doc, usdrif, usdt0, wrbtc
// ADV-16
uint256 allowlistEmptySince;                     // block at which the allowlist became empty; 0 while some swapper is allowlisted
// ADV-19 (optional)
uint256 reentryAttempts; uint256 reentrySucceeded;
```

## Snapshot fields needed (Snapshots.sol `State`)

Agent 1's snapshot (ACCOUNTS: native, doc, usdrif, claim per handler, shares per lending handler) plus:
- `NAVs(a,T)` and `NAVr(a)` (ADV-11) for the acting actor;
- `unlock`;
- every Dex handler's `getSwapPath()` hash, `getFeeCollector()` and `getFeeSettings()` (ADV-12/15);
- swapper and admin balances (ADV-09).

---

## A. Liveness of exits (an attacker or the environment cannot trap funds)

PROPERTY_ID: [ADV-01]
TYPE: SPECIFIC (probe handler `adv_withdrawLiveness(scheduleSeed, amountSeed, bool full)`)
ENGLISH: An attacker cannot stop a schedule owner from withdrawing principal. Outside a live protected window, `withdrawToken` on an owned schedule with `tokenBalance > 0` succeeds for any amount in `[1, tokenBalance]` and for the `type(uint256).max` sentinel. This holds whatever the other actors, the swapper, the owner or the environment did before. The list covers deposit pauses, a cap lowered to 0, a raised token minimum, both swappers revoked, an invalid oracle, any fee setting, a fallen Sovryn price, a Sovryn exit fee, LayerBank index bumps, stray donations, and other users' exits first ("last withdrawer").
SOLIDITY_SKETCH:
```
idx = _pickOwnedSchedule(actor, scheduleSeed); if (idx == max) return;
if (block.number < dcaManager.getUserMutationsAllowedFromBlock()) return;
TrackedSchedule s = trackedSchedules[idx]; DcaSchedule a = dcaManager.getDcaSchedule(s.token, s.scheduleId);
if (a.tokenBalance == 0) return;
uint256 amt = full ? type(uint256).max : clampBetween(amountSeed, 1, a.tokenBalance);
uint256 eff = full ? a.tokenBalance : amt;
vm.prank(actor);
try dcaManager.withdrawToken(s.token, s.scheduleId, amt) {
    assertEq(dcaManager.getDcaSchedule(s.token, s.scheduleId).tokenBalance, a.tokenBalance - eff, "ADV-01 debit");
} catch (bytes memory err) {
    assertWithMsg(false, "ADV-01 principal exit reverted outside a window");   // log sel(err)
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: schedule `tokenBalance` before the call (read inline)
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE authority table: Schedule owner "Can … withdraw their stablecoin, interest, and accumulated rBTC". AUDIT_GUIDE: "A governance deposit pause blocks new inflows only, preserving purchases and exits". The window "blocks only … withdrawals through activation block N + 4; those actions resume at N + 5". The only stated exception is "External illiquidity or pauses can revert purchases or withdrawals", and the harness mocks rule that out: FizzIToken and MockLayerBank mint missing cash, and MockStablecoin never pauses. Context §5 states that a zero-share user "withdraws zero tokens", which means a payout, not a revert.
RATIONALE: This detects any state another party can force that bricks a user's exit. Candidates are a share-burn mismatch, a zero-cash revert after a Sovryn fall or exit fee, an underflow in `_redeemShares`, pooled idle cash drained by someone else, and a SafeCast or approval revert. Clamped `amountSeed` values near 1 wei also cover the Pattern H dust exits.

PROPERTY_ID: [ADV-02]
TYPE: SPECIFIC (probe handler `adv_deleteLiveness(scheduleSeed)`)
ENGLISH: An attacker cannot stop a schedule owner from deleting a schedule and recovering its balance. Outside a live window, `deleteDcaSchedule(token, id, correctIndex)` on an owned schedule never reverts in any reachable environment state. This includes `tokenBalance == 0`, dust balances, balances below `purchaseAmount`, and a cap lowered below the live count. Afterwards the key reads as nonexistent and the owner's list is one shorter.
SOLIDITY_SKETCH:
```
idx = _pickOwnedSchedule(actor, seed); if (idx == max || windowLive) return;
s = trackedSchedules[idx]; uint256 i = _scheduleIdIndex(s); uint256 n = ids(actor, s.token).length;
vm.prank(actor);
try dcaManager.deleteDcaSchedule(s.token, s.scheduleId, i) {
    _untrackSchedule(s.token, s.scheduleId);
    assertEq(ids(actor, s.token).length, n - 1, "ADV-02 list");
    try dcaManager.getDcaSchedule(s.token, s.scheduleId) { assertWithMsg(false, "ADV-02 still live"); } catch {}
} catch { assertWithMsg(false, "ADV-02 delete reverted outside a window"); }
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: As ADV-01: the AUDIT_GUIDE authority table (owner can "Fund and manage their schedules; withdraw …"), "A governance deposit pause … preserving purchases and exits", and window resumption at N+5. x-ray I-8 / context §5: lowering `maxSchedulesPerToken` "does not rewrite existing schedules".
RATIONALE: Delete is the full-amount exit (Pattern I-c). It is the path a user takes when a route is broken or a market lost value. A revert here strands the whole balance. On a lending route it also drives `_withdrawToken` with the whole nominal balance against a possibly smaller share value.

PROPERTY_ID: [ADV-03]
TYPE: SPECIFIC (probe handlers `adv_interestLiveness(routeMask)` and `adv_principalAndInterestLiveness(scheduleSeed, amountSeed)`)
ENGLISH: An attacker cannot block interest exits. Outside a live window, the following never revert:
- `withdrawAllAccumulatedInterest` over any non-empty mask of assigned pairs, including idle pairs, which are skipped;
- `withdrawTokenAndInterest` on an owned lending schedule for any amount in `[1, tokenBalance]`.

This holds whether interest is zero or 1–2 wei, when the principal exit leaves dust interest, with any Sovryn exit fee in 0..100 bps, and after a Sovryn price fall.
SOLIDITY_SKETCH:
```
// interest only
if (windowLive) return; (tokens, routes) = _routePairs(routeMask);
vm.prank(actor);
try dcaManager.withdrawAllAccumulatedInterest(tokens, routes) {
    for each lending pair in the mask: assertEq(dcaManager.getAccruedInterest(actor, t, r), 0, "ADV-03 residual");
} catch { assertWithMsg(false, "ADV-03 interest exit reverted"); }
// principal + interest
pick an owned lending schedule with tokenBalance>0; amt = clampBetween(seed, 1, tokenBalance);
vm.prank(actor);
try dcaManager.withdrawTokenAndInterest(t, id, amt) {} catch { assertWithMsg(false, "ADV-03 principal+interest reverted"); }
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: The AUDIT_GUIDE authority table lists "withdraw their … interest" as an owner capability. The window section says interest withdrawals "resume at N + 5". The only stated exception is external illiquidity, which these mocks cannot produce. In FizzIToken the exit fee floors (`paid − floor(paid·bps/1e4)` ≥ 1 when paid ≥ 1), so a positive interest burn always pays cash.
RATIONALE: This targets the scan lead "an interest redeem that pays zero reverts `withdrawTokenAndInterest`". It also catches any rounding state (Sovryn price < 1e18, LayerBank `+1` sizing) where the second redeem of a combined call fails and takes the principal exit down with it.

PROPERTY_ID: [ADV-04]
TYPE: SPECIFIC (probe handler `adv_claimLiveness(accountSeed, routeMask)`, accountSeed picks an actor or the current collector of a random handler)
ENGLISH: An attacker cannot block rBTC claims. For any account in ACCOUNTS and any route mask, `withdrawAllAccumulatedRbtc` never reverts. This holds inside or outside a protected window, with an invalid oracle, with both swappers revoked, after native rBTC is force-sent to a handler, and after a collector rotation. The call pays the caller exactly `Σ claim(a,h)` over the selected handlers.
SOLIDITY_SKETCH:
```
address a = pickAccount(accountSeed); (tokens, routes) = _routePairs(routeMask);
uint256 due = Σ_{selected h} claim(a,h); uint256 nb = a.balance;
vm.prank(a);
try dcaManager.withdrawAllAccumulatedRbtc(tokens, routes) {
    assertEq(a.balance - nb, due, "ADV-04 claim amount");
} catch { assertWithMsg(false, "ADV-04 rBTC claim reverted"); }
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none (inline)
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE: "Creation, deposits, interest top-up, rBTC withdrawal, reads, governance, and purchases remain open" during the window. "Accumulated rBTC is payable only to the recorded user through `DcaManager`". "Users and the fee collector must accept native rBTC with empty calldata", and every harness account (an `Actor`) does. x-ray E-2.
RATIONALE: This detects WRBTC/native insolvency on a handler, which would make the last claimant's unwrap or transfer fail. It also catches a sentinel-encoding slip that turns a claim into `NoAccumulatedRbtcToWithdraw` while `claim > 0`, and any purchase-side state (oracle, path, window) that leaks into the claim path.

PROPERTY_ID: [ADV-05]
TYPE: SPECIFIC (composite handler `adv_fullExitAndReenter(routeSeed, depositSeed)`)
ENGLISH: An actor can always leave the protocol completely and come back on equal terms. Outside a window, the current actor deletes every owned schedule, withdraws interest on every lending pair, then claims rBTC on every handler. Each step must succeed. Afterwards:
- the actor owns no schedules;
- `claim(actor,h) == 0` on every handler;
- `shares(actor,LB) == 0` on both LayerBank handlers;
- `V(actor,Sovryn) == 0`, i.e. `shares·price < 1e18`.

No other account's shares, claims, schedules or wallets moved during the exit. If deposits are not paused on the chosen route and the cap is above 0, a fresh `createDcaSchedule` then succeeds. The new position is worth no more than the deposit plus one share's rounding, and the accrued interest on it is at most 1 wei plus the value of any residual Sovryn dust shares.
SOLIDITY_SKETCH:
```
if (windowLive) return;
snapshot others (shares, claims, wallets, tracked schedules of b != actor)
for each tracked s with owner==actor: vm.prank(actor); try delete(s, _scheduleIdIndex(s)) { _untrack } catch { fail("ADV-05 delete"); }
vm.prank(actor); try withdrawAllAccumulatedInterest(all lending pairs) {} catch { fail("ADV-05 interest"); }
vm.prank(actor); try withdrawAllAccumulatedRbtc(all pairs) {} catch { fail("ADV-05 claim"); }   // skips zero claims itself
for t in {doc, usdrif}: assertEq(ids(actor,t).length, 0);
for h: assertEq(claim(actor,h), 0);
assertEq(shares(actor, layerBankDocMoc), 0); assertEq(shares(actor, layerBankUsdrifDex), 0);
assertLt(shares(actor, sovrynDocMoc) * sovrynIToken.tokenPrice(), 1e18);
assert others unchanged;
// re-entry
r = _route(routeSeed); if (!paused(r) && maxSchedules > 0) {
   d = clampBetween(depositSeed, minPurchase(r.token), min(balance, MAX_DEPOSIT)); v0 = r.lending ? V(actor,h) : 0;
   vm.prank(actor); try create(r.token, d, d, minPeriod, r.routeIndex) { track;
       if (r.lending) { assertLe(V(actor,h) - v0, d + rate/D + 1);  assertLe(getAccruedInterest(actor,r.token,r.routeIndex), v0 + 1); }
   } catch { fail("ADV-05 re-entry create"); }
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: other accounts' shares, claims, doc/usdrif/native balances, tracked schedules (inline)
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. Pattern G (zero state and re-entry). The leftover-share bounds follow from ceil/floor arithmetic: an interest redeem with locked principal 0 leaves shares worth < 1 wei, and LayerBank's index ≥ RAY makes that 0 shares.
RATIONALE: This detects four failures:
- "Last one out" failures, where an earlier user's exit leaves the handler unable to serve the last one.
- Residual claims that cannot be withdrawn.
- A position that cannot be fully closed, for example interest that keeps reappearing or a Sovryn exit that needs an exact remainder burn (scan lead: Sovryn small remainder).
- A re-entry that inherits a stale loss or profit through leftover shares, letting a returning user's old dust shares become claimable interest.

---

## B. Liveness of purchases (an attacker cannot block other users' buys)

PROPERTY_ID: [ADV-06]
TYPE: SPECIFIC (probe handler `adv_cleanBatchLiveness(routeSeed, rowMask, swapperSeed)`)
ENGLISH: No actor, swapper choice or environment move can make a batch of clean rows revert when the venue can fill it. Clean rows are distinct, spec-due, unpaused and nominally funded. On a lending route each clean row's buyer must still hold positive share value after that buyer's earlier rows in the same batch (`cleanRows`). Take an allowlisted swapper, `minRbtcOut = 0` and `venueOk(r, cashIn)`. Then `batchBuyRbtc` succeeds, whatever else holds:
- deposit pauses on any pair, a live or expired window, or no window at all;
- donations to any handler, either path being active, either oracle being active;
- any fee settings and collector;
- a token minimum or minimum period raised after the rows were created;
- other users' rows on the same handler that are not in the batch.
SOLIDITY_SKETCH:
```
r = _route(routeSeed); (ids, G, SR, cashIn) = cleanRows(r, rowMask); if (ids.length == 0) return;
address sw = swappers[swapperSeed % 2]; if (!operationsAdmin.isSwapper(sw)) return;
if (!venueOk(r, cashIn)) return;
if (r.dex && venueOut(r,cashIn) * 1e6 < dexFloor(h,cashIn) * (1e6 + 1)) return;   // rounding margin at the floor edge
vm.prank(sw);
try dcaManager.batchBuyRbtc(Batch(ids, r.token, r.routeIndex, 0)) {}
catch (bytes memory err) { assertWithMsg(false, "ADV-06 clean batch reverted"); }   // log sel(err)
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. AUDIT_GUIDE lists the purchase revert causes as "A zero-value row … Illiquidity, zero received cash, an incompatible share burn, or an unmet minimum output". It also says "Purchases do not require a live window" and that a deposit pause preserves purchases. The precondition above excludes each listed cause. Treating that list as exhaustive is this agent's inference.
RATIONALE: This is griefing that blocks other users' purchases. The harness's own `_eligibleRows` does not simulate share value, so no existing handler can tell a "bad row" revert (accepted) from a revert caused by someone else's state. The candidates for the latter are:
- a donation that upsets the exact-input check;
- another user's withdrawal draining pooled idle cash;
- a LayerBank `+1` burn on a summed share amount;
- the Sovryn exit fee on a large `SR`;
- a fee configuration where `totalFee` rounds to a revert;
- a collector that is also a buyer in the batch.

PROPERTY_ID: [ADV-07]
TYPE: SPECIFIC (handler pair `adv_planProtectedBatch(routeSeed, rowMask, swapperSeed)` / `adv_executeProtectedBatch()`; the fuzzer interleaves any calls between them)
ENGLISH: Once a swapper has activated a protected window and planned a batch from that state, no user can change how much stablecoin the batch spends. Suppose that by execution, still inside the same window, the lending rate and the Sovryn exit fee on the route are unchanged and no planned row has been bought. Then the receipt shares the batch burns equal the planned `SR`, and the venue receives exactly the planned `cashIn`. This holds whatever unguarded user calls ran in between: `depositToken`, `createDcaSchedule`, `topUpFromInterest`, rBTC claims and approval restores.
SOLIDITY_SKETCH:
```
function adv_planProtectedBatch(routeSeed, rowMask, swapperSeed) {
  if (plan.live && block.number < plan.unlock) return;
  sw = swappers[seed%2]; vm.prank(sw); try dcaManager.activateProtectedPurchaseWindow() {} catch { return; }
  r = _route(routeSeed); (ids, G, SR, cashIn) = cleanRows(r, rowMask); if (ids.length == 0) { plan.live = false; return; }
  plan = Plan(true, k, ids, sw, unlock, G, SR, cashIn, rate(h), exitFee, dexRouterPrice, oraclePrice, oracleValid,
              /*minOut*/ venueOut(r, cashIn), anchorsOf(ids));
}
function adv_executeProtectedBatch() {
  if (!plan.live) return; if (block.number >= plan.unlock) { plan.live = false; return; }
  if (any planned row's cadenceAnchor != plan.anchors[i]) { plan.live = false; return; }   // already bought
  r = routes[plan.routeK]; rcpt0 = r.lending ? receipt(h) : 0; rin0 = usdrif.balanceOf(address(swapRouter));
  vm.prank(plan.swapper);
  try dcaManager.batchBuyRbtc(Batch(plan.ids, r.token, r.routeIndex, 0)) {
     bool sameRate = !r.lending || (rate(h) == plan.rate && exitFee == plan.exitFeeBps);
     if (sameRate) {
        if (r.lending) assertEq(rcpt0 - receipt(h), plan.SR, "ADV-07 burned shares moved inside window");
        if (r.dex)     assertEq(usdrif.balanceOf(address(swapRouter)) - rin0, plan.cashIn, "ADV-07 Dex input moved inside window");
     }
  } catch {}   // ADV-08 handles reverts; ADV-07 uses minRbtcOut = 0 to isolate the input dimension
  plan.live = false;
}
```
GHOST_NEEDS: `Plan plan` (see the ghost block). Optional diagnostics: `plan.userGrowth`, set by the create/deposit/topUp wrappers when `actor` is a planned buyer on `plan.routeK`.
SNAPSHOT_NEEDS: `receipt(h)` and `usdrif.balanceOf(swapRouter)` at execution (inline)
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. The DcaManager header promises a window that "blocks only user mutations capable of invalidating a batch refreshed after activation". Whether growing a clamped row counts as "invalidating" is exactly the open question of Finding 1 and the leads "A deposit / a new schedule in the protected window grows a short lending row". Expect a counterexample after `env_moveSovrynPrice(down)` leaves a buyer short; that buyer then calls `depositToken` or `createDcaSchedule` on the Sovryn route inside the window. A violation confirms the finding is reachable, not that it is a bug.
RATIONALE: This puts Finding 1's root cause into the harness. The batch's gross input is read at execution, and `depositToken`/`createDcaSchedule` lack the window guard. ST-19 checks only that a prepared row stays purchasable. This property checks how much it spends.

PROPERTY_ID: [ADV-08]
TYPE: SPECIFIC (same plan/execute pair; the execute variant `adv_executeProtectedBatchWithQuote()` sends `plan.minOut` instead of 0)
ENGLISH: The swapper's `minRbtcOut` cannot be turned against the users it protects, in either direction.
- (a) DoS: a planned batch executed inside its window with `minRbtcOut = venueOut(r, plan.cashIn)` does not revert with `PurchaseRbtc__BelowSwapperMinimum` while the venue price is no worse than at planning. On MoC that is always the case (fixed price). On Dex it means `dexRouterPrice <= plan.dexPrice`, the oracle is valid and `venueOk` holds.
- (b) Dilution: if it succeeds, the realised price is at least the price the minimum implied: `Q * plan.cashIn + plan.cashIn >= plan.minOut * actualIn`. Here `Q` is the handler's measured rBTC/WRBTC gain in the call, and `actualIn` is the venue's measured stablecoin intake.
SOLIDITY_SKETCH:
```
... same guards as ADV-07 ...
q0 = r.dex ? wrbtc.balanceOf(h) : h.balance; rin0 = r.dex ? usdrif.balanceOf(router) : 0; rcpt0 = receipt(h)
vm.prank(plan.swapper);
try dcaManager.batchBuyRbtc(Batch(plan.ids, r.token, r.routeIndex, plan.minOut)) {
   Q = (r.dex ? wrbtc.balanceOf(h) : h.balance) - q0;
   actualIn = r.dex ? usdrif.balanceOf(router) - rin0 : cashForBurn(rcpt0 - receipt(h)) /* idle: Σ pa */;
   assertGe(Q * plan.cashIn + plan.cashIn, plan.minOut * actualIn, "ADV-08b minimum diluted by larger input");
} catch (bytes memory err) {
   bool priceNotWorse = !r.dex || (dexRouterPrice <= plan.dexPrice && oracleValid && venueOk(r, plan.cashIn));
   if (priceNotWorse) assertWithMsg(sel(err) != PurchaseRbtc__BelowSwapperMinimum.selector,
                                    "ADV-08a quote-derived minimum reverted at an unchanged venue price");
}
```
GHOST_NEEDS: `Plan plan`
SNAPSHOT_NEEDS: handler rBTC/WRBTC, router USDRIF and receipt shares at execution (inline)
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none — this is open Finding 1 ("Batch `minRbtcOut` does not scale with the input that the batch spends"). Its Fix B, a per-unit minimum, would satisfy both halves.
RATIONALE: (a) is reachable now. `env_moveSovrynPrice(down)` inside the window shrinks a clamped Sovryn row, so `Q` falls below an absolute minimum at an unchanged MoC price, and every co-buyer's purchase is blocked. (b) is the dilution form in the scan report: a row grows after the quote, and the extra input fills at a worse price than the swapper accepted. In this harness (b) can only fail by rounding dust. The only Dex lending route is LayerBank, whose index never falls, so its rows clamp by at most dust, and MoC prices are fixed. It is kept as a regression guard in case `SovrynHandlerDex` is ever deployed.

---

## C. Value extraction

PROPERTY_ID: [ADV-09]
TYPE: GLOBAL
ENGLISH: Neither swapper key nor the owner can extract value. Both swapper addresses hold zero of everything, always:
- no DOC, USDRIF, USDT0, WRBTC or native rBTC;
- no claim on any handler;
- no lending shares;
- no schedules.

The owner (the fuzz contract) never ends with more DOC, USDRIF, USDT0 or WRBTC than at the end of setup, and never holds a claim or shares.
SOLIDITY_SKETCH:
```
for sw in swappers:
   assertEq(doc.balanceOf(sw)+usdrif.balanceOf(sw)+usdt0.balanceOf(sw)+wrbtc.balanceOf(sw), 0);
   assertEq(sw.balance, 0);
   for h: assertEq(claim(sw,h), 0); for lending h: assertEq(shares(sw,h), 0);
   for t: assertEq(dcaManager.getDcaSchedules(sw,t).scheduleIds.length, 0);
for tok in {doc, usdrif, usdt0, wrbtc}: assertLe(tok.balanceOf(admin), ghosts.privBaseline[admin][tok]);
for h: assertEq(claim(admin,h), 0); for lending h: assertEq(shares(admin,h), 0);
```
GHOST_NEEDS: `privBaseline[admin][token]` (set at the end of `setup()`)
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE authority table: Swapper "Cannot … withdraw user funds, redirect a row's buyer or amount". Governance owner "Cannot … migrate or rescue user funds". "Accumulated rBTC is payable only to the recorded user through `DcaManager`; there is no owner rescue or arbitrary recipient parameter." x-ray adversary model: Swapper "Cannot move principal or redirect buyers".
RATIONALE: A leaked swapper key is #2 in the x-ray adversary ranking, and a compromised owner is #4. This is the direct Pattern D check that neither key can route value to itself through batches, path switches, collector or fee setters, oracle swaps or window abuse. The admin native balance is excluded because a fuzzer may send value to the test contract.

PROPERTY_ID: [ADV-10]
TYPE: SPECIFIC (after every non-actor wrapper: swapper window/batch/across-handlers/setPurchasePath, all admin `*_secondary` setters, permissionless `restore*Approval`, and env price/oracle/rate/fee/time moves; env donation handlers are excluded because they are actor transfers by construction)
ENGLISH: No one but a user can move that user's money. Across any call made by a swapper, the owner, a permissionless caller or the environment, every account in ACCOUNTS keeps exactly the same DOC, USDRIF and native rBTC wallet balances, and no account's claimable rBTC falls. A batch may only raise claims.
SOLIDITY_SKETCH:
```
for a in ACCOUNTS:
   assertEq(stateAfter.doc[a], stateBefore.doc[a]); assertEq(stateAfter.usdrif[a], stateBefore.usdrif[a]);
   assertEq(stateAfter.native[a], stateBefore.native[a]);
   for h: assertGe(stateAfter.claim[a][h], stateBefore.claim[a][h]);
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: agent 1's per-account doc/usdrif/native/claim snapshot, taken in the non-actor wrappers
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE: "Principal cannot leave to anyone but its owner". Swapper "Cannot … withdraw user funds". There is no rescue path ("Accumulated rBTC is payable only to the recorded user through `DcaManager`"). The `transferFrom` pull happens only inside `TokenHandler._depositToken`, reached only from the owner's own create/deposit (G-22).
RATIONALE: Every actor approved every handler for `type(uint256).max`, so a non-user path that reaches `_depositToken` or `safeTransferFrom` with a victim address would drain wallets. CON-23 covers a user's own call against others. This property covers the privileged and environment callers, which CON-23 does not.

PROPERTY_ID: [ADV-11]
TYPE: SPECIFIC (after every actor wrapper: create, deposit (incl. dust), withdrawToken (incl. full), withdrawTokenAndInterest, delete, topUpFromInterest, updatePurchaseAmount/Period, setSchedulePaused, withdrawAllAccumulatedInterest, withdrawAllAccumulatedRbtc, and the ADV probes)
ENGLISH: An attacker cannot profit from their own operations. Value the actor's position per stablecoin `T` at the current rate:

`NAVs(a,T) = T.balanceOf(a) + Σ tokenBalance of a's idle-route schedules on T + Σ_{lending h of T} V(a,h)`

and in rBTC:

`NAVr(a) = a.balance + Σ_h claim(a,h)`

No single user call raises `NAVs` by more than its LayerBank rounding allowance or changes `NAVr` at all. Specifically, `ΔNAVr == 0`. `ΔNAVs(T) <= ε`, where `ε = 0` for idle and Sovryn routes, `ε = 1` per LayerBank redeem (the `+1` exact-burn sizing), and `ε = 1 + idx/(2·RAY)` per LayerBank deposit (half-up mint). `withdrawTokenAndInterest` counts as two redeems.
SOLIDITY_SKETCH:
```
// snapshotBefore/After capture NAVs(actor, doc), NAVs(actor, usdrif), NAVr(actor) at the same timestamp
assertEq(stateAfter.navR, stateBefore.navR, "ADV-11 rBTC value created/destroyed by a user call");
for T: assertLe(stateAfter.navS[T], stateBefore.navS[T] + epsLB(op, T), "ADV-11 user profited from own call");
// epsLB = 0 unless the op touched T's LayerBank handler: redeem → +1 each; deposit → +1 + idx/(2*RAY)
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: `navS[doc]`, `navS[usdrif]`, `navR` for the acting actor (agent 1's `V(a,h)` reused); the LayerBank idx at call time
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. Pattern D/F. The ε terms come from the documented rounding: LendingHandler ceil-debits and floor-values, Sovryn mint floors, and the LayerBank `+1` and half-up mint (`LayerBankHandler._underlyingForExactScaledBurn`).
RATIONALE: This is the single "no free money" check for all user-reachable paths. It catches a withdrawal paying more than the shares burned, interest that can be taken twice or before principal, top-up or edit side effects that create value, rBTC appearing from a claim, and dust-sized cycles whose per-call gain exceeds ε. Repeated over a campaign, a per-call violation compounds (Pattern I-d). Because the snapshots share one timestamp, LayerBank's time accrual cannot cause false positives.

---

## D. Access control under active attack

PROPERTY_ID: [ADV-12]
TYPE: SPECIFIC (attack handler `adv_impersonateSwapper(which, callerSeed, routeSeed, rowMask, pathSeed)`; caller ∈ actors, feeCollector, admin, and any swapper currently revoked)
ENGLISH: An account that is not currently an allowlisted swapper cannot use the swapper's powers. Window activation, `batchBuyRbtc` and `batchBuyRbtcAcrossHandlers` revert with `DcaManager__UnauthorizedSwapper` and change nothing. `setPurchasePath` on a Dex handler reverts for any caller that is neither the owner nor allowlisted. The unlock block, every schedule's anchor and balance, every claim and every active path are unchanged.
SOLIDITY_SKETCH:
```
address c = pickCaller(callerSeed); if (operationsAdmin.isSwapper(c)) return;
uint256 u0 = unlock; snapshot anchors/tokenBalances of the rows, claims, path hashes
vm.prank(c);
if (which==0) try dcaManager.activateProtectedPurchaseWindow() { fail(); } catch (bytes memory e) { assertEq(sel(e), UnauthorizedSwapper.selector); }
if (which==1) try dcaManager.batchBuyRbtc(Batch(cleanRowIds, t, r, 0)) { fail(); } catch (bytes memory e) { assertEq(sel(e), UnauthorizedSwapper.selector); }
if (which==2) try dcaManager.batchBuyRbtcAcrossHandlers(...) { fail(); } catch (bytes memory e) { assertEq(sel(e), UnauthorizedSwapper.selector); }
if (which==3 && c != admin) try IPurchaseUniswap(dex).setPurchasePath(allowedPath) { fail(); } catch {}
assertEq(unlock, u0); assert snapshots unchanged;
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: inline (unlock, rows' anchor/tokenBalance, claims, `keccak256(getSwapPath())` per Dex handler)
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: x-ray G-1 (`onlySwapper`, `DcaManager.sol:75`) and G-33 ("Only the owner or a swapper activates a path"). AUDIT_GUIDE: the swapper powers belong to the allowlisted Swapper role, and `revokeSwapper` ends a leaked key's abilities ("`revokeSwapper` ends it").
RATIONALE: The active-attack form of ST-15. This handler sends the calls itself, from actors, the collector and a revoked key, and checks that the attempted call left nothing behind. A gap would let any user lock all users out (chained windows) or trigger purchases at a chosen moment.

PROPERTY_ID: [ADV-13]
TYPE: SPECIFIC (attack handler `adv_callHandlerDirectly(which, routeSeed, victimSeed, amount)`, caller = current actor)
ENGLISH: Nobody can bypass DcaManager by calling a handler directly. Every fund-moving or interest call on every handler, made by an actor, reverts with `DcaManagerAccessControl__OnlyDcaManagerCanCall` and moves nothing. The calls are `depositToken(victim, x)`, `withdrawToken(actor, x)`, `batchBuyRbtc(...)`, `withdrawAccumulatedRbtc(victim)`, `withdrawInterest(actor, 0)`, `getAccruedInterest` and `quoteAccruedInterest`. Victim wallets, shares, claims and handler balances stay the same.
SOLIDITY_SKETCH:
```
h = _route(routeSeed).handler; v = toActorNotCurrent(victimSeedAddr); snapshot balances/shares/claims of actor & v, handler cash/receipt
vm.prank(actor);
which%7==0: try ITokenHandler(h).depositToken(v, clampBetween(amount,1,1e24))      { fail("ADV-13 pull victim"); } catch (bytes memory e) { assertEq(sel(e), OnlyDcaManagerCanCall.selector); }
which%7==1: try ITokenHandler(h).withdrawToken(actor, amount)                       { fail(); } catch ...
which%7==2: try IPurchaseRbtc(h).batchBuyRbtc([v], [id], [pa], 0)                   { fail(); } catch ...
which%7==3: try IPurchaseRbtc(h).withdrawAccumulatedRbtc(v)                         { fail(); } catch ...
which%7==4 (lending): try ILendingHandler(h).withdrawInterest(actor, 0)             { fail("ADV-13 interest = whole position"); } catch ...
which%7==5 (lending): try ILendingHandler(h).getAccruedInterest(actor, 0)           { fail(); } catch ...
which%7==6 (lending): try ILendingHandler(h).quoteAccruedInterest(actor, 0)         { fail(); } catch ...
assert all snapshots unchanged
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: inline
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: x-ray G-22: "Handlers move funds only for their immutable manager". Context §4: "`onlyDcaManager` on every fund-moving handler call". AUDIT_GUIDE: "Handlers take deposits, withdrawals, interest calls, purchases, and rBTC claims from their immutable [manager]".
RATIONALE: This catches a missing modifier on any of these entry points. The worst cases are `depositToken(victim)`, which would pull a victim's approved stablecoin with no ledger credit, and `withdrawInterest(attacker, 0)`, which would redeem the attacker's whole position as "interest" while the principal stays on the books. Either is a one-call drain.

PROPERTY_ID: [ADV-14]
TYPE: SPECIFIC (attack handler `adv_mutateForeignSchedule(which, victimScheduleSeed, amount)`)
ENGLISH: An actor cannot change, fund, pause, withdraw from, top up or delete a schedule owned by someone else. This covers all eight schedule mutators, and for delete both the victim's real `scheduleIdIndex` and an index into the attacker's own list. Each one reverts with `DcaManager__NotScheduleOwner`, or with `UserMutationsLocked` for a guarded call inside a window. The victim's schedule, id list, shares, claims and wallet do not change.
SOLIDITY_SKETCH:
```
pick tracked s with s.owner != actor; snapshot S(s), ids(s.owner,s.token), shares/claims/wallet of s.owner and actor
vm.prank(actor);
which%9: depositToken | withdrawToken | withdrawTokenAndInterest | deleteDcaSchedule(victimIdx) | deleteDcaSchedule(attackerIdx)
       | updatePurchaseAmount | updatePurchasePeriod | setSchedulePaused | topUpFromInterest
try ... { fail("ADV-14 foreign mutation succeeded"); }
catch (bytes memory e) { assertTrue(sel(e) == NotScheduleOwner.selector || (windowLive && guarded(which) && sel(e) == UserMutationsLocked.selector)); }
assert snapshots unchanged
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: inline
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE authority table: Schedule owner "Cannot: Address another user's schedule through a mutator". x-ray G-4 ("The single ownership check for every schedule mutator"). DcaManager NatSpec: "`_callersSchedule` is the single user-ownership check".
RATIONALE: Pattern J, "User A cannot operate on User B's position". The harness's clamped wrappers only ever pick the actor's own schedules (`_pickOwnedSchedule`), so without this handler the ownership check is never exercised against a real victim. `depositToken` on a foreign id matters too: it would pull the attacker's funds into the victim's principal on a lending route while minting the shares to the attacker.

PROPERTY_ID: [ADV-15]
TYPE: SPECIFIC (attack handler `adv_nonOwnerSetter(which, handlerSeed, arg)`, caller = current actor or a swapper)
ENGLISH: A non-owner cannot reconfigure the protocol to their benefit. Each of the following reverts and leaves the setting unchanged when called by an actor or a swapper:
- `setFeeCollector(self)` and `setFeeRateParams` on any handler;
- `setMocOracle`, `setAmountOutMinimumPercent`, `setAmountOutMinimumSafetyCheck` and `setPurchasePathAllowed` on Dex handlers;
- DcaManager's three setters;
- OperationsAdmin's `addSwapper(self)`, `revokeSwapper`, `setDepositsPaused`, `registerRoute` and `assignHandler`;
- `transferOwnership(self)` anywhere.

`renounceOwnership` reverts even for the owner.
SOLIDITY_SKETCH:
```
snapshot getFeeCollector/getFeeSettings/getMocOracle/percent/safety/path-allowed(hashes)/min period/cap/min amounts/isSwapper/areDepositsPaused/owner()
vm.prank(actorOrSwapper); try <setter>(attackerFavouringArgs) { fail("ADV-15 non-owner setter"); } catch {}
vm.prank(admin); try BitChillOwnable(target).renounceOwnership() { fail("ADV-15 renounce"); } catch {}
assert snapshot unchanged
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: inline
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: Context §4: "`onlyOwner` (Ownable2Step, renounce reverts) on every setter". AUDIT_GUIDE authority table: only the Governance owner configures fees, collector, oracle, floors, paths, swappers and pauses, and it "Cannot … renounce ownership".
RATIONALE: `setFeeCollector(attacker)` would redirect every later fee credit. `setFeeRateParams(500,500,…)` with the collector role is a 5% skim. `addSwapper(self)` would turn any user into a window and batch controller. `setMocOracle` or a lowered floor would open sandwiching. The admin wrappers in the harness only ever call these as admin, so their access checks are never attacked.

---

## E. Swapper key, window and environment edge states

PROPERTY_ID: [ADV-16]
TYPE: GLOBAL
ENGLISH: A swapper cannot lock users out for more than one window per activation, and revoking every swapper frees users within five blocks.
- Always, `unlock <= block.number + 5`.
- If the allowlist has been empty since block `B`, then `unlock <= B + 5`. Every guarded user call is therefore available from `B + 5` on, and no activation succeeds while it is empty.
SOLIDITY_SKETCH:
```
assertLe(dcaManager.getUserMutationsAllowedFromBlock(), block.number + 5, "ADV-16 window longer than 5 blocks");
if (ghosts.allowlistEmptySince != 0)
    assertLe(dcaManager.getUserMutationsAllowedFromBlock(), ghosts.allowlistEmptySince + 5, "ADV-16 lock outlived revocation");
// ghost upkeep in operationsAdmin_secondary: after revoke, if !isSwapper(sw0) && !isSwapper(sw1) && since==0: since = block.number;
//                                           after add: since = 0
```
GHOST_NEEDS: `allowlistEmptySince`
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: DcaManager header: "a self-expiring five-block window". x-ray I-13: "each activation sets the unlock block to `block.number + 5`". AUDIT_GUIDE, leaked swapper key: "`revokeSwapper` ends it". X-5 / context §5: a revoked swapper's live window stays in place, but only until its own `N + 5`, which is consistent with the `B + 5` bound.
RATIONALE: This bounds the accepted "chained windows" grief. A leaked key may chain windows, but only one activation at a time, each lasting exactly five blocks, and the owner's revocation is a hard stop. The property would catch an unlock block set too far ahead, through arithmetic or a stale write, or a revoked key still able to extend the lock.

PROPERTY_ID: [ADV-17]
TYPE: SPECIFIC (after `env_donateIntermediateToRouter`, then `adv_cleanBatchLiveness` on the USDRIF routes with path 1 active)
ENGLISH: Donating an intermediate token to the shared router cannot block Dex purchases. Suppose the alternative path (USDRIF → USDT0 → WRBTC) is active and any amount of USDT0 was sent to the router beforehand. A clean Dex batch that meets ADV-06's preconditions still succeeds and does not revert with `PurchaseUniswap__IntermediateBalanceChangedInRouter`.
SOLIDITY_SKETCH:
```
function env_donateIntermediateToRouter(uint256 amount) public { usdt0.mint(address(swapRouter), clampBetween(amount, 1, 1e24)); }
// in adv_cleanBatchLiveness on a Dex route whose keccak256(getSwapPath()) == keccak256(path1):
catch (bytes memory err) { assertTrue(sel(err) != PurchaseUniswap__IntermediateBalanceChangedInRouter.selector, "ADV-17 donation blocked purchase"); }
```
GHOST_NEEDS: none (optional: `routerUsdt0Donated`)
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: `PurchaseUniswap._purchaseRbtc` NatSpec: "This venue-specific layer also requires every intermediate-token router balance to return to its pre-swap value. Comparing deltas, not zero balances, prevents donated tokens from blocking it."
RATIONALE: This is a one-wei griefing vector against every Dex batch if the check ever compared against zero instead of the pre-swap balance. The harness has no way to put USDT0 on the router today, so G-31 is never reached without this handler. Handler-side stablecoin and native donations are already in ADV-01/04/06's "any state" scope.

PROPERTY_ID: [ADV-18]
TYPE: SPECIFIC (probe handlers `adv_createLiveness(routeSeed, d, pa, periodDays)`, `adv_depositLiveness(scheduleSeed, d)`, `adv_topUpLiveness(scheduleSeed, amount)`)
ENGLISH: An attacker cannot stop other users from funding. The following succeed inside or outside a protected window, after any donation, price move or other users' activity:
- `createDcaSchedule` with valid arguments: pair not paused, owner's list below the cap, `minPurchase <= pa <= d <= balance`, a whole-day period ≥ the minimum, and on Sovryn `d·1e18 >= tokenPrice` so that at least one share mints;
- `depositToken` of any `d` in `[1, balance]` on an owned schedule of an unpaused pair, on Sovryn with `d·1e18 >= tokenPrice`;
- `topUpFromInterest` with `needed <= amount <= accrued`.
SOLIDITY_SKETCH:
```
// create
r = _route(seed); if (paused(r) || ids(actor,r.token).length >= cap) return; clamp args as dcaManager_createDcaSchedule_clamped;
if (r.routeIndex == SOVRYN_ROUTE && d * 1e18 < sovrynIToken.tokenPrice()) return;
vm.prank(actor); try dcaManager.createDcaSchedule(...) { _trackSchedule(...); } catch { fail("ADV-18 create"); }
// deposit / topUp analogous (topUp bounds exactly as dcaManager_topUpFromInterest_clamped)
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. The window part is stated in AUDIT_GUIDE ("Creation, deposits, interest top-up … remain open") and already checked by ST-10. The claim that valid arguments always succeed in every other state is this agent's inference.
RATIONALE: Pattern C for the entry points. It catches states that one user or the environment can create to brick everyone's funding:
- a donation that breaks the exact-delta deposit check;
- a LayerBank or Sovryn rate that makes `mintedAmount == 0` for normal amounts;
- an overflow in the uint128 balance write;
- a top-up within the quoted interest that the contract still refuses (RD-08 checks the quote; this checks liveness under any state).

PROPERTY_ID: [ADV-19]
TYPE: SPECIFIC (requires the optional `ReentrantActor`; checked in `adv_claimLiveness` when the claimant is the reentrant actor)
ENGLISH: A claimant whose `receive()` re-enters the protocol cannot collect more rBTC than it was owed or move any book. During its claim it attempts each of the following re-entries:
- a second `withdrawAllAccumulatedRbtc`;
- `depositToken`, `withdrawToken` or `createDcaSchedule`;
- a direct `withdrawAccumulatedRbtc` on the handler.

Its native gain equals its pre-claim `Σ claim`, every re-entry attempt fails, which it records, and no schedule, share or claim of any account changes beyond the zeroed claims.
SOLIDITY_SKETCH:
```
// ReentrantActor.receive(): if (mode != 0 && !inReentry) { inReentry = true; try <mode call> { ghosts.reentrySucceeded++; } catch {} ghosts.reentryAttempts++; inReentry = false; }
due = Σ claim(ra, h); nb = ra.balance; vm.prank(ra); try dcaManager.withdrawAllAccumulatedRbtc(all) {} catch { fail("ADV-19 claim"); }
assertEq(ra.balance - nb, due); assertEq(ghosts.reentrySucceeded, 0, "ADV-19 re-entry succeeded mid-claim");
assert other accounts' claims/shares/schedules unchanged
```
GHOST_NEEDS: `reentryAttempts`, `reentrySucceeded`
SNAPSHOT_NEEDS: inline
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. DcaManager marks every user mutator `nonReentrant`, and `_withdrawRbtcChecksEffects` writes the sentinel before paying. Neither source states a property for a reentrant claimant.
RATIONALE: The native rBTC payout is the only place where the protocol hands control to a user contract. The harness `Actor` has an empty `receive()`, so the reentrancy guard and the checks-effects ordering are never attacked. A double-claim or a mid-claim deposit desync would show here.

PROPERTY_ID: [ADV-20]
TYPE: SPECIFIC (after `layerBankHandlerDex_secondary` selectors 0 and 1: permissionless `restoreLendingApproval` / `restoreSwapRouterApproval` by an actor)
ENGLISH: The permissionless approval restorers are harmless. When an actor calls them, the only change is the handler's allowance to its own fixed spender (lending pool or iToken, or SwapRouter02), set to `type(uint256).max`. No balance, share, claim, schedule or setting changes, and later exits and purchases are unaffected.
SOLIDITY_SKETCH:
```
// snapshot (agent 1's full snapshot + handler allowances to every known address)
assertEq(IERC20(stablecoin(h)).allowance(h, spender(h)), type(uint256).max);
for every other known address x != spender(h): assertEq(allowance(h, x) after, before);
assert every balance/share/claim/schedule/setting unchanged
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: handler allowances to lending spender, router, MoC proxy, actors; agent 1's snapshot
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. The functions are public by design (context §4: "`restore*Approval` permissionless").
RATIONALE: These are the only public non-view functions on handlers that are not gated. An attacker would use them to aim an allowance at an address they control, or to disturb state in the middle of a window. This is cheap to keep as a regression guard.

---

## Assessed and not turned into properties

- Pattern E (share inflation): no handler prices its shares from its own balances. Both rates are external (aToken index, iToken `tokenPrice`), and the harness cannot donate receipt tokens. RD-05 covers the deposit-credit bound.
- Pattern I-b (narrowing): every narrowing write uses SafeCast, and the harness bounds (`MAX_DEPOSIT` 100k, `uint96` amounts, fee bound ≤ 10k ether) sit far from the limits. A property here would never be falsified.
- Delete-and-recreate buying twice a day, and a period cut making a schedule due again: accepted by design (context §5, x-ray I-12).
- Chained windows by a leaked key: accepted (AUDIT_GUIDE). ADV-16 bounds them instead.
- Price impact across rows, across batches in one call, sandwiches, path changes inside a window: MockSwapRouter02 has no price impact and ignores the path. The only per-row MEV guarantee left is the oracle floor (RD-12), and the per-row bound follows from RD-12 with RD-03.
- Oracle staleness and depeg: the mock oracle reports `block.number` as its publication block, and prices stay in [40k, 60k]. Exits staying live under an invalid oracle is part of ADV-01/04.
