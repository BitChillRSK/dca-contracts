# AuditAgent report - Scan ID `ca256ac8-f203-4034-ab2a-1656bef69a13`

## Scan details

| Key | Value |
|---|---|
| Repository | BitChillRSK/dca-contracts |
| Branch | `docs/r113-audit-readiness-docs` |
| Commit | `284b3500...bb3be0f8` |
| Scan ID | `ca256ac8-f203-4034-ab2a-1656bef69a13` |
| Scan type | Auditor Scan |
| Date | October 6, 2026 |
| Lines of code | 4,343 |
| Contracts in scope | 37 |
| Vulnerabilities found | 6 |
| Audit score | 95 |

## Contracts in scope

- `src/idle/IdleDocHandlerMoc.sol`
- `src/idle/IdleHandler.sol`
- `src/idle/IdleHandlerDex.sol`
- `src/interfaces/ICoinPairPrice.sol`
- `src/interfaces/IDcaManager.sol`
- `src/interfaces/IDcaManagerAccessControl.sol`
- `src/interfaces/ILendingHandler.sol`
- `src/interfaces/IMocProxy.sol`
- `src/interfaces/IOperationsAdmin.sol`
- `src/interfaces/IPurchaseFees.sol`
- `src/interfaces/IPurchaseRbtc.sol`
- `src/interfaces/IPurchaseUniswap.sol`
- `src/interfaces/IStablecoinSource.sol`
- `src/interfaces/ITokenHandler.sol`
- `src/interfaces/IUniswapV3SwapRouter.sol`
- `src/interfaces/IWRBTC.sol`
- `src/layerbank/ILayerBankAToken.sol`
- `src/layerbank/ILayerBankHandler.sol`
- `src/layerbank/ILayerBankPool.sol`
- `src/layerbank/LayerBankDocHandlerMoc.sol`
- `src/layerbank/LayerBankHandler.sol`
- `src/layerbank/LayerBankHandlerDex.sol`
- `src/sovryn/IiToken.sol`
- `src/sovryn/SovrynDocHandlerMoc.sol`
- `src/sovryn/SovrynHandler.sol`
- `src/sovryn/SovrynHandlerDex.sol`
- `src/BitChillOwnable.sol`
- `src/DcaManager.sol`
- `src/DcaManagerAccessControl.sol`
- `src/LendingHandler.sol`
- `src/OperationsAdmin.sol`
- `src/PurchaseFees.sol`
- `src/PurchaseMoc.sol`
- `src/PurchaseRbtc.sol`
- `src/TokenHandler.sol`
- `src/StablecoinSource.sol`
- `src/PurchaseUniswap.sol`

## Findings summary

| Severity | Count |
|---|---|
| High | 0 |
| Medium | 3 |
| Low | 3 |
| Info | 0 |
| Best practices | 0 |
| Total | 6 |

## Code summary

BitChill is a decentralized dollar-cost averaging (DCA) protocol built on the Rootstock network that allows users to automate recurring purchases of rBTC using supported stablecoins, such as Dollar on Chain (DOC). The protocol is architected around a modular separation of schedule accounting, governance routing, token custody, yield generation, and trade execution.

The core schedule management engine is `DcaManager`, which serves as the primary gateway for users and swappers. Rather than holding tokens itself, it maintains schedule state, balances, and cadence tracking. DCA schedules operate on a fixed UTC midnight grid, preventing cadence drift and disallowing catch-up purchases for missed intervals. To protect automated batch executions from being invalidated or front-run by user adjustments, `DcaManager` incorporates a temporary five-block execution window (`activateProtectedPurchaseWindow`) during which user balance modifications, schedule cancellations, and setting adjustments are locked.

Routing and system configuration are governed by `OperationsAdmin`, an immutable-per-route registry that maps `(token, routeIndex)` pairs to dedicated handlers and classifies them as either `Idle` or `Lending`. OperationsAdmin also manages authorized swappers and individual per-pair deposit pauses.

