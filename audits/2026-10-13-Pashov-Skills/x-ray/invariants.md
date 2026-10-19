# Invariant Map

> BitChill dca-contracts | 37 guards | 31 inferred | 10 not enforced on-chain

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (!i_operationsAdmin.isSwapper(msg.sender)) revert DcaManager__UnauthorizedSwapper` · `DcaManager.sol:75` · Keeps window activation and batch execution behind the OperationsAdmin swapper allowlist.

#### G-2
`if (block.number < userMutationsAllowedFromBlock) revert DcaManager__UserMutationsLocked` · `DcaManager.sol:487` · Freezes the seven guarded user mutators while a protected window is live, so a refreshed batch is not invalidated.

#### G-3
`if (block.number < userMutationsAllowedFromBlock) revert DcaManager__ProtectedPurchaseWindowStillActive` · `DcaManager.sol:344` · Stops a swapper from extending a live window.

#### G-4
`if (owner == address(0)) revert DcaManager__InexistentSchedule; if (owner != msg.sender) revert DcaManager__NotScheduleOwner` · `DcaManager.sol:592-593` · The single ownership check for every schedule mutator.

#### G-5
`if (scheduleIds.length >= settings.maxSchedulesPerToken) revert DcaManager__MaxSchedulesPerTokenReached` · `DcaManager.sol:154` · Bounds per-user enumeration loops (`_lockedPrincipal`, `getDcaSchedules`).

#### G-6
`if (minPurchaseAmount == 0) revert DcaManager__TokenMinPurchaseAmountNotSet` · `DcaManager.sol:618` · Fails closed for a token whose minimum governance never set.

#### G-7
`if (purchaseAmount < minPurchaseAmount) revert …; if (purchaseAmount > tokenBalance) revert …` · `DcaManager.sol:622-627` · Keeps each written purchase amount between the token minimum and the schedule balance.

#### G-8
`if (purchasePeriod < minPurchasePeriod) revert …; if (purchasePeriod % 1 days != 0) revert …` · `DcaManager.sol:635-638` · Keeps periods on the whole-day midnight grid and above the protocol minimum.

#### G-9
`if (minPurchasePeriod < 1 days) revert …; if (minPurchasePeriod % 1 days != 0) revert …` · `DcaManager.sol:68-69` · Keeps the protocol minimum itself a whole number of UTC days.

#### G-10
`if (i_operationsAdmin.areDepositsPaused(token, routeIndex)) revert DcaManager__DepositsPaused` · `DcaManager.sol:688` · Governance circuit breaker for new inflows on one pair only.

#### G-11
`if (handler == address(0)) revert DcaManager__TokenNotAccepted` · `DcaManager.sol:697` · Refuses any call on an unassigned (token, route) pair.

#### G-12
`if (dcaSchedule.paused) revert DcaManager__SchedulePaused` · `DcaManager.sol:533` · A user pause stops purchases only.

#### G-13
`if (currentDayStart < nextDue) revert DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed` · `DcaManager.sol:548` · Enforces the cadence grid on the purchase path.

#### G-14
`if (purchaseAmount > tokenBalance) revert DcaManager__ScheduleBalanceNotEnoughForPurchase` · `DcaManager.sol:564` · A row cannot spend more than its schedule holds.

#### G-15
`if (scheduleRouteIndex != batch.routeIndex) revert DcaManager__RouteIndexMismatch` · `DcaManager.sol:505` · Ties every row to the handler the batch names.

#### G-16
`if (purchaseCount == 0) revert DcaManager__EmptyBatchPurchaseArrays` · `DcaManager.sol:495` · No empty handler call.

#### G-17
`if (withdrawalAmount > tokenBalance) revert DcaManager__WithdrawalAmountExceedsBalance` · `DcaManager.sol:715` · A withdrawal cannot debit more than the schedule's nominal principal.

#### G-18
`if (accruedInterest == 0) revert …; if (amount > accruedInterest) revert …` · `DcaManager.sol:286-289` · Bounds an interest top-up by the interest the handler reports at that moment.

#### G-19
`if (newTokenBalance / purchaseAmount == tokenBalance / purchaseAmount) revert DcaManager__TopUpDoesNotFundAnotherPurchase` · `DcaManager.sol:297` · Stops interest from being moved over in dust.

#### G-20
`if (index >= scheduleCount || scheduleIds[index] != scheduleId) revert DcaManager__ScheduleIdIndexMismatch` · `DcaManager.sol:603` · Keeps the swap-pop removal on the caller's own id.

#### G-21
`if (!_isLendingRoute(routeIndex)) revert DcaManager__TokenIsNotLent` · `DcaManager.sol:768` · Keeps interest paths off idle routes.

#### G-22
`if (msg.sender != i_dcaManager) revert DcaManagerAccessControl__OnlyDcaManagerCanCall` · `DcaManagerAccessControl.sol:24` · Handlers move funds only for their immutable manager.

#### G-23
`if (depositedAmount != depositAmount) revert TokenHandler__DepositAmountMismatch` · `TokenHandler.sol:73` · Credits only an exact measured pull; refuses fee-on-transfer tokens.

#### G-24
`if (mintedAmount == 0) revert LendingHandler__LendingProtocolDepositFailed` · `LendingHandler.sol:130` · A deposit must mint measured receipt shares.

#### G-25
`if (purchaseAmounts[i] == 0) revert LendingHandler__ZeroShareValue` · `LendingHandler.sol:175` · A clamped row worth nothing reverts the batch instead of buying for free.

#### G-26
`if (sharesAfter >= sharesBefore || sharesBefore - sharesAfter != sharesAmount) revert LendingHandler__ShareConsumptionMismatch` · `LendingHandler.sol:332` · Every redeem must burn exactly the virtual shares debited, so the books never drift from the external position.

#### G-27
`if (stablecoinReceived == 0) revert LendingHandler__ZeroStablecoinReceived` · `LendingHandler.sol:194, 306` · A positive share burn must pay cash.

#### G-28
`if (inputBalanceAfter > inputBalanceBefore || inputBalanceBefore - inputBalanceAfter != totalStablecoinRetrieved) revert PurchaseRbtc__InputAmountNotFullySpent` · `PurchaseRbtc.sol:65-71` · The venue must consume exactly the retrieved input.

#### G-29
`if (totalPurchasedRbtc == 0) revert …; if (totalPurchasedRbtc < minRbtcOut) revert PurchaseRbtc__BelowSwapperMinimum` · `PurchaseRbtc.sol:74-77` · The swapper's minimum binds on measured gross output on every route.

#### G-30
`if (stored <= 1) revert PurchaseRbtc__NoAccumulatedRbtcToWithdraw` · `PurchaseRbtc.sol:199` · Preserves the `claimable + 1` encoding on withdraw.

#### G-31
`if (routerBalanceAfter != routerBalancesBefore[i]) revert PurchaseUniswap__IntermediateBalanceChangedInRouter` · `PurchaseUniswap.sol:251` · No intermediate token may be left in or taken from the shared router.

#### G-32
`if (!isValid) revert PurchaseUniswap__OutdatedPrice` · `PurchaseUniswap.sol:276` · The swap-time floor needs an oracle price the oracle marks valid.

#### G-33
`if (!s_purchasePathAllowed[pathHash]) revert …; if (!…isSwapper(msg.sender)) revert …` · `PurchaseUniswap.sol:151-157` · Only the owner or a swapper activates a path, and only an allowlisted one.

#### G-34
`if (!allowed && keccak256(s_swapPath) == pathHash) revert PurchaseUniswap__CannotRevokeActivePurchasePath` · `PurchaseUniswap.sol:138` · Keeps the active path allowlisted.

#### G-35
`amountOutMinimumPercent > HUNDRED_PERCENT | amountOutMinimumSafetyCheck > HUNDRED_PERCENT | amountOutMinimumPercent < amountOutMinimumSafetyCheck → revert` · `PurchaseUniswap.sol:362-369` · Bounds the Dex floor between the safety check and 100%.

#### G-36
`if (maxFeeRate > MAX_FEE_RATE_CAP) revert …; if (minFeeRate > maxFeeRate) revert …` · `PurchaseFees.sol:211-212` · Caps fees at 5% and orders the two rates.

#### G-37
`registered route · no handler yet · handler address unused · ITokenHandler / ILendingHandler match route class · i_stablecoin == token · handler's manager uses this registry` · `OperationsAdmin.sol:79-105` · Add-only, once-per-pair handler assignment with structural checks.

