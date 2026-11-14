# Agent 1 — Conservation Auditor: property list

Scope: conservation and accounting identities only (patterns A–D). The list builds on `x-ray/invariants.md`
(I-1, I-20, X-1, X-2, X-3, X-6, E-1, E-2, E-3) and makes each one computable from what the Fizz harness can read.

## Shared notation (used in every sketch)

- `ACCOUNTS` = `actors[0..2]` plus `feeCollector`. These are the only addresses that can own schedules or receive fee
  credits in this harness: every create goes through `asActor`, and `_collectorCandidate` picks only from this set.
  `feeCollector` is not in `actors[]`, so the set has no duplicates.
- `routes[k]` = `{token, routeIndex, handler h, lending, dex}`.
- `rbtcAsset(h)` = `r.dex ? wrbtc.balanceOf(h) : h.balance`. MoC handlers hold native rBTC; Dex handlers hold WRBTC.
- `claim(a,h)` = `IPurchaseRbtc(h).getAccumulatedRbtcBalance(a)`. This returns the decoded `claimable`, not the stored `claimable+1`.
- `receipt(h)`: DOC LayerBank route → `layerBankATokenDoc.scaledBalanceOf(h)`; USDRIF LayerBank route →
  `layerBankATokenUsdrif.scaledBalanceOf(h)`; Sovryn route → `sovrynIToken.balanceOf(h)`.
- `rate(h)`, `D(h)`: LayerBank → `aToken.getNormalizedIncome()`, `1e27`; Sovryn → `sovrynIToken.tokenPrice()`, `1e18`.
  This rate equals the handler's `_viewExchangeRate()`, and `_exchangeRate()` equals it on both adapters.
- `shares(a,h)` = `ILendingHandler(h).getUserShares(a)`; `V(a,h)` = `shares(a,h) * rate(h) / D(h)` (floor, the same
  formula as `_sharesToStablecoin`).
- `L(a,r)` = Σ `dcaManager.getDcaSchedule(s.token, s.scheduleId).tokenBalance` over `trackedSchedules` with
  `s.owner==a && s.token==r.token && s.routeIndex==r.routeIndex`.
