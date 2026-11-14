# Agent 2 — Round-Trip & Rounding Analyst: property list

Scope: round trips (deposit/withdraw, create/delete, interest withdraw/re-withdraw) and rounding direction of every
conversion (ceilDiv share debit, floor share value, venue mint/burn rounding, LayerBank floor-then-+1 sizing,
fee floor, rBTC allocation floors, Dex oracle floor). Conservation identities are in agent-1 (CON-*); where a
property here touches the same quantity, it checks the *rounding direction* or a *round trip*, not the
balance identity.

## Notation (extends agent-1's shared notation)

Agent-1 notation is reused: `routes[k] = {token, routeIndex, handler h, lending, dex}`, `rbtcAsset(h)`, `claim(a,h)`,
`receipt(h)`, `rate(h)`, `D(h)`, `shares(a,h)`, `V(a,h) = shares(a,h)*rate(h)/D(h)` (floor), `ACCOUNTS`.
New helpers:

- `isLB(h)` = `h == layerBankDocMoc || h == layerBankUsdrifDex`. `isSov(h)` = `h == sovrynDocMoc`.
- `ceilDiv(x, y)` = `x == 0 ? 0 : (x - 1) / y + 1`.
- `I(a, r)` = `dcaManager.getAccruedInterest(a, r.token, r.routeIndex)` (lending routes only). In this harness the
  quote and the spendable ceiling read the same rate (neither adapter overrides `_exchangeRate`), so
  `I(a,r) == max(0, V(a,h) − L(a,r))` (agent-1 CON-14).
- `rhuMint(d, idx)` = `(d * 1e27 + idx / 2) / idx` (MockLayerBankAToken mint, Aave half-up `rayDiv`).
- `sovMint(d, p)` = `d * 1e18 / p` (FizzIToken mint, floor).
- `sovPay(T, p, fee)` = `a - a * fee / 10_000` with `a = T * p / 1e18` (FizzIToken burn: floor payout, floored fee
  kept by the market, so the payout itself rounds *up* relative to the exact net by < 1 wei; that is venue rounding).
- `specFee(x, s)` (s = `IPurchaseFees(h).getFeeSettings()`, `m = s.minFeeRate`, `M = s.maxFeeRate`,
  `L = s.feePurchaseLowerBound`), copied from the spec `docs/PURCHASE_FEES.md` §Integer rounding, not from the code:
  `m == M ? x*M/10_000 : x <= L ? x*M/10_000 : (m*x*x + (M-m)*L*(2*x-L)) / (x*10_000)`.
- `withinWindow()` = `block.number < dcaManager.getUserMutationsAllowedFromBlock()`.
- `selectorOf(bytes err)` = first 4 bytes of a caught revert.

Value accounting in RT-* uses an **exact scaled integer** so no rational rounding enters the check:
`Δval(h) = int(ΔC) * int(D(h)) + int(ΔS) * int(rate(h))` where `ΔC` = actor stablecoin change and `ΔS` = actor
virtual-share change. Magnitudes: C ≤ 1.1e24, D ≤ 1e27, so |terms| ≤ ~1e51 < 2^255. `rate(h)` is constant inside one
handler call (LayerBank index depends only on `block.timestamp` or a stored override; FizzIToken price only moves
via `env_moveSovrynPrice`).

## Derived rounding slack (used by several properties; all exact, assume `RAY ≤ idx`, which the harness keeps:
the mock index starts at RAY and both time accrual and `env_bumpLayerBankIndex` only raise it)

- LayerBank deposit `d`: minted `s = rhuMint(d, idx)` ⇒ `s*idx − d*RAY ≤ floor(idx/2)` and `s*idx − d*RAY > floor(idx/2) − idx`.
- LayerBank redeem of `sr` shares: the handler withdraws `a = floor(sr*idx/RAY)` or `a+1` and G-26 forces the mock's
  half-up burn to equal `sr` exactly ⇒ `paid*RAY − sr*idx ≤ ceil(idx/2) − 1` and `paid ≥ floor(sr*idx/RAY)`.
  (Proof that floor-then-+1 is always exact for `idx ≥ RAY`: in the +1 branch `a*RAY + floor(idx/2) < sr*idx`, so
  `(a+1)*RAY + floor(idx/2) < sr*idx + RAY ≤ (sr+1)*idx` and `(a+1)*RAY > sr*idx`; in the floor branch
  `a*RAY ≤ sr*idx` gives `rayDiv(a) ≤ sr`. Hence no ShareConsumptionMismatch in this harness.)
- Sovryn deposit `d` at price `p`: `s*p ≤ d*1e18` and `s*p > d*1e18 − p`. Redeem of `sr`: `paid*1e18 ≤ sr*p`.
- ceilDiv debit for a request `w'`: `sr*rate ≥ w'*D` and `(sr−1)*rate < w'*D`.
- So per op, `Δval` ≤ `floor(idx/2)` (LB deposit), `ceil(idx/2) − 1` (LB redeem), `0` (any Sovryn op), and one
  LB deposit→redeem cycle is ≤ `idx − 1` (i.e. strictly less than one wei of real value, all of it the venue's
  half-up gift, never taken from another BitChill user because virtual shares equal measured receipt deltas).

## Pattern E2 (code-analysis result, not a runtime property)

| Direction | Conversion used | Rounding | Favors |
|---|---|---|---|
| deposit (create/deposit) | measured receipt delta (venue: Sovryn floor, LayerBank half-up) | venue | Sovryn: protocol; LB: up to ½ share to depositor, paid by the venue |
| withdrawToken / delete | `_sharesToStablecoin` clamp (floor), then `_stablecoinToShares` (ceilDiv) | floor value / ceil debit | protocol |
| withdrawInterest | floor value − principal, ceilDiv debit | floor / ceil | protocol |
| batch row | ceilDiv debit; clamp weight = floor value | ceil / floor | protocol |
| LB burn sizing | floor + conditional 1 wei | exact burn | neutral (exact share consumption) |
| rBTC allocation | `floor(Q*net_i/G)`, `floor(Q*F/G)` | floor | protocol (dust stays on handler) |
| fee | single final floor | floor | user by < 1 wei |

