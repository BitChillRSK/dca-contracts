# Entry Point Map

> BitChill dca-contracts | 40 entry points | 6 permissionless | 19 role-gated | 15 admin-only

---

## Protocol Flow Paths

### Setup (Owner)

`OperationsAdmin.registerRoute()` → [deploy handlers] → `DcaManager.setTokenMinPurchaseAmount()` → `OperationsAdmin.assignHandler()` → `OperationsAdmin.addSwapper()`

### User Flow

`[owner setup above]` → `DcaManager.createDcaSchedule()`  ◄── deposits not paused on the pair
                         ├─→ `depositToken()` / `updatePurchaseAmount()` / `updatePurchasePeriod()` / `setSchedulePaused()`
                         ├─→ `withdrawToken()` / `withdrawTokenAndInterest()` / `deleteDcaSchedule()`  ◄── no live window
                         └─→ `topUpFromInterest()`  ◄── lending route, interest accrued

### Purchase (Swapper)

`[schedule above]` → `activateProtectedPurchaseWindow()` (optional) → `batchBuyRbtc()` / `batchBuyRbtcAcrossHandlers()`  ◄── period elapsed, not paused, balance ≥ amount
    → `PurchaseRbtc.batchBuyRbtc()` → `_batchRetrieveStablecoin()` → `_purchaseRbtc()` (MoC or Uniswap)  ◄── venue liquidity, oracle valid

### Claims (User)

`[purchase above]` → `DcaManager.withdrawAllAccumulatedRbtc()` → `PurchaseRbtc.withdrawAccumulatedRbtc()`
`[lending deposit]` ◄── exchange rate rises → `DcaManager.withdrawAllAccumulatedInterest()` → `LendingHandler.withdrawInterest()`

---

## Permissionless

### `DcaManager.createDcaSchedule()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | User |
| Parameters | token (user-controlled), depositAmount (user-controlled), purchaseAmount (user-controlled), purchasePeriod (user-controlled), routeIndex (user-controlled) |
| Call chain | `→ OperationsAdmin.getHandler()/areDepositsPaused() → TokenHandler.depositToken() → [LendingHandler._depositToken() → LayerBankHandler/SovrynHandler._protocolDeposit()]` |
| State modified | `s_protocolSettings.scheduleNonce`, `s_dcaSchedules`, `s_scheduleIds`; handler `s_shares` on lending routes |
| Value flow | Tokens: user → handler (→ lending market) |
| Reentrancy guard | yes |

### `DcaManager.withdrawAllAccumulatedRbtc()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, nonReentrant |
| Caller | User (acts on `msg.sender` only) |
| Parameters | tokens (user-controlled), routeIndexes (user-controlled) |
| Call chain | `→ OperationsAdmin.getHandler() → PurchaseRbtc.withdrawAccumulatedRbtc() → [PurchaseUniswap._withdrawRbtc() → WRBTC.withdraw()] → user.call{value}` |
| State modified | handler `s_accumulatedRbtc[msg.sender]` |
| Value flow | rBTC: handler → user |
| Reentrancy guard | yes (manager); handler relies on the manager's guard |

### `DcaManager.withdrawAllAccumulatedInterest()`

| Aspect | Detail |
|--------|--------|
| Visibility | external, whenUserMutationsAllowed, nonReentrant |
| Caller | User (acts on `msg.sender` only) |
| Parameters | tokens (user-controlled), routeIndexes (user-controlled) |
| Call chain | `→ OperationsAdmin.getHandler()/getRouteClass() → LendingHandler.withdrawInterest() → _protocolRedeem() → IERC20.safeTransfer()` |
| State modified | handler `s_shares[msg.sender]` |
| Value flow | Tokens: lending market → handler → user |
| Reentrancy guard | yes |

### `LendingHandler.restoreLendingApproval()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone |
| Parameters | none |
| Call chain | `→ IERC20.forceApprove(lending spender, max)` |
| State modified | stablecoin allowance only |
| Value flow | None |
| Reentrancy guard | no |

### `PurchaseUniswap.restoreSwapRouterApproval()`

| Aspect | Detail |
|--------|--------|
| Visibility | external |
| Caller | Anyone |
| Parameters | none |
| Call chain | `→ IERC20.forceApprove(SwapRouter02, max)` |
| State modified | stablecoin allowance only |
| Value flow | None |
| Reentrancy guard | no |

### `PurchaseRbtc.receive()`

| Aspect | Detail |
|--------|--------|
| Visibility | external payable |
| Caller | MoC, WRBTC, or anyone |
| Parameters | msg.value |
| Call chain | none |
| State modified | native balance only; credited to no one outside a measured purchase |
| Value flow | rBTC: sender → handler |
| Reentrancy guard | no |

---

## Role-Gated

### Schedule owner (`_callersSchedule`, `DcaManager.sol:589`)

