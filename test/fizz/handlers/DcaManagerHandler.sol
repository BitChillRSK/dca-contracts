// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";

/// @notice Handles the interaction with DcaManager
/// @dev Clamped handlers act for the current `actor` on schedules the harness tracks, and as the current
///      `swapper` for window and batch calls. Unclamped handlers forward raw arguments.
///      Every unclamped handler goes through one internal funnel (`_createOp`, `_withdrawTokenOp`, ...)
///      that makes a single-shot pranked call inside try/catch (plan H1). On success it updates the
///      tracking list, takes `snapshotAfter()`, calls the ghost hooks and runs the op's specific
///      properties plus `_postCommon`. On failure it runs `_onRevert`. The adversarial and round-trip
///      handlers reuse the same funnels, so their calls are checked the same way.
abstract contract DcaManagerHandler is Properties {
    uint256 internal constant MAX_DEPOSIT = 100_000 ether;
    uint256 internal constant MAX_PERIOD_DAYS = 60;
    uint256 internal constant MAX_BATCH_ROWS = 16;
    /// @dev Raw (token, route) pair lists longer than this are not sent: they only cost gas.
    uint256 internal constant MAX_RAW_PAIRS = 16;
    /// @dev Row cap for the clamped across-handlers batch (gas: ~12M at 54 fresh rows).
    uint256 internal constant MAX_ACROSS_ROWS = 32;

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function dcaManager_activateProtectedPurchaseWindow_clamped(uint256 swapperSeed) public {
        swapper = swappers[swapperSeed % swappers.length];
        dcaManager_activateProtectedPurchaseWindow();
    }

    /// @dev One handler's batch built from tracked schedules that are due, unpaused and funded.
    ///      `rowMask` picks a subset; `minOutSeed` is clamped to the venue's expected gross output.
    function dcaManager_batchBuyRbtc_clamped(uint256 routeSeed, uint256 rowMask, uint256 minOutSeed) public {
        Route memory r = _route(routeSeed);
        (uint64[] memory ids,) = _eligibleRows(r, rowMask);
        if (ids.length == 0) return;
        CleanPlan memory quote = _simLendingBatch(r, ids);
        uint256 minOut = clampLte(minOutSeed, _expectedGrossRbtc(r, quote.cashIn));
        dcaManager_batchBuyRbtc(
            IDcaManager.Batch({
                scheduleIds: ids,
                token: r.token,
                routeIndex: r.routeIndex,
                minRbtcOut: minOut,
                quotedStablecoinIn: quote.cashIn
            })
        );
    }

    /// @dev Same as above with no swapper minimum: only the venue (and the Dex oracle floor) bounds output.
    function dcaManager_batchBuyRbtc_zeroMinOut(uint256 routeSeed, uint256 rowMask) public {
        Route memory r = _route(routeSeed);
        (uint64[] memory ids,) = _eligibleRows(r, rowMask);
        if (ids.length == 0) return;
        dcaManager_batchBuyRbtc(
            IDcaManager.Batch({
                scheduleIds: ids, token: r.token, routeIndex: r.routeIndex, minRbtcOut: 0, quotedStablecoinIn: 0
            })
        );
    }

    /// @dev Every tracked schedule on the route, eligible or not, so cadence / pause / balance guards
    ///      and lending clamps are reached inside a batch that also holds valid rows.
    function dcaManager_batchBuyRbtc_allRows(uint256 routeSeed) public {
        Route memory r = _route(routeSeed);
        uint64[] memory ids = _routeRows(r);
        if (ids.length == 0) return;
        dcaManager_batchBuyRbtc(
            IDcaManager.Batch({
                scheduleIds: ids, token: r.token, routeIndex: r.routeIndex, minRbtcOut: 0, quotedStablecoinIn: 0
            })
        );
    }

    /// @dev At most MAX_ACROSS_ROWS rows in total, so the checked call stays inside Medusa's 12.5M gas limit.
    function dcaManager_batchBuyRbtcAcrossHandlers_clamped(uint256 routeMask, uint256 rowMask) public {
        IDcaManager.Batch[] memory tmp = new IDcaManager.Batch[](routes.length);
        uint256 count;
        uint256 total;
        for (uint256 i; i < routes.length; i++) {
            if ((routeMask >> i) & 1 == 0) continue;
            (uint64[] memory ids,) = _eligibleRows(routes[i], rowMask);
            if (ids.length + total > MAX_ACROSS_ROWS) ids = _truncate(ids, MAX_ACROSS_ROWS - total);
            if (ids.length == 0) continue;
            total += ids.length;
            tmp[count++] = IDcaManager.Batch({
                scheduleIds: ids,
                token: routes[i].token,
                routeIndex: routes[i].routeIndex,
                minRbtcOut: 0,
                quotedStablecoinIn: 0
            });
        }
        if (count == 0) return;
        IDcaManager.Batch[] memory batches = new IDcaManager.Batch[](count);
        for (uint256 i; i < count; i++) {
            batches[i] = tmp[i];
        }
        dcaManager_batchBuyRbtcAcrossHandlers(batches);
    }

    function dcaManager_createDcaSchedule_clamped(
        uint256 routeSeed,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 periodDays
    ) public {
        if (trackedSchedules.length >= MAX_TRACKED) return;
        Route memory r = _route(routeSeed);
        if (operationsAdmin.areDepositsPaused(r.token, r.routeIndex)) return;
        uint256 minPurchase = dcaManager.getTokenMinPurchaseAmount(r.token);
        uint256 balance = MockStablecoin(r.token).balanceOf(actor);
        uint256 maxDeposit = balance < MAX_DEPOSIT ? balance : MAX_DEPOSIT;
        if (maxDeposit < minPurchase) return;
        depositAmount = clampBetween(depositAmount, minPurchase, maxDeposit);
        purchaseAmount = clampBetween(purchaseAmount, minPurchase, depositAmount);
        uint256 purchasePeriod = clampBetween(periodDays, _minPeriodDays(), MAX_PERIOD_DAYS) * 1 days;
        dcaManager_createDcaSchedule(r.token, depositAmount, purchaseAmount, purchasePeriod, r.routeIndex);
    }

    function dcaManager_deleteDcaSchedule_clamped(uint256 scheduleSeed) public {
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        dcaManager_deleteDcaSchedule(s.token, s.scheduleId, _scheduleIdIndex(s));
    }

    function dcaManager_depositToken_clamped(uint256 scheduleSeed, uint256 depositAmount) public {
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        uint256 balance = MockStablecoin(s.token).balanceOf(actor);
        if (balance == 0) return;
        depositAmount = clampBetween(depositAmount, 1, balance < MAX_DEPOSIT ? balance : MAX_DEPOSIT);
        dcaManager_depositToken(s.token, s.scheduleId, depositAmount);
    }

    /// @dev Near-zero deposits: share mints round toward zero on the lending routes.
    function dcaManager_depositToken_dust(uint256 scheduleSeed, uint256 depositAmount) public {
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        depositAmount = clampBetween(depositAmount, 1, 1e6);
        dcaManager_depositToken(s.token, s.scheduleId, depositAmount);
    }

    function dcaManager_setSchedulePaused_clamped(uint256 scheduleSeed, bool paused) public {
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        dcaManager_setSchedulePaused(s.token, s.scheduleId, paused);
    }

    /// @dev Bounded by the interest the manager quotes; the floor is the credit that funds one more purchase.
    ///      Every amount sent is in (0, quote], so SP-18 checks the refusal.
    function dcaManager_topUpFromInterest_clamped(uint256 scheduleSeed, uint256 amount) public {
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        if (!_routeOf(s.token, s.routeIndex).lending) return;
        uint256 accrued = dcaManager.getAccruedInterest(actor, s.token, s.routeIndex);
        if (accrued == 0) return;
        IDcaManager.DcaSchedule memory sched = dcaManager.getDcaSchedule(s.token, s.scheduleId);
        uint256 needed = sched.purchaseAmount - (sched.tokenBalance % sched.purchaseAmount);
        amount = clampBetween(amount, needed < accrued ? needed : accrued, accrued);
        (bool ok, bytes memory err) = _topUpOp(actor, s.token, s.scheduleId, amount);
        if (!ok) property_topUpQuoteSafe(err);
    }

    function dcaManager_updatePurchaseAmount_clamped(uint256 scheduleSeed, uint256 newPurchaseAmount) public {
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        IDcaManager.DcaSchedule memory sched = dcaManager.getDcaSchedule(s.token, s.scheduleId);
        uint256 minPurchase = dcaManager.getTokenMinPurchaseAmount(s.token);
        if (sched.tokenBalance < minPurchase) return;
        newPurchaseAmount = clampBetween(newPurchaseAmount, minPurchase, sched.tokenBalance);
        dcaManager_updatePurchaseAmount(s.token, s.scheduleId, newPurchaseAmount);
    }

    function dcaManager_updatePurchasePeriod_clamped(uint256 scheduleSeed, uint256 periodDays) public {
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        uint256 newPurchasePeriod = clampBetween(periodDays, _minPeriodDays(), MAX_PERIOD_DAYS) * 1 days;
        dcaManager_updatePurchasePeriod(s.token, s.scheduleId, newPurchasePeriod);
    }

    function dcaManager_withdrawAllAccumulatedInterest_clamped(uint256 routeMask) public {
        (address[] memory tokens, uint256[] memory routeIndexes) = _routePairs(routeMask);
        dcaManager_withdrawAllAccumulatedInterest(tokens, routeIndexes);
    }

    function dcaManager_withdrawAllAccumulatedRbtc_clamped(uint256 routeMask) public {
        (address[] memory tokens, uint256[] memory routeIndexes) = _routePairs(routeMask);
        dcaManager_withdrawAllAccumulatedRbtc(tokens, routeIndexes);
    }

    /// @dev The fee collector claims through the same manager entry point as buyers. The collector is
    ///      read from the chosen handler, so a rotated collector (possibly an actor) is exercised.
    function dcaManager_withdrawAllAccumulatedRbtc_asCollector(uint256 routeSeed, uint256 routeMask) public {
        address collector = IPurchaseFees(_route(routeSeed).handler).getFeeCollector();
        (address[] memory tokens, uint256[] memory routeIndexes) = _routePairs(routeMask);
        _rbtcAllOp(collector, tokens, routeIndexes);
    }

    function dcaManager_withdrawToken_clamped(uint256 scheduleSeed, uint256 withdrawalAmount) public {
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        IDcaManager.DcaSchedule memory sched = dcaManager.getDcaSchedule(s.token, s.scheduleId);
        if (sched.tokenBalance == 0) return;
        withdrawalAmount = clampBetween(withdrawalAmount, 1, sched.tokenBalance);
        dcaManager_withdrawToken(s.token, s.scheduleId, withdrawalAmount);
    }

    /// @dev Full-amount variant through the `type(uint256).max` sentinel.
    function dcaManager_withdrawToken_full(uint256 scheduleSeed) public {
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        dcaManager_withdrawToken(s.token, s.scheduleId, type(uint256).max);
    }

    function dcaManager_withdrawTokenAndInterest_clamped(uint256 scheduleSeed, uint256 withdrawalAmount) public {
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        if (!_routeOf(s.token, s.routeIndex).lending) return;
        IDcaManager.DcaSchedule memory sched = dcaManager.getDcaSchedule(s.token, s.scheduleId);
        if (sched.tokenBalance == 0) return;
        withdrawalAmount = clampBetween(withdrawalAmount, 1, sched.tokenBalance);
        dcaManager_withdrawTokenAndInterest(s.token, s.scheduleId, withdrawalAmount);
    }

    function dcaManager_secondary(uint8 selector, uint256 arg0, uint256 arg1) public {
        selector = uint8(selector % 3);
        OpCtx memory ctx = _newCtx(selector == 0 ? OP_SET_MAX_SCHEDULES : OP_ADMIN, admin);
        snapshotBefore();
        if (selector == 0) {
            // Includes 0 and values below live counts: the cap is not retroactive (x-ray I-8).
            _dcaManager_setMaxSchedulesPerToken(clampLte(arg0, 2 * MAX_SCHEDULES_PER_TOKEN));
        } else if (selector == 1) {
            _dcaManager_setMinPurchasePeriod(clampBetween(arg0, 1, 14) * 1 days);
        } else {
            address token = arg1 % 2 == 0 ? address(doc) : address(usdrif);
            _dcaManager_setTokenMinPurchaseAmount(token, clampBetween(arg0, 1, 100 ether));
        }
        snapshotAfter();
        if (selector == 0) property_createRespectsCap(ctx);
        _postCommon(ctx);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function dcaManager_activateProtectedPurchaseWindow() public {
        _activateOp(swapper);
    }

    function dcaManager_batchBuyRbtc(IDcaManager.Batch memory batch) public {
        if (batch.scheduleIds.length > MAX_CTX_ROWS) return;
        IDcaManager.Batch[] memory batches = new IDcaManager.Batch[](1);
        batches[0] = batch;
        _batchOp(OP_BATCH, swapper, batches);
    }

    function dcaManager_batchBuyRbtcAcrossHandlers(IDcaManager.Batch[] memory batches) public {
        if (batches.length > MAX_CTX_BATCHES) return;
        for (uint256 i; i < batches.length; i++) {
            if (batches[i].scheduleIds.length > MAX_CTX_ROWS) return;
        }
        _batchOp(OP_ACROSS, swapper, batches);
    }

    function dcaManager_createDcaSchedule(
        address token,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 routeIndex
    ) public {
        if (trackedSchedules.length >= MAX_TRACKED) return;
        _createOp(actor, token, depositAmount, purchaseAmount, purchasePeriod, routeIndex);
    }

    function dcaManager_deleteDcaSchedule(address token, uint64 scheduleId, uint256 scheduleIdIndex) public {
        _deleteOp(actor, token, scheduleId, scheduleIdIndex);
    }

    function dcaManager_depositToken(address token, uint64 scheduleId, uint256 depositAmount) public {
        _depositOp(actor, token, scheduleId, depositAmount);
    }

    function dcaManager_setSchedulePaused(address token, uint64 scheduleId, bool paused) public {
        OpCtx memory ctx = _schedCtx(OP_PAUSE, actor, token, scheduleId);
        ctx.flag = paused;
        snapshotBefore();
        vm.prank(ctx.caller);
        try dcaManager.setSchedulePaused(token, scheduleId, paused) {
            _afterEdit(ctx);
        } catch (bytes memory err) {
            _onRevert(ctx, err);
        }
    }

    function dcaManager_topUpFromInterest(address token, uint64 scheduleId, uint256 amount) public {
        _topUpOp(actor, token, scheduleId, amount);
    }

    function dcaManager_updatePurchaseAmount(address token, uint64 scheduleId, uint256 newPurchaseAmount) public {
        OpCtx memory ctx = _schedCtx(OP_UPDATE_AMOUNT, actor, token, scheduleId);
        ctx.amount = newPurchaseAmount;
        snapshotBefore();
        vm.prank(ctx.caller);
        try dcaManager.updatePurchaseAmount(token, scheduleId, newPurchaseAmount) {
            _afterEdit(ctx);
        } catch (bytes memory err) {
            _onRevert(ctx, err);
        }
    }

    function dcaManager_updatePurchasePeriod(address token, uint64 scheduleId, uint256 newPurchasePeriod) public {
        OpCtx memory ctx = _schedCtx(OP_UPDATE_PERIOD, actor, token, scheduleId);
        ctx.amount = newPurchasePeriod;
        snapshotBefore();
        vm.prank(ctx.caller);
        try dcaManager.updatePurchasePeriod(token, scheduleId, newPurchasePeriod) {
            _ghostPeriodEdit(token, scheduleId);
            _afterEdit(ctx);
        } catch (bytes memory err) {
            _onRevert(ctx, err);
        }
    }

    function dcaManager_withdrawAllAccumulatedInterest(address[] memory tokens, uint256[] memory routeIndexes) public {
        if (tokens.length > MAX_RAW_PAIRS || routeIndexes.length > MAX_RAW_PAIRS) return;
        _interestAllOp(actor, tokens, routeIndexes);
    }

    function dcaManager_withdrawAllAccumulatedRbtc(address[] memory tokens, uint256[] memory routeIndexes) public {
        if (tokens.length > MAX_RAW_PAIRS || routeIndexes.length > MAX_RAW_PAIRS) return;
        _rbtcAllOp(actor, tokens, routeIndexes);
    }

    function dcaManager_withdrawToken(address token, uint64 scheduleId, uint256 withdrawalAmount) public {
        _withdrawTokenOp(actor, token, scheduleId, withdrawalAmount);
    }

    function dcaManager_withdrawTokenAndInterest(address token, uint64 scheduleId, uint256 withdrawalAmount) public {
        _withdrawTokenAndInterestOp(actor, token, scheduleId, withdrawalAmount);
    }

    function _dcaManager_setMaxSchedulesPerToken(uint256 maxSchedulesPerToken) internal asAdmin {
        dcaManager.setMaxSchedulesPerToken(maxSchedulesPerToken);
    }

    function _dcaManager_setMinPurchasePeriod(uint256 minPurchasePeriod) internal asAdmin {
        dcaManager.setMinPurchasePeriod(minPurchasePeriod);
    }

    function _dcaManager_setTokenMinPurchaseAmount(address token, uint256 minPurchaseAmount) internal asAdmin {
        dcaManager.setTokenMinPurchaseAmount(token, minPurchaseAmount);
    }

    // ――――――――――――――――――――――― Funnels (H1) ―――――――――――――――――――――――

    function _activateOp(address caller) internal returns (bool ok, bytes memory err) {
        OpCtx memory ctx = _newCtx(OP_ACTIVATE, caller);
        snapshotBefore();
        vm.prank(caller);
        try dcaManager.activateProtectedPurchaseWindow() {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        if (!ok) {
            _onRevert(ctx, err);
            return (ok, err);
        }
        snapshotAfter();
        _ghostWindowActivated();
        property_activationSemantics(ctx, true, "");
        property_swapperAllowlistTransitions(ctx);
        _postCommon(ctx);
    }

    function _createOp(
        address caller,
        address token,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 routeIndex
    ) internal returns (bool ok, bytes memory err) {
        OpCtx memory ctx = _newCtx(OP_CREATE, caller);
        ctx.token = token;
        ctx.amount = depositAmount;
        ctx.amount2 = purchaseAmount;
        ctx.amount3 = purchasePeriod;
        ctx.routeIndex = routeIndex;
        ctx.routeK = _routeKOf(token, routeIndex);
        ctx.ids0 = _idsOf(caller, token);
        ctx.maxIdBefore = ghosts.maxIdSeen;
        _setOps(ctx, 1);
        snapshotBefore();
        vm.prank(caller);
        try dcaManager.createDcaSchedule(token, depositAmount, purchaseAmount, purchasePeriod, routeIndex) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        if (!ok) {
            _onRevert(ctx, err);
            return (ok, err);
        }
        ctx.id = uint64(dcaManager.getSchedulesCreatedCount());
        _trackSchedule(token, ctx.id, caller, routeIndex);
        snapshotAfter();
        SchedPair[] memory sp = _schedPairs();
        property_createPostconditions(ctx, sp);
        property_depositExact(ctx);
        property_depositPauseRespected(ctx);
        property_createRespectsCap(ctx);
        _afterLendingDeposit(ctx);
        _postCommonWith(ctx, sp);
    }

    function _depositOp(address caller, address token, uint64 id, uint256 amount)
        internal
        returns (bool ok, bytes memory err)
    {
        OpCtx memory ctx = _schedCtx(OP_DEPOSIT, caller, token, id);
        ctx.amount = amount;
        _setOps(ctx, 1);
        snapshotBefore();
        vm.prank(caller);
        try dcaManager.depositToken(token, id, amount) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        if (!ok) {
            _onRevert(ctx, err);
            return (ok, err);
        }
        snapshotAfter();
        SchedPair[] memory sp = _schedPairs();
        property_depositExact(ctx);
        property_depositPauseRespected(ctx);
        property_mutatorFieldFrame(ctx, sp);
        property_mutatorsOnlyLiveOwnedKeys(ctx, new BRow[](0));
        _afterLendingDeposit(ctx);
        _postCommonWith(ctx, sp);
    }

    /// @dev Lending create/deposit: SP-03, SP-05 (first deposit after a donation), then the slack and
    ///      donation hooks (SP-05 runs before `_ghostLendingDeposit`, plan §6).
    function _afterLendingDeposit(OpCtx memory ctx) internal {
        if (ctx.routeK >= 5 || !routes[ctx.routeK].lending) return;
        address h = routes[ctx.routeK].handler;
        property_lendingDepositCredit(ctx);
        if (ghosts.donatedSinceDeposit[h]) property_postDonationDepositCredit(ctx);
        _ghostAddShareSlack(ctx.caller, h, 1);
        _ghostLendingDeposit(h);
    }

    function _withdrawTokenOp(address caller, address token, uint64 id, uint256 amount)
        internal
        returns (bool ok, bytes memory err)
    {
        OpCtx memory ctx = _schedCtx(OP_WITHDRAW, caller, token, id);
        ctx.amount = amount;
        _setOps(ctx, 1);
        snapshotBefore();
        vm.prank(caller);
        try dcaManager.withdrawToken(token, id, amount) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        if (!ok) {
            _onRevert(ctx, err);
            return (ok, err);
        }
        snapshotAfter();
        _slackOnRoute(ctx, 1);
        SchedPair[] memory sp = _schedPairs();
        property_withdrawExact(ctx);
        property_lendingPayoutNoLoss(ctx);
        property_redeemDebitCeil(ctx);
        property_redeemPaysAtMostBurned(ctx);
        property_mutatorFieldFrame(ctx, sp);
        property_mutatorsOnlyLiveOwnedKeys(ctx, new BRow[](0));
        _postCommonWith(ctx, sp);
    }

    function _withdrawTokenAndInterestOp(address caller, address token, uint64 id, uint256 amount)
        internal
        returns (bool ok, bytes memory err)
    {
        OpCtx memory ctx = _schedCtx(OP_WITHDRAW_INTEREST, caller, token, id);
        ctx.amount = amount;
        if (ctx.routeK < 5) ctx.routeMask = 1 << ctx.routeK;
        _setOps(ctx, 2);
        snapshotBefore();
        vm.prank(caller);
        try dcaManager.withdrawTokenAndInterest(token, id, amount) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        if (!ok) {
            _onRevert(ctx, err);
            return (ok, err);
        }
        snapshotAfter();
        _slackOnRoute(ctx, 2);
        SchedPair[] memory sp = _schedPairs();
        property_withdrawExact(ctx);
        property_redeemDebitCeil(ctx);
        property_redeemPaysAtMostBurned(ctx);
        property_interestWithdrawalSafe(ctx);
        property_interestIdempotent(caller, ctx.routeMask);
        property_mutatorFieldFrame(ctx, sp);
        property_mutatorsOnlyLiveOwnedKeys(ctx, new BRow[](0));
        _postCommonWith(ctx, sp);
    }

    function _deleteOp(address caller, address token, uint64 id, uint256 index)
        internal
        returns (bool ok, bytes memory err)
    {
        OpCtx memory ctx = _schedCtx(OP_DELETE, caller, token, id);
        ctx.amount = index;
        ctx.ids0 = _idsOf(caller, token);
        if (ctx.pre.tokenBalance > 0) _setOps(ctx, 1);
        snapshotBefore();
        vm.prank(caller);
        try dcaManager.deleteDcaSchedule(token, id, index) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        if (!ok) {
            _onRevert(ctx, err);
            return (ok, err);
        }
        _untrackSchedule(token, id);
        snapshotAfter();
        if (ctx.pre.tokenBalance > 0) _slackOnRoute(ctx, 1);
        SchedPair[] memory sp = _schedPairs();
        property_withdrawExact(ctx);
        property_lendingPayoutNoLoss(ctx);
        property_redeemDebitCeil(ctx);
        property_redeemPaysAtMostBurned(ctx);
        property_deletePostconditions(ctx, sp);
        property_mutatorsOnlyLiveOwnedKeys(ctx, new BRow[](0));
        _postCommonWith(ctx, sp);
    }

    function _topUpOp(address caller, address token, uint64 id, uint256 amount)
        internal
        returns (bool ok, bytes memory err)
    {
        OpCtx memory ctx = _schedCtx(OP_TOPUP, caller, token, id);
        ctx.amount = amount;
        _setOps(ctx, 1);
        snapshotBefore();
        vm.prank(caller);
        try dcaManager.topUpFromInterest(token, id, amount) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        if (!ok) {
            _onRevert(ctx, err);
            return (ok, err);
        }
        snapshotAfter();
        SchedPair[] memory sp = _schedPairs();
        property_topUpExact(ctx);
        property_mutatorFieldFrame(ctx, sp);
        property_mutatorsOnlyLiveOwnedKeys(ctx, new BRow[](0));
        _postCommonWith(ctx, sp);
    }

    /// @dev Success path shared by updatePurchaseAmount, updatePurchasePeriod and setSchedulePaused.
    function _afterEdit(OpCtx memory ctx) internal {
        snapshotAfter();
        SchedPair[] memory sp = _schedPairs();
        if (ctx.op == OP_PAUSE) property_pauseTransitions(ctx, sp);
        property_mutatorFieldFrame(ctx, sp);
        property_mutatorsOnlyLiveOwnedKeys(ctx, new BRow[](0));
        _postCommonWith(ctx, sp);
    }

    function _interestAllOp(address caller, address[] memory tokens, uint256[] memory routeIndexes)
        internal
        returns (bool ok, bytes memory err)
    {
        OpCtx memory ctx = _newCtx(OP_INTEREST_ALL, caller);
        ctx.routeMask = _pairMask(tokens, routeIndexes);
        for (uint256 k; k < 5; k++) {
            if (routes[k].lending && _named(ctx, k) && ctx.ai < 3) ctx.ops[ctx.ai][k] = 1;
        }
        snapshotBefore();
        vm.prank(caller);
        try dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        if (!ok) {
            _onRevert(ctx, err);
            return (ok, err);
        }
        snapshotAfter();
        for (uint256 k; k < 5; k++) {
            if (routes[k].lending && _named(ctx, k)) _ghostAddShareSlack(caller, routes[k].handler, 1);
        }
        property_redeemDebitCeil(ctx);
        property_redeemPaysAtMostBurned(ctx);
        property_interestWithdrawalSafe(ctx);
        property_interestIdempotent(caller, ctx.routeMask);
        property_interestPayoutVsQuote(ctx);
        _postCommon(ctx);
    }

    function _rbtcAllOp(address caller, address[] memory tokens, uint256[] memory routeIndexes)
        internal
        returns (bool ok, bytes memory err)
    {
        OpCtx memory ctx = _newCtx(OP_RBTC_ALL, caller);
        ctx.routeMask = _pairMask(tokens, routeIndexes);
        snapshotBefore();
        vm.prank(caller);
        try dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        if (!ok) {
            _onRevert(ctx, err);
            return (ok, err);
        }
        snapshotAfter();
        property_rbtcClaimExact(ctx);
        _postCommon(ctx);
    }

    function _batchOp(uint8 op, address caller, IDcaManager.Batch[] memory batches)
        internal
        returns (bool ok, bytes memory err)
    {
        OpCtx memory ctx = _newCtx(op, caller);
        ctx.routeMask = _batchRouteMask(batches);
        // H2's pre-batch context comes from `stateBefore` and `batches` (see Properties "Batches"); the
        // storage capture `_captureBatchCtx` is not called because it does not fit the 12.5M gas limit.
        snapshotBefore();
        vm.prank(caller);
        if (op == OP_BATCH) {
            try dcaManager.batchBuyRbtc(batches[0]) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            try dcaManager.batchBuyRbtcAcrossHandlers(batches) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        }
        if (!ok) {
            _onRevert(ctx, err);
            property_cadenceRefusalsMatchSpec(batches, err, false);
            property_oracleValidity(batches, false, err);
            return (ok, err);
        }
        snapshotAfter();
        _afterBatch(ctx, batches);
    }

    function _afterBatch(OpCtx memory ctx, IDcaManager.Batch[] memory batches) internal {
        SchedPair[] memory sp = _schedPairs();
        (BRow[] memory rows, BatchSim memory s) = _analyseBatch(sp, batches);
        for (uint256 a; a < 3; a++) {
            for (uint256 k; k < 5; k++) {
                ctx.ops[a][k] = s.rowsOf[a][k];
            }
        }
        _batchGhosts(rows, s);
        property_batchCreditsBounded(s);
        property_batchFeeCap(s);
        property_batchFeeLowerBounds(s);
        property_batchDebitsExact(rows, s, sp);
        property_lendingBatchFunding(s);
        property_idleOutputMatchesVenue(s);
        property_batchShareSimulation(s);
        property_batchCreditsExact(rows, s);
        property_dexOracleFloor(ctx.op, s);
        property_minRbtcOutBinds(s);
        property_acrossDexFloor(ctx.op, s);
        property_oracleValidity(batches, true, "");
        property_batchRowLegality(rows, sp);
        property_pauseTransitions(ctx, sp);
        property_swapperAllowlistTransitions(ctx);
        property_mutatorsOnlyLiveOwnedKeys(ctx, rows);
        _batchRedeemBounds(s);
        _postCommonWith(ctx, sp);
    }

    /// @dev SP-11 for batches: LayerBank Dex retrieval between G and floor(T·idx/RAY)+1; MoC lending spend at most the burn's value.
    function _batchRedeemBounds(BatchSim memory s) internal {
        if (s.foreign) return;
        for (uint256 k; k < 5; k++) {
            if (s.batchesOn[k] != 1 || !routes[k].lending || s.qFell[k]) continue;
            uint256 burnValue = s.burn[k] * stateBefore.rate[k] / _Dk(k);
            bool lb = isLB(routes[k].handler);
            if (routes[k].dex) {
                if (s.batchesOn[K_IDLE_DEX] > 0) continue;
                (bool okIn, uint256 rin) = _routerIntake();
                if (!okIn) continue;
                lte(rin, burnValue + 1, "SP-11: LayerBank batch retrieved above the burn value + 1");
                gte(rin, s.gFund[k], "SP-11: LayerBank batch retrieved less than the funded weights");
            } else {
                lte(
                    s.q[k] * BTC_PRICE_USD,
                    burnValue + (lb ? 1 : 0),
                    "SP-11: MoC lending batch spent above the burn value"
                );
                if (lb || stateBefore.sovrynExitFee == 0) {
                    gte(s.q[k], s.gFund[k] / BTC_PRICE_USD, "SP-11: MoC lending batch under-funded vs funded weights");
                }
            }
        }
    }

    /// @dev Ghost hooks for a successful batch call (plan §9): dust budget, cadence, slack, window debits.
    function _batchGhosts(BRow[] memory rows, BatchSim memory s) internal {
        for (uint256 k; k < 5; k++) {
            if (s.rowsOn[k] > 0) _ghostBatchRows(routes[k].handler, s.rowsOn[k]);
        }
        bool live = block.number < stateBefore.unlock;
        for (uint256 i; i < rows.length; i++) {
            BRow memory r = rows[i];
            _ghostBuy(r.token, r.id);
            if (r.k < 5 && routes[r.k].lending) _ghostAddShareSlack(r.buyer, routes[r.k].handler, 1);
            if (live) _ghostWindowBatch(r.token, r.id, r.amount);
        }
        if (!live) return;
        address[4] memory accts = _accounts();
        for (uint256 k; k < 5; k++) {
            if (s.batchesOn[k] == 0 || !routes[k].lending) continue;
            for (uint256 a; a < 4; a++) {
                uint256 sb = stateBefore.shares[a][k];
                uint256 sa = stateAfter.shares[a][k];
                if (sb > sa) _ghostWindowShareBurn(accts[a], routes[k].handler, sb - sa);
            }
        }
    }

    function _slackOnRoute(OpCtx memory ctx, uint256 ops) internal {
        if (ctx.routeK < 5) _ghostAddShareSlack(ctx.caller, routes[ctx.routeK].handler, ops);
    }

    // ―――――――――――――――――――――――― Helpers ―――――――――――――――――――――――――――

    function _minPeriodDays() internal view returns (uint256) {
        return dcaManager.getMinPurchasePeriod() / 1 days;
    }

    function _windowLive() internal view returns (bool) {
        return block.number < dcaManager.getUserMutationsAllowedFromBlock();
    }

    /// @dev Position of the schedule's id in its owner's list, as `deleteDcaSchedule` requires.
    function _scheduleIdIndex(TrackedSchedule memory s) internal view returns (uint256) {
        (uint64[] memory ids,) = dcaManager.getDcaSchedules(s.owner, s.token);
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == s.scheduleId) return i;
        }
        return ids.length;
    }

    function _isEligible(IDcaManager.DcaSchedule memory sched) internal view returns (bool) {
        if (sched.paused || sched.purchaseAmount > sched.tokenBalance) return false;
        if (sched.cadenceAnchor == 0) return true;
        uint256 currentDayStart = block.timestamp - (block.timestamp % 1 days);
        return currentDayStart >= uint256(sched.cadenceAnchor) + sched.purchasePeriod;
    }

    /// @dev Eligible tracked rows on `r` whose position bit is set in `rowMask` (all rows if the mask
    ///      selects none), capped at MAX_BATCH_ROWS. `total` is their summed nominal purchase amount.
    function _eligibleRows(Route memory r, uint256 rowMask) internal view returns (uint64[] memory ids, uint256 total) {
        uint64[] memory tmp = new uint64[](MAX_BATCH_ROWS);
        uint64[] memory all = new uint64[](MAX_BATCH_ROWS);
        uint256 picked;
        uint256 eligible;
        uint256 allTotal;
        for (uint256 i; i < trackedSchedules.length && eligible < MAX_BATCH_ROWS; i++) {
            TrackedSchedule memory s = trackedSchedules[i];
            if (s.token != r.token || s.routeIndex != r.routeIndex) continue;
            IDcaManager.DcaSchedule memory sched = dcaManager.getDcaSchedule(s.token, s.scheduleId);
            if (!_isEligible(sched)) continue;
            all[eligible] = s.scheduleId;
            allTotal += sched.purchaseAmount;
            if ((rowMask >> eligible) & 1 == 1) {
                tmp[picked++] = s.scheduleId;
                total += sched.purchaseAmount;
            }
            eligible++;
        }
        if (picked == 0) {
            (tmp, picked, total) = (all, eligible, allTotal);
        }
        ids = new uint64[](picked);
        for (uint256 i; i < picked; i++) {
            ids[i] = tmp[i];
        }
    }

    function _truncate(uint64[] memory ids, uint256 n) internal pure returns (uint64[] memory out) {
        out = new uint64[](n);
        for (uint256 i; i < n; i++) {
            out[i] = ids[i];
        }
    }

    function _routeRows(Route memory r) internal view returns (uint64[] memory ids) {
        uint256 count;
        for (uint256 i; i < trackedSchedules.length; i++) {
            if (trackedSchedules[i].token == r.token && trackedSchedules[i].routeIndex == r.routeIndex) count++;
        }
        if (count > MAX_BATCH_ROWS) count = MAX_BATCH_ROWS;
        ids = new uint64[](count);
        uint256 n;
        for (uint256 i; i < trackedSchedules.length && n < count; i++) {
            if (trackedSchedules[i].token == r.token && trackedSchedules[i].routeIndex == r.routeIndex) {
                ids[n++] = trackedSchedules[i].scheduleId;
            }
        }
    }

    /// @dev Gross rBTC the venue would pay for `stablecoinAmount` at current mock prices. On lending
    ///      routes the handler may spend less after its per-row clamp, so this is an upper estimate.
    function _expectedGrossRbtc(Route memory r, uint256 stablecoinAmount) internal view returns (uint256) {
        if (!r.dex) return stablecoinAmount / BTC_PRICE_USD;
        return stablecoinAmount * 997 / (1000 * dexRouterPrice);
    }

    /// @dev Non-empty (token, route) pair list from the bits of `routeMask` (all routes if none set).
    function _routePairs(uint256 routeMask)
        internal
        view
        returns (address[] memory tokens, uint256[] memory routeIndexes)
    {
        uint256 count;
        for (uint256 i; i < routes.length; i++) {
            if ((routeMask >> i) & 1 == 1) count++;
        }
        if (count == 0) routeMask = type(uint256).max;
        if (count == 0) count = routes.length;
        tokens = new address[](count);
        routeIndexes = new uint256[](count);
        uint256 n;
        for (uint256 i; i < routes.length; i++) {
            if ((routeMask >> i) & 1 == 0) continue;
            tokens[n] = routes[i].token;
            routeIndexes[n] = routes[i].routeIndex;
            n++;
        }
    }
}
