# 🔐 Security Review — dca-contracts

---

## Scope

|  |  |
| --- | --- |
| **Mode** | filename |
| **Files reviewed** | `src/BitChillOwnable.sol` · `src/DcaManager.sol` · `src/DcaManagerAccessControl.sol`<br>`src/LendingHandler.sol` · `src/OperationsAdmin.sol` · `src/PurchaseFees.sol`<br>`src/PurchaseMoc.sol` · `src/PurchaseRbtc.sol` · `src/PurchaseUniswap.sol`<br>`src/StablecoinSource.sol` · `src/TokenHandler.sol` · `src/idle/IdleDocHandlerMoc.sol`<br>`src/idle/IdleHandler.sol` · `src/idle/IdleHandlerDex.sol` · `src/layerbank/LayerBankDocHandlerMoc.sol`<br>`src/layerbank/LayerBankHandler.sol` · `src/layerbank/LayerBankHandlerDex.sol` · `src/sovryn/SovrynDocHandlerMoc.sol`<br>`src/sovryn/SovrynHandler.sol` · `src/sovryn/SovrynHandlerDex.sol` · `script/DeployFinal.s.sol`<br>`script/DeployBase.s.sol` · `script/Constants.sol` |
| **Confidence threshold (1-100)** | 75 |
| **Passes** | 3 |
| **Memory** | 0 records before this scan · 30 after · `d5c09c32` |

---

## Findings

[75] **1. Batch `minRbtcOut` does not scale with the input that the batch spends**

`DcaManager._batchBuyRbtc` · Confidence: 75 · seen in 3/3 runs · NEW

**Description**
A user grows a row after the quote with an amount edit or a lending deposit, so `minRbtcOut` permits a lower price for other rows.

**Fix (Option A — validate the batch input)**:

```diff
 struct Batch {
     uint64[] scheduleIds;
     address token;
     uint256 routeIndex;
     uint256 minRbtcOut;
+    uint256 maxStablecoinIn;
 }
```

```diff
         address[] memory buyers = new address[](purchaseCount);
         uint256[] memory purchaseAmounts = new uint256[](purchaseCount);
+        uint256 totalStablecoinIn;
         for (uint256 i; i < purchaseCount; ++i) {
             buyers[i] = buyer;
             purchaseAmounts[i] = schedulePurchaseAmount;
+            totalStablecoinIn += schedulePurchaseAmount;
         }
+        if (totalStablecoinIn > batch.maxStablecoinIn) {
+            revert DcaManager__BatchInputAboveSwapperMaximum(totalStablecoinIn, batch.maxStablecoinIn);
+        }
         IPurchaseRbtc(address(_handler(batch.token, batch.routeIndex)))
             .batchBuyRbtc(buyers, batch.scheduleIds, purchaseAmounts, batch.minRbtcOut);
```

**Fix (Option B — validate the price, not the amount)**:

```diff
-        if (totalPurchasedRbtc < minRbtcOut) {
-            revert PurchaseRbtc__BelowSwapperMinimum(totalPurchasedRbtc, minRbtcOut);
+        // minRbtcOutPerToken: the minimum rBTC wei for each 1e18 units of stablecoin input
+        if (totalPurchasedRbtc * 1e18 < minRbtcOutPerToken * totalStablecoinRetrieved) {
+            revert PurchaseRbtc__BelowSwapperMinimum(totalPurchasedRbtc, minRbtcOutPerToken);
         }
```

---

[75] **2. `DeployFinal` assigns a Sovryn DOC market that holds no free DOC**

`DeployFinal.deployStack` · Confidence: 75 · seen in 1/3 runs · NEW

**Description**
Other Sovryn lenders withdraw the DOC that a user deposits on route 2, so the purchases and the withdrawals of that user revert.

**Fix (Option A — ban the route until the market holds free DOC)**:

```diff
         operationsAdmin.assignHandler(s_cfg.doc, LAYERBANK_INDEX, s_stack.docLayerBank);
-        operationsAdmin.assignHandler(s_cfg.doc, SOVRYN_INDEX, s_stack.docSovryn);
         operationsAdmin.assignHandler(s_cfg.usdrif, IDLE_INDEX, s_stack.usdrifIdle);
```

**Fix (Option B — restrict deposits in the same script)**:

```diff
         operationsAdmin.assignHandler(s_cfg.doc, SOVRYN_INDEX, s_stack.docSovryn);
+        operationsAdmin.setDepositsPaused(s_cfg.doc, SOVRYN_INDEX, true);
```

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [75] | Batch `minRbtcOut` does not scale with the input that the batch spends |
| 2 | [75] | `DeployFinal` assigns a Sovryn DOC market that holds no free DOC |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **A delete and a create let a user buy again that day** — `DcaManager._rbtcPurchaseChecksEffects` · seen in 3/3 runs · NEW — Code smells: The first-purchase branch (`cadenceAnchor == 0`) has no time check; `deleteDcaSchedule` clears the anchor and `createDcaSchedule` leaves the new anchor at zero; `minPurchasePeriod` limits one schedule, not one user; `deleteDcaSchedule` is guarded by the window, so the user acts outside it — A user deletes a schedule and creates a new one, and the new schedule buys on the same day. The user pays the fee each time, and we found no loss for other users.
- **A swapper can open a new protected window with no gap** — `DcaManager.activateProtectedPurchaseWindow` · seen in 3/3 runs · NEW — Code smells: `activateProtectedPurchaseWindow` reverts only when `block.number < s_userMutationsAllowedFromBlock`; block N+5 opens both the user calls and a new activation; the lock costs about 576 calls a day, about 4.5e-4 rBTC; deposits and `createDcaSchedule` stay open, so users can add funds but cannot withdraw them; `revokeSwapper` by the owner is the only stop; `AUDIT_GUIDE.md` and `AGENTS.md` invariant 10 accept this; `revokeSwapper` does not end a window that is already open, so the last window runs up to four more blocks; chained windows also keep users in a lending market that is failing — A swapper can open a new window in the block the last window ends, so users cannot withdraw while the swapper repeats this. The audit guide accepts this risk.
- **An attacker can move the pool between window activation and the quote** — `DcaManager.activateProtectedPurchaseWindow` · seen in 2/3 runs · NEW — Code smells: `activateProtectedPurchaseWindow` emits `DcaManager__ProtectedPurchaseWindowActivated` before the bot quotes; R66 step 2 has the bot quote again after activation, and R51 accepts any quote that clears the estimated floor; `amountOutMinimum = max(minRbtcOut, amountOutLowerBound)` then lets the 97% oracle floor bind; with BTC at $100,000, a 20,000 USDT0 batch moved from a 99.0% fill to a 97.3% fill loses about $340, against about $100 for a sandwich of an unmoved quote; the fix is in the bot: reject a quote after activation that falls below the oracle output minus the normal tolerance — An attacker sees the window open and moves the pool before the bot quotes, so each Dex batch fills near the 97% floor. We did not prove that the trade pays after arbitrage over one to four Rootstock blocks.
- **Later batches in one call pay the price impact of earlier batches** — `DcaManager.batchBuyRbtcAcrossHandlers` · seen in 2/3 runs · NEW — Code smells: `batchBuyRbtcAcrossHandlers` runs the batches in the order that the swapper gives; `DeployFinal` routes USDT0 and USDRIF, idle and LayerBank, through the same USDT0/WRBTC 0.30% pool; each batch must clear only its own `minRbtcOut` and the 97% oracle floor; in a pool of 2,000,000 USDT0 and 20 WRBTC, two 10,000 batches get 0.099502 and 0.098517 WRBTC, against 0.099010 each in one swap — The swapper sets the batch order, so users of a later handler pay the price impact of the earlier batches in the shared pool. We did not prove a profit for any party.
- **A new schedule in the protected window grows a short lending row** — `DcaManager.createDcaSchedule` · seen in 2/3 runs · NEW — Code smells: `createDcaSchedule` has `nonReentrant` and no `whenUserMutationsAllowed`; on a lending route `LendingHandler._depositToken` adds the minted shares to `s_shares[user]`, which `_batchRetrieveStablecoin` reads to size each short row of that user; R66 states that the guarded calls cover every change that can make a prepared row wrong; a fix that guards only `depositToken` leaves this path open; on LayerBank only rounding dust is at stake, because the index never falls — A user creates a lending schedule in the protected window, so a short row of that user spends more than the bot's snapshot shows. We did not prove a loss for another user.
- **`depositToken` stores a balance that it reads before the handler call** — `DcaManager.depositToken` · seen in 3/3 runs · NEW — Code smells: `newTokenBalance` is computed before `_handlerForDeposit(...).depositToken(...)` and stored after it; `batchBuyRbtc` and `batchBuyRbtcAcrossHandlers` have no `nonReentrant`; `_withdrawToken`, `deleteDcaSchedule` and `topUpFromInterest` do not use this order; DOC, USDRIF and USDT0 have no transfer hooks — A purchase that runs inside the deposit call loses its debit, so the schedule keeps stablecoin that the handler already spent. We found no listed token or market that calls a swapper during a deposit.
- **A deposit in the protected window adds shares to a short row** — `DcaManager.depositToken` · seen in 3/3 runs · NEW — Code smells: `depositToken` and `createDcaSchedule` have no `whenUserMutationsAllowed` modifier; `LendingHandler._batchRetrieveStablecoin` funds a short row from all the shares that the buyer holds at the purchase; R66 states that the window stops changes to the funding book; a short row of material size needs a loss in the lending market — A buyer who deposits in the protected window adds shares, so a short lending row spends more than the bot's snapshot shows. We did not find a production state where nominal principal exceeds share value by more than rounding dust.
- **A period edit after a late purchase makes the schedule due again** — `DcaManager.updatePurchasePeriod` · seen in 3/3 runs · NEW — Code smells: `updatePurchasePeriod` keeps `cadenceAnchor`; `_rbtcPurchaseChecksEffects` sets `newAnchor = cadenceAnchor + periodsElapsed * purchasePeriod`, which can be before the current day; `AUDIT_GUIDE.md` states "one extra purchase, not a loop"; a schedule paused until day 127 and cut from 64 days to 32, 16, 8 and 7 buys five times in one UTC day, and a longer period gives about log2(P / 7) + 1 purchases — A schedule owner shortens the period in steps, and the swapper then buys for that schedule several times in one UTC day. We found no loss for another user.
- **`DeployFinal` allowlists a USDRIF path through a pool with zero liquidity** — `DeployFinal._allowUsdrifAltPath` · seen in 1/3 runs · NEW — Code smells: `_mainnetConfig` allowlists USDRIF to USDT (0.05%) to WRBTC (0.30%) on both USDRIF handlers; pool 0x69c4D1fCd58CbDd7f9857AC4F8D56A1Cc6B598FE has `liquidity()` = 0; a swapper can activate the path with `setPurchasePath` and send `minRbtcOut = 0` — `DeployFinal` allowlists a USDRIF path through a pool with zero liquidity, so a swapper who supplies that liquidity fills batches at the oracle floor. Only a swapper can activate the path, and the 97% oracle floor still limits the loss.
- **A LayerBank reserve with no free cash blocks each exit** — `LayerBankHandler._protocolRedeem` · seen in 3/3 runs · NEW — Code smells: `i_pool.withdraw(address(i_stablecoin), amountOut, address(this))` reverts when the aToken lacks cash, and the handler has no partial exit; free cash against supply is DOC 4,924 of 55,074, USDRIF 26,008 of 582,015 and USDT0 78,793 of 389,141; a bad handler batch reverts the whole `batchBuyRbtcAcrossHandlers` call; a borrower can take the free cash after a window activation, so the lending batch and every other batch in the bundle revert — A borrower can take the 4,924 DOC of free liquidity in the LayerBank reserve, and then each LayerBank DOC withdrawal and purchase reverts. The guide accepts external illiquidity, and we did not measure the cost of the borrow.
- **A LayerBank switch to round-up burns makes many redeems revert** — `LayerBankHandler._underlyingForExactScaledBurn` · seen in 2/3 runs · NEW — Code smells: The `+1` branch (`if (_rayDiv(amount, index) < sharesAmount) ++amount;`) is exact only for a half-up burn, and the handlers are immutable; at index 1.1e27 and `sharesAmount` 7 the code withdraws 8, a round-up burn of 8 burns 8 shares, and `_measuredProtocolRedeem` reverts `ShareConsumptionMismatch`; the branch fires for about 45% of share amounts at index 1.1 RAY; `withdrawToken`, `deleteDcaSchedule`, both interest withdrawals and batch purchases all use it; `src/layerbank/README.md` documents and accepts this risk, the call fails closed and no funds are lost; we did not check the upgrade plans of LayerBank; simulations put the revert share at 50% just above index 1.0 RAY, 47.6% at 1.05, 39.8% at 1.2 and 25% at 1.5; under a round-up burn the floor amount alone is exact, so a round-up adapter needs no `+1` — If LayerBank burns with round-up, the `+1` amount burns one share too many, so up to half of withdrawals and purchases revert. A user can retry with another amount or after the index changes.
- **A schedule with no backing shares reverts each batch that holds it** — `LendingHandler._batchRetrieveStablecoin` · seen in 2/3 runs · NEW — Code smells: `DcaManager` debits the full `purchaseAmount` of each row, but the handler clamps each row against the whole share position of the user; with two rows of 100 and a 50% rate loss, the first row takes all the shares; the second row then reverts `LendingHandler__ZeroShareValue`, and the whole batch reverts; `DcaManager` still shows the second schedule as funded and due, and a withdrawal from it pays 0; a user who withdraws one schedule after a loss also redeems the shares of the other schedules (see `LendingHandler._withdrawToken`) — After a lending loss, one row of a user takes all their shares, so the user's second row reverts each batch that holds it. The swapper can leave that row out, and we found no user action that causes the loss.
- **A clamped lending row can grow after the bot's snapshot** — `LendingHandler._batchRetrieveStablecoin` · seen in 3/3 runs · NEW — Code smells: A row's funded weight is min(`purchaseAmount`, value of the buyer's shares); `depositToken` and `createDcaSchedule` stay open in the protected window and add shares; nominal rows cannot change in the window, because `updatePurchaseAmount` is guarded; `minRbtcOut` stays absolute; without a lending loss the ledger stays within rounding dust of the share value, so a user cannot set up a large short row — A buyer with a short row deposits in the protected window, and the row then spends its full amount. We found this state only after a lending loss.
- **`_depositToken` does not check that the market takes the full deposit** — `LendingHandler._depositToken` · seen in 3/3 runs · NEW — Code smells: After `_protocolDeposit(depositAmount)` the function checks only `mintedAmount == 0`; the redeem path (`_measuredProtocolRedeem`) and the purchase path (`PurchaseRbtc__InputAmountNotFullySpent`) each require an exact amount; no function moves stablecoin that stays in a lending handler — The handler checks that a deposit mints more than zero shares, but it does not check that the market takes the full amount. We found no in-scope market that takes a part.
- **A Sovryn burn that clears a small remainder fails the exact-burn check** — `LendingHandler._measuredProtocolRedeem` · seen in 3/3 runs · NEW — Code smells: `_measuredProtocolRedeem` reverts unless the handler's iToken `balanceOf` falls by exactly `sharesAmount`; Sovryn `_burn` also burns a remainder of ten units or fewer, and a fork test confirms the rule on the live iDOC token; `test/mocks/MockIToken.sol` burns exactly `burnAmount`; a lone last user who exits fully leaves no remainder, so the trigger needs a second holder with 1 to 10 shares; an attacker gets that state with a transfer of 1 to 10 wei of iToken, or with a `withdrawToken` that leaves 3 to 5 shares behind a balance of 5 wei; the last user then must leave about 11 wei behind, or someone must send 6 or more wei of iToken to the handler; a principal exit by the last holder that leaves 10 or fewer interest shares also triggers it — Sovryn `_burn` also burns a remainder of ten units or fewer, so `_measuredProtocolRedeem` reverts the last full exit from the handler. An attacker can create that remainder with a small iToken transfer or a partial withdrawal.
- **A withdrawal after a lending loss takes the shares of other schedules** — `LendingHandler._withdrawToken` · seen in 1/3 runs · NEW — Code smells: `_withdrawToken` clamps the request to the value of all `s_shares[user]` on the route, but `DcaManager` debits only the named schedule; with schedule A at 1000e18 and schedule B at 25e18 on Sovryn, a 3% `tokenPrice` fall makes `withdrawToken(A, 1000e18)` redeem every share; B keeps a `tokenBalance` of 25e18 with no shares, so its next row reverts `LendingHandler__ZeroShareValue`; the loss must be at least B / (A + B) — After a lending loss, a user who withdraws one schedule also redeems the shares behind the other schedules, so their rows revert each batch. We did not prove a loss of that size on a live Sovryn market.
- **`_withdrawToken` sends a transfer of zero tokens when shares have no value** — `LendingHandler._withdrawToken` · seen in 3/3 runs · NEW — Code smells: When share value is 0, after a loss or after a clamped purchase takes all the shares, the amount is clamped to 0, `_redeemShares` returns 0 without a burn, and `super._withdrawToken(user, 0)` still calls `safeTransfer`; `DcaManager._withdrawToken` still lowers the schedule balance by the full request; `withdrawInterest` guards the same case with `if (stablecoinReceived > 0)`, and the batch path reverts `LendingHandler__ZeroShareValue`; DOC, USDRIF and USDT0 accept transfers of zero — The handler sends a transfer of zero tokens when the user's shares have no value. A token that rejects zero transfers makes the withdrawal and the deletion fail.
- **An interest redeem that pays zero reverts `withdrawTokenAndInterest`** — `LendingHandler.withdrawInterest` · seen in 3/3 runs · NEW — Code smells: `_redeemShares` reverts with `LendingHandler__ZeroStablecoinReceived` when a share burn of more than zero pays zero stablecoin; `withdrawTokenAndInterest` runs the principal redeem and then the interest redeem in one transaction, and `withdrawAllAccumulatedInterest` runs one loop for all schedules; `AUDIT_GUIDE.md` states that Sovryn charges a 0.1% exit fee; the Sovryn exit fee charges from about block 9,219,745 (`test/mainnet-debug/sovryn-exit-fee/README.md`); the interest left after a principal withdrawal is often 1 to 2 wei — If Sovryn rounds its exit fee up on a one-wei burn, the interest redeem pays zero and `withdrawTokenAndInterest` reverts for that user. We did not read the Sovryn fee code.
- **Money on Chain limits the gas price of each DOC purchase** — `PurchaseMoc._purchaseRbtc` · seen in 2/3 runs · NEW — Code smells: Every DOC purchase calls `i_mocProxy.redeemFreeDoc`; the repo probe notes (`test/mainnet-debug/moc-redeem-free-doc/README.md`) say MoC rejects a transaction above its `maxGasPrice`; a bundle from `batchBuyRbtcAcrossHandlers` with one MoC batch carries the same cap for its Dex batches; on 2026-09-07 `maxGasPrice()` was 0.0303 gwei against a network price of 0.026 gwei, about 16% of headroom; `batchBuyRbtcAcrossHandlers` is atomic, so one DOC batch above the cap reverts every batch in the call — Money on Chain reverts `redeemFreeDoc` above its `maxGasPrice` of 0.0303 gwei, so a gas price rise of about 16% stops every DOC purchase. One DOC batch above the cap reverts every batch in the same call.
- **Money on Chain redeems at most its free DOC in one call** — `PurchaseMoc._purchaseRbtc` · seen in 2/3 runs · NEW — Code smells: MoC `redeemFreeDoc` redeems at most the free DOC and reverts in protection mode; `PurchaseRbtc__InputAmountNotFullySpent` then reverts the whole batch, and on lending DOC routes the redeem from the market rolls back with it; `test_partialFreeDocRedemptionRevertsAndRollsBack` pins this revert; the MoC source is not in the repo — A DOC batch above the free DOC of Money on Chain reverts in full, so DOC purchases stop until the bot splits the batch. We did not measure the live free DOC.
- **The MoC route has no price floor of its own** — `PurchaseMoc._purchaseRbtc` · seen in 3/3 runs · NEW — Code smells: `_purchaseRbtc` ignores its `minRbtcOut` argument and applies no oracle bound; `PurchaseRbtc.batchBuyRbtc` checks only `totalPurchasedRbtc < minRbtcOut`, and the guide allows a zero caller minimum; the Dex route has a 97% oracle floor — The MoC route accepts any rBTC output above the swapper minimum. We did not verify whether a third party can lower the `redeemFreeDoc` output.
- **One large row moves the pool price for every row** — `PurchaseRbtc.batchBuyRbtc` · seen in 3/3 runs · NEW — Code smells: The purchase gives every row of a batch one average price; no check limits the size of one row relative to the batch; the 97% oracle floor is the only bound in the contract on price impact; in a pool of 1,000,000 USDT0 at $60,000, one 20,000 row lowers the fill of 1,000 of small rows from 99.60% to 97.65% of the oracle price, and only a back-run arbitrageur profits — A schedule owner sets a row that moves the pool price, so other buyers in the batch get up to 3% less rBTC. We did not verify how the bot splits a batch.
- **The Uniswap floor accepts an oracle price of any age** — `PurchaseUniswap._getAmountOutLowerBound` · seen in 3/3 runs · NEW — Code smells: `(uint256 currentPrice, bool isValid,) = s_mocOracle.getPriceInfo();` discards `lastPubBlock`; the floor is `amount * scale * percent / currentPrice`; a 5% fall after the last publication puts the 97% floor 7.85% below the market output; a price of 0 with `isValid` true causes a division-by-zero panic — The handler accepts each price that the oracle marks valid, and it ignores the publication block. We did not read the valid period of the live oracle.
- **The Uniswap floor prices each stablecoin at one dollar** — `PurchaseUniswap._getAmountOutLowerBound` · seen in 2/3 runs · NEW — Code smells: The floor is `amount * i_stablecoinToUsdScale * s_amountOutMinimumPercent / currentPrice`; on the USDRIF to USDT0 to WRBTC path a 3% USDRIF discount gives at best 0.9666 of the oracle output, below the 0.97 floor; the owner can lower the floor in one call only to the 0.95e18 safety check; a stablecoin above one dollar gives a swapper about 2% more room under the floor; the NatSpec states the peg assumption — A 3% USDRIF depeg puts every USDRIF purchase below the floor, so each purchase reverts until the owner lowers the floor. Withdrawals still work.
- **The handler does not compare the measured WRBTC with the oracle floor** — `PurchaseUniswap._purchaseRbtc` · seen in 3/3 runs · NEW — Code smells: `amountOutMinimum = max(minRbtcOut, amountOutLowerBound)` goes to the router and is not used again; after the swap the only check on measured output is `if (totalPurchasedRbtc < minRbtcOut)`; with `minRbtcOut = 0` the oracle floor rests on the router's own figure — The router alone enforces the oracle floor on its own output figure, and the handler never compares the measured WRBTC with that floor. We found no input that makes the two figures differ.
- **A swapper can activate a path just before the owner revokes it** — `PurchaseUniswap.setPurchasePath` · seen in 2/3 runs · NEW — Code smells: `setPurchasePathAllowed(..., false)` reverts `PurchaseUniswap__CannotRevokeActivePurchasePath` when the path is active; any allowlisted swapper can call `setPurchasePath` with any allowlisted path; two separate owner calls leave a gap in which the swapper activates the path again; `CUTOVER_RUNBOOK.md` covers this under "Compromised swapper": send both calls in one Safe multisend, or call `revokeSwapper` first — A swapper activates a path before the revoke of the owner lands, so the revoke reverts. We found no loss beyond the delay.
- **A swapper can change the active path after the bot quotes** — `PurchaseUniswap.setPurchasePath` · seen in 1/3 runs · NEW — Code smells: `_purchaseRbtc` reads `s_swapPath` when it runs, and `IDcaManager.Batch` has no path field; any allowlisted swapper or the owner can call `setPurchasePath` at any time, also inside a protected window; `revokeSwapper` leaves the active path that the revoked swapper chose; the allowlist holds the USDRIF path through the pool with zero liquidity from `DeployFinal`; with a quote-derived `minRbtcOut` a worse path makes the batch revert; the harm needs a second swapper or a compromised owner, and the launch setup has one swapper — A swapper sets another allowlisted path after the bot quotes, and the batch runs on that path. The `minRbtcOut` of the bot still limits the loss.
- **A Sovryn pool with no free DOC blocks each exit** — `SovrynHandler._protocolRedeem` · seen in 2/3 runs · NEW — Code smells: Sovryn `_burnToken` requires `loanAmountPaid <= _underlyingBalance()` (error "37"), and the handler has no partial exit; `withdrawToken`, `deleteDcaSchedule`, `withdrawInterest` and each Sovryn batch redeem through `burn`; a pass 1 read of the live iDOC market showed 99.99% of its DOC lent out; the `DeployFinal.deployStack` finding reports the same market state — A borrower who takes the free DOC of the Sovryn pool makes every exit and every purchase on the Sovryn route revert. We did not measure the cost of the borrow.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