---

## 2. Inferred Invariants (Single-Contract)

Each block cites one extraction method: Δ-pair, guard lift (with every write site), state-machine edge, temporal predicate, or NatSpec.

---

#### I-1

`Conservation` · On-chain: **Yes**

> For each lending handler, Σ `s_shares[user]` ≤ the handler's external receipt-share balance (`scaledBalanceOf` / iToken `balanceOf`).

**Derivation** — Δ-pair: `LendingHandler.sol:129 ↔ :132` (credit = measured mint), `:304 ↔ :330-332` (debit = exact burn), `:181,183 ↔ :189` (Σ row debits = exact batch burn). NatSpec `LendingHandler.sol:238-240` — "keeps sum of per-user shares <= shares the handler actually holds". All `s_shares` writes (`:132, :181, :304`) go through `_setUserShares:317`.

**If violated** — One user's exit would consume shares that back another user.

---

#### I-2

`Ratio` · On-chain: **Yes**

> Stablecoin→shares rounds up and shares→stablecoin rounds down, so a conversion round trip never creates value for the user.

**Derivation** — guard-lift: `Math.ceilDiv(stablecoinAmount * i_exchangeRateDecimals, exchangeRate)` `LendingHandler.sol:252` vs `sharesAmount * exchangeRate / i_exchangeRateDecimals` `:266`; both are the only converters.