The two directions use **different** converters with opposite rounding, so the classic same-converter bug is absent.
The only user-favoring rounding is LayerBank's half-up mint and burn, which is venue behaviour. The mandatory C2
properties (RT-01..RT-03) are still generated below and must allow exactly that venue slack, no more.

## Harness additions these properties need

1. Round-trip handlers (new, in `DcaManagerHandler` or a new `RoundTripHandler`): `roundTrip_depositWithdraw`,
   `roundTrip_createDelete`, `roundTrip_interestTwice`. They call `dcaManager` directly inside one `asActor` prank
   (do not nest the existing `asActor` wrappers; nested `startPrank` reverts).
2. try/catch wrappers (or a variant of the existing unclamped wrappers) around lending redeems, batches and
   `topUpFromInterest`, so RD-07 and RD-08 can inspect revert selectors.
3. A batch pre-snapshot inside `dcaManager_batchBuyRbtc` (the funnel for every single-handler batch variant):
   per row `(buyer, purchaseAmount)` read from `getDcaSchedule` before the call; `shares(b,h)` for every actor;
   `claim(a,h)` for `ACCOUNTS`; `rbtcAsset(h)`; `rate(h)`; `getFeeSettings()`; `getFeeCollector()`;
   `usdrif.balanceOf(swapRouter)`; for Dex handlers `getAmountOutMinimumPercent()` and `getMocOracle().getPrice()`.
4. Snapshot field `interest[actorIdx][routeIdx]` (3 actors × 5 routes; zero on idle routes) taken before and after
   every actor-driven handler and every batch (RD-06, RD-05).
5. A test-only probe `FizzFeeProbe is PurchaseFees` (constructor forwards to `PurchaseFees(collector, settings, owner)`;
   one view `calc(uint256[] memory a) returns (uint256 totalFee, uint256[] memory net, uint256 sum)` that returns
   `_calculateFeeAndNetWeights(a)`). Deploy one in `setup()`, owned by `admin`, and copy a live handler's settings
   into it before each probe call (RD-10, RD-11).

---

PROPERTY_ID: [RT-01] [MANDATORY C2]
TYPE: SPECIFIC (dedicated round-trip handler `roundTrip_depositWithdraw`)
ENGLISH: On a lending route, any number of deposit→withdraw (or withdraw→re-deposit) cycles of the same amount on
one schedule leaves its nominal principal unchanged and never increases the actor's value (stablecoin plus the
exact value of their virtual shares). On Sovryn the gain is ≤ 0 exactly. On LayerBank it is at most `idx − 1` scaled
units per cycle, which is less than one wei of real value and comes from the venue's half-up mint and burn.
SOLIDITY_SKETCH:
```solidity
function roundTrip_depositWithdraw(uint256 seed, uint256 amount, uint8 cycles, bool withdrawFirst) public asActor {
    if (withinWindow()) return;                                     // withdrawToken is window-guarded
    uint256 i = _pickOwnedSchedule(actor, seed); if (i == type(uint256).max) return;
    TrackedSchedule memory s = trackedSchedules[i];
    Route memory r = _routeOf(s.token, s.routeIndex);
    if (operationsAdmin.areDepositsPaused(r.token, r.routeIndex)) return;
    cycles = uint8(1 + cycles % 4);
    uint256 tb0 = dcaManager.getDcaSchedule(s.token, s.scheduleId).tokenBalance;
    uint256 bal = IERC20(r.token).balanceOf(actor);
    uint256 cap = bal / cycles; if (cap > MAX_DEPOSIT) cap = MAX_DEPOSIT;
    if (withdrawFirst && tb0 < cap) cap = tb0;
    if (cap == 0) return;
    amount = clampBetween(amount, 1, cap);

    uint256 C0 = IERC20(r.token).balanceOf(actor);
    uint256 S0 = r.lending ? shares(actor, r.handler) : 0;
    uint256 R  = r.lending ? rate(r.handler) : 0;
    uint256 I0 = r.lending ? I(actor, r) : 0;
    bool clamped;                                                   // recorded for RT-03 / RT-04
    for (uint256 k; k < cycles; k++) {
        if (!withdrawFirst) {
            try dcaManager.depositToken(r.token, s.scheduleId, amount) {} catch { if (k == 0) return; else revert(); }
            if (r.lending && shares(actor, r.handler) * R / D(r.handler) < amount) clamped = true;
            dcaManager.withdrawToken(r.token, s.scheduleId, amount);        // a revert here is itself an RD-07 lead
        } else {
            if (r.lending && shares(actor, r.handler) * R / D(r.handler) < amount) clamped = true;
            try dcaManager.withdrawToken(r.token, s.scheduleId, amount) {} catch { if (k == 0) return; else revert(); }
            dcaManager.depositToken(r.token, s.scheduleId, amount);
        }
    }
    int256 dC = int256(IERC20(r.token).balanceOf(actor)) - int256(C0);
    eq(dcaManager.getDcaSchedule(s.token, s.scheduleId).tokenBalance, tb0, "RT-01 principal changed by round trip");
    if (r.lending) {
        int256 dS = int256(shares(actor, r.handler)) - int256(S0);
        int256 dVal = dC * int256(D(r.handler)) + dS * int256(R);
        int256 slack = isLB(r.handler) ? int256(cycles) * (int256(R) - 1) : int256(0);
        lte(dVal, slack, "RT-01 round trip created value for the user");
    }
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: local only (C0, S0, R, I0, tb0, clamped)
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: `LendingHandler._stablecoinToShares` NatSpec: "Rounds up so the virtual share debit is never below what the lending protocol may burn"; `_redeemShares` NatSpec: "Redeems stablecoin by debiting the corresponding rounded-up shares"; `_sharesToStablecoin` "(round down)"; x-ray I-2 "a conversion round trip never creates value for the user". Closed form: Sovryn per-op Δval ≤ 0 (floor mint `s*p ≤ d*1e18`, floor payout `paid*1e18 ≤ sr*p`). LB per-cycle Δval ≤ `floor(idx/2) + ceil(idx/2) − 1 = idx − 1` (half-up mint and G-26-exact half-up burn; see "Derived rounding slack").
RATIONALE: This is the Pattern C2 dust-extraction loop and the most direct test that the protocol never rounds a round trip in the user's favour. A cash-only C2 check would fire on known dust. Example (Sovryn `p = 2.9e18`, `d = 100`, with prior shares): mint 34 shares, debit `ceil(34.48) = 35`, pay `floor(101.5) = 101`. Cash rises by 1 while a 2.9-wei share is lost. So value, not cash, is the right measure. The check fires if the debit ever rounds down, if the clamp ever rounds the value up, if LB sizing over-withdraws by more than its +1, or if a deposit credits computed (ceil) shares instead of measured ones. The withdrawFirst flag covers Pattern B (reverse-then-forward).

PROPERTY_ID: [RT-02] [MANDATORY C2]
TYPE: SPECIFIC (same handler, idle routes)
ENGLISH: On an idle route, deposit→withdraw (or withdraw→re-deposit) cycles return the actor exactly the stablecoin they started with, leave the schedule's principal unchanged, and leave the handler's stablecoin balance unchanged.
SOLIDITY_SKETCH:
```solidity
// inside roundTrip_depositWithdraw when !r.lending, after the loop:
eq(IERC20(r.token).balanceOf(actor), C0, "RT-02 idle round trip changed actor cash");
eq(IERC20(r.token).balanceOf(r.handler), H0, "RT-02 idle round trip changed handler cash");   // H0 taken before the loop
eq(dcaManager.getDcaSchedule(s.token, s.scheduleId).tokenBalance, tb0, "RT-02 principal changed");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: local H0 = handler stablecoin before
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: Identity. G-23: the deposit pulls exactly `depositAmount` (`TokenHandler.sol:73`). `TokenHandler._withdrawToken` transfers exactly `withdrawalAmount`. `IdleHandler` NatSpec: "Deposits stay on this contract as the stablecoin itself". There is no conversion on idle routes, so the round trip is exact.
RATIONALE: This is the zero-rounding baseline for C2. Any non-zero delta means a conversion or fee slipped into the idle path, or the manager debits differently from what it pays.

