# Krait State Audit Candidates — Phase 2

## Coupled State Dependency Map

```
Contract: DcaManager
┌──────────────────────────────────┬──────────────────────────────────┬──────────────────────────────────────────────┐
│ State                            │ Coupled with                     │ Invariant                                    │
├──────────────────────────────────┼──────────────────────────────────┼──────────────────────────────────────────────┤
│ s_dcaSchedules[t][id].user       │ s_scheduleIds[user][t]           │ id ∈ list ⇔ schedule live and owned by user │
│ s_protocolSettings.scheduleNonce │ every id ever stored             │ strictly increasing; ids never reused        │
│ schedule.tokenBalance (idle)     │ handler stablecoin balance       │ Σ balances = cash held (+ donations)         │
│ schedule.tokenBalance (lending)  │ LendingHandler.s_shares[user]    │ value(shares) ≥ Σ balances, less ceil dust   │
│                                  │                                  │ and venue loss                               │
│ schedule.purchaseAmount          │ s_tokenMinPurchaseAmounts[t]     │ ≥ min at write time; never zero              │
│ schedule.purchaseAmount          │ schedule.tokenBalance            │ ≤ balance at write time only                 │
│ schedule.cadenceAnchor           │ schedule.purchasePeriod          │ next due = anchor + period (UTC midnights)   │
│ s_userMutationsAllowedFromBlock  │ the seven guarded mutators       │ refused while block.number < value           │
└──────────────────────────────────┴──────────────────────────────────┴──────────────────────────────────────────────┘

Contract: LendingHandler (+ adapter)
│ s_shares[user]                   │ external receipt-share balance   │ Σ s_shares ≤ balanceOf / scaledBalanceOf     │
│ s_shares[user]                   │ stablecoin paid or spent         │ debit = ceil(amount/rate); burn = debit      │

Contract: PurchaseRbtc / PurchaseFees
│ s_accumulatedRbtc[a] (claim+1)   │ handler rBTC / WRBTC balance     │ Σ claimable ≤ balance                        │
│ s_feeCollector                   │ s_accumulatedRbtc[collector]     │ fee credited to the collector at credit time │
│ s_minFeeRate, s_maxFeeRate       │ MAX_FEE_RATE_CAP                 │ min ≤ max ≤ 500                              │

Contract: PurchaseUniswap
│ s_swapPath                       │ s_swapIntermediateTokens         │ always written together                      │
│ s_swapPath                       │ s_purchasePathAllowed[hash]      │ active path is allowlisted                   │
│ s_amountOutMinimumPercent        │ s_amountOutMinimumSafetyCheck    │ safety ≤ percent ≤ 1e18                      │

Contract: OperationsAdmin
│ s_tokenRoute[t][r].handler       │ s_handlerAssigned[handler]       │ one handler ⇔ one pair, write-once           │
│ s_tokenRoute[t][r].handler       │ s_routeClass[r]                  │ lending class ⇔ ILendingHandler              │
```

## Mutation Matrix

```
schedule.tokenBalance
├── createDcaSchedule            + deposit   (handler pull exact; lending: + measured shares)
├── depositToken                 + deposit   (same)
├── topUpFromInterest            + amount    (no cash; amount ≤ value(shares) − Σ balances)
├── _withdrawToken               − requested (handler pays requested / clamped)
├── deleteDcaSchedule            → deleted   (handler pays balance / clamped)
└── _rbtcPurchaseChecksEffects   − purchaseAmount (handler spends Σ / burns ceil shares)

LendingHandler.s_shares[user]
├── _depositToken                + measured mint
├── _redeemShares (withdraw)     − ceil(amount/rate), bounded by clamp
├── _redeemShares (interest)     − ceil(interest/rate)
└── _batchRetrieveStablecoin     − ceil(purchase/rate), revert if short

s_scheduleIds[user][token]
├── createDcaSchedule            push
└── _removeScheduleId            swap-pop (index verified)

s_accumulatedRbtc[account]
├── _creditRbtc (buyer, collector)   + share of measured Q
└── _withdrawRbtcChecksEffects       → sentinel 1

s_swapPath / s_swapIntermediateTokens
├── constructor                  _setPurchasePath
└── setPurchasePath              _setPurchasePath        (no other writer; both fields in one helper)

s_userMutationsAllowedFromBlock
└── activateProtectedPurchaseWindow   (only writer)
```

No `???` entries: every writer of each coupled variable is listed, and each list was confirmed by
searching the contract (the accounting mappings are `private`, so leaves cannot add writers).

## Cross-Check, Ordering, Parallel Paths

- **Full removal** (`deleteDcaSchedule`): list entry and both schedule slots cleared before the handler
  call; handler shares are reduced by the redeem; leftover shares remain as the user's interest and are
  withdrawable because locked principal drops.
- **Partial reduction** (`_withdrawToken`, purchase): balance and shares move in the same call; shares by
  `ceil`.
