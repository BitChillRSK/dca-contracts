# Fuzzing Suite Report

## Suite Overview
- **Project**: BitChill DCA (`dca-contracts`), the stablecoin-to-rBTC dollar-cost-averaging protocol (x-ray: 1600 nSLOC, commit `f414708a`, Foundry). Protocol understanding came from `x-ray/x-ray.md` and `fizz_data/invariant-context.md`; there is no `fizz_data/protocol-understanding.md`.
- **Suite location**: `test/fizz/` (entry points `FuzzTester.sol` and `FoundryTester.sol`). Metadata, corpus, logs and coverage are in `fizz_data/`.
- **Contracts targeted**: 3 selected contracts: `DcaManager` (17 entry points), `OperationsAdmin` (3) and `LayerBankHandlerDex` (9). `LayerBankHandlerDex` stands in for the setters of all five handlers. Selection: 29 entry points, 14 primary and 15 secondary. The harness deploys 5 routes: DOC idle, LayerBank and Sovryn on MoC; USDRIF idle and LayerBank on the Uniswap mock. Line coverage covers the 20 in-scope `src/` contracts. `src/tropykus-legacy/` is out of scope, and `SovrynHandlerDex` is not deployed.
- **Total handlers**: 71 (68 primary, 3 secondary/dispatcher), plus the `setCurrentActor` and `setCurrentSwapper` selectors, so Medusa fuzzes 73 entry points. The 3 dispatchers are `dcaManager_secondary`, `operationsAdmin_secondary` and `layerBankHandlerDex_secondary`. Together they carry the 15 secondary-tier selectors. Per file:

  | File | Functions | Kind |
  |---|---|---|
  | `DcaManagerHandler` | 34 | clamped and raw variants |
  | `OperationsAdminHandler` | 2 | |
  | `LayerBankHandlerDexHandler` | 1 | |
  | `EnvironmentHandler` | 11 | `env_*` |
  | `RoundTripHandler` | 3 | |
  | `AdversarialHandler` | 20 | 18 `adv_*` and 2 `probe_*` |
- **Properties**: 106 (29 global, 77 function-specific), all `[x]` in `PROPERTIES.md`. They are implemented as 108 functions in `Properties.sol`, because SP-15 and SP-62 each have two. 83 are SHOULD-HOLD and 23 EXPLORATORY.
- **Harness notes**:
  - Implementer 7B departed from plan H2. The batch funnels do not call `_captureBatchCtx`: about 7.3M gas for 54 rows plus two snapshots would exceed Medusa's 12.5M per-transaction limit. Instead, the batch properties read the same facts from `stateBefore` and from the call's `batches` argument.
  - 7B fixed a harness false positive in SP-23 and SP-21 (Sovryn below par). The regression test is `test_roundTripSovrynBelowPar`.
  - Medusa 1.5.1 crashes if `coverageEnabled` is false.
- **Validation**: `forge build` passes. `FoundryTester` passes 8/8: `test_harnessFlow`, `test_sequence`, `test_globalsHold`, `test_specificHandlersSmoke`, `test_specificHandlersGasNearCap`, `test_roundTripSovrynBelowPar`, `test_repro_adv_protectedBatchScenario` and `test_repro_property_sharePreviewPositive`.

## Coverage Results

Line coverage from the campaign's `fizz_data/corpus_medusa/coverage/lcov.info`. Medusa writes no `BRDA` records, so there are no per-contract branch percentages. Medusa's own counter reached 15,301 branches. Targets come from `fizz_data/coverage-targets.md`.