Fund custody and trade execution are delegated to specialized handler contracts (`TokenHandler`, `IdleHandler`, `LendingHandler`, `PurchaseMoc`, and `PurchaseUniswap`):
- Idle Handlers hold deposited stablecoins directly in the handler until swapper execution.
- Lending Handlers deploy idle stablecoins into integrated lending platforms (such as LayerBank using scaled aTokens or Sovryn using iTokens) to generate yield while awaiting purchase triggers. Users can withdraw interest or top up their schedules directly with earned yield without moving underlying tokens.
- Money on Chain (MoC) Purchase routes directly redeem DOC for native rBTC through the MoC protocol at the protocol redemption price.
- Uniswap V3 Purchase routes swap stablecoins into Wrapped rBTC (WRBTC) through Uniswap V3 SwapRouter02 and unwrap to native rBTC upon withdrawal. These swaps enforce both caller slippage bounds and an on-chain price floor computed via Money on Chain BTC/USD oracle feeds.
- Fee management in `PurchaseFees` calculates basis-point fees along an asymptotic curve, crediting native rBTC to a designated fee collector upon purchase execution.

### Main Entry Points

- createDcaSchedule (Actor: User): Creates and funds a new recurring DCA schedule for rBTC purchases using a specified stablecoin and route.
- depositToken (Actor: User): Deposits additional stablecoin principal into an existing DCA schedule.
- updatePurchaseAmount (Actor: User): Updates the recurring purchase amount to spend on rBTC for an existing schedule.
- updatePurchasePeriod (Actor: User): Updates the interval in whole UTC days between rBTC purchases for an existing schedule.
- setSchedulePaused (Actor: User): Pauses or resumes rBTC purchases on a user's schedule while preserving schedule balances and other user actions.
- deleteDcaSchedule (Actor: User): Cancels and deletes an existing schedule, returning remaining unspent stablecoin principal to the owner.
- withdrawToken (Actor: User): Withdraws a specified amount or the entire unspent stablecoin principal from a schedule.
- withdrawTokenAndInterest (Actor: User): Withdraws principal from a schedule as well as all accrued lending interest on that route.
- topUpFromInterest (Actor: User): Credits accrued lending interest directly toward a schedule's spendable principal balance.
- withdrawAllAccumulatedInterest (Actor: User): Claims and withdraws accrued lending interest across multiple specified token and route pairs.
- withdrawAccumulatedRbtc (Actor: User): Withdraws native rBTC accumulated on a specific token and route handler.
- withdrawAllAccumulatedRbtc (Actor: User): Withdraws accumulated native rBTC across multiple specified token and route handlers.
- activateProtectedPurchaseWindow (Actor: Swapper): Opens a 5-block execution window locking user schedule mutations to safely execute batch purchases.
- batchBuyRbtc (Actor: Swapper): Executes a batch purchase of rBTC on a single handler for all specified due schedules.
- batchBuyRbtcAcrossHandlers (Actor: Swapper): Atomically executes batch rBTC purchases across multiple handlers in a single transaction.
- setPurchasePath (Actor: Swapper): Switches the active Uniswap V3 swap path to an already allowlisted route.
- restoreSwapRouterApproval (Actor: Any Caller): Re-establishes the maximum stablecoin approval to Uniswap SwapRouter02 on DEX handlers.
- restoreLendingApproval (Actor: Any Caller): Re-establishes the maximum stablecoin allowance to the underlying lending spender on lending handlers.

## Findings

### 1. Rounded-up share redemptions consume remaining principal backing and revert shared purchase batches

**Severity:** Medium  
**Contracts:** `src/LendingHandler.sol`, `src/DcaManager.sol`, `src/layerbank/LayerBankHandler.sol`

#### Context

