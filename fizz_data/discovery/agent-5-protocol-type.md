# Agent 5 — Protocol-Type Specialist (BitChill dca-contracts)

## Classification

**Yield Aggregator (lending-adapter vault) + DEX/venue integrator with an oracle floor + keeper-driven scheduler.**

- **Vault/Yield (adapter form, not ERC-4626).** Each lending handler pools user stablecoin into one external market
  position (LayerBank aToken scaled shares, Sovryn iToken shares). It keeps per-user *virtual shares* `s_shares`
  that are exactly the receipt shares minted for that user, so 1 virtual share = 1 receipt share. There is **no
  handler-level share price**: every conversion uses the market's rate (`pool.getReserveNormalizedIncome`,
  `iToken.tokenPrice`) and the handler's own balances never enter it. There is no share token, no
  `totalSupply`/`totalAssets`, and no ERC-4626 claim. Template clauses therefore count as SHOULD-HOLD only when
  the docs (AUDIT_GUIDE / x-ray / context §5) or an exact identity back them.
- **Lending (supplier side only).** The protocol never borrows, so debt, liquidation, health factor and
  utilization do not apply. One lending idea does transfer: *principal vs. collateral health*. Principal is
  nominal (`tokenBalance`), the claim is share value, and a share-value fall can leave a shortfall (§5).
- **AMM/DEX (client, not pool).** The protocol makes Uniswap V3 `exactInput` swaps under an oracle floor and
  MoC `redeemFreeDoc` redemptions with no venue floor. Pool invariants (k, LP supply, reserves) belong to the
  venue mock and do not apply.
- **Scheduler/keeper.** The role file has no scheduler/keeper template. I checked the Queue/Order template:
  there is no queue (the swapper picks the rows) and no FIFO promise, so it does not apply. Agents 1–4
  already cover cadence, window and liveness (ST-06/07/08, ST-19, ADV-06/16).

Most template items are already covered by agents 1–4; see the mapping at the end. Below are only the
domain properties they miss, plus mandatory V-06.

Common notation (shared with agents 1–2):
- `LEND = {layerBankDocMoc (DOC, route 1), sovrynDocMoc (DOC, route 2), layerBankUsdrifDex (USDRIF, route 1)}`.
- `rate(h)`: LayerBank uses `ILayerBankPool(h.i_pool()).getReserveNormalizedIncome(token)` with `D = 1e27`.
  Sovryn uses `sovrynIToken.tokenPrice()` with `D = 1e18`.
- `V(a,h) = getUserShares(a) * rate(h) / D` (floor). `L(a,r)` = Σ `tokenBalance` of `a`'s live schedules on
  `(r.token, r.routeIndex)`, read from `dcaManager.getDcaSchedules(a, r.token)` and filtered by `routeIndex`.
- `dust(h) = rate(h) / D + 2`, the same per-operation slack as CON-15.
- `ACCOUNTS = actors ∪ {feeCollector}`.

---