| Contract | Target | Achieved | Status |
|---|---|---|---|
| DcaManager | 80% | 96.7% (233/241) | ✅ |
| LendingHandler | 80% | 96.6% (85/88) | ✅ |
| PurchaseRbtc | 80% | 100% (57/57) | ✅ |
| PurchaseFees | 80% | 100% (60/60) | ✅ |
| TokenHandler | 80% | 94.4% (17/18) | ✅ |
| idle/IdleHandler | 80% | 100% (5/5) | ✅ |
| idle/IdleDocHandlerMoc | — (not listed) | 100% (3/3) | ✅ |
| idle/IdleHandlerDex | — (not listed) | 100% (7/7) | ✅ |
| StablecoinSource | — (not listed) | 100% (3/3) | ✅ |
| PurchaseUniswap | 50% | 87.1% (88/101) | ✅ |
| PurchaseMoc | 50% | 87.5% (7/8) | ✅ |
| layerbank/LayerBankHandler | 50% | 91.7% (22/24) | ✅ |
| layerbank/LayerBankDocHandlerMoc | 50% | 100% (3/3) | ✅ |
| layerbank/LayerBankHandlerDex | 50% | 100% (7/7) | ✅ |
| sovryn/SovrynHandler | 50% | 85.7% (12/14) | ✅ |
| sovryn/SovrynDocHandlerMoc | 50% | 100% (3/3) | ✅ |
| sovryn/SovrynHandlerDex | skip | 0% (0/7) | ✅ (intentional skip: not deployed, no USDRIF Sovryn route) |
| OperationsAdmin | 60% | 88.2% (45/51) | ✅ |
| BitChillOwnable | 60% | 100% (2/2) | ✅ |
| DcaManagerAccessControl | 60% | 75.0% (3/4) | ✅ |
| tropykus-legacy/* (3 contracts) | skip | 0% (0/27) | ✅ (intentional skip: out of scope, legacy) |

Change from Step 8 cycle 2 to the campaign:

| Contract | Cycle 2 | Campaign |
|---|---|---|
| DcaManager | 94% | 96.7% |
| LendingHandler | 93% | 96.6% |
| OperationsAdmin | 84% | 88.2% |
| PurchaseUniswap | 82% | 87.1% |
| BitChillOwnable | 50% | 100% |

- `DcaManagerAccessControl.sol:25` is the `_;` placeholder of `onlyDcaManager`. The guard on line 24 has 1,334,446 hits, but Medusa never credits a hit to the placeholder line. The 75% is therefore a tooling artifact.
- `coverage-targets.md` blames Medusa for the missed revert lines, saying it only records successful executions. This campaign's lcov does not support that claim: `BitChillOwnable.sol:37` (the `renounceOwnership` revert) has 47 hits and `LendingHandler.sol:176` (`ZeroShareValue`) has 1. Also, `PurchaseUniswap.sol` line 247 has 818 hits and line 249 has 698, so 120 swaps reverted and their lines up to the revert were still recorded. The revert lines still missed (listed below) were therefore never reached by the harness.

## Skipped Paths

| Contract | Function / Path | Reason |
|---|---|---|
| `tropykus-legacy/*` | all | Out of scope (legacy, not deployed). |
| SovrynHandlerDex | all | Built but not deployed (AUDIT_GUIDE). The harness has no USDRIF Sovryn route. |
| DcaManager | constructor `OperationsAdminIsNotAContract` (L102) | Setup only. |
| PurchaseUniswap | constructor reverts (L94, L116); immutable declarations (L32, L34) | Setup only. Immutables never get a runtime hit. |
| PurchaseMoc, LayerBankHandler, SovrynHandler | immutable declarations (PurchaseMoc L18, LayerBankHandler L34, SovrynHandler L24); constructor `UnderlyingMismatch` (LayerBankHandler L50, SovrynHandler L40) | Setup only. |
| DcaManagerAccessControl | L25 (`_;` of `onlyDcaManager`) | The guard runs (L24, 1,334,446 hits) and SP-69 exercises its revert. No hit is credited to the placeholder line. |
| OperationsAdmin | `registerRoute` / `assignHandler` validation reverts (L82, L90, L97, L100, L104) | Bootstrap only, not selected. `operationsAdmin_remapAttempt` only reaches the already-assigned reverts (SP-57). |
| OperationsAdmin | `DepositsPauseUnchanged` (L127) | `operationsAdmin_secondary` returns early on a same-value pause. |
| TokenHandler | `DepositAmountMismatch` (L74) | Needs a fee-on-transfer stablecoin. The harness uses plain mocks. |
| PurchaseUniswap | `IntermediateBalanceChangedInRouter` (L253) | Needs a router that strands intermediates. The mock never does. |
| PurchaseUniswap | intermediate-token loop body (L243, L250, L251) | **Unintended gap.** None of the 818 Dex swaps (L241) ran with harness path 1 (USDRIF→USDT0→WRBTC) active, so SP-72 was never evaluated. |
| PurchaseUniswap | setter validation reverts (L181 zero oracle, L342 malformed path, L363/L366/L369 percent and safety bounds) | The harness clamps setter inputs to valid domains. |
| DcaManager | input-validation reverts: L288 `TopUpExceedsAccruedInterest`, L392 zero minimum, L507 `RouteIndexMismatch`, L604 `ScheduleIdIndexMismatch`, L623/L626 purchase amount below minimum / above balance, L716 `WithdrawalAmountExceedsBalance` | Clamped wrappers avoid them. The raw wrappers almost never name a live owned key. |
| LendingHandler | `ZeroStablecoinReceived` (L194, L307), `ShareConsumptionMismatch` (L333) | Expected to be unreachable. SP-12 asserts they never fire. |
| BitChillOwnable | ownership transfer | Not selected. |

## Campaign Results
- **Fuzzer used**: Medusa 1.5.1 in assertion mode on 102 tests (29 global `property_*` functions plus the 73 entry points). Settings:
  - 10 workers, `callSequenceLength` 100, `testLimit` 500,000.
  - 600 s timeout set at launch (`medusa.json` has `timeout: 0`).
  - `blockNumberDelayMax` 4, `blockTimestampDelayMax` 604,800, `transactionGasLimit` 12.5M.
  - Compiled with crytic-compile in 50 s.
  - Medusa reused the cached Slither result from the pre-Step-9 harness (`fizz_data/slither_results.json`). The Slither key in `medusa.json` was corrected from `enabled` to `useSlither`. Behaviour is the same, since Medusa had defaulted to Slither on.
- **Duration**: 8m25s. The run stopped when it reached `testLimit` ("Transaction test limit reached"), before the 600 s timeout.
- **Total calls**: 501,776 in 5,187 sequences.
- **Branches hit**: 15,301. Growth flattened early: 14,232 at 30 s, 15,121 at 1 min, 15,262 at 2 min, 15,279 at 5 min.
- **Corpus size**: 626.
- **Violations found**: 5 stored failing sequences (`fizz_data/corpus_medusa/test_results/`) and 2 failed tests ("100 test(s) passed, 2 test(s) failed"). They have **2 distinct root causes, both EXPLORATORY**. No SHOULD-HOLD property failed. First hits: SP-64 at about 3m07s, GL-15 at about 3m28s.
- **Unconfirmed lead, not reproduced in the campaign**: GL-24 tripped in implementer 7B's 4-minute smoke run (scratch corpus). The case was a Sovryn deposit of `purchaseAmount + 1`. One buy burned all the shares and left 1 wei of principal with zero shares (rounding dust).

### Violation Details

#### V-1: SP-64, protected batch burns one share more than planned (2 stored sequences)
- **Property violated**: SP-64 `property_protectedBatchInputFixed`, called from `adv_protectedBatchScenario`. Statement: "Finding 1: suppose a swapper activates a window and plans a batch, and at execution the same window is live with the lending rate, Sovryn exit fee and planned rows all unchanged. Then the shares burned and the Dex router's input equal the plan, whatever unguarded user calls ran in between."
- **Guarantee**: EXPLORATORY
- **Assertion**: `eq(ev.rcpt0 - now_, ghosts.plan.SR, "SP-64: burned shares moved inside the protected window")`.
  - First stored sequence and Foundry repro: `45339366870081688524800 != 45339366870081688524799`.
  - Shrunk sequence in the final summary: `4604083229089054395234 != 4604083229089054395233`.
- **Root cause**:
  1. After `adv_fullExitAndReenter`, Alice holds one LayerBank DOC schedule (route 1) with `purchaseAmount == tokenBalance == deposit`.
  2. The half-up aToken mint leaves her shares worth just under `purchaseAmount`. The plan therefore clamps her row to all her shares (`SR` = 45339366870081688524799 in the repro).
  3. Inside the live window (unlock block 30 in the summary trace), the scenario's user op makes Alice call `depositToken(DOC, 1, 1)`. `depositToken` has no `whenUserMutationsAllowed` guard. The 1-wei deposit mints one share.
  4. At execution the row is no longer clamped: `ceilDiv(amount·RAY, index)` now equals her new balance. The batch therefore burns the exact-burn amount, one share more than planned. In the summary trace that burn is 4604083229089054395234 shares, with 4604083404282480159658 DOC withdrawn.

  This is a dynamic confirmation of the scan's "Deposits and new schedules in the protected window" lead and of the Finding 1 mechanism: the batch input is not fixed when the swapper plans it. Without a lending loss the clamp gap is at most one share, so the extra spend is dust (about 1 wei of DOC). This matches the audit README ("Without a lending loss the effect is rounding dust"). Alice funds the extra share herself. In the trace, only Alice's schedule, Alice's shares and the handler's receipt balance move.
- **Severity assessment**: `needs human review`. This is real protocol behaviour and matches a documented, untriaged lead, so it is not a false positive. The fuzzer showed only dust impact. The README lists the fixes: add `whenUserMutationsAllowed` to `depositToken` and `createDcaSchedule`, or apply Finding 1 Fix A (`maxStablecoinIn` in `Batch`) or Fix B (a per-token price check).
- **Reproducing sequence**:
  - Stored `1792443332939607000-152af9ca…json` (used by the repro), sender `0x10000` (Alice):
    ```
    1) adv_fullExitAndReenter(21024335355776915299101188012106854391436269275498184707108144420689833445126, 177684100258073654261007264031024834504374210172652464502406003705877663695)
    2) adv_protectedBatchScenario(1975002696069456087214340238281671596821, 421249970143250876261811275459913810280165123251885570202849875862, 2204170690891626633309222478778813937632695548626627593618633, 6739986666787659948716747286684485514180790527444378453215531223095, 1606938044071917663131576722572516091220514129647059794356917, false, true)
    ```
  - Stored `1792443469858020000-51202f4a…json`: same pattern (`adv_fullExitAndReenter(6564884559935786913787462645624740629187880633605400846918287578960147725091, 74551610127532259184319038635280866386834398182444822176547051182)`, then `adv_protectedBatchScenario(…, 0, true, false)`). It sets `fallFirst = true`, which moves the Sovryn price and does not affect the LayerBank route.
- **Foundry repro**: PASS. `test_repro_adv_protectedBatchScenario` fires the SP-64 assertion with these exact values.

#### V-2: GL-15, a 1-wei token minimum previews zero Sovryn shares (3 stored sequences)
- **Property violated**: GL-15 `property_sharePreviewPositive`. Statement: "[MANDATORY V-06] At the current market rate, a deposit of 1e18 and a deposit of the token minimum would each mint a positive number of receipt shares on every lending handler, so donations cannot price later depositors out."
- **Guarantee**: EXPLORATORY. It was downgraded in the property plan for exactly this governance-only case.
- **Assertion**: `gt(_previewMint(h, minAmount, r), 0, "GL-15: a minimum deposit previews zero receipt shares")` reports `0<=0`. The 1e18 half (the donation-inflation check) failed in none of the stored sequences.
- **Root cause**:
  - `dcaManager_secondary` maps selector 20, 98 or 14 (all ≡ 2 mod 3) to the owner's `setTokenMinPurchaseAmount(DOC, 1)`, with `arg0` clamped to 1. `DcaManager` rejects only a zero minimum (`DcaManager.sol:391-392`).
  - At FizzIToken price 1.0137e18, a 1-wei Sovryn deposit previews `floor(1e18 / 1.0137e18) = 0` shares.
  - A real 1-wei deposit there reverts with `LendingHandler__LendingProtocolDepositFailed` (`LendingHandler.sol:130`). It fails closed and loses no value.
- **Severity assessment**: `test harness false positive`. The inferred property is too strong: it treats an owner-set dust minimum as a protocol fault. Fix: assert the min-amount half only when `minAmount * D(h) >= rate(h)`. Alternatively, clamp the harness's token minimum to at least one share's price. In both cases keep the 1e18 half.
- **Reproducing sequence**: `dcaManager_secondary(20, 400123900000000000000000000, 42396913941755556936654186938328322142679471649784381576262641083582743421624)`, then `property_sharePreviewPositive()`. The other two stored sequences use `(98, 505062500000000000000000000, …730)` and `(14, 0, …512)`, and all three set the DOC minimum to 1.
- **Foundry repro**: PASS (`test_repro_property_sharePreviewPositive`).

## Properties Implemented

Confidence counts: 88 HIGH, 19 MEDIUM, 1 LOW (108 functions).

| # | Property | Type | Guarantee | Confidence |
|---|---|---|---|---|
| 1 | GL-01 `property_rbtcSolvency`: on every handler, held rBTC covers the sum of all accounts' claimable rBTC | Global | SHOULD-HOLD | HIGH |
| 2 | GL-02 `property_rbtcBooksExact`: rBTC asset == claimable book + native donations (MoC) + at most one wei per batch row | Global | SHOULD-HOLD | HIGH |
| 3 | GL-03 `property_rbtcAssetSplit`: Dex handlers hold no native rBTC beyond donations; MoC handlers hold no WRBTC | Global | SHOULD-HOLD | HIGH |
| 4 | GL-04 `property_idleCashCoversPrincipal`: each idle handler's stablecoin covers the route's total nominal principal | Global | SHOULD-HOLD | HIGH |
| 5 | GL-05 `property_idleCashExact`: each idle handler's stablecoin == route principal + stray donations | Global | SHOULD-HOLD | HIGH |
| 6 | GL-06 `property_lendingNoRawStablecoin`: a lending handler keeps no raw stablecoin other than stray donations | Global | SHOULD-HOLD | HIGH |
| 7 | GL-07 `property_virtualSharesBacked`: Σ accounts' virtual shares <= the handler's receipt shares | Global | SHOULD-HOLD | HIGH |
| 8 | GL-08 `property_virtualSharesExact`: Σ accounts' virtual shares == the handler's receipt shares | Global | SHOULD-HOLD | HIGH |
| 9 | GL-09 `property_accruedInterestIdentity`: quoted accrued interest == max(0, share value - live principal) per actor and lending route | Global | SHOULD-HOLD | HIGH |
| 10 | GL-10 `property_principalBackedNoLoss`: while value per share never fell, principal <= share value + per-op rounding slack | Global | EXPLORATORY | MEDIUM — depends on the hand-wired per-operation `shareSlack` ghost; Sovryn skipped after any price fall |
| 11 | GL-11 `property_scheduleCounts`: nonce == creates, live == creates - deletes, id lists hold exactly the live schedules | Global | SHOULD-HOLD | HIGH |
| 12 | GL-12 `property_nativeConservation`: native rBTC is conserved across accounts, handlers, MoC proxy, router and WRBTC | Global | SHOULD-HOLD | HIGH |
| 13 | GL-13 `property_stablecoinConservation`: DOC/USDRIF supply == known holders; DcaManager and OperationsAdmin hold nothing | Global | SHOULD-HOLD | HIGH |
| 14 | GL-14 `property_marketValueCoversUserValues`: the market's valuation of each lending position covers Σ the values of users' shares | Global | SHOULD-HOLD | HIGH |
| 15 | GL-15 `property_sharePreviewPositive`: at the current rate, 1e18 and the token minimum each mint > 0 receipt shares | Global | EXPLORATORY | MEDIUM — min-amount half is not conditioned on the minimum being worth at least one share; fires on an owner-set 1-wei minimum |
| 16 | GL-16 `property_retiredIdsStayDead`: deleted ids stay retired; no id list holds a deleted id or an id above the nonce | Global | SHOULD-HOLD | HIGH |
| 17 | GL-17 `property_oneBuyPerDay`: a schedule buys at most once per UTC day plus once per same-day period edit | Global | SHOULD-HOLD | HIGH |
| 18 | GL-18 `property_windowFreeze`: inside a live window, activation-time schedules are frozen except batch debits | Global | SHOULD-HOLD | MEDIUM — checks only while a ghost-snapshotted window is live; with `blockNumberDelayMax` 4 it runs mostly inline from `adv_protectedBatchScenario` |
| 19 | GL-19 `property_routesFixed`: route handlers, classes, handler stablecoin/manager and live schedules' pairs never change | Global | SHOULD-HOLD | HIGH |
| 20 | GL-20 `property_anchorOnGrid`: a live schedule's anchor is 0 or a UTC midnight no later than today | Global | SHOULD-HOLD | HIGH |
| 21 | GL-21 `property_scheduleDomains`: live schedule fields and protocol settings stay in their domains | Global | SHOULD-HOLD | HIGH |
| 22 | GL-22 `property_activePathAllowlisted`: each Dex handler's active path is allowlisted, a harness path, stablecoin → WRBTC | Global | SHOULD-HOLD | HIGH |
| 23 | GL-23 `property_settingsDomains`: fee settings, collectors, Dex floor settings and oracles stay in their domains | Global | SHOULD-HOLD | HIGH |
| 24 | GL-24 `property_principalHasSharesNoLoss`: with no loss on a lending route, live principal there implies shares there | Global | EXPLORATORY | MEDIUM — no value threshold: a 1-wei Sovryn principal residue with zero shares trips it (7B smoke run) |
| 25 | GL-25 `property_windowBounded`: unlock is at most 5 blocks ahead, and at most 5 blocks after the allowlist emptied | Global | SHOULD-HOLD | HIGH |
| 26 | GL-26 `property_canActivateSync`: canActivateProtectedPurchaseWindow() == (block.number >= unlock) | Global | SHOULD-HOLD | HIGH |
| 27 | GL-27 `property_privilegedHoldNothing`: swappers hold nothing; the owner gains no tokens and holds no claims or shares | Global | SHOULD-HOLD | HIGH |
| 28 | GL-28 `property_previewsNeverRevert`: the read surface (schedule lists, rBTC/interest previews, handler getters) never reverts | Global | EXPLORATORY | HIGH |
| 29 | GL-29 `property_depositPauseOnlyAssigned`: a pair whose deposits are paused is an assigned pair | Global | SHOULD-HOLD | HIGH |
| 30 | SP-01 `property_depositExact`: a create or deposit pulls exactly d from the actor into the one schedule and its route position | Specific | SHOULD-HOLD | HIGH |
| 31 | SP-02 `property_createPostconditions`: a create takes id nonce+1 above every id seen, stores its arguments, and appends the id last | Specific | SHOULD-HOLD | HIGH |
| 32 | SP-03 `property_lendingDepositCredit`: a lending deposit credits exactly the venue mint; interest rises by at most LayerBank's half-up dust | Specific | EXPLORATORY | HIGH |
| 33 | SP-04 `property_donationMovesNoBook`: a stray stablecoin or native donation moves no shares, interest, claims, schedules or receipts | Specific | SHOULD-HOLD | HIGH |
| 34 | SP-05 `property_postDonationDepositCredit`: the first lending deposit after a donation credits exactly the market-formula shares at the pre-call rate | Specific | SHOULD-HOLD | HIGH |
| 35 | SP-06 `property_depositPauseRespected`: setDepositsPaused flips exactly one pair's flag; create and deposit succeed only on unpaused pairs | Specific | SHOULD-HOLD | HIGH |
| 36 | SP-07 `property_createRespectsCap`: a create stays within the cap in force; setting the cap removes no schedule | Specific | SHOULD-HOLD | HIGH |
| 37 | SP-08 `property_withdrawExact`: a principal withdrawal debits exactly the request (whole balance for max / delete) on that schedule | Specific | SHOULD-HOLD | HIGH |
| 38 | SP-09 `property_lendingPayoutNoLoss`: with no loss, a lending withdrawal pays at least the debit and at most one share's rounding more | Specific | EXPLORATORY | MEDIUM — skips Sovryn after any loss or exit fee and whenever value < debit; fixed +2 wei slack |
| 39 | SP-10 `property_redeemDebitCeil`: a lending redeem debits exactly ceilDiv(w'·D, rate) shares, w' the request clamped to the floored value | Specific | SHOULD-HOLD | HIGH |
| 40 | SP-11 `property_redeemPaysAtMostBurned`: a lending redeem never pays more than the burned shares are worth (+1 wei per LayerBank burn) | Specific | SHOULD-HOLD | HIGH |
| 41 | SP-12 `property_noBurnMismatchRevert`: no lending redeem or batch reverts with ShareConsumptionMismatch or ZeroStablecoinReceived | Specific | SHOULD-HOLD | HIGH |
| 42 | SP-13 `property_deletePostconditions`: a delete retires the key and swap-pops the list; nonce, other schedules and claims stay | Specific | SHOULD-HOLD | HIGH |
| 43 | SP-14 `property_interestWithdrawalSafe`: an interest withdrawal keeps principal, burns exactly the virtual debit and keeps principal backed | Specific | SHOULD-HOLD | HIGH |
| 44 | SP-15 `property_interestIdempotent`: after an interest withdrawal, accrued interest is exactly zero on every lending pair named | Specific | SHOULD-HOLD | HIGH |
| 45 | SP-15 `property_interestSecondCallNoop`: a second interest withdrawal in the same block pays nothing and burns no shares | Specific | SHOULD-HOLD | HIGH |
| 46 | SP-16 `property_interestPayoutVsQuote`: a single-pair interest withdrawal pays between the quote and the quote plus one share (+1) | Specific | EXPLORATORY | MEDIUM — evaluated only when exactly one lending pair per token is named |
| 47 | SP-17 `property_topUpExact`: a top-up moves no tokens or shares, raises the schedule by amount and lowers interest by amount | Specific | SHOULD-HOLD | HIGH |
| 48 | SP-18 `property_topUpQuoteSafe`: a top-up within the quoted interest never reverts TopUpExceedsAccruedInterest or NoInterestToTopUpWith | Specific | SHOULD-HOLD | HIGH |
| 49 | SP-19 `property_rtLendingNoValue`: lending deposit⇄withdraw cycles keep principal and create no value (LayerBank: under one wei per cycle) | Specific | SHOULD-HOLD | HIGH |
| 50 | SP-20 `property_rtIdleExact`: idle deposit⇄withdraw cycles restore the actor's cash, the handler's cash and the principal exactly | Specific | SHOULD-HOLD | HIGH |
| 51 | SP-21 `property_rtNoFreeShares`: a lending round trip never leaves more shares and never raises accrued interest | Specific | SHOULD-HOLD | MEDIUM — share-count half skipped whenever a withdrawal was clamped (7B false-positive fix); value bound left to SP-19 |
| 52 | SP-22 `property_rtMaxOneShareLoss`: without a clamp, a round trip costs the actor at most one virtual share per cycle | Specific | EXPLORATORY | MEDIUM — skipped whenever a withdrawal was clamped |
| 53 | SP-23 `property_rtCreateDelete`: create+delete restores the id list, idle cash exactly, and gives no lending shares, value or interest | Specific | SHOULD-HOLD | MEDIUM — share-count half skipped when the delete was clamped |
| 54 | SP-24 `property_batchCreditsBounded`: per handler, Σ credits lies in [Q − rows, Q] with Q > 0; other handlers and non-participants unchanged | Specific | SHOULD-HOLD | HIGH |
| 55 | SP-25 `property_batchFeeCap`: when the collector is not a buyer, its fee credit is at most maxFeeRate (and 5%) of the output | Specific | SHOULD-HOLD | HIGH |
| 56 | SP-26 `property_batchFeeLowerBounds`: when the collector is not a buyer, buyers get >= Q·(1 − max) − rows and the collector >= Q·min − 2 | Specific | EXPLORATORY | MEDIUM — skipped when the collector is also a buyer; fixed 2-wei slack on the min-fee bound |
| 57 | SP-27 `property_batchDebitsExact`: each bought row is debited exactly its pre-batch amount; idle cash falls by the nominal sum; burn == Σ share drops | Specific | SHOULD-HOLD | HIGH |
| 58 | SP-28 `property_lendingBatchFunding`: a lending batch funds at most the debit plus one share per row; without clamp or exit fee, at least the debit | Specific | EXPLORATORY | MEDIUM — MoC funding inferred from output x fixed mock price; Dex lending case skipped when the idle Dex route is in the same call |
| 59 | SP-29 `property_idleOutputMatchesVenue`: on idle routes the measured output equals exactly what the mock venue pays for the nominal sum | Specific | EXPLORATORY | HIGH |
| 60 | SP-30 `property_batchShareSimulation`: lending rows debit ceilDiv(amount·D, rate) shares or all that remain; shares and burn match the simulation | Specific | SHOULD-HOLD | HIGH |
| 61 | SP-31 `property_batchCreditsExact`: each account's credit is exactly Σ floor(Q·(x − fee(x))/G) over its rows, plus floor(Q·ΣF/G) for the collector | Specific | SHOULD-HOLD | HIGH |
| 62 | SP-32 `property_dexOracleFloor`: a single-handler Dex batch's output meets the oracle floor retrieved·percent/oraclePrice | Specific | SHOULD-HOLD | HIGH |
| 63 | SP-33 `property_minRbtcOutBinds`: every successful batch's measured output is positive and at least the swapper's minRbtcOut | Specific | SHOULD-HOLD | HIGH |
| 64 | SP-34 `property_acrossDexFloor`: across handlers, the router's intake splits into the Dex handlers' inputs and each meets its own floor | Specific | SHOULD-HOLD | HIGH |
| 65 | SP-35 `property_oracleValidity`: a batch naming a Dex handler succeeds only with a valid active oracle; OutdatedPrice implies an invalid one | Specific | SHOULD-HOLD | HIGH |
| 66 | SP-36 `property_batchRowLegality`: a batch buys only tracked, unpaused, spec-due, unique rows of its route and anchors each on the newest due slot | Specific | SHOULD-HOLD | HIGH |
| 67 | SP-37 `property_cadenceRefusalsMatchSpec`: cadence, pause and balance refusals agree with the spec predicate; a clean single row is never refused | Specific | SHOULD-HOLD | HIGH |
| 68 | SP-38 `property_pauseTransitions`: setSchedulePaused sets only the flag and a same-value call is a no-op; paused schedules are never bought | Specific | SHOULD-HOLD | HIGH |
| 69 | SP-39 `property_rbtcClaimExact`: an rBTC claim pays the caller exactly its claims on the named handlers and moves nothing else | Specific | SHOULD-HOLD | HIGH |
| 70 | SP-40 `property_rbtcBookMovesOnlyByClaimOrBatch`: a claim falls only through the account's own claim (to zero) and rises only in a batch on that handler | Specific | SHOULD-HOLD | HIGH |
| 71 | SP-41 `property_rbtcSentinelSlot`: the raw claim slot never returns to 0, equals claim + 1 while non-zero, and is exactly 1 after a claim | Specific | SHOULD-HOLD | MEDIUM — reads `s_accumulatedRbtc` through hard-coded storage slots (4 idle, 5 lending) |
| 72 | SP-42 `property_noCrossUserEffect`: a user's own call changes no other account's claims, shares, wallets or schedules | Specific | SHOULD-HOLD | HIGH |
| 73 | SP-43 `property_mutatorFieldFrame`: each mutator writes only its own field, on the one schedule it names | Specific | SHOULD-HOLD | HIGH |
| 74 | SP-44 `property_nonScheduleCallFrame`: a call that names no schedule changes no schedule, id list or nonce | Specific | SHOULD-HOLD | HIGH |
| 75 | SP-45 `property_anchorMonotone`: a live schedule's anchor never decreases, never returns to 0, and moves only when a batch buys it | Specific | SHOULD-HOLD | HIGH |
| 76 | SP-46 `property_unlockMonotone`: the unlock block never decreases and moves only through an activation, by at least 5 | Specific | SHOULD-HOLD | HIGH |
| 77 | SP-47 `property_shareChangeAttribution`: shares rise only by the account's own create/deposit there and fall only by its own exits or batch rows | Specific | EXPLORATORY | HIGH |
| 78 | SP-48 `property_noOpRaisesInterest`: no non-deposit, non-environment call raises any actor's accrued interest | Specific | SHOULD-HOLD | HIGH |
| 79 | SP-49 `property_shortfallNotDeepened`: no non-environment call deepens a principal shortfall beyond per-operation rounding | Specific | EXPLORATORY | MEDIUM — tolerance is a per-operation heuristic `n * (rate/D + 2)` |
| 80 | SP-50 `property_activationSemantics`: activation succeeds only outside a live window and sets unlock to block + 5; a live window is never renewed | Specific | SHOULD-HOLD | HIGH |
| 81 | SP-51 `property_windowGatesGuardedCalls`: the window gates exactly the guarded calls; nothing else ever reverts UserMutationsLocked | Specific | SHOULD-HOLD | HIGH |
| 82 | SP-52 `property_refusalAttribution`: each refusal comes only from the operations documented to raise it | Specific | SHOULD-HOLD | HIGH |
| 83 | SP-53 `property_swapperAllowlistTransitions`: add/revoke set exactly that key; activation, batches and path switches need an authorised caller | Specific | SHOULD-HOLD | HIGH |
| 84 | SP-54 `property_pathStateMachine`: path switches need an allowlisted hash and touch one handler; allowlist edits flip one hash and never revoke the active path | Specific | SHOULD-HOLD | HIGH |
| 85 | SP-55 `property_preparedRowSurvivesWindow`: while a window is live, a row eligible at activation and not yet bought is never refused | Specific | EXPLORATORY | MEDIUM — needs a live ghost-snapshotted window; reached mainly through scenario and `probe_buyOne` calls |
| 86 | SP-56 `property_mutatorsOnlyLiveOwnedKeys`: a successful mutator acted on a live key owned by the caller; a batch bought only live keys of its token | Specific | SHOULD-HOLD | HIGH |
| 87 | SP-57 `property_noRouteRemap`: re-assigning a pair, reusing a handler or re-registering a route always reverts with the documented error | Specific | SHOULD-HOLD | HIGH |
| 88 | SP-58 `property_withdrawLiveness`: outside a window, an owner can always withdraw any amount in [1, balance] or the whole balance | Specific | SHOULD-HOLD | HIGH |
| 89 | SP-59 `property_deleteLiveness`: outside a window, an owner can always delete a schedule with its correct index | Specific | SHOULD-HOLD | HIGH |
| 90 | SP-60 `property_interestExitLiveness`: outside a window, interest-only and principal+interest withdrawals never revert | Specific | SHOULD-HOLD | HIGH |
| 91 | SP-61 `property_claimLiveness`: any account can always claim its rBTC over any route mask | Specific | SHOULD-HOLD | HIGH |
| 92 | SP-62 `property_fullExitAndReenter`: after a full exit the actor holds no schedules, claims, LayerBank shares or Sovryn value; others untouched | Specific | EXPLORATORY | HIGH |
| 93 | SP-62 `property_reenterOnEqualTerms`: re-entry after a full exit is worth at most the deposit plus one share and carries no stale interest | Specific | EXPLORATORY | MEDIUM — heuristic tolerances (`rate/D + 1` on value, `v0 + 1 + rate/(2D)` on interest) |
| 94 | SP-63 `property_cleanBatchLiveness`: a batch of clean rows from an allowlisted swapper with minRbtcOut 0 never reverts when the venue can fill it | Specific | EXPLORATORY | MEDIUM — "clean" rows come from the harness simulator (`_simLendingBatch`, `_venueOk` with a 1e-6 margin); simulator drift would read as a violation |
| 95 | SP-64 `property_protectedBatchInputFixed`: inside the planning window, with rate and exit fee unchanged, the batch burns the planned SR and the router takes the planned cash | Specific | EXPLORATORY | MEDIUM — planned `SR` / `cashIn` come from the harness simulator; skipped unless the lending rate is unchanged |
| 96 | SP-65 `property_minRbtcOutNotWeaponized`: a quote-derived minRbtcOut does not revert at an unchanged price, and a fill is priced no worse than quoted | Specific | EXPLORATORY | MEDIUM — same plan dependency as SP-64 |
| 97 | SP-66 `property_nonUserCallsKeepWallets`: swapper, owner, permissionless and environment calls leave every account's DOC, USDRIF and native unchanged | Specific | SHOULD-HOLD | HIGH |
| 98 | SP-67 `property_noProfitPerUserCall`: no user call profits its caller: rBTC net worth unchanged, stablecoin net worth up only by LayerBank dust | Specific | EXPLORATORY | MEDIUM — LayerBank allowance `_navEps` is hand-tuned per operation |
| 99 | SP-68 `property_nonSwapperCannotActAsSwapper`: a caller that is not an allowlisted swapper cannot activate, batch or switch a Dex path | Specific | SHOULD-HOLD | HIGH |
| 100 | SP-69 `property_handlersOnlyFromManager`: direct actor calls to a handler's fund-moving or interest functions revert OnlyDcaManagerCanCall | Specific | SHOULD-HOLD | HIGH |
| 101 | SP-70 `property_noForeignScheduleMutation`: an actor cannot mutate another owner's schedule: NotScheduleOwner, or UserMutationsLocked when guarded in a window | Specific | SHOULD-HOLD | HIGH |
| 102 | SP-71 `property_nonOwnerSettersRevert`: owner-only setters revert for actors and swappers, and renounceOwnership reverts even for the owner | Specific | SHOULD-HOLD | HIGH |
| 103 | SP-72 `property_intermediateDonationNoDos`: USDT0 donated to the shared router never makes a clean Dex batch on the alternative path revert | Specific | SHOULD-HOLD | LOW — never evaluated in the campaign: no Dex purchase ran on harness path 1 (`PurchaseUniswap.sol:243`, `:250`, `:251` have 0 hits) |
| 104 | SP-73 `property_fundingLiveness`: valid creates, deposits and top-ups succeed in any reachable state, including inside a window | Specific | EXPLORATORY | HIGH |
| 105 | SP-74 `property_reentrantClaimSafe`: a re-entrant claimant collects exactly its claims (SP-39) and every re-entry attempt fails | Specific | EXPLORATORY | HIGH |
| 106 | SP-75 `property_approvalRestorersHarmless`: an approval restorer only resets the handler's allowance to its fixed spender; nothing else moves | Specific | EXPLORATORY | HIGH |
| 107 | SP-76 `property_feeCurveMatchesSpec`: the fee equals the spec's single-floor formula, is monotone, bounded by the min/max rates and priced per row | Specific | SHOULD-HOLD | HIGH |
| 108 | SP-77 `property_feeSplitNoGain`: splitting a purchase into two rows never lowers the total fee by more than 1 wei | Specific | EXPLORATORY | HIGH |

## Open TODOs

None. `grep -rniE 'TODO|FIXME|XXX|HACK' test/fizz/` returns no matches in the suite files (`Base.sol`, `Snapshots.sol`, `Properties.sol`, `FuzzTester.sol`, `FoundryTester.sol`, `Actor.sol`, `ReentrantActor.sol`, `handlers/*`, `mocks/*`, `utils/*`).

## Next Steps
1. **Fix the harness false positive (GL-15).** In `property_sharePreviewPositive`, assert the min-amount half only when `minAmount * D(h) >= rate(h)`. Alternatively, clamp `dcaManager_secondary`'s token minimum to at least one share's price. Keep the 1e18 half. After the change, `test_repro_property_sharePreviewPositive` should be updated to expect no panic.
2. **Triage SP-64 (needs human review).** It is a dynamic confirmation of the "Deposits and new schedules in the protected window" lead and of the Finding 1 mechanism, with dust impact when there is no loss. The README's simple fix is `whenUserMutationsAllowed` on `depositToken` and `createDcaSchedule`. After a fix, `test_repro_adv_protectedBatchScenario` should stop firing.
3. **Check the unconfirmed GL-24 lead.** It comes from the 7B smoke run only: a Sovryn deposit of `purchaseAmount + 1` at a price above 1e18 leaves 1 wei of principal with zero shares. Pin it down in a Foundry unit test. If it is confirmed as accepted floor/ceil dust, add a value threshold to GL-24, for example "principal above one share's value implies shares > 0".
4. **Make the LOW-confidence property live (SP-72).** No purchase ran on harness path 1, so `PurchaseUniswap.sol:243/250/251` have 0 hits. Add a step that allowlists and activates path 1 on a Dex handler before `adv_cleanBatchLiveness` runs, through `setPurchasePathAllowed` and then `setPurchasePath`. Alternatively, start one Dex handler on path 1 in `Base.sol` setup.
5. **Tighten the MEDIUM properties where it is cheap.**
   - GL-18 and SP-55 rarely see a live window across calls. Add more inline window scenarios, or a dedicated `env_skipBlocks`-style handler that stays inside N..N+4.
   - SP-63, SP-64 and SP-65 depend on the harness batch simulator. Keep it in step with any change to `LendingHandler._batchRetrieveStablecoin`.
6. **Coverage.** There is no ❌ row. Add targeted negative wrappers that pick a live owned schedule with an out-of-domain argument, so the `DcaManager` validation reverts get exercised and checked through SP-52: L288, L507, L604, L623, L626, L716. Also update `coverage-targets.md`, whose claim that Medusa does not record revert lines is contradicted by this campaign's lcov (see Coverage Results).
7. **Blocking TODOs**: none.
8. **Production campaign duration.**
   - Current run: 8m25s and 501,776 calls, stopped by `testLimit` 500,000. Branches reached 15,121 after 1 minute and 15,301 at the end.
   - Recommended: at least 4 h (`medusa fuzz --timeout 14400` with `testLimit` 0), reusing the 626-entry corpus in `fizz_data/corpus_medusa`, after fixes 1 and 4. Then a 24 h run before release, to reach deeper window and loss sequences.
9. **Complementary Echidna pass.** No Echidna corpus exists yet (`fizz_data/corpus_echidna`). Run `echidna test/fizz/FuzzTester.sol --contract FuzzTester --config echidna.yaml`, with `testLimit` raised from 50,000 to at least 1,000,000. Keep `maxBlockDelay` 4 so the 5-block window survives between calls.
10. **Cosmetic.** Medusa warns that the `property_*` functions do not return `bool`, because its property-testing provider is still enabled. All checks run as assertion tests, so set `"propertyTesting": {"enabled": false}` in `medusa.json` to remove the noise.