PROPERTY_ID: [RT-03] [MANDATORY C2]
TYPE: SPECIFIC (same handler, lending routes)
ENGLISH: A deposit→withdraw round trip never leaves the actor with more virtual shares than before (no free shares), and does not raise their accrued interest. The reverse order gives the same guarantee whenever the withdrawal was not clamped.
SOLIDITY_SKETCH:
```solidity
// after the loop, r.lending:
uint256 S1 = shares(actor, r.handler);
if (!withdrawFirst || !clamped) lte(S1, S0, "RT-03 round trip minted free shares");
if (!withdrawFirst) lte(I(actor, r), I0, "RT-03 round trip raised accrued interest");
else lte(I(actor, r), I0 + (isLB(r.handler) ? cycles * ((R / 2 + 1e27 - 1) / 1e27) : 0), "RT-03 reverse round trip raised interest beyond LB mint dust");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: local S0, I0, clamped
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: Closed form from the documented ceil debit. No clamp: `s*rate ≤ d*D + floor(rate/2)` (LB) or `≤ d*D` (Sovryn), and `sr*rate ≥ d*D`, so `s − sr < 1` and therefore `≤ 0`. Clamp (deposit first): `sr = ceilDiv(floor(S*rate/D)*D, rate) = S` (all shares), so `ΔS = −S0 ≤ 0`. Since principal is unchanged and shares do not grow, `V` cannot grow, so `I` cannot grow. Reverse order with a clamp can legitimately end with more shares, because the full re-deposit buys more shares than the clamped position held after a loss; that case is excluded.
RATIONALE: This is Pattern B, `deposit(redeem(x)) ≥ x` from the protocol's side. A share count that grows across a round trip is the textbook symptom of a debit that rounds down. The interest check catches the loop "withdraw principal, get 1 wei of interest, withdraw interest".

PROPERTY_ID: [RT-04]
TYPE: SPECIFIC (same handler, lending routes)
ENGLISH: When no withdrawal in the loop was clamped, the actor loses at most one virtual share per deposit→withdraw cycle. The protocol's rounding favours itself by at most one share, never more.
SOLIDITY_SKETCH:
```solidity
if (r.lending && !clamped) gte(shares(actor, r.handler) + cycles, S0, "RT-04 round trip over-debited shares");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: local S0, clamped
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. Derivation: `sr < d*D/rate + 1`. The mint gives `s > d*D/rate − 1` (Sovryn floor) or `> d*D/rate − 1/2 − …` (LB half-up). So `sr − s < 2`, and therefore `≤ 1`. It holds in both orders.
RATIONALE: This is the user-protection side of RT-03. A debit that rounds up twice, or a ceil applied to an already-ceiled amount, would quietly drain users by one share per operation.