PROPERTY_ID: [SPEC-01] [MANDATORY V-06]
TYPE: GLOBAL + SPECIFIC (global preview check; specific check after `env_donateStablecoin` / `env_donateETH`, and on the first lending deposit after a donation)
ENGLISH: Donations cannot inflate a share price or grief later depositors. (a) Global: at the current market rate, a deposit of 1e18 and a deposit of the token minimum (`getTokenMinPurchaseAmount`) would each mint more than 0 receipt shares on every lending handler. (b) A stray stablecoin or native donation to any handler changes no book: no account's virtual shares, no quoted accrued interest, no claimable rBTC, no schedule `tokenBalance`, and no handler receipt-share balance. (c) The first successful lending deposit or create after a donation credits exactly the shares the market formula gives for the deposit amount at the current rate. That amount does not depend on the handler's stablecoin balance, its total receipt shares or the donation.
SOLIDITY_SKETCH:
```solidity
// (a) global
function property_SPEC01_noShareInflationGrief() public {
    for (k in routes) if (routes[k].lending) {
        address h = routes[k].handler; uint256 r = rate(h);
        uint256 minAmt = dcaManager.getTokenMinPurchaseAmount(routes[k].token);
        if (h == address(sovrynDocMoc)) {
            gt(1e18 * 1e18 / r, 0, "SPEC-01 1e18 deposit previews 0 iToken shares");
            gt(minAmt * 1e18 / r, 0, "SPEC-01 min deposit previews 0 iToken shares");
        } else {
            gt((1e18 * 1e27 + r / 2) / r, 0, "SPEC-01 1e18 deposit previews 0 scaled shares");
            gt((minAmt * 1e27 + r / 2) / r, 0, "SPEC-01 min deposit previews 0 scaled shares");
        }
    }
}
// (b) after env_donateStablecoin(routeSeed, amt) / env_donateETH(routeSeed, amt)
for a in ACCOUNTS:
    for h in LEND: eq(shares_after[a][h], shares_before[a][h], "SPEC-01 donation moved virtual shares");
                   eq(interest_after[a][h], interest_before[a][h], "SPEC-01 donation became interest");
    for h in all 5 handlers: eq(claim_after[a][h], claim_before[a][h], "SPEC-01 donation became claimable rBTC");
for s in trackedSchedules: eq(tokenBalance_after(s), tokenBalance_before(s), "SPEC-01 donation moved principal");
for h in LEND: eq(receiptShares_after(h), receiptShares_before(h), "SPEC-01 donation moved receipt shares");
ghosts.donatedSinceDeposit[h] = true;
// (c) inside dcaManager_depositToken* / dcaManager_createDcaSchedule* on a lending route, if ghosts.donatedSinceDeposit[h]:
uint256 r0 = rate(h);   // snapshot before the call
uint256 expected = (h == sovryn) ? d * 1e18 / r0 : (d * 1e27 + r0 / 2) / r0;
eq(getUserShares(actor)_after - getUserShares(actor)_before, expected, "SPEC-01 post-donation deposit credit depends on handler balances");
ghosts.donatedSinceDeposit[h] = false;
```
where `interest[a][h] = dcaManager.getAccruedInterest(a, token(h), routeIndex(h))` (a view; the manager calls `quoteAccruedInterest`), `claim[a][h] = IPurchaseRbtc(h).getAccumulatedRbtcBalance(a)`, and `receiptShares(h)` is `aToken.scaledBalanceOf(h)` or `sovrynIToken.balanceOf(h)`.
GHOST_NEEDS: `mapping(address handler => bool) donatedSinceDeposit` (agent 1's donation counters can be reused for CON-02/10/11)
SNAPSHOT_NEEDS: for `ACCOUNTS × LEND`: `getUserShares` and `getAccruedInterest`; for `ACCOUNTS × handlers`: `getAccumulatedRbtcBalance`; every tracked schedule's `tokenBalance`; receipt-share balance per lending handler; `rate(h)` before the deposit
PRIORITY: HIGH
GUARANTEE: SHOULD-HOLD
EVIDENCE: Context §5: "Stray donations sit on a handler, credited to no one." AUDIT_GUIDE "Accounting properties": "Integrator return values and balance views are not treated as received cash. Stablecoin and native receipts are measured by balance deltas." x-ray I-1 Δ-pair derivation: credit = measured mint. Part (a) is a closed-form identity under the harness bounds: Sovryn price ≤ 3e18 gives ≥ 3.3e17 shares per 1e18, and the LayerBank index stays near RAY.
RATIONALE: This is template V-06, mandatory. The classic attack, depositing 1 wei and then donating so that later depositors' shares round to 0, needs a handler-level share price, and this protocol has none. The property pins that design down. If anyone later prices shares from `balanceOf(handler)`, adds an `assets/totalShares` conversion, or counts a donation as a mint or as interest, it fails. It also checks the harness's direct-to-handler donations, which no other property ties to the interest quotes and receipt shares together.

---

PROPERTY_ID: [SPEC-02]
TYPE: GLOBAL
ENGLISH: On each lending handler, the market's own valuation of the handler's whole position is at least the sum of the stablecoin values the protocol assigns to each user's virtual shares. This is "totalAssets ≥ Σ convertToAssets(balanceOf(user))" with totalAssets read from the external market (`aToken.balanceOf(h)`, `iToken.assetBalanceOf(h)`), not from the handler's formula.
SOLIDITY_SKETCH:
```solidity
function property_SPEC02_marketValueCoversUserValues() public {
    // LayerBank DOC / USDRIF
    for ((h, aTok, pool, tok) in [(layerBankDocMoc, layerBankATokenDoc, layerBankPoolDoc, doc),
                                  (layerBankUsdrifDex, layerBankATokenUsdrif, layerBankPoolUsdrif, usdrif)]) {
        uint256 idx = pool.getReserveNormalizedIncome(address(tok));
        uint256 sumV;
        for (a in ACCOUNTS) sumV += h.getUserShares(a) * idx / 1e27;
        lte(sumV, aTok.balanceOf(address(h)), "SPEC-02 LayerBank user values exceed market valuation");
    }
    // Sovryn DOC
    uint256 p = sovrynIToken.tokenPrice(); uint256 sumS;
    for (a in ACCOUNTS) sumS += sovrynDocMoc.getUserShares(a) * p / 1e18;
    lte(sumS, sovrynIToken.assetBalanceOf(address(sovrynDocMoc)), "SPEC-02 Sovryn user values exceed market valuation");
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: x-ray I-1 (On-chain: Yes): "For each lending handler, Σ `s_shares[user]` ≤ the handler's external receipt-share balance". Add the exact identity Σᵢ ⌊sᵢ·r/D⌋ ≤ ⌊(Σᵢ sᵢ)·r/D⌋ ≤ ⌊receipt·r/D⌋. `LayerBankHandler._viewExchangeRate` reads the same normalized income that `MockLayerBankAToken.balanceOf` uses, and `SovrynHandler._viewExchangeRate` reads the same `tokenPrice` that `assetBalanceOf` uses.
RATIONALE: Template V-01. CON-12/13 compare share counts only. This property also checks that the handler values shares with the rate the market itself applies. It catches a rate-source or decimals mismatch, such as a wrong `EXCHANGE_RATE_DECIMALS`, the wrong reserve address passed to `getReserveNormalizedIncome`, or a cached rate. Any of these would let interest quotes, top-ups and clamps promise more than the market will pay.

---

PROPERTY_ID: [SPEC-03]
TYPE: SPECIFIC (after every non-environment handler call: user mutators, batches, rBTC claims, interest withdrawals, top-ups, governance and permissionless setters)
ENGLISH: No user, swapper, owner or permissionless operation deepens any account's principal shortfall on a lending route by more than per-operation rounding. The shortfall is `S(a,r) = max(0, L(a,r) − V(a,h))`. This holds both before and after a loss. A solvent position (`V ≥ L`) stays solvent within dust. An underwater position (after a Sovryn price fall) is never pushed further underwater by deposits, withdrawals, deletes, batch rows, top-ups or interest withdrawals. Only environment moves (a price fall or exit fee) can create or grow a shortfall. Accounts and routes the call does not touch keep `S` exactly.
SOLIDITY_SKETCH:
```solidity
// snapshot S_before[a][k] for a in actors, lending route k (same block, so rate(h) is unchanged by the call itself)
function _S(address a, Route memory r) internal view returns (uint256) {
    uint256 L = lockedPrincipal(a, r);                          // Σ tokenBalance over getDcaSchedules(a, r.token) with routeIndex == r.routeIndex
    uint256 V = ILendingHandler(r.handler).getUserShares(a) * rate(r.handler) / D(r.handler);
    return L > V ? L - V : 0;
}
// after the call
for a in actors, lending route k:
    uint256 ops = opsTouching(a, k);   // 1 for a single op by a on k; for a batch, the number of a's rows on k; 0 otherwise
    lte(_S(a, routes[k]), S_before[a][k] + ops * dust(routes[k].handler),
        "SPEC-03 non-price operation deepened a principal shortfall");
    if (ops == 0) eq(_S(a, routes[k]), S_before[a][k], "SPEC-03 shortfall moved for an untouched account/route");
```
GHOST_NEEDS: none (the per-call row counts come from the batch the wrapper built)
SNAPSHOT_NEEDS: `S_before[a][k]` for `actors × lending routes`; the batch's buyer list per route
PRIORITY: HIGH
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. This is the transition form of x-ray X-2/E-3 ("a user's Σ `tokenBalance` ≤ the stablecoin value of their `s_shares`", On-chain: No). AUDIT_GUIDE allows only "rounding dust" outside losses and says a loss shortfall "is not restored to principal", but it never promises that later operations will not deepen it. My derivation per operation: a clamped withdrawal or batch row debits nominal `w` while consuming value `≤ V`, so `S` falls. A top-up is capped at `⌊V⌋ − L`. Deposit, withdrawal and row debits move `V` by the amount within `rate/D + 1`. This does not contradict §5, which only accepts that a shortfall *exists* after a value fall.
RATIONALE: Template L-03 ("healthy before ⇒ healthy after for non-price operations"), adapted to nominal principal vs. share collateral. CON-15 and VS-05 switch off once Sovryn's price has fallen. This property keeps the post-loss regime under test, which is where the open leads sit: a withdrawal after a loss taking other schedules' shares, the clamp arithmetic, and a top-up during a loss. It catches an operation that turns one user's nominal debit into extra share burn, and a top-up or deposit credited above its share backing. Because it is a delta property, it stays meaningful after the global CON-15 gate has closed.

---

PROPERTY_ID: [SPEC-04]
TYPE: SPECIFIC (around `dcaManager_batchBuyRbtc*` and `dcaManager_batchBuyRbtcAcrossHandlers*`; wrap the call in try/catch)
ENGLISH: A Dex purchase prices its floor only from a valid oracle, and only the handler's active oracle matters. (a) If a batch that includes a Dex handler succeeds, that handler's active oracle (`getMocOracle()`) reported `isValid == true` at execution. (b) If a batch reverts with `PurchaseUniswap__OutdatedPrice`, at least one Dex handler in it had an invalid active oracle. Whether the inactive oracle (the other of `mocOracle` / `mocOracleAlt`) is valid never affects the outcome. (c) MoC handlers never revert with `OutdatedPrice`.
SOLIDITY_SKETCH:
```solidity
// before: for each Dex handler h in the call
(, bool valid_h, ) = ICoinPairPrice(address(IPurchaseUniswap(h).getMocOracle())).getPriceInfo();
bool anyMoc = batch contains a MoC route; bool anyInvalidActive = OR over Dex h of !valid_h;
vm.prank(swapper);
try dcaManager.batchBuyRbtc(batch) {
    for Dex h in call: t(valid_h, "SPEC-04 Dex batch filled against an invalid oracle");
} catch (bytes memory err) {
    if (bytes4(err) == IPurchaseUniswap.PurchaseUniswap__OutdatedPrice.selector) {
        t(anyInvalidActive, "SPEC-04 OutdatedPrice with every active oracle valid (inactive oracle consulted?)");
    }
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: each Dex handler's active oracle address and its `getPriceInfo()` validity before the call
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: x-ray G-32: `if (!isValid) revert PurchaseUniswap__OutdatedPrice` (PurchaseUniswap.sol:276), "The swap-time floor needs an oracle price the oracle marks valid." AUDIT_GUIDE external assumptions: the MoC BTC/USD oracle must remain "correct and available"; the floor binds on `Q`. `setMocOracle` replaces "the price the floor is computed from".
RATIONALE: This is the DEX-integrator oracle-floor template, safety side. RD-12 checks the floor's value on success. ADV-04 and ADV-06 check that exits and clean batches stay live. None of them checks that the *validity* flag is enforced, or that it is read from the oracle `setMocOracle` installed rather than a cached or stale reference. The harness's `env_setOracleValid(alt, …)` and the `setMocOracle` rotation reach every combination of the two flags.

---

PROPERTY_ID: [SPEC-05]
TYPE: SPECIFIC (after a successful `dcaManager_batchBuyRbtc*` on any route; for an across-handler batch, check each batch against its own `minRbtcOut`)
ENGLISH: The swapper's `minRbtcOut` binds on the handler's measured gross output on every venue. This includes Money on Chain, where the venue ignores any minimum and only `PurchaseRbtc` enforces it. On a MoC handler the measured output is the handler's native rBTC balance delta; on a Dex handler it is the WRBTC balance delta.
SOLIDITY_SKETCH:
```solidity
uint256 Q = r.dex ? wrbtc.balanceOf(h) - wrbtcBefore[h] : h.balance - nativeBefore[h];
gte(Q, batch.minRbtcOut, "SPEC-05 batch filled below the swapper minimum");
gt(Q, 0, "SPEC-05 zero-output batch accepted");
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: `h.balance` (MoC) and `wrbtc.balanceOf(h)` (Dex) before the call; the `minRbtcOut` sent
PRIORITY: MEDIUM
GUARANTEE: SHOULD-HOLD
EVIDENCE: x-ray G-29: `if (totalPurchasedRbtc == 0) revert …; if (totalPurchasedRbtc < minRbtcOut) revert PurchaseRbtc__BelowSwapperMinimum`. AUDIT_GUIDE: "`minRbtcOut` and the Uniswap oracle floor bind on `Q`, before the fee share."
RATIONALE: This is the venue-integration template "output ≥ caller minimum" for the venue that has no floor of its own. RD-12 covers only the Dex route. `PurchaseMoc._purchaseRbtc` explicitly drops its `minRbtcOut` argument, so the MoC route depends entirely on the post-swap check. The clamped wrapper sends a minimum up to the expected gross, so on lending MoC routes the clamp and the minimum can conflict (Finding 1 territory). This property makes sure such a batch reverts and never fills below the minimum.

---

PROPERTY_ID: [SPEC-06]
TYPE: SPECIFIC (after a successful `dcaManager_batchBuyRbtcAcrossHandlers*` that includes at least one Dex handler)
ENGLISH: In an across-handler call, each Dex handler's output still satisfies its own oracle floor, and the shared router and WRBTC contract never misattribute output. `idleUsdrifDex` and `layerBankUsdrifDex` share `MockSwapRouter02` and `MockWrbtcToken`. Each handler's WRBTC gain must be at least `floor(G_h · percent_h / oraclePrice_h)` for its own gross input `G_h`. The router's total USDRIF intake must equal the sum of the `G_h`.
SOLIDITY_SKETCH:
```solidity
// before: Gidle = Σ purchaseAmount of the idleUsdrifDex rows (idle retrieval = nominal sum); routerBefore = usdrif.balanceOf(address(swapRouter))
uint256 routerIn = usdrif.balanceOf(address(swapRouter)) - routerBefore;
uint256 Glb = routerIn - (idleIncluded ? Gidle : 0);           // layerBankUsdrifDex gross; reverts (underflow) if attribution is broken
if (idleIncluded) gte(wrbtc.balanceOf(idleUsdrifDex) - wBefore[idle], Gidle * pct(idle) / oraclePrice(idle), "SPEC-06 idle Dex below floor in across batch");
if (lbIncluded)   gte(wrbtc.balanceOf(layerBankUsdrifDex) - wBefore[lb], Glb * pct(lb) / oraclePrice(lb), "SPEC-06 LB Dex below floor in across batch");
if (!lbIncluded)  eq(routerIn, Gidle, "SPEC-06 router intake != idle Dex gross");
// pct(h) = IPurchaseUniswap(h).getAmountOutMinimumPercent(); oraclePrice(h) = MockMocOracle(address(IPurchaseUniswap(h).getMocOracle())).getPrice()
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: `usdrif.balanceOf(swapRouter)`, `wrbtc.balanceOf` of both Dex handlers, the idle Dex rows' nominal sum, each Dex handler's percent and active-oracle price before the call
PRIORITY: LOW
GUARANTEE: SHOULD-HOLD
EVIDENCE: AUDIT_GUIDE: "The Uniswap path checks both an oracle-derived floor and the swapper's batch `minRbtcOut`; the stricter bound wins", and "A multi-handler batch is also atomic across all handlers." x-ray G-32. IdleHandler `_batchRetrieveStablecoin` returns the nominal sum.
RATIONALE: This is the DEX-integrator template for a shared venue. RD-12 deliberately excludes across-handler batches because the router's intake cannot be split. This property splits it using the exact idle retrieval, so the oracle floor is also checked on the multi-handler path that the production bot uses for its main call (`batchBuyRbtcAcrossHandlers`).

---

PROPERTY_ID: [SPEC-07]
TYPE: GLOBAL
ENGLISH: The read surface that keepers and frontends use to preview actions never reverts in any reachable state. This includes paused deposits, revoked swappers, an invalid oracle, a live window, a Sovryn loss, donations, and a cap lowered below live counts. For every actor and every assigned route the following never revert: `getDcaSchedules`, `getAccumulatedRbtcBalance`, `getAccruedInterest` on lending routes only, and `getDcaSchedule` for every tracked schedule. The same holds for each handler's `getUserShares`, `getFeeSettings` and `getFeeCollector`, and for each Dex handler's `getMocOracle`, `getSwapPath` and floor settings.
SOLIDITY_SKETCH:
```solidity
function property_SPEC07_previewsNeverRevert() public {
    for (a in ACCOUNTS) for (k in routes) {
        try dcaManager.getDcaSchedules(a, routes[k].token) {} catch { t(false, "SPEC-07 getDcaSchedules reverted"); }
        try dcaManager.getAccumulatedRbtcBalance(a, routes[k].token, routes[k].routeIndex) {} catch { t(false, "SPEC-07 rBTC preview reverted"); }
        if (routes[k].lending) {
            try dcaManager.getAccruedInterest(a, routes[k].token, routes[k].routeIndex) {} catch { t(false, "SPEC-07 interest preview reverted"); }
        }
    }
    for (s in trackedSchedules) try dcaManager.getDcaSchedule(s.token, s.scheduleId) {} catch { t(false, "SPEC-07 tracked schedule unreadable"); }
    // handler getters likewise
}
```
GHOST_NEEDS: none
SNAPSHOT_NEEDS: none
PRIORITY: LOW
GUARANTEE: EXPLORATORY
EVIDENCE: none — inferred. AUDIT_GUIDE: "the bot must simulate actual gross funding"; "reads … remain open" during a window. The ERC-4626 rule that max/preview functions must not revert applies only by analogy.
RATIONALE: Template V-04 (preview/max functions usable in every state). The off-chain keeper and the interest top-up flow (RD-08) depend on these previews. A view that reverts, for example `_lockedPrincipal` iterating a corrupted id list or a rate getter breaking after a loss, would silently stop batch planning or exits without failing any mutating-call property.

---

## Template items not emitted, and where they are covered

| Template | Mapping in this protocol | Covered by |
|---|---|---|
| V-01 totalAssets ≥ Σ convertToAssets | share-count form / market-value form | CON-12, CON-13 / **SPEC-02** |
| V-02 share price monotonic excl. losses | no handler share price; the rate is external (LayerBank index rises in the harness, Sovryn price can fall by design) | env-only; RD-06 (no op raises interest) |
| V-03 receiver credited, not msg.sender | `depositToken(user=msg.sender)` | CON-16, CON-23 |
| V-04 max*/preview usable | sentinel withdraw, top-up preview, read surface | ADV-01, RD-08, **SPEC-07** |
| V-05 convertTo* consistency | `_stablecoinToShares` ceil / `_sharesToStablecoin` floor | RD-01, RD-04, RT-03/04 |
| V-06 inflation grief (mandatory) | donation to handler | **SPEC-01** |
| V-07 empty-vault first deposit | first or re-entry deposit credits formula shares | RD-05, ADV-05 (re-entry), ADV-18 |
| V-08 asset() correct | `i_stablecoin`, `i_dcaManager`, path ends | ST-18 / X-4 check, VS-03 |
| L-01 / L-02 solvency, no unbacked debt | nominal principal vs share value | CON-15, VS-05 (no-loss), **SPEC-03** (all regimes) |
| L-03 healthy before ⇒ healthy after | shortfall not deepened by non-price ops | **SPEC-03** |
| L-04 index monotonic | external market (mock) | environment only |
| L-05/06/07/08/10 liquidation, utilization, borrow shares | no borrowing | n/a |
| L-09 full repay ⇒ healthy | full exit leaves zero-value shares | ADV-05 |
| A-01/02/03/05/08 pool invariants | venue is a mock; protocol is a swap client | n/a |
| A-06 output ≤ reserve → credited ≤ measured output | | CON-04 |
| A-07 price impact | MockSwapRouter02 is linear | n/a (agent 4 note) |
| DEX oracle floor | per-batch / multi-handler / validity / MoC minimum | RD-12 / **SPEC-06** / **SPEC-04** / **SPEC-05** |
| Q-01..Q-03 queue | no queue; id list size | CON-24, ST-01/02 |
| Keeper (no template in role file) | cadence, once per day, window, liveness | ST-06/07/08/09/10, ST-19, ADV-06, ADV-16 |
| S-*, T-*, G-* | no staking rewards, no protocol token, no governance voting | n/a |

Not turned into properties:
- The oracle publication age is never checked (lead). `MockMocOracle.getPriceInfo` always returns `block.number`, so the fuzzer cannot falsify a staleness property.
- A zero-value row after a loss reverts the whole handler batch. AUDIT_GUIDE states this ("A zero-value row still reverts …"), so it is accepted by design and is not a property.
