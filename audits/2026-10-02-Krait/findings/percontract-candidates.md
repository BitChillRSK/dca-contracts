# Krait Per-Contract Candidates — Phase 1c

Run inline, one focused pass per cluster (no sub-agents were spawned for this session).

## Cluster plan

| Cluster | Files | LOC | Reason for grouping |
|---------|-------|-----|---------------------|
| 1 | DcaManager.sol, interfaces/IDcaManager.sol | 1,294 | Standalone ledger + its surface |
| 2 | OperationsAdmin.sol, BitChillOwnable.sol, DcaManagerAccessControl.sol, interfaces/IOperationsAdmin.sol, IDcaManagerAccessControl.sol | 424 | Registry and access bases |
| 3 | PurchaseRbtc.sol, PurchaseFees.sol, PurchaseMoc.sol, StablecoinSource.sol, IPurchaseRbtc, IPurchaseFees, IStablecoinSource, IMocProxy | 779 | Purchase branch chain |
| 4 | PurchaseUniswap.sol, IPurchaseUniswap, IUniswapV3SwapRouter, ICoinPairPrice, IWRBTC | 648 | Dex purchase chain |
| 5 | TokenHandler.sol, LendingHandler.sol, ITokenHandler, ILendingHandler | 607 | Custody chain |
| 6 | layerbank/* (handler, two leaves, three interfaces) | 253 | LayerBank adapter chain |
| 7 | sovryn/* (handler, two leaves, IiToken) | 208 | Sovryn adapter chain |
| 8 | idle/* (handler, two leaves) | 130 | Idle chain |

No scope file is left without a cluster. `src/tropykus-legacy/` is out of scope by instruction.

## Exclusion list

All 19 `C-` entries and 6 `RS-` entries (see `rescan-candidates.md`, plus):
- [LOW] OperationsAdmin.sol:79 — assignment irreversible
- [LOW] OperationsAdmin.sol:91 — handler self-reported validation
- [LOW] IdleHandler.sol:37 — no handler-side per-user book
- [LOW] DcaManager.sol:621 vs 712 — `purchaseAmount ≤ balance` not preserved by withdrawals
- [LOW] DcaManager.sol:61 — global window lock
- [LOW] DcaManager.sol:395 — raised minimum blocks edits on low balances

## Cluster 1 — DcaManager

Per-function: state completeness (both slots written together on create; slot 0 only on purchase),
branch audit (`cadenceAnchor != 0`, `tokenBalance > 0`, `index != lastIndex`, sentinel max, `continue`
paths), boundaries (0, 1, max for amounts; `uint32` period and route; `uint64` nonce), pairing
(push/swap-pop, deposit/withdraw, pause set/unset).

### [PC1-1] Purchases are eligible at 00:00 UTC of the due day, so a first interval can be almost a day short

**Severity**: LOW
**File**: src/DcaManager.sol
**Lines**: 545-563
**Description**: the anchor is the UTC midnight of the first buy. A 7-day schedule first bought at
23:59 UTC is due again 6 days and 1 minute later. Later intervals sit on the grid.
**Depth Evidence**: [TRACE:first buy ts=day0+86399 → anchor day0 → eligible at day0+7d = 6d 0h 0m 1s later]
**Status**: UNVERIFIED

EXCLUDED — same-day second purchase after a period cut at DcaManager.sol:194-205. Duplicate of
[LOW] DcaManager.sol:194.
EXCLUDED — immediate first purchase at DcaManager.sol:540-551. Duplicate of [LOW] DcaManager.sol:540.

No further finding. Verified: `nextDue − block.timestamp` cannot underflow (both midnight-aligned and
`nextDue > currentDayStart`), `periodsElapsed × purchasePeriod` cannot exceed today, `scheduleNonce`
is written before the external pull and is never decremented, `_lockedPrincipal` reads the list after the
swap-pop on delete.

## Cluster 2 — OperationsAdmin and access bases

No new finding. `renounceOwnership` reverts; `transferOwnership`/`acceptOwnership` are OZ two-step;
`DcaManagerAccessControl` constructor does not validate its argument, but a handler with a wrong
manager cannot pass `assignHandler` (`i_operationsAdmin()` call on a non-contract or foreign manager
reverts or mismatches).

## Cluster 3 — PurchaseRbtc / PurchaseFees / PurchaseMoc

Fee and reward trace: accrual (`_calculateFeeAndNetWeights`) → allocation (`Q×netᵢ/G`, `Q×F/G`) →
credit (`_creditRbtc`) → withdrawal (`_withdrawRbtcChecksEffects`, `_withdrawRbtc`). Assets and books
stay consistent at each step; `Σnetᵢ + F = G` exactly.

### [PC3-1] `amountSpent` and fee-stablecoin event fields are independent floors that do not sum to the retrieved total

**Severity**: LOW (informational)
**File**: src/PurchaseRbtc.sol
**Lines**: 164, 180
**Description**: `userStablecoinSpent = R×Pᵢ/G` per row and `feeStablecoin = R×F/G` are event-only values;
`Σ userStablecoinSpent ≤ R`, and the fee figure is a share of the same `R`, not an addition to it. An
indexer that sums rows will be short of `SuccessfulRbtcBatchPurchase.totalStablecoinAmountSpent` by
less than one unit per row.
**Status**: UNVERIFIED

## Cluster 4 — PurchaseUniswap

### [PC4-1] `setMocOracle` accepts any non-zero address without probing it

**Severity**: LOW
**File**: src/PurchaseUniswap.sol
**Lines**: 179-185
**Description**: a wrong address halts purchases (call reverts) or, if it answers `getPriceInfo` with
another pair's price, produces a meaningless floor until corrected.
**Precondition Type**: ACCESS (owner)
**Status**: UNVERIFIED

### [PC4-2] The path allowlist does not constrain intermediate tokens

**Severity**: LOW
**File**: src/PurchaseUniswap.sol
**Lines**: 132-145, 336-351
**Description**: an allowlisted path may repeat a token or name the stablecoin or WRBTC as an
intermediate; the intermediate-balance check then watches the wrong balances for that path.
**Precondition Type**: ACCESS (owner)
**Status**: UNVERIFIED

EXCLUDED — floor/`minRbtcOut` slack at PurchaseUniswap.sol:231-237. Duplicate of [MEDIUM] PurchaseUniswap.sol:231.

## Cluster 5 — TokenHandler / LendingHandler

Parent standalone pass on `TokenHandler`: deposit requires an exact delta; withdraw reports the measured
delta. Pairing audit on `_stablecoinToShares` (ceil) and `_sharesToStablecoin` (floor): debit side never
below what the protocol burns.

### [PC5-1] `_exchangeRate()` defaults to the view rate, so a future lazily-accruing adapter compiles without a poke

**Severity**: LOW (informational)
**File**: src/LendingHandler.sol
**Lines**: 196-204
**Description**: acknowledged in the NatSpec. Not reachable with the two in-scope adapters: Sovryn
`tokenPrice()` and Aave `getReserveNormalizedIncome()` already include pending interest.
**Status**: UNVERIFIED

EXCLUDED — clamp and request-sized debit at LendingHandler.sol:139-152. Duplicate of [MEDIUM] DcaManager.sol:712.

## Cluster 6 — LayerBank

No new finding. `_underlyingForExactScaledBurn` verified for `index ∈ [RAY, 3·RAY)`; the `+1` amount never
exceeds `rayMul(s, index)` so a full-position withdrawal stays within the aToken balance.
EXCLUDED — burn rounding assumption at LayerBankHandler.sol:88-111. Duplicate of [MEDIUM] LayerBankHandler.sol:88.

## Cluster 7 — Sovryn

No new finding. Constructor checks `loanTokenAddress() == stablecoin`; `burn`/`mint` returns ignored;
deposits too small to mint one share revert `LendingProtocolDepositFailed`.

## Cluster 8 — Idle

No new finding beyond RS-3.

## File coverage checkpoint

| File | LOC | Opened? | Functions analyzed |
|------|-----|---------|--------------------|
| DcaManager.sol | 780 | YES | all 47 (incl. constructor) |
| interfaces/IDcaManager.sol | 514 | YES | surface + NatSpec vs implementation |
| OperationsAdmin.sol | 170 | YES | all 10 |
| BitChillOwnable.sol | 39 | YES | 1 |
| DcaManagerAccessControl.sol | 36 | YES | modifier + ctor |
| PurchaseRbtc.sol | 220 | YES | all 12 |
| PurchaseFees.sol | 214 | YES | all 11 |
| PurchaseMoc.sol | 59 | YES | 1 |
| StablecoinSource.sol | 48 | YES | ctor + hook |
| PurchaseUniswap.sol | 382 | YES | all 21 |
| TokenHandler.sol | 86 | YES | all 6 |
| LendingHandler.sol | 335 | YES | all 23 |
| layerbank/LayerBankHandler.sol + 2 leaves + 3 interfaces | 253 | YES | all |
| sovryn/SovrynHandler.sol + 2 leaves + IiToken | 208 | YES | all |
| idle/IdleHandler.sol + 2 leaves | 130 | YES | all |
| remaining interfaces (ILendingHandler, ITokenHandler, IPurchase*, IOperationsAdmin, IMocProxy, ICoinPairPrice, IUniswapV3SwapRouter, IWRBTC, IStablecoinSource, IDcaManagerAccessControl) | 1,047 | YES | surface |

Per-contract complete: 8 clusters, 5 new candidates.