PROPERTY_ID: [RT-05]
TYPE: SPECIFIC (new handler `roundTrip_createDelete`)
ENGLISH: Creating a schedule with deposit `d` and deleting it in the same call is a no-profit round trip. On idle routes the actor's cash is exactly restored. On lending routes `Δval ≤ 0` (Sovryn) or `≤ idx − 1` (LayerBank), the actor's shares do not increase, and their accrued interest does not increase. Their schedule list for the token and every other schedule they own are unchanged.
SOLIDITY_SKETCH:
```solidity
function roundTrip_createDelete(uint256 routeSeed, uint256 d, uint256 p, uint256 periodDays) public asActor {
    if (withinWindow()) return;
    Route memory r = _route(routeSeed);
    if (operationsAdmin.areDepositsPaused(r.token, r.routeIndex)) return;
    uint256 minP = dcaManager.getTokenMinPurchaseAmount(r.token);
    uint256 bal = IERC20(r.token).balanceOf(actor); if (bal < minP) return;
    d = clampBetween(d, minP, bal < MAX_DEPOSIT ? bal : MAX_DEPOSIT); p = clampBetween(p, minP, d);
    uint256 period = clampBetween(periodDays, _minPeriodDays(), MAX_PERIOD_DAYS) * 1 days;
    (uint64[] memory ids0,) = dcaManager.getDcaSchedules(actor, r.token);
    uint256 C0 = IERC20(r.token).balanceOf(actor); uint256 S0 = r.lending ? shares(actor, r.handler) : 0;
    uint256 R = r.lending ? rate(r.handler) : 0; uint256 I0 = r.lending ? I(actor, r) : 0;
    try dcaManager.createDcaSchedule(r.token, d, p, period, r.routeIndex) {} catch { return; }
    uint64 id = uint64(dcaManager.getSchedulesCreatedCount());
    dcaManager.deleteDcaSchedule(r.token, id, ids0.length);         // the new id was pushed last
    (uint64[] memory ids1,) = dcaManager.getDcaSchedules(actor, r.token);
    eq(ids1.length, ids0.length, "RT-05 schedule list not restored");
    for (uint256 j; j < ids0.length; j++) eq(ids1[j], ids0[j], "RT-05 other schedule ids reordered");
    int256 dC = int256(IERC20(r.token).balanceOf(actor)) - int256(C0);
    if (!r.lending) { eq(dC, 0, "RT-05 idle create/delete changed cash"); return; }
    int256 dS = int256(shares(actor, r.handler)) - int256(S0);
    lte(dS, 0, "RT-05 create/delete minted free shares");
    lte(dC * int256(D(r.handler)) + dS * int256(R), isLB(r.handler) ? int256(R) - 1 : int256(0), "RT-05 create/delete created value");
    lte(I(actor, r), I0, "RT-05 create/delete raised interest");
}
```
GHOST_NEEDS: none (the schedule is created and deleted inside the call, so `trackedSchedules` is untouched)
SNAPSHOT_NEEDS: local
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: The same closed form as RT-01 and RT-03 (one deposit→redeem cycle). `deleteDcaSchedule` withdraws the whole `tokenBalance = d` through the same `_withdrawToken`/`_redeemShares` path. Swap-pop of the last index leaves the earlier ids in place (`DcaManager._removeScheduleId`).
RATIONALE: This is the open/close pair. It exercises the delete path, which skips the `withdrawalAmount > 0` guard and reads `tokenBalance` before `delete`. It also checks that a full exit right after entry yields no rounding profit even when the user has other schedules sharing the same share pool.