| Function | Extra guards | State modified | Value flow |
|----------|--------------|----------------|------------|
| `DcaManager.depositToken()` | nonReentrant, deposit pause | `tokenBalance`; `s_shares` | user → handler |
| `DcaManager.updatePurchaseAmount()` | window, nonReentrant | `purchaseAmount` | none |
| `DcaManager.updatePurchasePeriod()` | window, nonReentrant | `purchasePeriod` | none |
| `DcaManager.setSchedulePaused()` | window, nonReentrant | `paused` | none |
| `DcaManager.deleteDcaSchedule()` | window, nonReentrant | schedule, `s_scheduleIds`; `s_shares` | handler → user |
| `DcaManager.withdrawToken()` | window, nonReentrant | `tokenBalance`; `s_shares` | handler → user |
| `DcaManager.withdrawTokenAndInterest()` | window, nonReentrant, lending route | `tokenBalance`; `s_shares` | handler → user |
| `DcaManager.topUpFromInterest()` | nonReentrant, lending route | `tokenBalance` | none (claim only) |

### Swapper (`onlySwapper`, `DcaManager.sol:74`)

| Function | Parameters | State modified | Value flow |
|----------|------------|----------------|------------|
| `DcaManager.activateProtectedPurchaseWindow()` | none | `s_userMutationsAllowedFromBlock` | none |
| `DcaManager.batchBuyRbtc()` | batch: scheduleIds, token, routeIndex, minRbtcOut (keeper-provided) | `tokenBalance`, `cadenceAnchor`; handler books | handler stablecoin → venue → handler rBTC |
| `DcaManager.batchBuyRbtcAcrossHandlers()` | batches (keeper-provided) | same, per handler | same |
| `PurchaseUniswap.setPurchasePath()` | intermediateTokens, poolFeeRates (keeper-provided; allowlisted) | `s_swapPath`, `s_swapIntermediateTokens` | none |

`setPurchasePath` also accepts the handler owner. The two batch functions have no reentrancy guard.

### DcaManager only (`onlyDcaManager`, `DcaManagerAccessControl.sol:23`)

| Function | Parameters | State modified | Value flow |
|----------|------------|----------------|------------|
| `TokenHandler.depositToken()` | user, depositAmount (protocol-derived) | `s_shares` (lending) | user → handler |
| `TokenHandler.withdrawToken()` | user, withdrawalAmount (protocol-derived) | `s_shares` (lending) | handler → user |
| `LendingHandler.withdrawInterest()` | user, locked principal (protocol-derived) | `s_shares` | handler → user |
| `LendingHandler.getAccruedInterest()` | user, locked principal (protocol-derived) | none; may poke market accrual | none |
| `PurchaseRbtc.batchBuyRbtc()` | buyers, scheduleIds, purchaseAmounts (protocol-derived), minRbtcOut (keeper-provided) | `s_shares`, `s_accumulatedRbtc` | stablecoin → venue → rBTC |
| `PurchaseRbtc.withdrawAccumulatedRbtc()` | user (protocol-derived) | `s_accumulatedRbtc` | rBTC → user |

### Pending owner (`Ownable2Step`)

| Function | State modified |
|----------|----------------|
| `acceptOwnership()` (all nine ownable contracts) | owner |

---

## Admin-Only

| Contract | Function | Parameters | State Modified |
|----------|----------|------------|----------------|
| DcaManager | `setMinPurchasePeriod()` | minPurchasePeriod | `s_protocolSettings.minPurchasePeriod` |
| DcaManager | `setMaxSchedulesPerToken()` | maxSchedulesPerToken | `s_protocolSettings.maxSchedulesPerToken` |
| DcaManager | `setTokenMinPurchaseAmount()` | token, minPurchaseAmount | `s_tokenMinPurchaseAmounts` |
| OperationsAdmin | `registerRoute()` | index, lends | `s_routeClass` (once) |
| OperationsAdmin | `assignHandler()` | token, routeIndex, handler | `s_tokenRoute.handler`, `s_handlerAssigned` (once) |
| OperationsAdmin | `setDepositsPaused()` | token, routeIndex, paused | `s_tokenRoute.depositsPaused` |
| OperationsAdmin | `addSwapper()` / `revokeSwapper()` | swapper | `s_swappers` |
| PurchaseFees | `setFeeRateParams()` | minFeeRate, maxFeeRate, feePurchaseLowerBound | fee rates, lower bound |
| PurchaseFees | `setFeeCollector()` | feeCollector | `s_feeCollector` |
| PurchaseUniswap | `setPurchasePathAllowed()` | intermediateTokens, poolFeeRates, allowed | `s_purchasePathAllowed` |
| PurchaseUniswap | `setAmountOutMinimumPercent()` | percent | `s_amountOutMinimumPercent` |
| PurchaseUniswap | `setAmountOutMinimumSafetyCheck()` | safetyCheck | `s_amountOutMinimumSafetyCheck` |
| PurchaseUniswap | `setMocOracle()` | newOracle | `s_mocOracle` |
| BitChillOwnable | `transferOwnership()` | newOwner | pending owner |

`renounceOwnership()` always reverts (`BitChillOwnable.sol:36`). No contract uses a proxy or an initializer.