`DcaManager` records nominal principal in each schedule's `tokenBalance`. `_lockedPrincipal` aggregates those balances for one user, token, and lending route, while `LendingHandler` maintains that user's pooled receipt shares in `s_shares`. Principal withdrawals reduce the schedule ledger by the requested amount; interest withdrawals should redeem only value above the remaining aggregate principal. Both use `_redeemShares`, which rounds the requested stablecoin amount upward into shares and pays the measured redemption proceeds. `LayerBankHandler` selects an underlying withdrawal amount that burns those scaled shares exactly. Later purchases require sufficient shares for every nominal purchase amount and deliberately revert rather than clamp a deficient row.

```solidity
// File: src/LendingHandler.sol
uint256 sharesToRedeem = _stablecoinToShares(stablecoinAmount, exchangeRate);
if (sharesToRedeem == 0) {
    return 0;
}
// @auditagent> Locked principal remains unreserved
_setUserShares(user, userShares, userShares - sharesToRedeem);
stablecoinReceived = _measuredProtocolRedeem(sharesToRedeem, exchangeRate);
```

#### Root Cause

The withdrawal accounting bounds redemption by the user's total shares but does not reserve the shares needed to back remaining locked principal. Let `S` be user shares, `r` the exchange rate, and `D` its scale. Share value is `floor(S*r/D)`, while redeeming an amount `a` burns `ceil(a*D/r)` shares. That ceiling can consume more share-backed value than the manager removes from principal or classifies as interest. `_measuredProtocolRedeem` verifies exact external share consumption, not whether the remaining shares still cover outstanding schedule claims.

The defect is reachable through several independent paths:

- **Interest-only withdrawal:** `withdrawAllAccumulatedInterest` calls `withdrawInterest` with unchanged aggregate locked principal `L`. The handler computes interest as `floor(S*r/D) - L`, then rounds its share debit upward. For example, two shares worth two underlying units each with three units locked have one unit of nominal interest. Burning one whole share can pay two units and leave only two units backing the unchanged three-unit claim. Similarly, with `S = 10`, `r = 1.5D`, and `L = 14`, withdrawing one unit burns one share and leaves a floored value of 13. On a Sovryn route with `tokenPrice = 1.05e18`, 1,000 shares and 1,000 locked units produce 50 units of interest; redeeming 48 shares leaves 952 shares worth 999 units, whereas purchasing the full principal requires 953 shares.

- **LayerBank interest-only exact-burn example:** At `r = 1.1e27`, 10,000,000 scaled shares back 11,000,000 underlying units against 10,000,000 locked units. Redeeming the 1,000,000-unit interest burns `ceil(1,000,000 / 1.1) = 909,091` shares. `_underlyingForExactScaledBurn` selects 1,000,000 underlying units, whose half-up division burns exactly those shares, so redemption succeeds. The remaining 9,090,909 shares have a floored value of 9,999,999 units. A purchase of the recorded 10,000,000 principal units requires 9,090,910 shares and fails.

- **Principal-only withdrawal:** `_withdrawToken` reduces `tokenBalance` only by `withdrawalAmount`, even when the rounded share debit consumes additional backing. At two underlying units per share, a schedule with balance 20, purchase amount 19, and 10 shares can withdraw one unit, burn one share, and retain a nominal balance of 19 against only 18 units of backing. The next purchase needs 10 shares but only nine remain. The interest-only variant with 10 shares and 19 locked units produces the same mismatch. This requires no lending loss or prior interest claim.

- **LayerBank principal exact-burn example:** Let `p = 1e18` and the index be `1.1e27`. A fresh schedule depositing `11p` with purchase amount `p` receives exactly `10p` scaled shares under the expected indexed accounting. Withdrawing `10p` debits 9,090,909,090,909,090,910 shares. The adapter requests `10p + 1` underlying units to burn them exactly. Remaining shares back only `p - 1`, although the manager retains a balance of `p`. The purchase requires one more share than remains, despite passing the manager's nominal balance check.