PROPERTY_ID: [RT-06]
TYPE: SPECIFIC (new handler `roundTrip_interestTwice`, also asserted after every successful `withdrawAllAccumulatedInterest` / `withdrawTokenAndInterest`)
ENGLISH: After an interest withdrawal on a lending route, the actor's accrued interest is exactly zero. A second interest withdrawal in the same block pays nothing and burns no shares. Interest cannot be re-extracted by repetition.
SOLIDITY_SKETCH:
```solidity
function roundTrip_interestTwice(uint256 routeMask) public asActor {
    if (withinWindow()) return;
    (address[] memory t, uint256[] memory ri) = _routePairs(routeMask);
    try dcaManager.withdrawAllAccumulatedInterest(t, ri) {} catch { return; }
    uint256 C1 = /* per token */ ...; uint256[] memory S1 = /* shares(actor,h) per lending pair */;
    for each lending pair r in (t, ri): eq(I(actor, r), 0, "RT-06 interest left after interest withdrawal");
    dcaManager.withdrawAllAccumulatedInterest(t, ri);                 // must not revert (all no-ops)
    for each token: eq(IERC20(token).balanceOf(actor), C1[token], "RT-06 second interest withdrawal paid");
    for each lending pair: eq(shares(actor, h), S1[h], "RT-06 second interest withdrawal burned shares");
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: local
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: Closed form from the ceil debit (`LendingHandler._redeemShares` NatSpec "debiting the corresponding rounded-up shares"; x-ray X-6). Let `I = floor(S*r/D) − L` and `sr = ceilDiv(I*D, r)`. Then `(S−sr)*r/D ≤ S*r/D − I < L + 1`, so `floor((S−sr)*r/D) ≤ L` and the new interest is 0. If `I == 0`, `withdrawInterest` returns early and the second call is a no-op.
RATIONALE: This is the idempotence form of the interest round trip. If the debit ever floored, each call would leave 1 wei of fresh "interest" and a loop would drain principal-backing shares 1 wei at a time. It is stricter than agent-1 CON-19, which allows `rate/D + 2` of remaining interest.

PROPERTY_ID: [RD-01]
TYPE: SPECIFIC (after successful `withdrawToken`, `deleteDcaSchedule`, `withdrawTokenAndInterest`, `withdrawAllAccumulatedInterest` on lending routes)
ENGLISH: Every single-user redeem debits exactly `ceilDiv(w'*D, rate)` virtual shares. Here `w'` is the requested principal clamped to the user's floored share value, or the floored interest for an interest withdrawal. The debit therefore always covers the request (it never rounds down) and never over-debits by a whole share.
SOLIDITY_SKETCH:
```solidity
// before: S0 = shares(actor,h), R = rate(h), I0 = I(actor,r), w = requested (tokenBalance for delete / max sentinel)
uint256 V0 = S0 * R / D(h);
uint256 wP = w < V0 ? w : V0;
uint256 sr1 = ceilDiv(wP * D(h), R);                       // principal part (0 for pure interest calls)
uint256 sr2;
if (isInterestCall) {                                       // withdrawAllAccumulatedInterest: wP = 0, interest = I0
    uint256 S1p = S0 - sr1, Lp = L0 - w;                    // withdrawTokenAndInterest: recompute after principal
    uint256 V1p = S1p * R / D(h); uint256 Ip = V1p > Lp ? V1p - Lp : 0;
    sr2 = ceilDiv(Ip * D(h), R);
}
eq(S0 - shares(actor, h), sr1 + sr2, "RD-01 share debit is not ceilDiv of the clamped request");
// directional form (if the synthesizer prefers inequalities):
//   (sr1) * R >= wP * D(h)                -- debit covers the request (protocol-favoring)
//   sr1 == 0 || (sr1 - 1) * R < wP * D(h) -- at most one share of over-debit
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: `shares(actor,h)`, `rate(h)`, `I(actor,r)`, `L(actor,r)` (sum of tracked `tokenBalance`), the schedule's `tokenBalance` before the call
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: `LendingHandler._stablecoinToShares` NatSpec: "Rounds up so the virtual share debit is never below what the lending protocol may burn … Round-down would allow the books to drift above reality". `_withdrawToken` clamps with `_sharesToStablecoin` "(round down)". x-ray I-2.
RATIONALE: This pins the rounding direction of the main conversion at every single-redeem call site. A floor instead of a ceil, or a clamp that rounds up, shows up here directly rather than as a later solvency drift.

PROPERTY_ID: [RD-02]
TYPE: SPECIFIC (after every successful batch on a lending handler; inside `dcaManager_batchBuyRbtc`, and per handler inside the across-handlers wrapper)
ENGLISH: Processing rows in order, each lending batch row debits its buyer `ceilDiv(purchaseAmount*D, rate)` shares when the buyer still holds that many. Otherwise it debits all the buyer's remaining shares and its funding weight becomes their floored value. Each buyer's final virtual shares equal this simulation exactly, and the receipt-share burn equals the simulated total `T`.
SOLIDITY_SKETCH:
```solidity
// pre: rows[k] = (buyer_k, p_k) from getDcaSchedule before the batch; rem[a] = shares(a,h) for a in actors; R = rate(h)
uint256 T; uint256[] memory x = new uint256[](n);
for (k = 0; k < n; k++) {
    uint256 need = ceilDiv(p_k * D(h), R);
    if (need > rem[buyer_k]) { x[k] = rem[buyer_k] * R / D(h); need = rem[buyer_k]; }   // clamp (x[k] > 0 on success)
    else x[k] = p_k;
    rem[buyer_k] -= need; T += need;
}
for (a in actors) eq(shares(a, h), rem[a], "RD-02 batch share debit differs from per-row ceilDiv/clamp");
eq(receipt_before(h) - receipt(h), T, "RD-02 receipt burn != simulated debit");
// x[] (funded weights) is handed to RD-03
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: batch pre-snapshot (rows, `shares(a,h)` for all actors, `receipt(h)`, `rate(h)`)
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE §Scheduling: "Each purchase row uses a rounded-up share debit. If the buyer has fewer shares, the row consumes those shares and reduces its funding weight to their stablecoin value. Fees and output allocation use the funded weights." `LendingHandler._batchRetrieveStablecoin` NatSpec: "the protocol burn is exactly the sum of those debits".
RATIONALE: The batch path is the highest-volume conversion and the swapper chooses its row order. Rounding the per-row debit the wrong way, or clamping to a ceiled value, would let one buyer's purchase be funded by another buyer's shares. This also covers the earlier scan's "Sovryn small remainder" and "repeated buyer" leads.

PROPERTY_ID: [RD-03]
TYPE: SPECIFIC (after every successful batch, all five handlers)
ENGLISH: Each account's rBTC claim on the handler rises by exactly the floor of its share of the measured output, `Σ_rows-of-a floor(Q*(x_k − specFee(x_k))/G)`. The current fee collector also gets `floor(Q*ΣspecFee/G)`. Here `x_k` are the funded weights (nominal on idle routes, RD-02's on lending routes), `G = Σ x_k`, and `Q` is the measured increase of the handler's rBTC asset during the batch. Credits are never rounded up, and a first credit or a credit after a full claim decodes to exactly that amount.
SOLIDITY_SKETCH:
```solidity
uint256 Q = rbtcAsset(h) - rbtcAsset_before(h);
IPurchaseFees.FeeSettings memory fs = feeSettings_before(h); address col = collector_before(h);
uint256 G; uint256 Ftot; for (k) { G += x[k]; Ftot += specFee(x[k], fs); }
mapping-like exp[a] = 0 for a in ACCOUNTS;
for (k) exp[buyer_k] += Q * (x[k] - specFee(x[k], fs)) / G;
exp[col] += Q * Ftot / G;
for (a in ACCOUNTS) eq(claim(a, h) - claim_before(a, h), exp[a], "RD-03 rBTC credit is not floor(Q*w/G)");
// directional fallback if the exact form proves brittle:
//   (claimΔ_a) * G <= Q * Σnet_a + (a==col ? Q*Ftot : 0)   and   claimΔ_a * G > that − G * (rows_a + (a==col))
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: batch pre-snapshot (`claim(a,h)` for ACCOUNTS, `rbtcAsset(h)`, fee settings, collector, rows) plus RD-02's `x[]`
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE §Accounting: "Each buyer is credited `floor(Q × netᵢ / G)` and the collector `floor(Q × F / G)` … where `netᵢ` is the row's funding weight minus its fee". `docs/PURCHASE_FEES.md` §Integer rounding (exact fee formula) and §Allocation into rBTC. `IPurchaseRbtc.batchBuyRbtc` NatSpec "buyers `floor(Q × netᵢ / G)`, collector `floor(Q × F / G)`". x-ray I-21 (weights use clamped amounts) and I-14 (`claimable + 1` encoding).
RATIONALE: Agent-1 CON-04/05/06 bound the batch totals. This property fixes each account's share and its rounding direction. It fires if nominal instead of funded weights are used after a clamp (I-21), if a credit is ceiled, if fees are computed on the batch sum instead of per row, or if the `claimable + 1` encoding is off by one on a first credit or after a withdrawal sentinel.

PROPERTY_ID: [RD-04]
TYPE: SPECIFIC (after every successful lending redeem: withdrawToken, delete, interest withdrawals, batches)
ENGLISH: A lending redeem never pays more stablecoin than the burned shares are worth, up to LayerBank's documented +1 wei sizing. Single redeems give the actor `paid ≤ floor(sr*rate/D) + (isLB ? 1 : 0)` and `paid*D ≤ sr*rate + (isLB ? ceil(idx/2) − 1 : 0)`. A redeem that burns zero shares pays exactly zero. On the USDRIF LayerBank route the batch's retrieved stablecoin `Rb` (router delta) satisfies `G ≤ Rb ≤ floor(T*idx/RAY) + 1`. On MoC lending routes `Q*50_000 ≤ floor(T*rate/D) + (isLB?1:0)`.
SOLIDITY_SKETCH:
```solidity
// single redeem: sr = S0 - shares(actor,h) (from RD-01), paid = actor stablecoin delta.
// withdrawTokenAndInterest does two redeems on one handler: sum both bounds (LB slack +2 / 2*(ceil(idx/2)-1), using sr1+sr2).
// withdrawAllAccumulatedInterest naming both DOC lending pairs pays one token from two handlers: sum the per-handler bounds.
if (sr == 0) eq(paid, 0, "RD-04 zero-share redeem paid tokens");
lte(paid, sr * R / D(h) + (isLB(h) ? 1 : 0), "RD-04 redeem paid more than burned shares (floor + LB +1)");
lte(paid * D(h), sr * R + (isLB(h) ? (R + 1) / 2 - 1 : 0), "RD-04 redeem paid above half-up burn value");
// batch on layerBankUsdrifDex (single-handler batch only):
uint256 Rb = usdrif.balanceOf(address(swapRouter)) - routerUsdrif_before;
lte(Rb, T * R / 1e27 + 1, "RD-04 batch retrieved above burned value + 1");
gte(Rb, G, "RD-04 batch retrieved less than funded weights");               // LB has no exit fee
// batch on MoC lending handlers (DOC LB, Sovryn): Q = rbtcAsset delta
lte(Q * 50_000, T * R / D(h) + (isLB(h) ? 1 : 0), "RD-04 MoC batch spent more than burned value");
if (isLB(h) || sovrynIToken.getExitFeeBps() == 0) gte(Q, G / 50_000, "RD-04 MoC batch under-funded vs funded weights");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: actor stablecoin per token, `shares`, `rate(h)`, `receipt(h)`, router USDRIF balance, `rbtcAsset(h)`, RD-02's `T` and `G`
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: `src/layerbank/README.md` §Burn rounding: "the handler picks the underlying amount `a` … `floor(s × index / RAY)`, plus one wei when half-up `rayDiv` of that floor lands on `s − 1`". `LayerBankHandler._underlyingForExactScaledBurn` NatSpec. `_redeemShares` NatSpec: "Zero shares is a no-op". For Sovryn the bound is the floored iToken payout (harness model `FizzIToken.burn`). `G ≤ Rb` follows from `sr_k*rate ≥ x_k*D` per row (ceil) summed.
RATIONALE: This is Pattern A per operation ("never withdraw free tokens"). Here a +2, or a sizing from the request rather than from the debited shares, would pay one user out of the shared receipt position. G-26 would not necessarily catch it if the venue burned to match. The `G ≤ Rb` side checks that the ceil debit really funds every unit of weight the buyers are credited for.

PROPERTY_ID: [RD-05]
TYPE: SPECIFIC (after successful `createDcaSchedule` / `depositToken` / `dcaManager_depositToken_dust` on lending routes)
ENGLISH: A lending deposit credits the actor exactly the receipt shares the venue minted, which is never more than the deposit is worth. On Sovryn `Δshares == floor(d*1e18/p)`, so `Δshares*p ≤ d*1e18`. On LayerBank `Δshares == (d*RAY + idx/2)/idx`, so `Δshares*idx ≤ d*RAY + idx/2`. The actor's accrued interest does not rise on Sovryn and rises by at most `ceil(floor(idx/2)/RAY)` (1 wei in practice) on LayerBank.
SOLIDITY_SKETCH:
```solidity
uint256 dS = shares(actor, h) - S0;  uint256 R = rate(h);
if (isSov(h)) { eq(dS, d * 1e18 / R, "RD-05 Sovryn deposit credit != floor mint"); lte(dS * R, d * 1e18, "RD-05 free Sovryn shares"); }
else          { eq(dS, (d * 1e27 + R / 2) / R, "RD-05 LB deposit credit != half-up mint"); lte(dS * R, d * 1e27 + R / 2, "RD-05 free LB shares"); }
uint256 iSlack = isLB(h) ? (R / 2 + 1e27 - 1) / 1e27 : 0;
lte(I(actor, r), I0 + iSlack, "RD-05 deposit created interest beyond venue mint dust");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: `shares(actor,h)`, `rate(h)`, `I(actor,r)` before
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. The exact mint formulas are the harness mocks' (FizzIToken floor, MockLayerBankAToken half-up). `LendingHandler._depositToken` NatSpec says credited shares are "the measured receipt-share gain, never a protocol return value"; the interest bound follows from `V1 ≤ floor(V0_exact + d + floor(idx/2)/RAY)`.
RATIONALE: This is Pattern B / "no free shares" on the mint side. A handler that credited `_stablecoinToShares(d)` (ceil) would over-credit up to one share per deposit and turn dust deposits (`dcaManager_depositToken_dust`) into an interest pump. AUDIT_GUIDE notes the current half-up mint "can mint fewer shares than a nominal full-principal purchase requires". This property bounds the opposite direction.

PROPERTY_ID: [RD-06]
TYPE: SPECIFIC (after every actor handler except deposits/creates, and after every batch for all buyers)
ENGLISH: No redeem-side or bookkeeping operation increases any account's accrued interest. Principal withdrawal, delete, batch purchase, top-up, interest withdrawal, pause and edits all satisfy `I_after ≤ I_before` exactly, with no slack, on every lending route and for every actor. Only time, an index bump, or a Sovryn price rise (environment calls) may raise it.
SOLIDITY_SKETCH:
```solidity
// snapshot interest[a][k] = I(actors[a], routes[k]) for lending k, before and after
for (a in actors) for (k in lending routes)
    lte(interestAfter[a][k], interestBefore[a][k], "RD-06 user/swapper operation created accrued interest");
// tighter where known: topUpFromInterest(amount) → eq(after, before - amount) is agent-1 CON-20; withdrawInterest → 0 (RT-06)
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: `interest[actorIdx][routeIdx]` before/after
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: Closed form from the documented rounding (ceil debit, floor value; `LendingHandler` NatSpec, x-ray I-2, X-6). Unclamped redeem of `w` with `sr = ceilDiv(w*D, r)`: `floor((S−sr)*r/D) ≤ floor(S*r/D) − w`, while principal falls by exactly `w`. Clamped redeem: `sr = S`, so value becomes 0. A batch row debits principal `p` and value `≥ p`, or all shares. A top-up raises principal only. Edits and pause touch neither.
RATIONALE: This is the global form of the dust-extraction guard. If any path rounds its share debit down, it turns principal into withdrawable interest at 1 wei per call, and the interest path then pays it out in cash. Checking every actor (not only the caller) also catches a batch row debiting the wrong buyer's shares in that buyer's favour.

PROPERTY_ID: [RD-07]
TYPE: SPECIFIC (try/catch around every lending redeem: withdrawToken, delete, withdrawTokenAndInterest, withdrawAllAccumulatedInterest, single and across-handler batches; also step 2 of RT-01)
ENGLISH: In this harness (half-up LayerBank burns, index ≥ RAY, Sovryn burning exactly the requested shares) no lending redeem ever reverts with `LendingHandler__ShareConsumptionMismatch` or `LendingHandler__ZeroStablecoinReceived`. The floor-then-+1 sizing always burns exactly the debited shares, and a positive ceil debit always pays at least 1 wei.
SOLIDITY_SKETCH:
```solidity
try dcaManager.withdrawToken(token, id, w) {} catch (bytes memory err) {
    bytes4 sel = selectorOf(err);
    t(sel != ILendingHandler.LendingHandler__ShareConsumptionMismatch.selector, "RD-07 LB floor+1 sizing missed exact burn");
    t(sel != ILendingHandler.LendingHandler__ZeroStablecoinReceived.selector, "RD-07 positive share debit paid zero");
}
// same wrapper for delete / interest / batch calls (batch may legitimately revert ZeroShareValue, BelowSwapperMinimum, cadence, etc.)
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: `LayerBankHandler._underlyingForExactScaledBurn` NatSpec: "Under the `index >= RAY` assumption on `_protocolRedeem`, floor never rayDivs above the target; when it undershoots, one more wei is enough." `src/layerbank/README.md` §Burn rounding. Closed form in "Derived rounding slack". ZeroStablecoinReceived: `w' ≥ 1` ⇒ `sr*rate/D ≥ 1` ⇒ LB `a ≥ 1`. On Sovryn, `a − floor(a*fee/1e4) ≥ 1` for `fee ≤ 100` bps. Batch: every funded weight is `≥ 1`, so `T*rate/D ≥ G ≥ 1`.
RATIONALE: This turns the earlier scan's lead (LayerBank +1 round-up burn sizing, G-26) into a check. If the sizing is wrong for some (shares, index) pair, users' exits and purchases revert under exactly the conditions the README says are safe. The fuzzer reaches many index values through time warps and `env_bumpLayerBankIndex`.

PROPERTY_ID: [RD-08]
TYPE: SPECIFIC (inside `dcaManager_topUpFromInterest_clamped`, wrapped in try/catch)
ENGLISH: The accrued-interest quote is a safe preview of the top-up ceiling: a top-up for any amount `0 < amount ≤ dcaManager.getAccruedInterest(actor, token, route)` never reverts with `TopUpExceedsAccruedInterest` or `NoInterestToTopUpWith`.
SOLIDITY_SKETCH:
```solidity
uint256 q = dcaManager.getAccruedInterest(actor, s.token, s.routeIndex);   // quote (view)
if (q == 0) return; amount = clampBetween(amount, 1, q);
try dcaManager.topUpFromInterest(s.token, s.scheduleId, amount) {} catch (bytes memory err) {
    bytes4 sel = selectorOf(err);
    t(sel != IDcaManager.DcaManager__TopUpExceedsAccruedInterest.selector, "RD-08 quote above spendable ceiling");
    t(sel != IDcaManager.DcaManager__NoInterestToTopUpWith.selector, "RD-08 quote positive but ceiling zero");
    // DcaManager__TopUpDoesNotFundAnotherPurchase is allowed
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: `IDcaManager.getAccruedInterest` NatSpec: "On a market that accrues lazily this can trail the spendable ceiling, never exceed it. This guarantees the quote satisfies the upper bound".
RATIONALE: This is Pattern D (preview bounds actual) for the protocol's only preview function. It fires if the view and write paths ever round or read differently, for example if a future adapter's `_exchangeRate` diverged from `_viewExchangeRate` downward.

PROPERTY_ID: [RD-09]
TYPE: SPECIFIC (after successful `withdrawAllAccumulatedInterest`, per lending pair named)
ENGLISH: An interest withdrawal pays at least the quoted interest (when there is no venue exit fee) and at most the quote plus one share's worth plus LayerBank's +1. Formally `I0 ≤ paid ≤ I0 + rate/D + 1`; with a Sovryn exit fee only the upper bound applies.
SOLIDITY_SKETCH:
```solidity
// per lending pair r with handler h, I0 = I(actor,r) before; paid = this pair's share of the actor's token delta
// (call the handler with one pair at a time, or split by token: DOC has two lending routes, so use single-pair masks)
lte(paid, I0 + R / D(h) + 1, "RD-09 interest paid above quote + one share");
if (isLB(h) || sovrynIToken.getExitFeeBps() == 0) gte(paid, I0, "RD-09 interest paid below quote without exit fee");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: `I(actor,r)`, actor stablecoin before/after; restrict the routeMask to one lending pair per call or attribute by token when only one lending pair of that token is named
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. `sr = ceilDiv(I0*D, r)` gives `I0 ≤ sr*r/D < I0 + r/D`. LB pays `floor(...)` or `+1`. Sovryn pays the floor minus the exit fee.
RATIONALE: This bounds the preview against actual cash. Overpaying interest beyond one share's rounding would spend principal-backing shares. Underpaying with no fee would mean the ceil debit burned value the user never received.

PROPERTY_ID: [RD-10]
TYPE: SPECIFIC (new stateless handler `probe_feeCurve(uint256 handlerSeed, uint256 x1, uint256 x2)` on `FizzFeeProbe`)
ENGLISH: For the live fee settings of any handler, the contract's fee function equals the spec's single-floor formula. It is nondecreasing in the amount, its net weight `x − F(x)` is nondecreasing, and it is bounded by `floor(x*m/1e4) ≤ F(x) ≤ floor(x*M/1e4)`. In a multi-row call each row is priced independently: `totalFee == F(x1) + F(x2)` and `Σnet + totalFee == Σx`.
SOLIDITY_SKETCH:
```solidity
function probe_feeCurve(uint256 seed, uint256 x1, uint256 x2) public {
    IPurchaseFees.FeeSettings memory fs = IPurchaseFees(_route(seed).handler).getFeeSettings();
    vm.prank(admin); feeProbe.setFeeRateParams(fs.minFeeRate, fs.maxFeeRate, fs.feePurchaseLowerBound);
    x1 = clampBetween(x1, 1, type(uint96).max); x2 = clampBetween(x2, x1, type(uint96).max);   // x1 <= x2
    uint256 f1 = _fee1(x1); uint256 f2 = _fee1(x2);           // _fee1: probe.calc([x]).totalFee
    eq(f1, specFee(x1, fs), "RD-10 fee != spec single-floor formula");
    lte(f1, f2, "RD-10 fee decreased as amount grew");
    lte(x1 - f1, x2 - f2, "RD-10 net weight decreased as amount grew");
    lte(f1, x1 * fs.maxFeeRate / 10_000, "RD-10 fee above max rate");
    gte(f1, x1 * fs.minFeeRate / 10_000, "RD-10 fee below min rate");
    (uint256 tf, uint256[] memory net, uint256 sum) = feeProbe.calc([x1, x2]);
    eq(tf, f1 + f2, "RD-10 batch fee not per-row"); eq(net[0] + net[1] + tf, sum, "RD-10 weights lost to rounding"); eq(sum, x1 + x2, "RD-10 sum");
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none (stateless)
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: `docs/PURCHASE_FEES.md` §Integer rounding: "Solidity calculates the fee with one final floor … Flooring a nondecreasing function preserves nondecreasing fees … the net weight x−F(x) is also nondecreasing for integer purchase amounts"; §Allocation: "All fees are calculated per purchase, even when several purchases share a batch or buyer". `PurchaseFees._calculateVariableFee` NatSpec: "Round the absolute fee once so increasing the purchase amount cannot reduce its fee". The bounds hold because `L(2x−L) ≤ x²` (x-ray I-22).
RATIONALE: These are Patterns G (monotonicity) and E for the fee conversion. Running against the private function at full `uint96` range reaches far more amounts than batches do. Batches only see amounts that schedules hold, so they rarely hit the `x = L` seam or extreme values where an intermediate floor or overflow would break monotonicity.

PROPERTY_ID: [RD-11]
TYPE: SPECIFIC (same probe handler)
ENGLISH: Splitting a purchase into two rows never lowers the total fee by more than 1 wei: `F(a) + F(b) ≥ F(a+b) − 1`. Per-row flooring gives no meaningful advantage to splitting.
SOLIDITY_SKETCH:
```solidity
// with a = x1, b = x2 - x1 (when x2 > x1), using the same probe and settings
if (x2 > x1) gte(_fee1(x1) + _fee1(x2 - x1) + 1, _fee1(x2), "RD-11 splitting a purchase saves more than 1 wei of fee");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. The unrounded fee `f` is linear on `[0, L]` and concave beyond with `f(0) = 0`, so it is subadditive. The two floors then cost at most 1 wei.
RATIONALE: Users choose how many schedules and what amounts to run. If integer rounding let a split noticeably beat the curve, fees could be gamed by splitting purchases. The 1-wei tolerance is the floor dust the docs accept.

PROPERTY_ID: [RD-12]
TYPE: SPECIFIC (after every successful single-handler batch on a Dex handler)
ENGLISH: On Uniswap routes the measured output never falls below the stricter of the swapper's `minRbtcOut` and the oracle floor computed at swap time. The floor uses the handler's active oracle and percent: `Q ≥ floor(Rb * percent / oraclePrice)`, where `Rb` is the stablecoin the router received.
SOLIDITY_SKETCH:
```solidity
uint256 Q  = wrbtc.balanceOf(h) - wrbtc_before(h);
uint256 Rb = usdrif.balanceOf(address(swapRouter)) - routerUsdrif_before;          // equals totalStablecoinRetrieved
uint256 floorOut = Rb * IPurchaseUniswap(h).getAmountOutMinimumPercent() / IPurchaseUniswap(h).getMocOracle().getPrice();
gte(Q, floorOut, "RD-12 Dex output below oracle floor");
gte(Q, batch.minRbtcOut, "RD-12 Dex output below swapper minimum");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: `wrbtc.balanceOf(h)`, router USDRIF balance, percent and oracle price read before the call (the oracle cannot change inside the batch)
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE: the Dex route uses the "oracle-derived floor and the swapper's batch `minRbtcOut`; the stricter bound wins", and `minRbtcOut` "and the Uniswap oracle floor bind on `Q`, before the fee share". `PurchaseUniswap._getAmountOutLowerBound` (`i_stablecoinToUsdScale = 1` for 18-decimal USDRIF). G-29, G-32.
RATIONALE: This is the "preview bounds actual" check for the Dex conversion `_getAmountOutLowerBound`. It catches a floor computed on the nominal batch sum instead of the retrieved amount, a floor computed with a stale oracle reference, or a unit-scale error. Across-handler batches are excluded because both Dex handlers share the router, so `Rb` cannot be split between them.