- **Increase** (`deposit`, `topUp`): deposit moves both sides; top-up moves only the balance and is
  bounded by the measured excess.
- **Batch**: per-row running `s_shares` (same buyer twice is handled), one protocol burn equal to the sum.
- **Ordering**: in every user path the schedule is written before the handler interaction, except
  `createDcaSchedule`/`depositToken`/`topUpFromInterest`, which write after the handler call under
  `nonReentrant`.

| Operation | withdrawToken | deleteDcaSchedule | purchase row | withdrawInterest |
|---|---|---|---|---|
| Debits schedule | requested | whole balance | purchaseAmount | — |
| Debits shares | ceil(request), clamped | ceil(balance), clamped | ceil(amount), revert if short | ceil(excess) |
| Exact share-consumption check | ✅ | ✅ | ✅ | ✅ |
| Window-guarded | ✅ | ✅ | n/a (swapper) | ✅ |
| Shortfall behaviour | clamp, pay less | clamp, pay less | revert | no-op when no excess |

The one asymmetry is deliberate: user exits clamp, purchases revert (a clamp would dilute the other
buyers in the batch).

## Multi-step journeys simulated

1. deposit → 3 purchases → withdraw interest → last purchase: last row can be short by ≤ 4 share units
   (tail case, C-03).
2. deposit → top-up all interest → purchases: same tail, one purchase earlier.
3. two schedules on one lending route → delete one → interest → purchase the other: locked principal
   tracks the list correctly after swap-pop.
4. create → delete → create on the same route: leftover shares are treated as interest of the new
   position; no stale per-schedule state survives because ids are never reused.
5. credit rBTC → withdraw → credit → withdraw: sentinel round trip pays exact amounts.

## Masking code review

| Pattern | Location | What it hides | Value-loss path? |
|---|---|---|---|
| Clamp `if (total < amount) amount = total` | LendingHandler.sol:144-147 | value(shares) < principal (venue loss, exit fee, ≤ N-unit ceil dust) | Only the caller's own position; not transferable to others |
| Early return on no interest | LendingHandler.sol:53-55 | value ≤ locked principal | none |
| `if (sharesToRedeem == 0) return 0` | LendingHandler.sol:299-301 | zero request after clamp | none |
| `if (balance > prev)` else 0 | PurchaseMoc.sol:53-57 | non-increasing native balance | caller reverts on 0 |
| Skip zero credit | PurchaseRbtc.sol:166 | sub-wei row share | dust |
| `continue` on unassigned/idle pair | DcaManager.sol:316-319, 338-339 | user passes a non-yielding pair | none |

## Desynchronization Candidates

### [STATE-1] Schedule principal and lending shares are coupled only by rounding direction; the clamp absorbs any gap

**Severity**: LOW
**Coupled Pair**: `schedule.tokenBalance` ↔ `LendingHandler.s_shares[user]`
**Breaking Operation**: `_withdrawToken` / `deleteDcaSchedule` when `value(shares) < Σ tokenBalance`
**File**: src/DcaManager.sol, src/LendingHandler.sol
**Lines**: DcaManager 712-736; LendingHandler 139-152

**Invariant**: `floor(shares × rate) ≥ Σ tokenBalance` on the route.
**Breaking Scenario**:
1. Venue loss or exit fee (external), or accumulated ceil debits (≤ N share units).
2. `withdrawToken(X)` debits `X`; handler clamps and pays `value(shares) < X`.
3. The difference is not re-credited.

**Masking Code**: clamp at LendingHandler.sol:144-147.
**Cross-Feed**: C-06 (same root cause), C-03 (purchase side of the same gap).

**Step Execution**: Phases: 1=✓ 2=✓ 3=✓ 4=✓ 5=✓ 6=✓ 7=✓ 8=✓
**Rules Applied**: [R8:✗, R10:✓(severity at venue-loss state), R11:✗, R12:✓(3 enablers listed), R15:✗(rate not pushable down), R16:✗]
**Depth Evidence**: [TRACE:52 purchases flat rate → 45 units short], [BOUNDARY:shares=0 → pays 0, principal debited]
**Who Benefits**: nobody inside the protocol

**Status**: UNVERIFIED

### [STATE-2] Fee credits are bound to the collector address at credit time, not to the current collector

**Severity**: LOW
**Coupled Pair**: `s_feeCollector` ↔ `s_accumulatedRbtc[collector]`
**Breaking Operation**: `setFeeCollector`
**File**: src/PurchaseFees.sol:78-82
**Cross-Feed**: C-07.
**Status**: UNVERIFIED

### [STATE-3] `purchaseAmount ≤ tokenBalance` holds only at write time

**Severity**: LOW
**Coupled Pair**: `schedule.purchaseAmount` ↔ `schedule.tokenBalance`
**Breaking Operation**: `_withdrawToken`, purchases
**Cross-Feed**: RS-4.
**Status**: UNVERIFIED

No coupled pair was found where one side is written without the other in a way that moves value between
accounts.