- **Combined principal and interest withdrawal:** `withdrawTokenAndInterest` performs `_withdrawToken` before calculating interest against the post-debit locked principal. Starting with `1e18` shares and `1e18` locked units deposited at rate `D`, then withdrawing 11 principal units at rate `1.1D` and claiming interest leaves share-backed value of 999,999,999,999,999,988 against 999,999,999,999,999,989 locked units. A fee-free interest redemption can also pay one unit above the computed interest. A purchase equal to the remaining balance is consequently one share short.

- **Compounding before principal withdrawal:** `topUpFromInterest` can eliminate the equity buffer without changing shares. Let `A = 1e18`; two schedules initially depositing `A` each at rate `D` hold `2A` shares. At `1.5D`, compounding all `A` interest into the first schedule creates balances `2A` and `A`, matching `3A` equity. Withdrawing `2A` from the first schedule burns 1,333,333,333,333,333,334 shares, leaving value `A - 1` against the second schedule's `A` claim. Independently, claiming the `A` interest without compounding leaves value `2A - 1` against unchanged principal of `2A`.

- **Deposit rounding:** A position can already start with the same share-coverage gap. The manager books the full deposit, while `_depositToken` credits only measured minted shares. Sovryn's floored mint and Aave-style LayerBank supply's half-up rounding can credit one share fewer than `ceil(depositAmount*D/r)`. Exact token-pull and receipt-delta checks do not establish full nominal principal backing.

`_batchRetrieveStablecoin` independently applies the ceiling to each purchase row. If a row requires more than the remaining `s_shares`, it raises `LendingHandler__InsufficientShares`; there is no failed-row isolation.

#### Impact

A schedule can remain apparently funded and purchase-eligible in the manager ledger while lacking enough shares to execute its remaining purchase. Including it reverts the entire batch, rolling back preceding users' share debits and the manager's schedule effects. Through `batchBuyRbtcAcrossHandlers`, the failure also rolls back the entire across-handlers transaction. Otherwise funded users experience delayed purchases, and swappers incur failed execution and retry costs.

An ordinary owner can manufacture the shortfall using their own funds. A griefing owner can also front-run a final-purchase batch with an interest withdrawal when the optional protected purchase window is inactive, and can recreate the condition for subsequent batches. Repeated partial principal withdrawals can increase the discrepancy. The protected window blocks new withdrawal-based front-running while active, but does not repair an already deficient position.

The examples create deficits as small as one underlying base unit. Per rounding event, the discrepancy is bounded by approximately one receipt share's underlying value at the withdrawal rate; it is commonly only 1–2 base units. Small size does not reduce the all-or-nothing batch consequence. Insufficient intervening accrual is necessary for the later failure: same-block ordering preserves the gap, and it can persist at flat rates, such as a LayerBank reserve with zero utilization after its index exceeds RAY or a Sovryn market with no borrows. Positive accrual may cover a dust deficit quickly.

This does not grant access to another user's booked shares or establish material principal loss or permanent fund lockup. Some principal may simply have been paid to its owner early, including redemption proceeds above the nominal request. A subsequent full principal withdrawal or schedule deletion instead clamps the request to available share-backed value and pays measured cash, which can be dust below the principal debited by the manager. Disruption is limited to transactions containing the deficient row and ends if that row is excluded, changed, or exited, or sufficient yield or additional shares restore coverage. Re-simulation can identify the deficient row before submission.

Severity Note:
- The coverage gap is typically one or two underlying base units and does not allow one user to redeem another user's shares.
- A batch fails only while it includes the underbacked schedule; excluding that row, exiting it, or covering the gap with yield or another deposit restores the other buyers' purchases.

### 2. Upward stablecoin depegs weaken the Uniswap fallback slippage floor

**Severity:** Medium  
**Contracts:** `src/PurchaseUniswap.sol`

#### Context

