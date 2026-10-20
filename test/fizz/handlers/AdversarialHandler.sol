// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {DcaManagerHandler} from "./DcaManagerHandler.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Attack and liveness probes (plan H3, H5, H7, H11, H4): exits, purchases, access control,
///         the Finding 1 plan/execute pair and its single-call scenario, and the fee probe.
/// @dev Liveness probes reuse the DcaManagerHandler funnels, so each call they make is checked like any
///      other call of its kind, and then fail the probe if it reverted. Attack probes expect a revert;
///      a reverted call changes nothing, so they only check that it reverted and why.
abstract contract AdversarialHandler is DcaManagerHandler {
    // ――――――――――――――――――――― A. Exit liveness ―――――――――――――――――――――

    /// @dev SP-58 (+ SP-08 inside the funnel).
    function adv_withdrawLiveness(uint256 scheduleSeed, uint256 amountSeed, bool full) public {
        if (_windowLive()) return;
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        uint256 balance = dcaManager.getDcaSchedule(s.token, s.scheduleId).tokenBalance;
        if (balance == 0) return;
        uint256 amount = full ? type(uint256).max : clampBetween(amountSeed, 1, balance);
        (bool ok, bytes memory err) = _withdrawTokenOp(actor, s.token, s.scheduleId, amount);
        property_withdrawLiveness(ok, err);
    }

    /// @dev SP-59 (+ SP-13 inside the funnel).
    function adv_deleteLiveness(uint256 scheduleSeed) public {
        if (_windowLive()) return;
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        (bool ok, bytes memory err) = _deleteOp(actor, s.token, s.scheduleId, _scheduleIdIndex(s));
        property_deleteLiveness(ok, err);
    }

    /// @dev SP-60 (+ SP-15 inside the funnel).
    function adv_interestLiveness(uint256 routeMask) public {
        if (_windowLive()) return;
        (address[] memory tokens, uint256[] memory routeIndexes) = _routePairs(routeMask);
        (bool ok, bytes memory err) = _interestAllOp(actor, tokens, routeIndexes);
        property_interestExitLiveness(ok, err);
    }

    /// @dev SP-60 for withdrawTokenAndInterest (+ SP-08, SP-14, SP-15 inside the funnel).
    function adv_principalAndInterestLiveness(uint256 scheduleSeed, uint256 amountSeed) public {
        if (_windowLive()) return;
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        if (!_routeOf(s.token, s.routeIndex).lending) return;
        uint256 balance = dcaManager.getDcaSchedule(s.token, s.scheduleId).tokenBalance;
        if (balance == 0) return;
        (bool ok, bytes memory err) =
            _withdrawTokenAndInterestOp(actor, s.token, s.scheduleId, clampBetween(amountSeed, 1, balance));
        property_interestExitLiveness(ok, err);
    }

    /// @dev SP-61 (+ SP-39 inside the funnel). When the claimant is the ReentrantActor (actors[2]) and
    ///      `reentryMode % 6 != 0`, it is armed to re-enter during its payment (SP-74), then disarmed.
    function adv_claimLiveness(uint256 accountSeed, uint256 routeMask, uint8 reentryMode) public {
        address claimant = _claimant(accountSeed);
        (address[] memory tokens, uint256[] memory routeIndexes) = _routePairs(routeMask);
        ReentrantActor ra = ReentrantActor(payable(actors[2]));
        bool armed = claimant == actors[2] && reentryMode % 6 != 0;
        uint256 successes0;
        if (armed) {
            _armReentry(ra, reentryMode % 6, tokens, routeIndexes);
            successes0 = ra.successes();
        }
        (bool ok, bytes memory err) = _rbtcAllOp(claimant, tokens, routeIndexes);
        if (armed) {
            ra.disarm();
            property_reentrantClaimSafe(successes0, ra.successes());
        }
        property_claimLiveness(ok, err);
    }

    /// @dev SP-62: delete every owned schedule, withdraw all interest, claim all rBTC, then re-enter.
    function adv_fullExitAndReenter(uint256 routeSeed, uint256 depositSeed) public {
        if (_windowLive()) return;
        uint256 ai = _actorIndex(actor);
        AccountsView memory prior = _accountsView(actor);
        if (!_exitAll()) return;
        property_fullExitAndReenter(prior, ai);
        _reenter(routeSeed % routes.length, depositSeed);
    }

    // ――――――――――――――――――――― B. Purchase liveness ―――――――――――――――――――――

    /// @dev SP-63, SP-72 (Dex route on path 1), plus every batch property on success.
    function adv_cleanBatchLiveness(uint256 routeSeed, uint256 rowMask, uint256 swapperSeed) public {
        Route memory r = _route(routeSeed);
        address sw = swappers[swapperSeed % swappers.length];
        if (!operationsAdmin.isSwapper(sw)) return;
        (uint64[] memory cand,) = _eligibleRows(r, rowMask);
        if (cand.length == 0) return;
        CleanPlan memory cp = _simLendingBatch(r, cand);
        if (cp.ids.length == 0 || !_venueOk(r, cp.cashIn)) return;
        bool path1 = r.dex && keccak256(IPurchaseUniswap(r.handler).getSwapPath()) == keccak256(_dexPath(1));
        (bool ok, bytes memory err) = _batchOp(OP_BATCH, sw, _oneBatch(cp.ids, r, 0));
        if (path1) property_intermediateDonationNoDos(ok, err);
        property_cleanBatchLiveness(ok, err);
    }

    /// @dev H3: a swapper activates a window and plans a batch from that state (`ghosts.plan`).
    function adv_planProtectedBatch(uint256 routeSeed, uint256 rowMask, uint256 swapperSeed) public {
        if (ghosts.plan.live && block.number < ghosts.plan.unlock) return;
        ghosts.plan.live = false;
        if (_windowLive()) return;
        address sw = swappers[swapperSeed % swappers.length];
        if (!_activateInline(sw)) return;
        _writePlan(routeSeed % routes.length, rowMask, sw);
    }

    /// @dev H3: executes the plan with minRbtcOut = 0 (SP-64, SP-55).
    function adv_executeProtectedBatch() public {
        _executePlan(false);
    }

    /// @dev H3: executes the plan with the quote-derived minimum (SP-64, SP-65, SP-55).
    function adv_executeProtectedBatchWithQuote() public {
        _executePlan(true);
    }

    /// @dev H3 single-call variant: [optional Sovryn price fall] → activate → plan → 1-3 user ops on the
    ///      planned buyers (unguarded ones may succeed, guarded ones must revert UserMutationsLocked) →
    ///      execute → GL-18 inline. Everything happens in one block, so the window is live throughout.
    function adv_protectedBatchScenario(
        uint256 routeSeed,
        uint256 rowMask,
        uint256 swapperSeed,
        uint256 opsSeed,
        uint256 amountSeed,
        bool fallFirst,
        bool withQuote
    ) public {
        if (_windowLive()) return;
        if (ghosts.plan.live && block.number < ghosts.plan.unlock) return;
        ghosts.plan.live = false;
        if (fallFirst) _scenarioPriceFall(opsSeed);
        address sw = swappers[swapperSeed % swappers.length];
        if (!_activateInline(sw)) return;
        if (!_writePlan(routeSeed % routes.length, rowMask, sw)) return;
        uint256 n = 1 + opsSeed % 3;
        for (uint256 i; i < n; i++) {
            _scenarioUserOp(uint8(opsSeed >> (8 * i + 8)), amountSeed >> (64 * i));
        }
        _executePlan(withQuote);
        _checkWindowFreeze();
    }

    /// @dev H11: one-row batch of a spec-due, unpaused, funded schedule with minRbtcOut 0 (SP-37). While a
    ///      window is live only rows eligible at activation and not yet bought are sent (SP-55).
    function probe_buyOne(uint256 scheduleSeed) public {
        uint256 len = trackedSchedules.length;
        if (len == 0) return;
        bool live = _windowLive();
        for (uint256 j; j < len; j++) {
            TrackedSchedule memory s = trackedSchedules[(scheduleSeed + j) % len];
            if (!_isEligible(dcaManager.getDcaSchedule(s.token, s.scheduleId))) continue;
            if (live && !_preparedUnbought(s.token, s.scheduleId)) continue;
            uint64[] memory ids = new uint64[](1);
            ids[0] = s.scheduleId;
            IDcaManager.Batch[] memory bs = _oneBatch(ids, _routeOf(s.token, s.routeIndex), 0);
            (bool ok, bytes memory err) = _batchOp(OP_BATCH, swapper, bs);
            if (!ok) {
                property_cadenceRefusalsMatchSpec(bs, err, true);
                if (live) property_preparedRowSurvivesWindow(bs, err, true);
            }
            return;
        }
    }

    // ――――――――――――――――――――― D. Access control ―――――――――――――――――――――

    /// @dev SP-68: actors, the collector, the owner and revoked swappers cannot use swapper powers.
    function adv_impersonateSwapper(
        uint8 which,
        uint256 callerSeed,
        uint256 routeSeed,
        uint256 rowMask,
        uint256 pathSeed
    ) public {
        address c = _impersonator(callerSeed);
        if (operationsAdmin.isSwapper(c)) return;
        uint256 unlock0 = dcaManager.getUserMutationsAllowedFromBlock();
        which = uint8(which % 4);
        bool ok;
        bytes memory err;
        if (which == 3) {
            if (c == admin) return; // the owner may switch paths
            address h = dexHandlers[pathSeed % dexHandlers.length];
            (address[] memory tokens, uint24[] memory fees) = _pathParts(_allowedPathIdx(h));
            vm.prank(c);
            try IPurchaseUniswap(h).setPurchasePath(tokens, fees) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
            property_nonSwapperCannotActAsSwapper(ok, err, true, unlock0);
            return;
        }
        if (which == 0) {
            vm.prank(c);
            try dcaManager.activateProtectedPurchaseWindow() {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            Route memory r = _route(routeSeed);
            (uint64[] memory ids,) = _eligibleRows(r, rowMask);
            if (ids.length == 0) {
                ids = new uint64[](1);
                ids[0] = 1;
            }
            IDcaManager.Batch[] memory bs = _oneBatch(ids, r, 0);
            vm.prank(c);
            if (which == 1) {
                try dcaManager.batchBuyRbtc(bs[0]) {
                    ok = true;
                } catch (bytes memory e) {
                    err = e;
                }
            } else {
                try dcaManager.batchBuyRbtcAcrossHandlers(bs) {
                    ok = true;
                } catch (bytes memory e) {
                    err = e;
                }
            }
        }
        property_nonSwapperCannotActAsSwapper(ok, err, false, unlock0);
    }

    /// @dev SP-69: the current actor calls a handler's fund-moving or interest functions directly.
    function adv_callHandlerDirectly(uint8 which, uint256 routeSeed, uint256 victimSeed, uint256 amount) public {
        Route memory r = _route(routeSeed);
        address h = r.handler;
        address victim = toActorNotCurrent(address(uint160(victimSeed)));
        amount = clampBetween(amount, 1, 1e24);
        which = uint8(which % 7);
        if (which >= 4 && !r.lending) which = uint8(which % 4);
        bool ok;
        bytes memory err;
        if (which == 2) {
            (ok, err) = _directBatch(h, victim, amount);
        } else {
            vm.prank(actor);
            if (which == 0) {
                try ITokenHandler(h).depositToken(victim, amount) {
                    ok = true;
                } catch (bytes memory e) {
                    err = e;
                }
            } else if (which == 1) {
                try ITokenHandler(h).withdrawToken(actor, amount) returns (uint256) {
                    ok = true;
                } catch (bytes memory e) {
                    err = e;
                }
            } else if (which == 3) {
                try IPurchaseRbtc(h).withdrawAccumulatedRbtc(victim) {
                    ok = true;
                } catch (bytes memory e) {
                    err = e;
                }
            } else if (which == 4) {
                try ILendingHandler(h).withdrawInterest(actor, 0) {
                    ok = true;
                } catch (bytes memory e) {
                    err = e;
                }
            } else if (which == 5) {
                try ILendingHandler(h).getAccruedInterest(actor, 0) returns (uint256) {
                    ok = true;
                } catch (bytes memory e) {
                    err = e;
                }
            } else {
                try ILendingHandler(h).quoteAccruedInterest(actor, 0) returns (uint256) {
                    ok = true;
                } catch (bytes memory e) {
                    err = e;
                }
            }
        }
        property_handlersOnlyFromManager(ok, err);
    }

    /// @dev SP-70: the current actor tries each mutator form on a schedule someone else owns.
    function adv_mutateForeignSchedule(uint8 which, uint256 victimSeed, uint256 amount) public {
        uint256 len = trackedSchedules.length;
        uint256 found = type(uint256).max;
        for (uint256 j; j < len; j++) {
            uint256 i = (victimSeed + j) % len;
            if (trackedSchedules[i].owner != actor) {
                found = i;
                break;
            }
        }
        if (found == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[found];
        which = uint8(which % 9);
        // deposit (0) and top-up (8) are unguarded; the other seven are window-guarded.
        bool guarded = which != 0 && which != 8;
        (bool ok, bytes memory err) = _foreignCall(which, s, clampBetween(amount, 1, 1e24));
        property_noForeignScheduleMutation(ok, err, guarded);
    }

    /// @dev SP-71: an actor or a swapper calls an owner-only setter; the owner calls renounceOwnership.
    function adv_nonOwnerSetter(uint8 which, uint256 handlerSeed, uint256 arg, uint256 callerSeed) public {
        which = uint8(which % 17);
        bool renounce = which == 16;
        address c = renounce ? admin : (callerSeed % 2 == 0 ? actor : swappers[(callerSeed >> 1) % swappers.length]);
        (bool ok, bytes memory err) = which < 8
            ? _handlerSetterCall(
                which, c, _route(handlerSeed).handler, dexHandlers[handlerSeed % dexHandlers.length], arg
            )
            : _coreSetterCall(which, c, _route(handlerSeed).handler, arg);
        property_nonOwnerSettersRevert(ok, err, renounce);
    }

    // ――――――――――――――――――――― E. Funding liveness ―――――――――――――――――――――

    /// @dev SP-73 for createDcaSchedule (+ SP-01, SP-02 inside the funnel).
    function adv_createLiveness(uint256 routeSeed, uint256 depositAmount, uint256 purchaseAmount, uint256 periodDays)
        public
    {
        if (trackedSchedules.length >= MAX_TRACKED) return;
        Route memory r = _route(routeSeed);
        if (operationsAdmin.areDepositsPaused(r.token, r.routeIndex)) return;
        if (_idsOf(actor, r.token).length >= dcaManager.getMaxSchedulesPerToken()) return;
        uint256 minP = dcaManager.getTokenMinPurchaseAmount(r.token);
        uint256 bal = MockStablecoin(r.token).balanceOf(actor);
        uint256 maxD = bal < MAX_DEPOSIT ? bal : MAX_DEPOSIT;
        if (maxD < minP) return;
        depositAmount = clampBetween(depositAmount, minP, maxD);
        purchaseAmount = clampBetween(purchaseAmount, minP, depositAmount);
        uint256 period = clampBetween(periodDays, _minPeriodDays(), MAX_PERIOD_DAYS) * 1 days;
        if (r.lending && _previewMint(r.handler, depositAmount, rate(r.handler)) == 0) return;
        (bool ok, bytes memory err) = _createOp(actor, r.token, depositAmount, purchaseAmount, period, r.routeIndex);
        property_fundingLiveness(ok, err);
    }

    /// @dev SP-73 for depositToken (+ SP-01 inside the funnel).
    function adv_depositLiveness(uint256 scheduleSeed, uint256 depositAmount) public {
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        Route memory r = _routeOf(s.token, s.routeIndex);
        if (operationsAdmin.areDepositsPaused(r.token, r.routeIndex)) return;
        uint256 bal = MockStablecoin(r.token).balanceOf(actor);
        if (bal == 0) return;
        depositAmount = clampBetween(depositAmount, 1, bal < MAX_DEPOSIT ? bal : MAX_DEPOSIT);
        if (r.lending && _previewMint(r.handler, depositAmount, rate(r.handler)) == 0) return;
        (bool ok, bytes memory err) = _depositOp(actor, s.token, s.scheduleId, depositAmount);
        property_fundingLiveness(ok, err);
    }

    /// @dev SP-73 for topUpFromInterest (+ SP-17 inside the funnel), with needed <= amount <= quoted interest.
    function adv_topUpLiveness(uint256 scheduleSeed, uint256 amount) public {
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        if (!_routeOf(s.token, s.routeIndex).lending) return;
        uint256 accrued = dcaManager.getAccruedInterest(actor, s.token, s.routeIndex);
        IDcaManager.DcaSchedule memory d = dcaManager.getDcaSchedule(s.token, s.scheduleId);
        uint256 needed = d.purchaseAmount - (d.tokenBalance % d.purchaseAmount);
        if (accrued == 0 || needed > accrued) return;
        (bool ok, bytes memory err) = _topUpOp(actor, s.token, s.scheduleId, clampBetween(amount, needed, accrued));
        property_fundingLiveness(ok, err);
    }

    // ――――――――――――――――――――― Fee probe (H4) ―――――――――――――――――――――

    /// @dev SP-76, SP-77 on `FizzFeeProbe` loaded with a live handler's settings. Stateless for the protocol.
    function probe_feeCurve(uint256 handlerSeed, uint256 x1, uint256 x2) public {
        IPurchaseFees.FeeSettings memory fs = IPurchaseFees(_route(handlerSeed).handler).getFeeSettings();
        feeProbe.setFeeRateParams(fs.minFeeRate, fs.maxFeeRate, fs.feePurchaseLowerBound);
        x1 = clampBetween(x1, 1, type(uint96).max);
        x2 = clampBetween(x2, x1, type(uint96).max);
        property_feeCurveMatchesSpec(fs, x1, x2);
        property_feeSplitNoGain(x1, x2);
    }

    // ――――――――――――――――――――― Helpers ―――――――――――――――――――――

    function _oneBatch(uint64[] memory ids, Route memory r, uint256 minOut)
        internal
        pure
        returns (IDcaManager.Batch[] memory bs)
    {
        bs = new IDcaManager.Batch[](1);
        bs[0] = IDcaManager.Batch({
            scheduleIds: ids, token: r.token, routeIndex: r.routeIndex, minRbtcOut: minOut, quotedStablecoinIn: 0
        });
    }

    /// @dev Activation outside the funnel (scenario gas); the window ghosts are still opened.
    function _activateInline(address sw) internal returns (bool) {
        vm.prank(sw);
        try dcaManager.activateProtectedPurchaseWindow() {
            _ghostWindowActivated();
            return true;
        } catch {
            return false;
        }
    }

    function _writePlan(uint256 k, uint256 rowMask, address sw) internal returns (bool) {
        Route memory r = routes[k];
        Plan storage pl = ghosts.plan;
        (uint64[] memory cand,) = _eligibleRows(r, rowMask);
        CleanPlan memory cp = _simLendingBatch(r, cand);
        if (cp.ids.length == 0) {
            pl.live = false;
            return false;
        }
        pl.live = true;
        pl.routeK = k;
        pl.ids = cp.ids;
        pl.swapper = sw;
        pl.unlock = dcaManager.getUserMutationsAllowedFromBlock();
        pl.G = cp.G;
        pl.SR = cp.SR;
        pl.cashIn = cp.cashIn;
        pl.rate = rate(r.handler);
        pl.exitFeeBps = sovrynIToken.getExitFeeBps();
        pl.dexPrice = dexRouterPrice;
        if (r.dex) (pl.oraclePrice, pl.oracleValid) = _oracleInfo(r.handler);
        pl.minOut = _venueOut(r, cp.cashIn);
        delete pl.anchors;
        for (uint256 i; i < cp.ids.length; i++) {
            pl.anchors.push(dcaManager.getDcaSchedule(r.token, cp.ids[i]).cadenceAnchor);
        }
        return true;
    }

    function _executePlan(bool withQuote) internal {
        Plan storage pl = ghosts.plan;
        if (!pl.live) return;
        pl.live = false;
        if (block.number >= pl.unlock || dcaManager.getUserMutationsAllowedFromBlock() != pl.unlock) return;
        Route memory r = routes[pl.routeK];
        if (!_planRowsUnbought(r)) return;
        ExecView memory ev = _execView(r);
        IDcaManager.Batch[] memory bs = _oneBatch(pl.ids, r, withQuote ? pl.minOut : 0);
        bs[0].quotedStablecoinIn = pl.cashIn;
        (bool ok, bytes memory err) = _inlineBatch(pl.swapper, bs);
        if (ok) property_protectedBatchExecutionRate(r, ev, withQuote);
        if (withQuote) property_minRbtcOutNotWeaponized(r, ev, ok, err);
        if (!ok) property_preparedRowSurvivesWindow(bs, err, pl.ids.length == 1);
    }

    /// @dev Plan executions run inline (plan §9: "inline"): no snapshots, only the batch ghost hooks, SP-12 and
    ///      SP-51 on a revert. The single-call scenario does not fit the gas limit with two full snapshots
    ///      on top of an activation's window snapshot.
    function _inlineBatch(address sw, IDcaManager.Batch[] memory bs) internal returns (bool ok, bytes memory err) {
        IDcaManager.Batch memory batch = bs[0];
        uint256 k = _routeKOf(batch.token, batch.routeIndex);
        uint256 n = batch.scheduleIds.length;
        address[4] memory accts = _accounts();
        uint256[4] memory sharesBefore;
        address h = routes[k].handler;
        for (uint256 a; a < 4; a++) {
            sharesBefore[a] = shares(accts[a], h);
        }
        IDcaManager.DcaSchedule[] memory pre = new IDcaManager.DcaSchedule[](n);
        for (uint256 i; i < n; i++) {
            pre[i] = dcaManager.getDcaSchedule(batch.token, batch.scheduleIds[i]);
        }
        uint256 unlock = dcaManager.getUserMutationsAllowedFromBlock();
        vm.prank(sw);
        try dcaManager.batchBuyRbtc(batch) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        if (!ok) {
            property_noBurnMismatchRevert(err);
            property_windowGatesGuardedCalls(OP_BATCH, false, err, unlock);
            return (ok, err);
        }
        bool live = block.number < unlock;
        _ghostBatchRows(h, n);
        for (uint256 i; i < n; i++) {
            _ghostBuy(batch.token, batch.scheduleIds[i]);
            if (routes[k].lending) _ghostAddShareSlack(pre[i].user, h, 1);
            if (live) _ghostWindowBatch(batch.token, batch.scheduleIds[i], pre[i].purchaseAmount);
        }
        if (!live || !routes[k].lending) return (ok, err);
        for (uint256 a; a < 4; a++) {
            uint256 now_ = shares(accts[a], h);
            if (sharesBefore[a] > now_) _ghostWindowShareBurn(accts[a], h, sharesBefore[a] - now_);
        }
    }

    /// @dev No planned row has been bought since planning (its anchor is unchanged) and all are still live.
    function _planRowsUnbought(Route memory r) internal view returns (bool) {
        Plan storage pl = ghosts.plan;
        for (uint256 i; i < pl.ids.length; i++) {
            try dcaManager.getDcaSchedule(r.token, pl.ids[i]) returns (IDcaManager.DcaSchedule memory d) {
                if (d.cadenceAnchor != pl.anchors[i]) return false;
            } catch {
                return false;
            }
        }
        return true;
    }

    function _execView(Route memory r) internal view returns (ExecView memory ev) {
        Plan storage pl = ghosts.plan;
        ev.sameRate = !r.lending
            || (rate(r.handler) == pl.rate && (!isSov(r.handler) || sovrynIToken.getExitFeeBps() == pl.exitFeeBps));
        if (r.dex) {
            (, bool valid) = _oracleInfo(r.handler);
            ev.priceNotWorse = dexRouterPrice <= pl.dexPrice && valid && _venueOk(r, pl.cashIn);
        } else {
            ev.priceNotWorse = true;
        }
        ev.rcpt0 = receipt(r.handler);
        ev.rin0 = usdrif.balanceOf(address(swapRouter));
        ev.q0 = rbtcAsset(r.handler);
        for (uint256 i; i < pl.ids.length; i++) {
            ev.g += dcaManager.getDcaSchedule(r.token, pl.ids[i]).purchaseAmount;
        }
    }

    function _scenarioPriceFall(uint256 seed) internal {
        uint256 bps = 1 + seed % 2_000;
        uint256 price = sovrynIToken.tokenPrice();
        uint256 next = price - price * bps / 10_000;
        if (next < 0.5 ether) return;
        sovrynIToken.setTokenPrice(next);
        _ghostSovrynPriceMoved(price, next);
    }

    /// @dev One user op by the owner of a planned row: 0 deposit, 1 create, 2 top-up (unguarded),
    ///      3 a guarded edit that must revert UserMutationsLocked (SP-51).
    function _scenarioUserOp(uint8 kind, uint256 amountSeed) internal {
        Plan storage pl = ghosts.plan;
        Route memory r = routes[pl.routeK];
        uint64 id = pl.ids[amountSeed % pl.ids.length];
        IDcaManager.DcaSchedule memory d = dcaManager.getDcaSchedule(r.token, id);
        uint256 op = kind % 4;
        if (op == 0) _scenarioDeposit(r, id, d.user, amountSeed);
        else if (op == 1) _scenarioCreate(r, d.user, amountSeed);
        else if (op == 2) _scenarioTopUp(r, id, d);
        else _scenarioGuarded(r, id, d, kind >> 2);
    }

    function _scenarioDeposit(Route memory r, uint64 id, address owner, uint256 amountSeed) internal {
        if (operationsAdmin.areDepositsPaused(r.token, r.routeIndex)) return;
        uint256 bal = MockStablecoin(r.token).balanceOf(owner);
        if (bal == 0) return;
        uint256 amount = clampBetween(amountSeed, 1, bal < MAX_DEPOSIT ? bal : MAX_DEPOSIT);
        if (r.lending && _previewMint(r.handler, amount, rate(r.handler)) == 0) return;
        bool ok;
        bytes memory err;
        vm.prank(owner);
        try dcaManager.depositToken(r.token, id, amount) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        if (ok) _ghostAddShareSlack(owner, r.handler, 1);
        property_windowGatesGuardedCalls(OP_DEPOSIT, ok, err, dcaManager.getUserMutationsAllowedFromBlock());
    }

    function _scenarioCreate(Route memory r, address owner, uint256 amountSeed) internal {
        if (trackedSchedules.length >= MAX_TRACKED || operationsAdmin.areDepositsPaused(r.token, r.routeIndex)) return;
        uint256 minP = dcaManager.getTokenMinPurchaseAmount(r.token);
        uint256 bal = MockStablecoin(r.token).balanceOf(owner);
        uint256 maxD = bal < MAX_DEPOSIT ? bal : MAX_DEPOSIT;
        if (maxD < minP) return;
        uint256 amount = clampBetween(amountSeed, minP, maxD);
        if (r.lending && _previewMint(r.handler, amount, rate(r.handler)) == 0) return;
        uint256 period = dcaManager.getMinPurchasePeriod();
        bool ok;
        bytes memory err;
        vm.prank(owner);
        try dcaManager.createDcaSchedule(r.token, amount, minP, period, r.routeIndex) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        if (ok) {
            _trackSchedule(r.token, uint64(dcaManager.getSchedulesCreatedCount()), owner, r.routeIndex);
            _ghostAddShareSlack(owner, r.handler, 1);
        }
        property_windowGatesGuardedCalls(OP_CREATE, ok, err, dcaManager.getUserMutationsAllowedFromBlock());
    }

    function _scenarioTopUp(Route memory r, uint64 id, IDcaManager.DcaSchedule memory d) internal {
        if (!r.lending) return;
        uint256 accrued = dcaManager.getAccruedInterest(d.user, r.token, r.routeIndex);
        uint256 needed = d.purchaseAmount - (d.tokenBalance % d.purchaseAmount);
        if (accrued == 0 || needed > accrued) return;
        bool ok;
        bytes memory err;
        vm.prank(d.user);
        try dcaManager.topUpFromInterest(r.token, id, needed) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        if (!ok) property_topUpQuoteSafe(err);
        property_windowGatesGuardedCalls(OP_TOPUP, ok, err, dcaManager.getUserMutationsAllowedFromBlock());
    }

    function _scenarioGuarded(Route memory r, uint64 id, IDcaManager.DcaSchedule memory d, uint256 which) internal {
        uint8 op;
        bool ok;
        bytes memory err;
        which %= 3;
        vm.prank(d.user);
        if (which == 0) {
            op = OP_UPDATE_AMOUNT;
            try dcaManager.updatePurchaseAmount(r.token, id, d.purchaseAmount) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 1) {
            op = OP_WITHDRAW;
            try dcaManager.withdrawToken(r.token, id, 1) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            op = OP_PAUSE;
            try dcaManager.setSchedulePaused(r.token, id, true) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        }
        property_windowGatesGuardedCalls(op, ok, err, dcaManager.getUserMutationsAllowedFromBlock());
    }

    /// @dev SP-62 exit: every step must succeed; a failure fails the property and aborts.
    function _exitAll() internal returns (bool) {
        for (uint256 guard; guard < MAX_TRACKED; guard++) {
            uint256 idx = _pickOwnedSchedule(actor, 0);
            if (idx == type(uint256).max) break;
            TrackedSchedule memory s = trackedSchedules[idx];
            uint256 balance = dcaManager.getDcaSchedule(s.token, s.scheduleId).tokenBalance;
            uint256 index = _scheduleIdIndex(s);
            vm.prank(actor);
            try dcaManager.deleteDcaSchedule(s.token, s.scheduleId, index) {
                _untrackSchedule(s.token, s.scheduleId);
                if (balance > 0) _ghostAddShareSlack(actor, _routeOf(s.token, s.routeIndex).handler, 1);
            } catch (bytes memory err) {
                _failWithErr("SP-62: delete reverted during a full exit", err);
                return false;
            }
        }
        uint256 lendingMask;
        for (uint256 k; k < routes.length; k++) {
            if (routes[k].lending) lendingMask |= 1 << k;
        }
        (address[] memory lt, uint256[] memory lr) = _routePairs(lendingMask);
        vm.prank(actor);
        try dcaManager.withdrawAllAccumulatedInterest(lt, lr) {
            for (uint256 k; k < routes.length; k++) {
                if (routes[k].lending) _ghostAddShareSlack(actor, routes[k].handler, 1);
            }
        } catch (bytes memory err) {
            _failWithErr("SP-62: interest withdrawal reverted during a full exit", err);
            return false;
        }
        (address[] memory allTokens, uint256[] memory allRoutes) = _routePairs(0);
        vm.prank(actor);
        try dcaManager.withdrawAllAccumulatedRbtc(allTokens, allRoutes) {}
        catch (bytes memory err) {
            _failWithErr("SP-62: rBTC claim reverted during a full exit", err);
            return false;
        }
        return true;
    }

    /// @dev SP-62 re-entry: a fresh create on route k must succeed when the pair is open and the cap allows it.
    function _reenter(uint256 k, uint256 depositSeed) internal {
        Route memory r = routes[k];
        if (trackedSchedules.length >= MAX_TRACKED || dcaManager.getMaxSchedulesPerToken() == 0) return;
        if (operationsAdmin.areDepositsPaused(r.token, r.routeIndex)) return;
        uint256 minP = dcaManager.getTokenMinPurchaseAmount(r.token);
        uint256 bal = MockStablecoin(r.token).balanceOf(actor);
        uint256 maxD = bal < MAX_DEPOSIT ? bal : MAX_DEPOSIT;
        if (maxD < minP) return;
        uint256 d = clampBetween(depositSeed, minP, maxD);
        if (r.lending && _previewMint(r.handler, d, rate(r.handler)) == 0) return;
        uint256 v0 = r.lending ? V(actor, r.handler) : 0;
        uint256 period = dcaManager.getMinPurchasePeriod();
        vm.prank(actor);
        try dcaManager.createDcaSchedule(r.token, d, d, period, r.routeIndex) {
            _trackSchedule(r.token, uint64(dcaManager.getSchedulesCreatedCount()), actor, r.routeIndex);
            if (r.lending) {
                _ghostAddShareSlack(actor, r.handler, 1);
                property_reenterOnEqualTerms(k, d, v0);
            }
        } catch (bytes memory err) {
            _failWithErr("SP-62: re-entry create reverted after a full exit", err);
        }
    }

    /// @dev An actor, the initial collector, or the current collector of a seeded handler.
    function _claimant(uint256 seed) internal view returns (address) {
        uint256 i = seed % 5;
        if (i < 3) return actors[i];
        if (i == 3) return feeCollector;
        return IPurchaseFees(routes[(seed >> 8) % routes.length].handler).getFeeCollector();
    }

    /// @dev Re-entry targets (H7): 1 claim again, 2 deposit, 3 withdraw, 4 create, 5 handler claim directly.
    function _armReentry(ReentrantActor ra, uint256 mode, address[] memory tokens, uint256[] memory routeIndexes)
        internal
    {
        address target = address(dcaManager);
        bytes memory data;
        uint256 idx = _pickOwnedSchedule(address(ra), 0);
        address token = idx == type(uint256).max ? address(doc) : trackedSchedules[idx].token;
        uint64 id = idx == type(uint256).max ? 1 : trackedSchedules[idx].scheduleId;
        if (mode == 1) {
            data = abi.encodeCall(dcaManager.withdrawAllAccumulatedRbtc, (tokens, routeIndexes));
        } else if (mode == 2) {
            data = abi.encodeCall(dcaManager.depositToken, (token, id, 1));
        } else if (mode == 3) {
            data = abi.encodeCall(dcaManager.withdrawToken, (token, id, 1));
        } else if (mode == 4) {
            uint256 minP = dcaManager.getTokenMinPurchaseAmount(address(doc));
            data = abi.encodeCall(
                dcaManager.createDcaSchedule, (address(doc), minP, minP, dcaManager.getMinPurchasePeriod(), IDLE_ROUTE)
            );
        } else {
            target = routes[0].handler;
            data = abi.encodeCall(IPurchaseRbtc.withdrawAccumulatedRbtc, (address(ra)));
        }
        ra.arm(uint8(mode), target, data);
    }

    /// @dev Actors, the initial collector, the owner, or either swapper key (skipped by the caller if allowlisted).
    function _impersonator(uint256 seed) internal view returns (address) {
        uint256 i = seed % 7;
        if (i < 3) return actors[i];
        if (i == 3) return feeCollector;
        if (i == 4) return admin;
        return swappers[i - 5];
    }

    function _allowedPathIdx(address h) internal view returns (uint256) {
        return IPurchaseUniswap(h).isPurchasePathAllowed(keccak256(_dexPath(0))) ? 0 : 1;
    }

    /// @dev Components of harness path 0 (direct pool) or 1 (via USDT0).
    function _pathParts(uint256 which) internal view returns (address[] memory tokens, uint24[] memory fees) {
        if (which == 0) {
            tokens = new address[](0);
            fees = new uint24[](1);
            fees[0] = DEFAULT_POOL_FEE;
        } else {
            tokens = new address[](1);
            tokens[0] = address(usdt0);
            fees = new uint24[](2);
            fees[0] = ALT_POOL_FEE;
            fees[1] = DEFAULT_POOL_FEE;
        }
    }

    function _directBatch(address h, address victim, uint256 amount) internal returns (bool ok, bytes memory err) {
        address[] memory buyers = new address[](1);
        buyers[0] = victim;
        uint64[] memory ids = new uint64[](1);
        ids[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(actor);
        try IPurchaseRbtc(h).batchBuyRbtc(buyers, ids, amounts, 0, 0) {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _foreignCall(uint8 which, TrackedSchedule memory s, uint256 amount)
        internal
        returns (bool ok, bytes memory err)
    {
        uint256 victimIdx = _scheduleIdIndex(s);
        uint256 period = dcaManager.getMinPurchasePeriod();
        vm.prank(actor);
        if (which == 0) {
            try dcaManager.depositToken(s.token, s.scheduleId, amount) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 1) {
            try dcaManager.withdrawToken(s.token, s.scheduleId, amount) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 2) {
            try dcaManager.withdrawTokenAndInterest(s.token, s.scheduleId, amount) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 3) {
            try dcaManager.deleteDcaSchedule(s.token, s.scheduleId, victimIdx) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 4) {
            try dcaManager.deleteDcaSchedule(s.token, s.scheduleId, 0) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 5) {
            try dcaManager.updatePurchaseAmount(s.token, s.scheduleId, amount) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 6) {
            try dcaManager.updatePurchasePeriod(s.token, s.scheduleId, period) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 7) {
            try dcaManager.setSchedulePaused(s.token, s.scheduleId, amount % 2 == 0) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            try dcaManager.topUpFromInterest(s.token, s.scheduleId, amount) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        }
    }

    /// @dev Handler setters 0..7 called by a non-owner `c`.
    function _handlerSetterCall(uint8 which, address c, address h, address dex, uint256 arg)
        internal
        returns (bool ok, bytes memory err)
    {
        (address[] memory tokens, uint24[] memory fees) = _pathParts(arg % 2);
        vm.prank(c);
        if (which == 0) {
            try IPurchaseFees(h).setFeeCollector(c) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 1) {
            try IPurchaseFees(h).setFeeRateParams(0, 0, 0) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 2) {
            try IPurchaseUniswap(dex).setMocOracle(address(mocOracleAlt)) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 3) {
            try IPurchaseUniswap(dex).setAmountOutMinimumPercent(1 ether) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 4) {
            try IPurchaseUniswap(dex).setAmountOutMinimumSafetyCheck(0) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 5) {
            try IPurchaseUniswap(dex).setPurchasePathAllowed(tokens, fees, (arg >> 1) % 2 == 0) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 6) {
            try Ownable2Step(h).transferOwnership(c) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            try Ownable2Step(dex).transferOwnership(c) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        }
    }

    /// @dev DcaManager / OperationsAdmin setters 8..15 called by a non-owner `c`; 16 = owner renounce.
    function _coreSetterCall(uint8 which, address c, address h, uint256 arg)
        internal
        returns (bool ok, bytes memory err)
    {
        address renounceTarget = arg % 3 == 0 ? address(dcaManager) : (arg % 3 == 1 ? address(operationsAdmin) : h);
        vm.prank(c);
        if (which == 8) {
            try dcaManager.setMinPurchasePeriod(1 days) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 9) {
            try dcaManager.setMaxSchedulesPerToken(arg % 100) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 10) {
            try dcaManager.setTokenMinPurchaseAmount(address(doc), 1) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 11) {
            try operationsAdmin.addSwapper(c) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 12) {
            try operationsAdmin.revokeSwapper(swappers[arg % swappers.length]) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 13) {
            try operationsAdmin.setDepositsPaused(address(doc), IDLE_ROUTE, true) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 14) {
            try operationsAdmin.registerRoute(3 + arg % 5, true) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 15) {
            try operationsAdmin.assignHandler(address(usdrif), SOVRYN_ROUTE, h) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            try Ownable2Step(renounceTarget).renounceOwnership() {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        }
    }
}