**If violated** — Virtual debits would fall below the protocol burn and break I-1.

---

#### I-3

`Bound` · On-chain: **Yes**

> Every schedule's `purchaseAmount` > 0.

**Derivation** — guard-lift: `_validatePurchaseAmount` `DcaManager.sol:618-623` at both write sites (`:189` update, `:662` create); `setTokenMinPurchaseAmount` refuses 0 (`:391`). NatSpec `DcaManager.sol:295-296`.

**If violated** — `topUpFromInterest:297` and the fee math would divide by zero.

---

#### I-4

`Bound` · On-chain: **No**

> Every schedule's `purchaseAmount` ≥ the token's current minimum.

**Derivation** — guard-lift: `purchaseAmount < minPurchaseAmount` `DcaManager.sol:622` at `:189` and `:662`; but `setTokenMinPurchaseAmount:394` raises the minimum without touching existing schedules. Accepted by design (per spec: "do not rewrite existing schedules").

**If violated** — Existing schedules keep buying below a raised minimum.

---

#### I-5

`Bound` · On-chain: **No**

> Every schedule's `purchaseAmount` ≤ its `tokenBalance`.

**Derivation** — guard-lift: `purchaseAmount > tokenBalance` `DcaManager.sol:626` at the `purchaseAmount` writes (`:189`, `:662`); `tokenBalance` writes `:584` (purchase debit) and `:725` (withdrawal) lower the balance with no such check.

**If violated** — The row reverts at `G-14` until the owner deposits or edits the amount.

---

#### I-6

`Bound` · On-chain: **No**

> Every schedule's `purchasePeriod` ≥ the current `minPurchasePeriod`.

**Derivation** — guard-lift: `DcaManager.sol:635` at `:203` and `:660`; `setMinPurchasePeriod:379` raises the minimum without touching existing schedules.

**If violated** — Existing schedules keep a period below a raised minimum.

---

#### I-7

`Bound` · On-chain: **Yes**

> Every `purchasePeriod` and `minPurchasePeriod` is a positive whole number of UTC days.

**Derivation** — guard-lift: `% 1 days != 0` at `DcaManager.sol:638` (writes `:203`, `:660`) and `:68-69` (writes `:106`, `:379`); every period ≥ minimum ≥ 1 day.

**If violated** — Due dates would leave the midnight grid and the period division at `:556` could hit zero.

---

#### I-8

`Bound` · On-chain: **No**

> Each user holds at most `maxSchedulesPerToken` schedules per token.

**Derivation** — guard-lift: `DcaManager.sol:154` at the only push `:159`; `setMaxSchedulesPerToken:385` can lower the cap (to any `uint16`, including 0) below existing counts.

**If violated** — Loops in `_lockedPrincipal:755` and `getDcaSchedules:419` exceed the intended bound.

---

#### I-9

`StateMachine` · On-chain: **Yes**

> `scheduleNonce` only grows by one, so a schedule id is never reused.

**Derivation** — edge: the only write is `DcaManager.sol:144` (`scheduleNonce + 1`, `toUint64`); no reset path.

**If violated** — A deleted schedule's id could address a new schedule.

---

#### I-10

`Temporal` · On-chain: **Yes**

> `cadenceAnchor` is 0 or a UTC midnight ≤ the current day start, and it never moves backwards.

**Derivation** — temporal: `if (currentDayStart < nextDue) revert` `DcaManager.sol:548`; `newAnchor = cadenceAnchor + periodsElapsed * purchasePeriod` `:557` ≤ `currentDayStart`; the only write is `:585`. NatSpec `:538`.

**If violated** — Later due dates would shift off the grid.

---

#### I-11

`Temporal` · On-chain: **Yes**

> While its period is unchanged, a schedule buys at most once per UTC day.