`PurchaseUniswap._getAmountOutLowerBound` converts retrieved stablecoin amounts into a WRBTC minimum using cached decimal normalization, the MoC BTC/USD oracle, and `s_amountOutMinimumPercent`. `_purchaseRbtc` applies the greater of this amount and the swapper's `minRbtcOut`. This fallback floor assumes that each whole stablecoin is worth one USD.

```solidity
// File: src/PurchaseUniswap.sol
(uint256 currentPrice, bool isValid,) = s_mocOracle.getPriceInfo();
if (!isValid) revert PurchaseUniswap__OutdatedPrice();
// @auditagent> Stablecoin USD value omitted
minimumRbtcAmount =
    (stablecoinAmountToSpend * i_stablecoinToUsdScale * s_amountOutMinimumPercent) / currentPrice;
```

#### Root Cause

`i_stablecoinToUsdScale` adjusts token decimals but does not incorporate the stablecoin's current USD value. During an upward depeg, `_getAmountOutLowerBound` consequently understates the value-aware minimum. No peg-deviation check stops execution in this condition. When `minRbtcOut` is zero or insufficiently protective, a purchase can execute at the understated floor. Exact stablecoin consumption, intermediate-router balance checks, and measured WRBTC accounting verify asset movement, not the stablecoin's USD valuation. The documented downward-depeg suspension is not part of this vulnerability.

#### Impact

Users whose purchases execute during an upward depeg can receive materially less value than the configured percentage suggests. With 100 stablecoins worth $1.20 each, BTC worth $100,000, and `s_amountOutMinimumPercent` at 95%, the floor permits 0.00095 BTC, worth $95, against $120 of input—a 20.83% shortfall before protocol fees and trading costs. A trader may exploit this headroom through front-running and back-running if liquidity, transaction ordering, and economics permit execution near the floor. This is conditional exposure, not guaranteed profit for every pool. A sufficiently tight `minRbtcOut` protects the individual batch.

Severity Note:
- Buyers receive the pool's actual output whenever it is above the floor, so a shortfall occurs only if the pool is already worse than fair value or a trader moves the price there.
- A caller minimum above the value-aware bound keeps the understated floor from binding on that batch.
- The extra headroom scales with the stablecoin's premium over one dollar; a large shortfall requires a large premium, not any small deviation.

### 3. Signer-bound native payouts permanently strand claims belonging to nonpayable contract wallets

**Severity:** Medium  
**Contracts:** `src/DcaManager.sol`, `src/PurchaseRbtc.sol`, `src/PurchaseUniswap.sol`

#### Context

`DcaManager.withdrawAccumulatedRbtc` and `withdrawAllAccumulatedRbtc` claim only for `msg.sender`. `PurchaseRbtc` pays that same address using an empty-calldata native transfer; `PurchaseUniswap` unwraps WRBTC before making the transfer. Schedule creation does not restrict users to addresses capable of receiving native rBTC.

```solidity
// File: src/PurchaseRbtc.sol
function _withdrawRbtc(address user, uint256 rbtcBalance) internal virtual {
    // @auditagent> Nonpayable wallets cannot claim
    (bool sent,) = user.call{value: rbtcBalance}("");
    if (!sent) revert PurchaseRbtc__rBtcWithdrawalFailed();
    emit PurchaseRbtc__rBtcWithdrawn(user, rbtcBalance);
}
```

#### Root Cause

A contract wallet can execute token approvals and manager calls while rejecting empty-calldata native transfers. Such a wallet can create a funded schedule and receive purchase credits, but every claim sends native rBTC back to the rejecting wallet. The failed transfer reverts the entire transaction, restoring the accumulated balance and, on Dex routes, the wrapped balance. Neither claim entry point permits the wallet to nominate a compatible recipient. An EOA controlling the wallet cannot claim directly because the manager would debit the EOA's balance instead.

#### Impact

All positive rBTC purchase credits belonging to an immutable, nonpayable wallet become permanently inaccessible through the supplied claim paths. Claim-capable fee-collector wallets with the same receiving restriction are also affected. Principal withdrawal or schedule deletion does not resolve this problem because accumulated rBTC remains keyed to the wallet. Other users' claims remain available, and failed bulk claims roll back atomically.

