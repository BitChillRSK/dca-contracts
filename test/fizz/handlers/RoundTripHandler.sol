// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {DcaManagerHandler} from "./DcaManagerHandler.sol";

/// @notice Mandatory C2 round-trip handlers (plan H10): deposit⇄withdraw cycles, create+delete, and a
///         repeated interest withdrawal, each run inside one call so the rate cannot move between steps.
/// @dev Calls `dcaManager` directly with single-shot `vm.prank(actor)` per step (plan gotcha 3); the
///      wrappers are not nested. A failure on the first step aborts with nothing changed. A failure on a
///      later step is checked against SP-12 and then reverts the whole call, so no partial trip survives
///      to desynchronise the ghosts.
abstract contract RoundTripHandler is DcaManagerHandler {
    /// @dev SP-19, SP-20, SP-21, SP-22.
    function roundTrip_depositWithdraw(uint256 scheduleSeed, uint256 amount, uint8 cycles, bool withdrawFirst) public {
        if (_windowLive()) return; // withdrawToken is window-guarded
        uint256 idx = _pickOwnedSchedule(actor, scheduleSeed);
        if (idx == type(uint256).max) return;
        TrackedSchedule memory s = trackedSchedules[idx];
        uint256 k = _routeKOf(s.token, s.routeIndex);
        if (k >= 5 || operationsAdmin.areDepositsPaused(s.token, s.routeIndex)) return;
        RoundTrip memory rt = _rtStart(s.token, s.scheduleId, k, withdrawFirst);
        rt.cycles = 1 + uint256(cycles) % 4;
        uint256 cap = rt.c0 / rt.cycles;
        if (cap > MAX_DEPOSIT) cap = MAX_DEPOSIT;
        if (withdrawFirst && rt.tb0 < cap) cap = rt.tb0;
        if (cap == 0) return;
        rt.amount = clampBetween(amount, 1, cap);
        // A deposit the venue mints zero shares for reverts by design (LendingProtocolDepositFailed).
        if (rt.lending && _previewMint(rt.h, rt.amount, rt.r) == 0) return;
        if (!_rtCycles(rt)) return;
        if (rt.lending) {
            _ghostAddShareSlack(actor, rt.h, 2 * rt.cycles);
            property_rtLendingNoValue(rt);
            property_rtNoFreeShares(rt);
            property_rtMaxOneShareLoss(rt);
        } else {
            property_rtIdleExact(rt);
        }
    }

    /// @dev SP-23. The schedule is tracked and untracked so GL-11 and the nonce stay in step.
    function roundTrip_createDelete(
        uint256 routeSeed,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 periodDays
    ) public {
        if (_windowLive() || trackedSchedules.length >= MAX_TRACKED) return;
        uint256 k = routeSeed % routes.length;
        Route memory r = routes[k];
        if (operationsAdmin.areDepositsPaused(r.token, r.routeIndex)) return;
        uint256 minP = dcaManager.getTokenMinPurchaseAmount(r.token);
        uint256 bal = MockStablecoin(r.token).balanceOf(actor);
        uint256 maxD = bal < MAX_DEPOSIT ? bal : MAX_DEPOSIT;
        if (maxD < minP) return;
        depositAmount = clampBetween(depositAmount, minP, maxD);
        purchaseAmount = clampBetween(purchaseAmount, minP, depositAmount);
        uint256 period = clampBetween(periodDays, _minPeriodDays(), MAX_PERIOD_DAYS) * 1 days;
        if (r.lending && _previewMint(r.handler, depositAmount, rate(r.handler)) == 0) return;
        CreateDeleteTrip memory cd = _cdStart(k);
        vm.prank(actor);
        try dcaManager.createDcaSchedule(r.token, depositAmount, purchaseAmount, period, r.routeIndex) {}
        catch {
            return;
        }
        uint64 id = uint64(dcaManager.getSchedulesCreatedCount());
        _trackSchedule(r.token, id, actor, r.routeIndex);
        if (r.lending) cd.clamped = V(actor, r.handler) < depositAmount;
        vm.prank(actor);
        try dcaManager.deleteDcaSchedule(r.token, id, cd.ids0.length) {}
        catch (bytes memory err) {
            property_noBurnMismatchRevert(err);
            revert("roundTrip_createDelete: delete after create failed");
        }
        _untrackSchedule(r.token, id);
        _ghostAddShareSlack(actor, r.handler, 2);
        property_rtCreateDelete(cd);
    }

    /// @dev SP-15: interest withdrawal leaves zero interest; a second one in the same block is a no-op.
    function roundTrip_interestTwice(uint256 routeMask) public {
        if (_windowLive()) return; // withdrawAllAccumulatedInterest is window-guarded
        (address[] memory tokens, uint256[] memory routeIndexes) = _routePairs(routeMask);
        uint256 mask = _pairMask(tokens, routeIndexes);
        vm.prank(actor);
        try dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes) {}
        catch (bytes memory err) {
            property_noBurnMismatchRevert(err);
            return;
        }
        uint256[5] memory sharesBefore;
        for (uint256 k; k < 5; k++) {
            if (!routes[k].lending) continue;
            sharesBefore[k] = shares(actor, routes[k].handler);
            if ((mask >> k) & 1 == 1) _ghostAddShareSlack(actor, routes[k].handler, 1);
        }
        property_interestIdempotent(actor, mask);
        uint256[2] memory wallets = [doc.balanceOf(actor), usdrif.balanceOf(actor)];
        bool ok;
        bytes memory err2;
        vm.prank(actor);
        try dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes) {
            ok = true;
        } catch (bytes memory e) {
            err2 = e;
        }
        property_interestSecondCallNoop(ok, err2, wallets, sharesBefore);
    }

    // ―――――――――――――――――――――――― Helpers ―――――――――――――――――――――――――――

    function _rtStart(address token, uint64 id, uint256 k, bool withdrawFirst)
        internal
        view
        returns (RoundTrip memory rt)
    {
        Route storage r = routes[k];
        rt.token = token;
        rt.id = id;
        rt.k = k;
        rt.h = r.handler;
        rt.lending = r.lending;
        rt.withdrawFirst = withdrawFirst;
        rt.c0 = MockStablecoin(token).balanceOf(actor);
        rt.h0 = MockStablecoin(token).balanceOf(r.handler);
        rt.tb0 = dcaManager.getDcaSchedule(token, id).tokenBalance;
        if (r.lending) {
            rt.s0 = shares(actor, r.handler);
            rt.r = rate(r.handler);
            (rt.i0, rt.iFailed) = _interest(actor, k);
        }
    }

    function _cdStart(uint256 k) internal view returns (CreateDeleteTrip memory cd) {
        Route storage r = routes[k];
        cd.token = r.token;
        cd.k = k;
        cd.h = r.handler;
        cd.lending = r.lending;
        cd.ids0 = _idsOf(actor, r.token);
        cd.c0 = MockStablecoin(r.token).balanceOf(actor);
        cd.h0 = MockStablecoin(r.token).balanceOf(r.handler);
        if (r.lending) {
            cd.s0 = shares(actor, r.handler);
            cd.r = rate(r.handler);
            (cd.i0, cd.iFailed) = _interest(actor, k);
        }
    }

    function _rtCycles(RoundTrip memory rt) internal returns (bool) {
        for (uint256 c; c < rt.cycles; c++) {
            if (rt.withdrawFirst) {
                _noteClamp(rt);
                if (!_rtStep(rt, false, c)) return false;
                if (!_rtStep(rt, true, c)) return false;
            } else {
                if (!_rtStep(rt, true, c)) return false;
                _noteClamp(rt);
                if (!_rtStep(rt, false, c)) return false;
            }
        }
        return true;
    }

    /// @dev A withdrawal is clamped when the actor's floored share value is below the request.
    function _noteClamp(RoundTrip memory rt) internal view {
        if (rt.lending && shares(actor, rt.h) * rt.r / D(rt.h) < rt.amount) rt.clamped = true;
    }

    /// @dev One deposit (`deposit`) or withdrawal. Returns false only when the very first step fails.
    function _rtStep(RoundTrip memory rt, bool deposit, uint256 cycle) internal returns (bool) {
        bool first = cycle == 0 && deposit != rt.withdrawFirst;
        bool ok;
        bytes memory err;
        vm.prank(actor);
        if (deposit) {
            try dcaManager.depositToken(rt.token, rt.id, rt.amount) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            try dcaManager.withdrawToken(rt.token, rt.id, rt.amount) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        }
        if (ok) return true;
        if (!deposit) property_noBurnMismatchRevert(err);
        if (first) return false;
        revert("roundTrip: later step failed, partial trip undone");
    }
}