**Derivation** — temporal: `DcaManager.sol:548` with the anchor set to the current day start or later grid slot at `:557`. Per spec: "While its period is unchanged, a schedule cannot purchase twice in one UTC day."

**If violated** — The swapper could spend a schedule faster than its cadence.

---

#### I-12

`Temporal` · On-chain: **No**

> A schedule buys at most once per UTC day across period edits and delete/re-create.

**Derivation** — temporal: `updatePurchasePeriod` writes `purchasePeriod` at `DcaManager.sol:203` and keeps `cadenceAnchor`; `:556-557` recomputes due slots from the old anchor with the new period. `deleteDcaSchedule:236` clears the anchor and a new schedule starts at 0 (`:546` skips the time check).

**If violated** — The owner can make a schedule due again on the same day.

---

#### I-13

`Temporal` · On-chain: **Yes**

> A protected window cannot be extended while live; each activation sets the unlock block to `block.number + 5`.

**Derivation** — temporal: `if (block.number < userMutationsAllowedFromBlock) revert` `DcaManager.sol:344`; the only write is `:351`.

**If violated** — A swapper could hold user mutations locked without new activations.

---

#### I-14

`StateMachine` · On-chain: **Yes**

> An accumulated-rBTC slot goes 0 → `claimable + 1` and never returns to 0; a withdrawal leaves the sentinel 1.

**Derivation** — edge: `0@PurchaseRbtc.sol:189 → (stored==0?1:stored)+amount@:191`; `≥2@:199 → 1@:204`. Mapping is `private` (`:25`).

**If violated** — A raw write would underpay or overpay one wei of encoding on every decode.

---

#### I-15

`StateMachine` · On-chain: **Yes**

> A (token, route) handler and a handler address are each assigned once and never changed.

**Derivation** — edge: `handler == address(0)@OperationsAdmin.sol:84 → handler@:107`; `s_handlerAssigned false@:87 → true@:108`; no other writer.

**If violated** — Live schedules could be redirected to another handler.

---

#### I-16

`StateMachine` · On-chain: **Yes**

> A route class goes `Unregistered` → `Idle` or `Lending` once and never changes.

**Derivation** — edge: `Unregistered@OperationsAdmin.sol:65 → Idle|Lending@:68`; index 0 set once in the constructor `:51`.

**If violated** — Interest paths could run against an idle handler.

---

#### I-17

`Bound` · On-chain: **Yes**

> `minFeeRate ≤ maxFeeRate ≤ 500` bps on every handler.

**Derivation** — guard-lift: `_validateFeeSettings` `PurchaseFees.sol:211-212` precedes every write (`:47-48` constructor, `:64`, `:68` setter).

**If violated** — Fees above 5% of output.

---

#### I-18

`Bound` · On-chain: **Yes**

> `s_amountOutMinimumSafetyCheck ≤ s_amountOutMinimumPercent ≤ 1e18`.

**Derivation** — guard-lift: `_validateSlippageSettings` `PurchaseUniswap.sol:362-369` precedes every write (`:102-103`, `:166`, `:175`). The safety check has no lower bound, so two owner calls can lower the floor to 0.

**If violated** — The oracle floor could exceed 100% or fall below the safety check.

---

#### I-19

`Bound` · On-chain: **Yes**

> The active Uniswap path is always allowlisted.

**Derivation** — guard-lift: `s_swapPath` is written only at `PurchaseUniswap.sol:302`, reached from the constructor (path allowlisted at `:112`) and `setPurchasePath` (guard `:151`); allowlist writes `:322` are refused for the active path by `:138`.

**If violated** — Purchases could run on a path governance never approved.

---

#### I-20

`Conservation` · On-chain: **Yes**

> Σ buyer rBTC credits + fee credit ≤ measured `totalPurchasedRbtc` per batch.

**Derivation** — Δ-pair: buyer credit `floor(Q × net_i / G)` `PurchaseRbtc.sol:159` and fee `floor(Q × F / G)` `:83`, with `net_i = amount_i − fee_i` and `G = Σ amount_i` (`PurchaseFees.sol:146-148, 173-176`). Per spec: residue under one wei per row and per fee.

**If violated** — Credits would exceed the rBTC the handler holds.

---

#### I-21

`Ratio` · On-chain: **Yes**

> Fee and buyer weights use the clamped row amounts, not the debited nominal amounts.

**Derivation** — guard-lift: `_batchRetrieveStablecoin` writes `purchaseAmounts[i]` at `LendingHandler.sol:174` before `_calculateFeeAndNetWeights` reads them at `PurchaseRbtc.sol:58` (snapshot after the clamp).