Severity Note:
- Permanent inaccessibility applies only while the credited account keeps rejecting empty-calldata native transfers. A wallet that can later accept plain native rBTC can claim after that change.
- Externally owned accounts and contracts with a payable receive or fallback are not blocked. Stablecoin principal remains withdrawable on the token withdrawal paths.

### 4. `assignHandler` verifies registry affiliation instead of the intended manager's identity

**Severity:** Low  
**Contracts:** `src/OperationsAdmin.sol`, `src/DcaManagerAccessControl.sol`, `src/idle/IdleHandler.sol`, `src/TokenHandler.sol`

#### Context

`OperationsAdmin.assignHandler` permanently assigns custody handlers. Each handler's immutable `i_dcaManager` controls deposits, withdrawals, and purchases through `onlyDcaManager`. Admission is intended to prevent assigning a handler that answers to the wrong manager.

```solidity
// File: src/OperationsAdmin.sol
address dcaManager = IDcaManagerAccessControl(handler).i_dcaManager();
// @auditagent> Registry equality permits impostors
if (address(IDcaManager(dcaManager).i_operationsAdmin()) != address(this)) {
    revert OperationsAdmin__HandlerDcaManagerMismatch(handler, dcaManager);
}
```

#### Root Cause

Admission only checks whether the handler's reported manager returns this registry from `i_operationsAdmin`. This does not establish that it is the intended manager: another manager, or an attacker-controlled contract implementing that getter, can return the same registry. An official idle handler constructed with that address passes the interface, token, and manager checks if the owner mistakenly assigns it. The registry does not maintain a canonical manager address against which to compare `i_dcaManager`.

#### Impact

If the owner assigns a handler whose manager is not the intended manager, that manager alone can call the handler, so the intended manager cannot deposit or withdraw on that pair and the assignment cannot be replaced. Service can be restored by registering a new route and assigning a correctly bound handler. If the admitted manager is attacker-controlled, it can pull stablecoins from any user who has approved that handler and send them to an address it chooses, up to the user's balance and allowance. Funds held by other handlers are not exposed.

Severity Note:
- Theft requires the owner to assign a handler whose immutable manager is attacker-controlled; an unprivileged caller cannot admit the handler.
- Only stablecoins the victim has approved to that admitted handler can be taken, and only up to the available balance and allowance.
- Balances already held by handlers bound to the intended manager are not reachable. The bricked pair cannot be overwritten, but a new route can be registered and assigned a correctly bound handler.

### 5. LayerBank mint rounding can underback schedule principal and revert purchase batches

**Severity:** Low  
**Contracts:** `src/LendingHandler.sol`, `src/DcaManager.sol`, `src/layerbank/LayerBankHandler.sol`

#### Context

`DcaManager.createDcaSchedule` validates `purchaseAmount` against the requested deposit and records that full deposit as the schedule's `tokenBalance`. For LayerBank routes, `LayerBankHandler._protocolDeposit` supplies the stablecoin to the pool, and `LendingHandler._depositToken` credits the user with the measured increase in aToken scaled shares. Purchases through `batchBuyRbtc` or `batchBuyRbtcAcrossHandlers` subsequently reach `_batchRetrieveStablecoin`, which converts each nominal purchase amount to shares using ceiling division and requires the user to hold those shares.

```solidity
// File: src/LendingHandler.sol
uint256 mintedAmount = _receiptSharesBalance() - sharesBefore;
// @auditagent> Mint backing remains unchecked
if (mintedAmount == 0) revert LendingHandler__LendingProtocolDepositFailed();
uint256 previousShares = s_shares[user];
_setUserShares(user, previousShares, previousShares + mintedAmount);
```

#### Root Cause