- `TB(r)` = Σ over all owners of the same sum (the route's total nominal principal).
- `slackOp(h)` = `rate(h)/D(h) + 2` wei, read at the time of the operation. Derivation:
  - LayerBank half-up mint: shares `s > d·RAY/idx − ½`, so the value lost on a deposit is `< idx/(2RAY)+1`.
  - Sovryn floor mint: the value lost on a deposit is `< price/1e18 + 1`.
  - A ceilDiv share debit of `w` removes at most `w + ceil(rate/D)` of value.
  - So each share-touching operation can open at most `rate/D + 2` wei between nominal principal and share value.
- rBTC floor dust: in a successful handler batch with `n` rows, `Q − Σ floor(Q·netᵢ/G) − floor(Q·F/G)` is a sum of `n+1`
  fractional parts, each below 1. It is therefore `≤ n` wei (AUDIT_GUIDE: "less than one wei per row, and per fee").
  Rows whose floor is 0 are skipped, which still stays inside this bound.

## Ghosts needed (Base.sol `Ghosts`; storage struct, so it may hold mappings)

```
mapping(address handler => uint256) stableDonated;   // += amount in env_donateStablecoin
mapping(address handler => uint256) ethDonated;      // += amount in env_donateETH
mapping(address handler => uint256) rbtcDustBudget;  // += rows sent to that handler, per successful batch / across-handlers call
mapping(address actor => mapping(address handler => uint256)) shareSlack; // += slackOp(h) per share-touching op of actor on h
                                                      // (create, deposit, withdrawToken, delete, each interest redeem, each batch row of that buyer)
bool sovrynPriceEverFell;                             // set in env_moveSovrynPrice when !up && delta>0
uint256 schedulesCreated; uint256 schedulesDeleted;   // successful create / delete wrappers (clamped and unclamped)
uint256 nativeTotal;                                  // fixed at the end of setup()
```

## Snapshot fields needed (Snapshots.sol `State`)

For the acting account and all of `ACCOUNTS`:
- native balance;
- `doc` and `usdrif` balances;
- `claim(a,h)` for all 5 handlers;
- `shares(a,h)` for all 3 lending handlers.

Per handler:
- stablecoin balance;
- `h.balance`;
- `wrbtc.balanceOf(h)`;
- `receipt(h)` for lending handlers;
- `getFeeCollector()`;
- `getFeeSettings()`.

Per tracked schedule, keyed by `(token, id)`: `tokenBalance` and `purchaseAmount`.

Per acting actor and lending route: `getAccruedInterest(actor, token, route)`, plus `usdrif.balanceOf(swapRouter)`.

---

PROPERTY_ID: CON-01
TYPE: GLOBAL
ENGLISH: On every handler, the rBTC (MoC) or WRBTC (Dex) it actually holds is at least the sum of all accounts' claimable accumulated rBTC.
SOLIDITY_SKETCH:
```
for r in routes: h = r.handler;
  uint sumClaim = Σ_{a∈ACCOUNTS} claim(a,h);
  assertGte(rbtcAsset(h), sumClaim, "CON-01 rBTC books exceed handler holdings");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE "Accounting properties": "Each buyer is credited floor(Q × netᵢ / G) and the collector floor(Q × F / G) … Integer division can leave less than one wei per row, and per fee, uncredited in the handler". Σ floors ≤ Q, so credits never exceed measured output (x-ray I-20, E-2).
RATIONALE: This is the core rBTC solvency identity. A double credit, a mis-decoded `claimable+1` sentinel, a fee credited on top of the full buyer share, or a payout that leaves the book intact would all break it.

PROPERTY_ID: CON-02
TYPE: GLOBAL
ENGLISH: Each handler's rBTC asset balance equals its claimable book plus stray donations plus floor dust, and the dust never exceeds one wei per batch row ever executed on that handler.
SOLIDITY_SKETCH:
```
for r in routes: h = r.handler;
  uint book = Σ_{a∈ACCOUNTS} claim(a,h);
  uint donated = r.dex ? 0 : ghosts.ethDonated[h];   // native donations land in .balance, not WRBTC
  assertGte(rbtcAsset(h), book + donated, "CON-02 lower");
  assertLte(rbtcAsset(h), book + donated + ghosts.rbtcDustBudget[h], "CON-02 unallocated rBTC beyond floor dust");
```
GHOST_NEEDS: ethDonated[h], rbtcDustBudget[h]
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE: "Integer division can leave less than one wei per row, and per fee, uncredited in the handler." IPurchaseRbtc.batchBuyRbtc NatSpec: "buyers floor(Q × netᵢ / G), collector floor(Q × F / G), floor dust uncredited". The n-row bound is the closed-form floor-sum identity (n+1 fractional parts < 1 ⇒ ≤ n).
RATIONALE: The upper bound catches fee leakage and under-crediting. Examples are a skipped row credit, a collector credit lost on rotation, or a withdrawal that zeroes the book but pays less than it. All of these leave orphaned rBTC on the handler that CON-01 cannot see.

PROPERTY_ID: CON-03
TYPE: GLOBAL
ENGLISH: Dex handlers never hold native rBTC except force-sent donations (WRBTC is unwrapped only inside a claim and paid on at once), and MoC handlers never hold WRBTC.
SOLIDITY_SKETCH:
```
for r in routes: h = r.handler;
  if (r.dex) assertEq(h.balance, ghosts.ethDonated[h], "CON-03 native stuck on Dex handler");
  else       assertEq(wrbtc.balanceOf(h), 0, "CON-03 WRBTC on MoC handler");
```
GHOST_NEEDS: ethDonated[h]
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE "Asset and call flow": USDRIF/USDT0 "are swapped to WRBTC … and then unwrapped only when the user withdraws". `PurchaseUniswap._withdrawRbtc` unwraps exactly `rbtcBalance` and then `super` pays exactly `rbtcBalance` (exact closed form).
RATIONALE: An unwrap/payment mismatch, for example unwrapping the decoded value plus the sentinel, would strand native rBTC on the Dex handler. It would also make its WRBTC book insolvent in a way the per-asset CON-01 splits across two assets.

PROPERTY_ID: CON-04
TYPE: SPECIFIC (after `dcaManager_batchBuyRbtc*` and `dcaManager_batchBuyRbtcAcrossHandlers*` succeed)
ENGLISH: In a successful batch on a handler, the rBTC credited to all accounts on that handler is between the measured gross output Q minus one wei per row and Q itself; no other handler's books or rBTC balances move.
SOLIDITY_SKETCH:
```
// per handler h touched by the call; n_h = total rows routed to h in this call
uint Q = rbtcAsset_after(h) - rbtcAsset_before(h);
assertGt(Q, 0, "CON-04 zero output accepted");
uint dC = Σ_{a∈ACCOUNTS} (claim_after(a,h) - claim_before(a,h));   // each term must be >= 0 (checked via CON-08)
assertLte(dC, Q, "CON-04 credits exceed measured output");
assertGte(dC + n_h, Q, "CON-04 more than one wei per row left uncredited");
for h' not touched: assertEq(rbtcAsset_after(h'), rbtcAsset_before(h')) and every claim(a,h') unchanged;
for a ∉ buyers(h) ∪ {collector_before(h)}: claim_after(a,h) == claim_before(a,h);
```
GHOST_NEEDS: rbtcDustBudget[h] += n_h (consumed by CON-02)
SNAPSHOT_NEEDS: rbtcAsset(h) and claim(a,h) for all h and a ∈ ACCOUNTS; getFeeCollector(h) before
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE "Accounting properties" allocation formula plus "less than one wei per row, and per fee, uncredited"; AGENTS.md invariant 13 ("The purchase-fee collector is credited on this mapping").
RATIONALE: This is the per-batch form of I-20. It also covers the fee collector being a buyer, since the sum is per account and `ACCOUNTS` has no duplicates. It also covers repeated buyers across rows, and an across-handlers bundle where later batches run after earlier handler calls.

PROPERTY_ID: CON-05
TYPE: SPECIFIC (after a successful batch, when the handler's collector is not among that batch's buyers)
ENGLISH: The fee collector's rBTC credit from a batch never exceeds maxFeeRate (≤ 5%) of the measured output.
SOLIDITY_SKETCH:
```
address c = collector_before(h);
if (!isBuyer(c)) {
  uint feeCredit = claim_after(c,h) - claim_before(c,h);
  assertLte(feeCredit * 10_000, Q * feeSettings_before(h).maxFeeRate, "CON-05 fee above max rate");
  assertLte(feeCredit * 10_000, Q * 500, "CON-05 fee above 5% cap");
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: fee collector and fee settings of h before; claim of the collector before/after; Q as in CON-04
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: PurchaseFees `MAX_FEE_RATE_CAP` NatSpec "Hard ceiling on fee rates (5%)". The closed form is F = Σ feeᵢ ≤ Σ wᵢ·max/1e4 = G·max/1e4. The variable fee satisfies feeᵢ ≤ max·x/1e4 because L(2x−L) ≤ x². So floor(Q·F/G) ≤ Q·max/1e4.
RATIONALE: This catches fee over-collection, which is a transfer of value from buyers to the collector. Examples are a fee computed on the nominal rather than the clamped weight, a doubled fee credit, or a variable-curve error above the lower bound.

PROPERTY_ID: CON-06
TYPE: SPECIFIC (after a successful batch, when the collector is not among the buyers)
ENGLISH: Buyers together receive at least the output minus the maximum fee share minus one wei per row, and the collector receives at least the minimum fee share minus 2 wei.
SOLIDITY_SKETCH:
```
uint buyersCredit = Σ_{a∈ACCOUNTS, a≠c} (claim_after(a,h) - claim_before(a,h));
assertGte((buyersCredit + n_h) * 10_000, Q * (10_000 - feeSettings_before(h).maxFeeRate), "CON-06 buyers short-changed");
assertGte((feeCredit + 2) * 10_000, Q * feeSettings_before(h).minFeeRate, "CON-06 fee under-collected");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: same as CON-05
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. The bounds rely on feeᵢ ≥ floor(wᵢ·min/1e4) and on Q/G < 1/40000 in this harness (MoC 1/50000; Dex ≤ 997/(1000·40000)), so Q·n/G < 1 for n ≤ 16.
RATIONALE: This is the lower-side counterpart of CON-05. It detects fee leakage toward nobody, where the fee is computed but not credited, and buyer credits floored against the wrong denominator. These defects stay hidden from CON-04 when they happen to cancel out.

PROPERTY_ID: CON-07
TYPE: SPECIFIC (after `dcaManager_withdrawAllAccumulatedRbtc*` and `_asCollector`)
ENGLISH: An rBTC claim pays the caller exactly the sum of its claimable balances on the selected handlers, debits each handler's rBTC asset by exactly that account's claim, zeroes those claims, and touches no other account.
SOLIDITY_SKETCH:
```
// caller = actor or collector; H = distinct handlers named by the pairs
uint expected = Σ_{h∈H} claim_before(caller,h);
assertEq(caller.balance_after - caller.balance_before, expected, "CON-07 payout != book");
for h∈H: assertEq(claim_after(caller,h), 0);
         assertEq(rbtcAsset_before(h) - rbtcAsset_after(h), claim_before(caller,h), "CON-07 handler debit != claim");
         if (r.dex) assertEq(h.balance_after, h.balance_before);   // unwrap fully forwarded
for h∉H: claim(caller,h) and rbtcAsset(h) unchanged;
for b∈ACCOUNTS, b≠caller: claim(b,·) and b.balance unchanged;
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: native balances of ACCOUNTS; claim(a,h); rbtcAsset(h); h.balance
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AGENTS.md invariant 3 "rBTC pays the signer — withdrawals go to msg.sender"; invariant 13 (decode `stored − 1`, leave sentinel 1); AUDIT_GUIDE "Accumulated rBTC is payable only to the recorded user through DcaManager".
RATIONALE: This is the paired-operation check for `_creditRbtc` / `_withdrawRbtcChecksEffects`. It catches the one-wei sentinel bugs AGENTS #13 warns about, double payment when a pair is repeated, and payment to the wrong account.

PROPERTY_ID: CON-08
TYPE: SPECIFIC (wrapped around every handler call)
ENGLISH: An account's claimable rBTC on a handler only falls through that account's own claim (to exactly zero), and only rises through a batch on that handler.
SOLIDITY_SKETCH:
```
for a∈ACCOUNTS, h∈handlers:
  if (claim_after(a,h) < claim_before(a,h))
      assertTrue(callWasRbtcClaimBy(a) && claim_after(a,h) == 0, "CON-08 book shrank without payout");
  if (claim_after(a,h) > claim_before(a,h))
      assertTrue(callWasBatchOn(h), "CON-08 credit outside a purchase");
```
GHOST_NEEDS: none (the wrapper knows which call it is)
SNAPSHOT_NEEDS: claim(a,h) before/after
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: AGENTS.md invariant 13: the mapping is written only by `_creditRbtc` (from `batchBuyRbtc`) and `_withdrawRbtcChecksEffects` (from `withdrawAccumulatedRbtc`); invariant 3 (only the signer withdraws).
RATIONALE: This catches phantom minting and burning on the rBTC books. One example is a fee-collector rotation that moves or erases the old collector's balance. Another is a schedule delete or withdraw that touches rBTC books.

PROPERTY_ID: CON-09
TYPE: GLOBAL
ENGLISH: Each idle handler's stablecoin balance covers the sum of nominal principal of every schedule on its route.
SOLIDITY_SKETCH:
```
for r in routes where !r.lending:
  assertGte(IERC20(r.token).balanceOf(r.handler), TB(r), "CON-09 idle pool under-collateralised");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: src/idle/README.md: "Each schedule's tokenBalance in DcaManager is the liability, and the handler's balance is the pooled cover for all of them". AUDIT_GUIDE: "pooled cash is bounded by the schedule balances DcaManager debits before any outflow" (x-ray X-1).
RATIONALE: Idle handlers keep no per-user book. If this fails, one user's withdrawal or purchase is spending another user's cash (E-1).

PROPERTY_ID: CON-10
TYPE: GLOBAL
ENGLISH: Each idle handler's stablecoin balance exactly equals the route's total nominal principal plus stray donations.
SOLIDITY_SKETCH:
```
for r in routes where !r.lending:
  assertEq(IERC20(r.token).balanceOf(r.handler), TB(r) + ghosts.stableDonated[r.handler], "CON-10 idle cash drift");
```
GHOST_NEEDS: stableDonated[h]
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: This is an exact identity from three code paths:
- deposits must equal the measured pull (G-23; AUDIT_GUIDE "Deposits credit only the handler's measured balance increase and require it to equal the request");
- an idle withdrawal "pays the requested amount from pooled cash" (ITokenHandler.withdrawToken NatSpec) and debits that same amount;
- purchases "reduce the handler's stablecoin balance by exactly the gross amount retrieved", and "Idle funding weights equal the nominal amounts" (AUDIT_GUIDE).
RATIONALE: Equality, beyond the ≥ in CON-09, catches over-debits of principal that leave cash orphaned on the handler. Examples are a batch row debited twice, or a withdraw that debits more than it pays. It also covers the `depositToken` lead (balance computed before the handler call).

PROPERTY_ID: CON-11
TYPE: GLOBAL
ENGLISH: A lending handler never keeps raw stablecoin except stray donations: deposits are fully supplied, redemptions are fully paid out or fully spent.
SOLIDITY_SKETCH:
```
for r in routes where r.lending:
  assertEq(IERC20(r.token).balanceOf(r.handler), ghosts.stableDonated[r.handler], "CON-11 stablecoin stranded on lending handler");
```
GHOST_NEEDS: stableDonated[h]
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: Each of the three flows has documented exact-amount behaviour:
- `LendingHandler._depositToken` NatSpec: "the mint always uses the full request".
- `_withdrawToken` NatSpec: "Pays out what the redemption actually produced", and `withdrawInterest` pays `stablecoinReceived`.
- AGENTS.md invariant 12: "decrease by exactly the retrieved gross supplied to the venue".
RATIONALE: This turns the lead "`_depositToken` does not check that the market takes the full deposit" into an observable check. It also catches a withdraw path that redeems more than it pays, such as the LayerBank `+1` underlying, or a batch that redeems more than it spends.

PROPERTY_ID: CON-12
TYPE: GLOBAL
ENGLISH: On each lending handler, the sum of all users' virtual shares never exceeds the receipt shares the handler actually holds.
SOLIDITY_SKETCH:
```
for r in routes where r.lending:
  assertLte(Σ_{a∈ACCOUNTS} shares(a,h), receipt(h), "CON-12 virtual shares exceed real position");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: LendingHandler `_stablecoinToShares` NatSpec: "keeps sum of per-user shares <= shares the handler actually holds" (x-ray I-1).
RATIONALE: This is the documented share-book solvency invariant. If it breaks, the last user to exit cannot redeem.

PROPERTY_ID: CON-13
TYPE: GLOBAL
ENGLISH: On each lending handler, the sum of all users' virtual shares exactly equals its receipt-share balance (no receipt tokens are ever donated in this harness).
SOLIDITY_SKETCH:
```
for r in routes where r.lending:
  assertEq(Σ_{a∈ACCOUNTS} shares(a,h), receipt(h), "CON-13 share books drifted from external position");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AGENTS.md invariant 11: "the handler's external receipt-share balance must decrease by exactly the amount debited from BitChill's per-user virtual books". `_depositToken`: "Credited shares are the measured receipt-share gain". The exact identity holds because every credit equals the measured mint and every debit equals the measured burn.
RATIONALE: Strict equality catches orphaned shares that CON-12 tolerates. Cases include:
- burns larger than the debit (the LayerBank `+1` sizing, G-26);
- a batch whose Σ row debits differs from the single protocol burn;
- Sovryn small-remainder burns.
Orphaned shares belong to nobody and stay in the protocol forever.

PROPERTY_ID: CON-14
TYPE: GLOBAL
ENGLISH: For every actor and lending route, the interest DcaManager quotes equals the actor's share value minus the principal of the actor's tracked schedules on that route (or zero). DcaManager's per-user enumeration therefore sums exactly the live schedules.
SOLIDITY_SKETCH:
```
for a∈actors, r in routes where r.lending:
  uint v = V(a, r.handler); uint l = L(a, r);
  assertEq(dcaManager.getAccruedInterest(a, r.token, r.routeIndex), v > l ? v - l : 0, "CON-14 locked principal != live schedules");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: ILendingHandler.withdrawInterest NatSpec: "Interest is `share-backed stablecoin - this amount`, or zero". `DcaManager._lockedPrincipal` sums `tokenBalance` over `s_scheduleIds[user][token]` filtered by route (x-ray X-6). This is an exact closed form: both sides use the same floor conversion and the same view rate.
RATIONALE: This is a Pattern A check on `_lockedPrincipal` against the harness's independent live set. A stale id after swap-pop, a deleted schedule still counted, a cross-route mix-up or a missed schedule would each let interest withdrawals spend principal or block legitimate interest.

PROPERTY_ID: CON-15
TYPE: GLOBAL
ENGLISH: While the lending market's value per share has never fallen, a user's nominal principal on a lending route stays covered by the value of that user's shares, up to accumulated per-operation rounding dust.
SOLIDITY_SKETCH:
```
for a∈actors, r in routes where r.lending:
  h = r.handler;
  if (isSovryn(h) && ghosts.sovrynPriceEverFell) continue;   // accepted by design after a loss (context §5, X-2)
  assertLte(L(a,r), V(a,h) + ghosts.shareSlack[a][h], "CON-15 principal not backed by shares beyond dust");
```
GHOST_NEEDS: shareSlack[a][h]; sovrynPriceEverFell
SNAPSHOT_NEEDS: none
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. AUDIT_GUIDE says "Nominal principal can still exceed share value by rounding dust", and section 5 accepts larger gaps only after a share-value fall. The slack bound `rate/D + 2` per operation is this agent's derivation (half-up/floor mint, ceilDiv debit). LayerBank's index never falls in the harness. Sovryn exit fees reduce cash, not share value, so they need no exemption.
RATIONALE: This is x-ray X-2/E-3, restricted to the no-loss regime where it should hold. A real violation means principal exists with no shares behind it, beyond what rounding explains. Possible causes are a top-up above accrued interest, a debit that burns more value than the request, or interest withdrawals eating principal.

PROPERTY_ID: CON-16
TYPE: SPECIFIC (after successful `createDcaSchedule` / `depositToken`, clamped, dust and unclamped)
ENGLISH: A deposit takes exactly the deposit amount from the actor, credits exactly that amount to the one schedule, and lands entirely in that route's position. On an idle route the handler's cash rises by the amount. On a lending route the handler's receipt shares rise by exactly the actor's new virtual shares (> 0) and its raw cash is unchanged.
SOLIDITY_SKETCH:
```
assertEq(bal_before(actor,token) - bal_after(actor,token), d, "CON-16 pulled != requested");
assertEq(tokenBalance_after(s) - tokenBalance_before(s), d);        // create: before = 0, and the new id == getSchedulesCreatedCount()
if (!r.lending) assertEq(stable_after(h) - stable_before(h), d);
else { uint dS = shares_after(actor,h) - shares_before(actor,h);
       assertGt(dS, 0); assertEq(receipt_after(h) - receipt_before(h), dS);
       assertEq(stable_after(h), stable_before(h)); }
// every other schedule, every other handler, every other account unchanged (see CON-23)
// ghost: shareSlack[actor][h] += slackOp(h) if r.lending; schedulesCreated++ on create
```
GHOST_NEEDS: shareSlack, schedulesCreated
SNAPSHOT_NEEDS: actor stablecoin balance; schedule tokenBalance; handler stablecoin, receipt, shares(actor,h)
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE: "Deposits credit only the handler's measured balance increase and require it to equal the request". `LendingHandler._depositToken`: "Credited shares are the measured receipt-share gain". G-23 and G-24.
RATIONALE: This is the inflow half of every principal identity. It also covers the lead about `depositToken` reading the balance before the handler call.

PROPERTY_ID: CON-17
TYPE: SPECIFIC (after successful `withdrawToken` (clamped, full, unclamped), `withdrawTokenAndInterest` and `deleteDcaSchedule`)
ENGLISH: A principal withdrawal debits exactly the requested amount from the named schedule only (a delete debits its whole balance). On an idle route the actor receives exactly that amount from the handler's cash. On a lending route the actor's receipt-share burn equals its virtual-share debit and the handler keeps no cash.
SOLIDITY_SKETCH:
```
uint w = (req == type(uint256).max || isDelete) ? tokenBalance_before(s) : req;
if (!isDelete) assertEq(tokenBalance_before(s) - tokenBalance_after(s), w);
uint paid = bal_after(actor,token) - bal_before(actor,token);
if (!r.lending) { assertEq(paid, w, "CON-17 idle pays != debit");
                  assertEq(stable_before(h) - stable_after(h), w); }
else { assertEq(receipt_before(h) - receipt_after(h), shares_before(actor,h) - shares_after(actor,h), "CON-17 burn != debit");
       assertEq(stable_after(h), stable_before(h)); }
// isDelete: getDcaSchedule reverts afterwards; schedulesDeleted++. Lending: shareSlack[actor][h] += slackOp(h) (x2 for withdrawTokenAndInterest)
```
GHOST_NEEDS: shareSlack, schedulesDeleted
SNAPSHOT_NEEDS: tokenBalance of the schedule; actor stablecoin; handler stablecoin/receipt; shares(actor,h)
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: IDcaManager.withdrawToken NatSpec: "Principal is reduced by the requested amount … An idle route pays the requested amount from the handler's pooled balance". AGENTS.md invariant 11 (exact external share consumption).
RATIONALE: This is the outflow half of CON-10 and CON-13. Section 5 accepts lending cash below the debit, so lending cash is not pinned here (see CON-18). The zero-share case, which pays zero tokens, passes because `paid == 0` and both share deltas are 0.

PROPERTY_ID: CON-18
TYPE: SPECIFIC (after a successful lending withdrawal or delete)
ENGLISH: On a lending route with no loss, the actor receives at least the debited amount and at most that amount plus one share's rounding. Specifically: LayerBank always, when the user's share value before covered the request; Sovryn when the price never fell and the exit fee is 0.
SOLIDITY_SKETCH:
```
if (r.lending && V_before(actor,h) >= w && (isLayerBank(h) || (!ghosts.sovrynPriceEverFell && sovrynIToken.getExitFeeBps()==0))) {
  assertGte(paid, w, "CON-18 paid less than debited without loss");
  assertLte(paid, w + rate(h)/D(h) + 2, "CON-18 overpaid beyond one share");
}
```
GHOST_NEEDS: sovrynPriceEverFell
SNAPSHOT_NEEDS: V(actor,h) before; actor stablecoin before/after
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. shares = ceil(w·D/rate) ⇒ floor(shares·rate/D) ≥ w. The LayerBank `+1` adds at most 1 wei.
RATIONALE: Within the no-loss regime the user's cash should match the debit. A shortfall there means value leaked inside the handler, for example to orphaned shares or to cash left on the handler. An excess means value moved from other users' positions.

PROPERTY_ID: CON-19
TYPE: SPECIFIC (after successful `withdrawAllAccumulatedInterest` / `withdrawTokenAndInterest` on lending pairs)
ENGLISH: An interest withdrawal leaves every schedule's principal untouched. It keeps the share books aligned with the receipt burn and pays the actor all of the burn's cash. Afterwards the remaining share value still covers the principal (within one operation's dust), and almost no interest remains.
SOLIDITY_SKETCH:
```
for each lending route r named (withdrawAllAccumulatedInterest):
  assertEq(L_after(actor,r), L_before(actor,r));                         // no tokenBalance moves
  assertEq(receipt_before(h)-receipt_after(h), shares_before(actor,h)-shares_after(actor,h));
  assertEq(stable_after(h), stable_before(h));
  if (V_before(actor,h) >= L_before(actor,r))
      assertGte(V_after(actor,h) + rate(h)/D(h) + 2, L_after(actor,r), "CON-19 interest withdrawal spent principal");
  assertLte(dcaManager.getAccruedInterest(actor, r.token, r.routeIndex), rate(h)/D(h) + 2, "CON-19 interest left behind");
assertEq(Σ_r cash paid == bal_after(actor,token) - bal_before(actor,token))  // implied by stable_after == stable_before
// ghost: shareSlack[actor][h] += slackOp(h) per redeem
```
GHOST_NEEDS: shareSlack
SNAPSHOT_NEEDS: L, V, shares(actor,h), receipt(h), handler stablecoin, actor stablecoin
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: ILendingHandler.withdrawInterest NatSpec: "Pay `user` the stablecoin interest above `stablecoinLockedInDcaSchedules`". Slack derivation: I = V − L, debit ceil(I·D/rate) ⇒ V_after ≥ L − ceil(rate/D) (x-ray X-6).
RATIONALE: Interest must come only from yield. If principal coverage drops by more than dust after an interest withdrawal, user principal is being paid out as interest.

PROPERTY_ID: CON-20
TYPE: SPECIFIC (after successful `topUpFromInterest`)
ENGLISH: An interest top-up moves no tokens and no shares. It raises the schedule's principal by exactly `amount`, and the quoted accrued interest falls by exactly `amount`.
SOLIDITY_SKETCH:
```
assertEq(tokenBalance_after(s) - tokenBalance_before(s), amount);
assertEq(shares_after(actor,h), shares_before(actor,h)); assertEq(receipt_after(h), receipt_before(h));
assertEq(stable_after(h), stable_before(h)); assertEq(bal_after(actor,token), bal_before(actor,token));
assertEq(accrued_before(actor,r) - accrued_after(actor,r), amount, "CON-20 top-up not drawn from interest");
assertLte(L_after(actor,r), V_after(actor,h), "CON-20 top-up created unbacked principal");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: tokenBalance(s); shares; receipt; handler/actor stablecoin; getAccruedInterest(actor,token,route) before/after
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: IDcaManager.topUpFromInterest NatSpec: "No tokens move; this raises the schedule's claim over funds already lent". G-18 bounds amount ≤ accrued, so accrued' = (V − L − amount) exactly (closed form, same block, same rate).
RATIONALE: This is the only path that creates principal without cash. Any slack here mints unbacked principal, which violates E-3 even with no market loss.

PROPERTY_ID: CON-21
TYPE: SPECIFIC (after a successful batch)
ENGLISH: A batch debits each named schedule exactly its pre-batch purchaseAmount and leaves every other schedule unchanged.
- On an idle route the handler's cash falls by exactly the sum of those amounts.
- On a lending route the receipt-share burn equals the sum of the buyers' virtual-share debits; non-buyers' shares do not move and the handler keeps no cash.
- On a Dex route the router receives exactly the stablecoin the handler gave up.
SOLIDITY_SKETCH:
```
uint G_nom;
for id in batch: assertEq(tokenBalance_before(id) - tokenBalance_after(id), purchaseAmount_before(id)); G_nom += purchaseAmount_before(id);
for tracked s ∉ batch: tokenBalance unchanged;
if (!r.lending) assertEq(stable_before(h) - stable_after(h), G_nom, "CON-21 idle spend != debits");
else { assertEq(receipt_before(h)-receipt_after(h), Σ_{b∈ACCOUNTS}(shares_before(b,h)-shares_after(b,h)));
       for b ∉ buyers: shares unchanged; for b ∈ buyers: shares_after <= shares_before;
       assertEq(stable_after(h), stable_before(h)); }
if (r.dex) R = usdrif.balanceOf(swapRouter)_after - _before; if (!r.lending) assertEq(R, G_nom);
// ghost: rbtcDustBudget[h] += rows; for lending, shareSlack[buyer][h] += slackOp(h) per row
```
GHOST_NEEDS: rbtcDustBudget, shareSlack
SNAPSHOT_NEEDS: tokenBalance/purchaseAmount of all tracked schedules; handler stablecoin, receipt, shares of ACCOUNTS; router USDRIF balance
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE:
- AUDIT_GUIDE: "Every successful purchase must reduce the handler's stablecoin balance by exactly the gross amount retrieved", and "Idle funding weights equal the nominal amounts".
- AGENTS.md invariants 11 and 12.
- Section 5: the schedule is still debited the full `purchaseAmount` on a clamp.
RATIONALE: This is the stablecoin side of a purchase: the debits of the paired operation must match the cash and shares consumed. It catches a row debited for another schedule's amount, and a batch that consumes a non-buyer's shares. It also catches a lending batch whose single burn differs from Σ row debits.

PROPERTY_ID: CON-22
TYPE: SPECIFIC (after a successful batch on a lending route)
ENGLISH: The stablecoin a lending batch funds is never more than the principal debited plus one share's rounding per row. When no buyer was short of share value (no-loss regime), it is at least the principal debited.
SOLIDITY_SKETCH:
```
// R observable: Dex → Δ usdrif.balanceOf(swapRouter); MoC → Q*50_000 <= R < (Q+1)*50_000
uint slack = n * (rate(h)/D(h) + 2);
assertLte(R_lower, G_nom + slack, "CON-22 batch redeemed more than it debited");
bool noClamp = ∀ buyer b: V_before(b,h) >= Σ_{rows of b} purchaseAmount + rowsOf(b)*(rate/D+2);
if (noClamp && (isLayerBank(h) || sovrynExitFee==0)) assertGte(R_upper, G_nom, "CON-22 under-funded without loss");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: V of buyers before; router USDRIF before/after; Q (rbtcAsset delta)
PRIORITY: MEDIUM
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred from x-ray X-3 and the ceilDiv/floor conversions. AUDIT_GUIDE allows the funded amount to be below nominal only through clamps ("Rounding can limit the funded amount before redemption") or venue fees.
RATIONALE: This bounds the gap between the nominal debit and what is actually spent, which is the conservation side of Finding 1 and the clamp leads. Over-redeeming would spend buyers' other principal. Under-funding without a clamp means buyers are debited for stablecoin that never bought rBTC.

PROPERTY_ID: CON-23
TYPE: SPECIFIC (after every user-initiated wrapper: create, deposit, withdraw*, delete, topUp, update*, pause, withdrawAllAccumulatedInterest, withdrawAllAccumulatedRbtc, _asCollector)
ENGLISH: A user's own call never changes another account's schedules, virtual shares, claimable rBTC, stablecoin balance or native balance.
SOLIDITY_SKETCH:
```
address caller = (collector call) ? collector : actor;
for b∈ACCOUNTS, b≠caller:
  for h: assertEq(claim_after(b,h), claim_before(b,h));
  for lending h: assertEq(shares_after(b,h), shares_before(b,h));
  assertEq(doc/usdrif bal_after(b), bal_before(b)); assertEq(b.balance_after, b.balance_before);
for tracked s with s.owner ≠ caller: tokenBalance/purchaseAmount unchanged;
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: per-account claims, shares, token and native balances; tracked schedules' tokenBalance/purchaseAmount
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE authority table: a schedule owner "Cannot … Address another user's schedule through a mutator". AGENTS.md invariants 3 and 8. x-ray E-1: "No user can withdraw stablecoin backing another user's position".
RATIONALE: This is per-entity conservation across users. Section 5 accepts that one schedule's withdrawal can consume a user's shares across that same user's schedules. This property confirms the effect never crosses to another user.

PROPERTY_ID: CON-24
TYPE: GLOBAL
ENGLISH: Schedule counts are conserved:
- the creation nonce equals the number of successful creates;
- live schedules equal creates minus deletes;
- the per-user id lists, summed over actors and tokens, contain exactly the live schedules, each once, under its owner, token and route.
SOLIDITY_SKETCH:
```
assertEq(dcaManager.getSchedulesCreatedCount(), ghosts.schedulesCreated);
assertEq(trackedSchedules.length, ghosts.schedulesCreated - ghosts.schedulesDeleted);
uint listed;
for a∈actors, t∈{doc,usdrif}: (ids, scheds) = dcaManager.getDcaSchedules(a,t); listed += ids.length;
   for i: assertEq(scheds[i].user, a); assertTrue(isTracked(t, ids[i], a, scheds[i].routeIndex)); no duplicate ids;
assertEq(listed, trackedSchedules.length);
for s in trackedSchedules: d = getDcaSchedule(s.token, s.scheduleId); assertEq(d.user, s.owner); assertEq(d.routeIndex, s.routeIndex);
```
GHOST_NEEDS: schedulesCreated, schedulesDeleted
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: AGENTS.md invariant 7: "`createDcaSchedule` pre-increments `scheduleNonce` … ids start at 1 and `getSchedulesCreatedCount()` is the last one assigned". Invariant 8: `s_scheduleIds[user][token]` is the enumeration (x-ray I-9).
RATIONALE: This guards the enumeration that `_lockedPrincipal` (CON-14) and the max-schedules bound rely on. It catches swap-pop removal bugs, duplicated or stale ids, and a nonce that skips or repeats.

PROPERTY_ID: CON-25
TYPE: GLOBAL
ENGLISH: Native rBTC is conserved in the harness's closed world. The total held by the actors, the fee collector, the five handlers, the MoC proxy, the swap router and the WRBTC contract never changes, so no rBTC is paid to an outside address.
SOLIDITY_SKETCH:
```
uint total = Σ_{a∈ACCOUNTS} a.balance + Σ_{r∈routes} r.handler.balance
           + address(mocProxy).balance + address(swapRouter).balance + address(wrbtc).balance;
assertEq(total, ghosts.nativeTotal, "CON-25 rBTC left the system");
// nativeTotal recorded at end of setup(); no harness call vm.deal's afterwards
```
GHOST_NEEDS: nativeTotal
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: AGENTS.md invariant 3: "withdrawals go to `msg.sender`. No `to` parameter; no owner rescue". AUDIT_GUIDE: "Accumulated rBTC is payable only to the recorded user". The mocks move native only among these addresses (MoC pays the caller, the router deposits into WRBTC, WRBTC pays the withdrawer), and ForceSendETH self-destructs into a handler.
RATIONALE: This is a cheap global catch for rBTC paid to the wrong recipient, such as DcaManager, the swapper or tx.origin, on any path.

PROPERTY_ID: CON-26
TYPE: GLOBAL
ENGLISH: Stablecoin is conserved in the closed world. For DOC and USDRIF, the token's totalSupply equals the balances of the known holders. DOC holders: actors, collector, its handlers, its lending markets and the MoC proxy. USDRIF holders: actors, collector, its handlers, its aToken and the swap router. DcaManager and OperationsAdmin hold none.
SOLIDITY_SKETCH:
```
assertEq(doc.totalSupply(), Σ_{a∈ACCOUNTS} doc.balanceOf(a) + doc.balanceOf(idleDocMoc) + doc.balanceOf(layerBankDocMoc)
         + doc.balanceOf(sovrynDocMoc) + doc.balanceOf(address(layerBankATokenDoc)) + doc.balanceOf(address(sovrynIToken))
         + doc.balanceOf(address(mocProxy)));
assertEq(usdrif.totalSupply(), Σ_{a∈ACCOUNTS} usdrif.balanceOf(a) + usdrif.balanceOf(idleUsdrifDex)
         + usdrif.balanceOf(layerBankUsdrifDex) + usdrif.balanceOf(address(layerBankATokenUsdrif)) + usdrif.balanceOf(address(swapRouter)));
for tok in {doc, usdrif, wrbtc}: assertEq(tok.balanceOf(address(dcaManager)), 0); assertEq(tok.balanceOf(address(operationsAdmin)), 0);
assertEq(address(dcaManager).balance, 0);
```
GHOST_NEEDS: none (venue mints and burns are absorbed by totalSupply)
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE "Asset and call flow": "Users call DcaManager, but it never holds user stablecoin or purchased rBTC". ITokenHandler/IDcaManager withdrawals pay the `user` (`msg.sender`). The ERC20 identity totalSupply = Σ balances is exact for OZ `MockStablecoin`.
RATIONALE: This catches stablecoin paid to an address outside the system, for example the wrong `user` passed to a handler, or a fee withheld in stablecoin. It also catches funds parked on the manager.

PROPERTY_ID: CON-27
TYPE: SPECIFIC (after a successful batch on an idle route)
ENGLISH: On an idle route the measured rBTC output equals what the venue pays for exactly the sum of nominal purchase amounts. No other rBTC is counted as purchase output, and none of the venue's output is missing.
SOLIDITY_SKETCH:
```
if (!r.lending) {
  if (!r.dex) assertEq(Q, G_nom / 50_000, "CON-27 MoC output mismatch");
  else        assertEq(Q, G_nom * 997 / (1000 * dexRouterPrice), "CON-27 Dex output mismatch");
}
```
GHOST_NEEDS: none (dexRouterPrice already in Base)
SNAPSHOT_NEEDS: Q (rbtcAsset delta); G_nom from the batch's pre-state
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred from the mock pricing in INVARIANT_CONTEXT §3 (MockMocProxy `docAmount / 50_000`; MockSwapRouter02 `amountIn·997/(1000·price)`).
RATIONALE: This ties the measured Q that feeds CON-04 to the external venue's real payment. Donated native rBTC counted as output, or a partial spend, would surface here.