**If violated** — A clamped row would be credited for stablecoin it did not supply.

---

#### I-22

`Bound` · On-chain: **Yes**

> The absolute fee never decreases as the purchase amount grows.

**Derivation** — NatSpec `PurchaseFees.sol:181` — "Round the absolute fee once so increasing the purchase amount cannot reduce its fee". The variable formula `:194` equals `maxFeeRate·L/BPS` at `x = L` (continuous with `:188`) and its derivative `minFeeRate + (maxFeeRate − minFeeRate)·L²/x²` is positive.

**If violated** — Users could lower their fee by buying more.

---

## 3. Inferred Invariants (Cross-Contract)

---

#### X-1

On-chain: **Yes**

> On an idle route, Σ `tokenBalance` of its schedules ≤ the IdleHandler's stablecoin balance.

**Caller side** — `DcaManager.sol:174, 658` credit only after the handler pull; `:568-584` and `:725` debit before the handler pays; `topUpFromInterest:282` refuses idle routes.

**Callee side** — `TokenHandler.sol:73` exact pull; `IdleHandler.sol:44-48` spends the supplied amounts; `TokenHandler.sol:82` pays the supplied amount. NatSpec `IdleHandler.sol:11-15`.

**If violated** — One user's withdrawal would spend another user's cash.

---

#### X-2

On-chain: **No**

> On a lending route, a user's Σ `tokenBalance` ≤ the stablecoin value of their `s_shares`.

**Caller side** — `DcaManager.sol:174, 301, 658` credit nominal principal; `:725` debits the requested amount, not what the handler paid (`:718-719`).

**Callee side** — `LendingHandler.sol:144-147` and `:173-179` clamp to share value, which falls when the external exchange rate falls (`SovrynHandler.sol:50` reads `tokenPrice()`); per spec, principal is nominal and a shortfall is not restored.

**If violated** — Schedules keep principal with no shares behind it; their rows revert with `G-25`.

---

#### X-3

On-chain: **No**

> The stablecoin a batch row spends equals the amount `DcaManager` debited from that schedule.

**Caller side** — `DcaManager.sol:568` debits the full `purchaseAmount`; `:511` passes it to the handler.

**Callee side** — `LendingHandler.sol:174` lowers the row to the buyer's remaining share value (R114 design). Idle routes spend the full amount (`IdleHandler.sol:47`).

**If violated** — On a lending route the debited excess has no cash behind it.

---

#### X-4

On-chain: **No**

> An assigned handler is bound to the canonical `DcaManager`.

**Caller side** — `DcaManager.sol:40` pins `i_operationsAdmin` and trusts every handler it resolves.

**Callee side** — `OperationsAdmin.sol:102-104` checks only that the handler's manager points at this registry, not which manager it is. Per spec this is mitigated by deployment checks.

**If violated** — A pair can be disabled, or tokens approved to a wrongly bound handler exposed.

---

#### X-5

On-chain: **No**

> Revoking a swapper removes every effect it set.

**Caller side** — `OperationsAdmin.sol:141` clears `s_swappers`; `DcaManager.sol:75` and `PurchaseUniswap.sol:155` read it on each call.

**Callee side** — `DcaManager.sol:351` (unlock block) and `PurchaseUniswap.sol:302` (active path) keep the values a revoked swapper wrote.

**If violated** — A live window and a chosen path outlast the revocation.

---

#### X-6

On-chain: **Yes**

> A user's whole-route interest is the share value above the sum of their schedules' principal on that route.

**Caller side** — `DcaManager._lockedPrincipal:748-764` sums `tokenBalance` per user, token and route and passes it to the handler.

**Callee side** — `LendingHandler._accruedInterest:278-289` and `withdrawInterest:49-65` pay only the value above that sum.

**If violated** — Interest withdrawals would spend principal.

---

## 4. Economic Invariants

---

#### E-1

On-chain: **Yes**

> No user can withdraw stablecoin backing another user's position.

**Follows from** — `I-1` + `X-1` + `X-6`

**If violated** — Cross-user loss of principal.

---

#### E-2

On-chain: **Yes**

> rBTC paid out never exceeds rBTC the handler measured receiving from its venue.

**Follows from** — `I-14` + `I-20`

**If violated** — The handler would pay later users from earlier users' rBTC.

---

#### E-3

On-chain: **No**

> Every unit of nominal principal on a lending route is backed by shares.

**Follows from** — `X-2` + `X-3`

**If violated** — Schedules show funds that cannot buy or be withdrawn in full.