A successful lending deposit requires only a positive `mintedAmount`; it does not verify that the minted shares cover the nominal principal recorded by the manager. When the LayerBank aToken uses the documented Aave-style half-up scaled mint, its division can round down while `_stablecoinToShares` rounds up, producing a one-share deficit.

At a liquidity index of `1.01e27`, depositing `1e18` base units mints `990099009900990099` scaled shares, but purchasing `1e18` requires `990099009900990100` shares. Similarly, at `1.1e27`, depositing `1e19` units mints `9090909090909090909` shares, while purchasing that amount requires `9090909090909090910` shares. In either case, a user without offsetting shares can successfully create a schedule with `purchaseAmount` equal to its deposit, yet its first purchase reverts with `LendingHandler__InsufficientShares`.

Creation and purchase can encounter the same index within one block, so no market loss is required. The withdrawal path exposes the same valuation mismatch differently: `_withdrawToken` floors the underlying value of the credited shares and clamps a request exceeding that value instead of reverting.

#### Impact

A valid, freshly funded schedule can be unpurchasable at the current exchange rate. Including it in either batch entrypoint reverts the entire transaction atomically, preventing other included schedules from purchasing as well. The swapper can omit the affected schedule. Additional funding or sufficient subsequent interest can resolve the deficit; if the market accrues no further interest, merely retrying does not repair it.

Principal withdrawal remains available, but the request can be adjusted below recorded principal. In the `1.01e27` example, `_withdrawToken` clamps an immediate request for `1e18` to `1e18 - 1` base units. This is a one-base-unit valuation/request discrepancy; actual payout is measured after LayerBank's exact-burn sizing, which may add a base unit, so the clamp alone does not establish an equal realized loss. This is a rounding-boundary liveness issue rather than an unbounded loss, and it does not grant access to another user's shares.

### 6. `_batchRetrieveStablecoin` can reject fully backed batches with repeated buyers

**Severity:** Low  
**Contracts:** `src/LendingHandler.sol`, `src/DcaManager.sol`

#### Context

A batch may contain multiple schedules belonging to the same buyer. `_batchRetrieveStablecoin` converts and debits each row independently, although `s_shares` is maintained per buyer rather than per schedule.

```solidity
// File: src/LendingHandler.sol
for (uint256 i; i < purchaseCount; ++i) {
    // @auditagent> Repeated buyers round separately
    uint256 sharesToRedeem = _stablecoinToShares(purchaseAmounts[i], exchangeRate);
    uint256 userShares = s_shares[users[i]];
    if (sharesToRedeem > userShares) {
        revert LendingHandler__InsufficientShares(users[i], sharesToRedeem, userShares);
    }
    unchecked {
        _setUserShares(users[i], userShares, userShares - sharesToRedeem);
    }
```

#### Root Cause

Summing independently rounded-up row conversions can require more shares than converting that buyer's aggregate purchase once. Full compounding can manufacture a fully backed batch that fails this check. Let `A = 10^18`: two initial deposits at rate `D` mint `2A` shares, which later represent `3A` at rate `1.5D`. The owner tops up the first schedule by `A`, then sets its purchase amount to its full `2A` balance; the second schedule purchases its full `A`. Both schedules are due and their aggregate purchase exactly equals the user's equity. Nevertheless, their separate conversions require 1,333,333,333,333,333,334 and 666,666,666,666,666,667 shares, totaling `2A + 1`. The second row therefore fails even though the aggregate purchase is fully backed.

#### Impact

Valid repeated-buyer row sets can become unexecutable solely because of rounding. If a swapper includes such rows alongside other buyers, the entire transaction reverts and those buyers' purchases are delayed. The example has a one-share shortfall. Excluding or restructuring the affected rows, additional backing, or later yield can resolve the failure; no funds move in the reverted batch.

Severity Note:
- The excess is at most one share per extra schedule of the same buyer. A one-unit reduction in the purchase amount, a further deposit, or later yield lets that buyer purchase again; co-batched buyers are delayed only for the reverted transaction.
