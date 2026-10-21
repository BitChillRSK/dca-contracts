// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "./Snapshots.sol";
import {Math as OzMath} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PropertiesAsserts} from "./utils/PropertiesAsserts.sol";
import {IStablecoinSource} from "src/interfaces/IStablecoinSource.sol";
import {IDcaManagerAccessControl} from "src/interfaces/IDcaManagerAccessControl.sol";

/// @notice Contains the functions that check the properties (invariants)
abstract contract Properties is PropertiesAsserts, Snapshots {
    // ―――――――――――――――――――― Global properties ―――――――――――――――――――――
    // These properties must always hold after any function call.
    // They MUST BE PUBLIC so that fuzzers can find and call them.
    //
    // Wiring these globals depend on (Base.sol hooks; handler-side calls belong to 7B, plan §9):
    //   GL-02 `_ghostBatchRows(h, rows)` per handler after every successful batch / across call.
    //   GL-02/03 `_ghostDonateEth(h, amt)`; GL-05/06 `_ghostDonateStable(h, amt)` in the donation handlers.
    //   GL-10 `_ghostAddShareSlack(a, h, ops)` on every share-touching op; GL-10/24 `_ghostSovrynPriceMoved`.
    //   GL-17 `_ghostBuy(token, id)` per bought row and `_ghostPeriodEdit(token, id)` per period edit.
    //   GL-18 `_ghostWindowActivated()` after activation; `_ghostWindowBatch` / `_ghostWindowShareBurn`
    //         for batches run inside the window. Without the activation hook GL-18 is skipped, not failed.
    //   GL-25 `_ghostSwapperSetChanged()` after addSwapper / revokeSwapper.
    //   GL-11/16 need every successful create / delete to go through `_trackSchedule` / `_untrackSchedule`.
    //   GL-12 needs no `vm.deal` after setup; GL-13 needs no stablecoin minted to an address outside
    //         `_sumKnownHolders`.
    // Underflow is silent under Medusa (`failOnArithmeticUnderflow: false`): every subtraction below is
    // preceded by an order check or written so it cannot underflow.

    /// @notice GL-01: on every handler, held rBTC covers the sum of all accounts' claimable rBTC
    function property_rbtcSolvency() public {
        for (uint256 k; k < routes.length; k++) {
            address h = routes[k].handler;
            gte(rbtcAsset(h), _sumClaims(h), "GL-01: handler rBTC below the claimable book");
        }
    }

    /// @notice GL-02: rBTC asset == claimable book + native donations (MoC) + at most one wei per batch row
    function property_rbtcBooksExact() public {
        for (uint256 k; k < routes.length; k++) {
            address h = routes[k].handler;
            uint256 floorAmount = _sumClaims(h) + (isDex(h) ? 0 : ghosts.ethDonated[h]);
            uint256 asset = rbtcAsset(h);
            gte(asset, floorAmount, "GL-02: rBTC asset below book + donations");
            lte(asset, floorAmount + ghosts.rbtcDustBudget[h], "GL-02: unallocated rBTC beyond one wei per batch row");
        }
    }

    /// @notice GL-03: Dex handlers hold no native rBTC beyond donations; MoC handlers hold no WRBTC
    function property_rbtcAssetSplit() public {
        for (uint256 k; k < routes.length; k++) {
            address h = routes[k].handler;
            if (isDex(h)) {
                eq(h.balance, ghosts.ethDonated[h], "GL-03: native rBTC stuck on a Dex handler");
            } else {
                eq(wrbtc.balanceOf(h), 0, "GL-03: WRBTC on a MoC handler");
            }
        }
    }

    /// @notice GL-04: each idle handler's stablecoin covers the route's total nominal principal
    function property_idleCashCoversPrincipal() public {
        (uint256[5] memory TB, bool failed) = _routePrincipal();
        t(!failed, "GL-04: tracked schedule unreadable");
        for (uint256 k; k < routes.length; k++) {
            Route storage r = routes[k];
            if (r.lending) continue;
            gte(MockStablecoin(r.token).balanceOf(r.handler), TB[k], "GL-04: idle cash below route principal");
        }
    }

    /// @notice GL-05: each idle handler's stablecoin == route principal + stray donations
    function property_idleCashExact() public {
        (uint256[5] memory TB, bool failed) = _routePrincipal();
        t(!failed, "GL-05: tracked schedule unreadable");
        for (uint256 k; k < routes.length; k++) {
            Route storage r = routes[k];
            if (r.lending) continue;
            eq(
                MockStablecoin(r.token).balanceOf(r.handler),
                TB[k] + ghosts.stableDonated[r.handler],
                "GL-05: idle cash != route principal + donations"
            );
        }
    }

    /// @notice GL-06: a lending handler keeps no raw stablecoin other than stray donations
    function property_lendingNoRawStablecoin() public {
        for (uint256 k; k < routes.length; k++) {
            Route storage r = routes[k];
            if (!r.lending) continue;
            eq(
                MockStablecoin(r.token).balanceOf(r.handler),
                ghosts.stableDonated[r.handler],
                "GL-06: stablecoin stranded on a lending handler"
            );
        }
    }

    /// @notice GL-07: Σ accounts' virtual shares <= the handler's receipt shares
    function property_virtualSharesBacked() public {
        for (uint256 k; k < routes.length; k++) {
            if (!routes[k].lending) continue;
            address h = routes[k].handler;
            lte(_sumShares(h), receipt(h), "GL-07: virtual shares exceed the handler's receipt shares");
        }
    }

    /// @notice GL-08: Σ accounts' virtual shares == the handler's receipt shares
    function property_virtualSharesExact() public {
        for (uint256 k; k < routes.length; k++) {
            if (!routes[k].lending) continue;
            address h = routes[k].handler;
            eq(_sumShares(h), receipt(h), "GL-08: virtual shares != the handler's receipt shares");
        }
    }

    /// @notice GL-09: quoted accrued interest == max(0, share value - live principal) per actor and lending route
    function property_accruedInterestIdentity() public {
        (uint256[5][3] memory L, bool failed) = _principalTable();
        t(!failed, "GL-09: tracked schedule unreadable");
        for (uint256 a; a < 3; a++) {
            for (uint256 k; k < routes.length; k++) {
                if (!routes[k].lending) continue;
                (uint256 quoted, bool readFailed) = _interest(actors[a], k);
                t(!readFailed, "GL-09: getAccruedInterest reverted");
                uint256 v = V(actors[a], routes[k].handler);
                uint256 expected = v > L[a][k] ? v - L[a][k] : 0;
                eq(quoted, expected, "GL-09: accrued interest != share value - live principal");
            }
        }
    }

    /// @notice GL-10: while value per share never fell, principal <= share value + per-op rounding slack
    function property_principalBackedNoLoss() public {
        (uint256[5][3] memory L, bool failed) = _principalTable();
        t(!failed, "GL-10: tracked schedule unreadable");
        for (uint256 a; a < 3; a++) {
            for (uint256 k; k < routes.length; k++) {
                if (!routes[k].lending) continue;
                address h = routes[k].handler;
                if (isSov(h) && ghosts.sovrynPriceEverFell) continue;
                lte(
                    L[a][k],
                    V(actors[a], h) + ghosts.shareSlack[actors[a]][h],
                    "GL-10: principal not backed by share value beyond rounding slack"
                );
            }
        }
    }

    /// @notice GL-11: nonce == creates, live == creates - deletes, id lists hold exactly the live schedules
    function property_scheduleCounts() public {
        eq(dcaManager.getSchedulesCreatedCount(), ghosts.schedulesCreated, "GL-11: nonce != successful creates");
        gte(ghosts.schedulesCreated, ghosts.schedulesDeleted, "GL-11: more deletes than creates");
        if (ghosts.schedulesCreated >= ghosts.schedulesDeleted) {
            eq(
                trackedSchedules.length,
                ghosts.schedulesCreated - ghosts.schedulesDeleted,
                "GL-11: live schedules != creates - deletes"
            );
        }
        TrackedSchedule[] memory tracked = trackedSchedules;
        address[4] memory accts = _accounts();
        uint256 listed;
        for (uint256 a; a < 4; a++) {
            listed += _checkIdList(accts[a], address(doc), tracked);
            listed += _checkIdList(accts[a], address(usdrif), tracked);
        }
        eq(listed, tracked.length, "GL-11: listed ids != live schedules");
        for (uint256 i; i < tracked.length; i++) {
            try dcaManager.getDcaSchedule(tracked[i].token, tracked[i].scheduleId) returns (
                IDcaManager.DcaSchedule memory d
            ) {
                t(d.user == tracked[i].owner, "GL-11: live schedule owner changed");
                eq(uint256(d.routeIndex), tracked[i].routeIndex, "GL-11: live schedule route changed");
            } catch {
                t(false, "GL-11: live schedule unreadable");
            }
        }
    }

    /// @notice GL-12: native rBTC is conserved across accounts, handlers, MoC proxy, router and WRBTC
    function property_nativeConservation() public {
        eq(_nativeWorldTotal(), ghosts.nativeTotal, "GL-12: native rBTC left the closed harness world");
    }

    /// @notice GL-13: DOC/USDRIF supply == known holders; DcaManager and OperationsAdmin hold nothing
    function property_stablecoinConservation() public {
        eq(doc.totalSupply(), _sumKnownHolders(doc), "GL-13: DOC held outside the known holders");
        eq(usdrif.totalSupply(), _sumKnownHolders(usdrif), "GL-13: USDRIF held outside the known holders");
        address[2] memory core = [address(dcaManager), address(operationsAdmin)];
        for (uint256 i; i < 2; i++) {
            eq(doc.balanceOf(core[i]), 0, "GL-13: manager or admin contract holds DOC");
            eq(usdrif.balanceOf(core[i]), 0, "GL-13: manager or admin contract holds USDRIF");
            eq(wrbtc.balanceOf(core[i]), 0, "GL-13: manager or admin contract holds WRBTC");
            eq(core[i].balance, 0, "GL-13: manager or admin contract holds native rBTC");
        }
    }

    /// @notice GL-14: the market's valuation of each lending position covers Σ the values of users' shares
    function property_marketValueCoversUserValues() public {
        address[4] memory accts = _accounts();
        for (uint256 k; k < routes.length; k++) {
            if (!routes[k].lending) continue;
            address h = routes[k].handler;
            uint256 r = rate(h);
            uint256 d = D(h);
            uint256 sumValue;
            for (uint256 a; a < 4; a++) {
                sumValue += shares(accts[a], h) * r / d;
            }
            uint256 market = isLB(h) ? _aTokenOf(h).balanceOf(h) : sovrynIToken.assetBalanceOf(h);
            lte(sumValue, market, "GL-14: users' share values exceed the market's valuation");
        }
    }

    /// @notice GL-15: at the current rate, 1e18 and the token minimum each mint > 0 receipt shares
    function property_sharePreviewPositive() public {
        for (uint256 k; k < routes.length; k++) {
            if (!routes[k].lending) continue;
            address h = routes[k].handler;
            uint256 r = rate(h);
            uint256 minAmount = dcaManager.getTokenMinPurchaseAmount(routes[k].token);
            gt(_previewMint(h, 1e18, r), 0, "GL-15: a 1e18 deposit previews zero receipt shares");
            if (minAmount * D(h) >= r) {
                gt(_previewMint(h, minAmount, r), 0, "GL-15: a viable minimum deposit previews zero receipt shares");
            }
        }
    }

    /// @notice GL-16: deleted ids stay retired; no id list holds a deleted id or an id above the nonce
    function property_retiredIdsStayDead() public {
        uint256 len = ghosts.deletedIds.length;
        uint256 start = len > DELETED_TAIL ? len - DELETED_TAIL : 0;
        uint64[] memory tail = new uint64[](len - start);
        for (uint256 i = start; i < len; i++) {
            uint64 id = ghosts.deletedIds[i];
            tail[i - start] = id;
            try dcaManager.getDcaSchedule(ghosts.deletedTokens[i], id) {
                t(false, "GL-16: deleted schedule readable again");
            } catch (bytes memory err) {
                t(
                    _errSelector(err) == IDcaManager.DcaManager__InexistentSchedule.selector,
                    "GL-16: deleted key reverts with an unexpected error"
                );
            }
        }
        uint256 nonce = dcaManager.getSchedulesCreatedCount();
        address[4] memory accts = _accounts();
        for (uint256 a; a < 4; a++) {
            _checkListedIdsLive(accts[a], address(doc), nonce, tail);
            _checkListedIdsLive(accts[a], address(usdrif), nonce, tail);
        }
    }

    /// @notice GL-17: a schedule buys at most once per UTC day plus once per same-day period edit
    function property_oneBuyPerDay() public {
        uint256 today = _today();
        uint256 len = trackedSchedules.length;
        for (uint256 i; i < len; i++) {
            address token = trackedSchedules[i].token;
            uint64 id = trackedSchedules[i].scheduleId;
            if (ghosts.buyDay[token][id] != today) continue;
            uint256 edits = ghosts.editDay[token][id] == today ? ghosts.editsOnDay[token][id] : 0;
            lte(ghosts.buysOnDay[token][id], 1 + edits, "GL-17: extra same-day purchase");
        }
    }

    /// @notice GL-18: inside a live window, activation-time schedules are frozen except batch debits
    function property_windowFreeze() public {
        _checkWindowFreeze();
    }

    /// @notice GL-19: route handlers, classes, handler stablecoin/manager and live schedules' pairs never change
    function property_routesFixed() public {
        t(
            operationsAdmin.getRouteClass(IDLE_ROUTE) == IOperationsAdmin.RouteClass.Idle,
            "GL-19: route 0 is no longer Idle"
        );
        for (uint256 k; k < routes.length; k++) {
            Route storage r = routes[k];
            t(operationsAdmin.getHandler(r.token, r.routeIndex) == r.handler, "GL-19: assigned handler replaced");
            IOperationsAdmin.RouteClass expected =
                r.lending ? IOperationsAdmin.RouteClass.Lending : IOperationsAdmin.RouteClass.Idle;
            t(operationsAdmin.getRouteClass(r.routeIndex) == expected, "GL-19: route class changed");
            t(address(IStablecoinSource(r.handler).i_stablecoin()) == r.token, "GL-19: handler stablecoin changed");
            t(
                IDcaManagerAccessControl(r.handler).i_dcaManager() == address(dcaManager),
                "GL-19: handler manager changed"
            );
        }
        uint256 len = trackedSchedules.length;
        for (uint256 i; i < len; i++) {
            TrackedSchedule storage s = trackedSchedules[i];
            t(_handlerOrZero(s.token, s.routeIndex) != address(0), "GL-19: live schedule on an unassigned pair");
        }
    }

    /// @notice GL-20: a live schedule's anchor is 0 or a UTC midnight no later than today
    function property_anchorOnGrid() public {
        uint256 today = _today();
        uint256 len = trackedSchedules.length;
        for (uint256 i; i < len; i++) {
            TrackedSchedule storage s = trackedSchedules[i];
            try dcaManager.getDcaSchedule(s.token, s.scheduleId) returns (IDcaManager.DcaSchedule memory d) {
                uint256 anchor = d.cadenceAnchor;
                if (anchor == 0) continue;
                eq(anchor % 1 days, 0, "GL-20: anchor off the UTC-midnight grid");
                lte(anchor, today, "GL-20: anchor later than today");
            } catch {
                t(false, "GL-20: live schedule unreadable");
            }
        }
    }

    /// @notice GL-21: live schedule fields and protocol settings stay in their domains
    function property_scheduleDomains() public {
        uint256 len = trackedSchedules.length;
        for (uint256 i; i < len; i++) {
            TrackedSchedule storage s = trackedSchedules[i];
            try dcaManager.getDcaSchedule(s.token, s.scheduleId) returns (IDcaManager.DcaSchedule memory d) {
                gt(uint256(d.purchaseAmount), 0, "GL-21: zero purchase amount");
                gte(uint256(d.purchasePeriod), 1 days, "GL-21: purchase period below one day");
                eq(uint256(d.purchasePeriod) % 1 days, 0, "GL-21: purchase period not whole days");
                t(d.user != address(0), "GL-21: live schedule without owner");
                t(_handlerOrZero(s.token, d.routeIndex) != address(0), "GL-21: schedule route not assigned");
            } catch {
                t(false, "GL-21: live schedule unreadable");
            }
        }
        uint256 minPeriod = dcaManager.getMinPurchasePeriod();
        gte(minPeriod, 1 days, "GL-21: minimum period below one day");
        eq(minPeriod % 1 days, 0, "GL-21: minimum period not whole days");
        gt(dcaManager.getTokenMinPurchaseAmount(address(doc)), 0, "GL-21: DOC minimum is zero");
        gt(dcaManager.getTokenMinPurchaseAmount(address(usdrif)), 0, "GL-21: USDRIF minimum is zero");
    }

    /// @notice GL-22: each Dex handler's active path is allowlisted, a harness path, stablecoin → WRBTC
    function property_activePathAllowlisted() public {
        bytes32 path0 = keccak256(_dexPath(0));
        bytes32 path1 = keccak256(_dexPath(1));
        for (uint256 i; i < dexHandlers.length; i++) {
            address h = dexHandlers[i];
            bytes memory path = IPurchaseUniswap(h).getSwapPath();
            bytes32 pathHash = keccak256(path);
            t(IPurchaseUniswap(h).isPurchasePathAllowed(pathHash), "GL-22: active path not allowlisted");
            t(pathHash == path0 || pathHash == path1, "GL-22: active path is not one of the harness paths");
            (address first, address last) = _pathEnds(path);
            t(first == address(IStablecoinSource(h).i_stablecoin()), "GL-22: path does not start at the stablecoin");
            t(last == address(wrbtc), "GL-22: path does not end at WRBTC");
        }
    }

    /// @notice GL-23: fee settings, collectors, Dex floor settings and oracles stay in their domains
    function property_settingsDomains() public {
        for (uint256 k; k < routes.length; k++) {
            address h = routes[k].handler;
            IPurchaseFees.FeeSettings memory fs = IPurchaseFees(h).getFeeSettings();
            lte(uint256(fs.minFeeRate), uint256(fs.maxFeeRate), "GL-23: min fee rate above max");
            lte(uint256(fs.maxFeeRate), 500, "GL-23: max fee rate above the 5% cap");
            t(IPurchaseFees(h).getFeeCollector() != address(0), "GL-23: zero fee collector");
        }
        for (uint256 i; i < dexHandlers.length; i++) {
            IPurchaseUniswap u = IPurchaseUniswap(dexHandlers[i]);
            uint256 percent = u.getAmountOutMinimumPercent();
            lte(u.getAmountOutMinimumSafetyCheck(), percent, "GL-23: safety check above the floor percent");
            lte(percent, 1e18, "GL-23: floor percent above 100%");
            t(address(u.getMocOracle()) != address(0), "GL-23: zero MoC oracle");
        }
    }

    /// @notice GL-24: with no loss on a lending route, live principal there implies shares there
    function property_principalHasSharesNoLoss() public {
        (uint256[5][3] memory L, bool failed) = _principalTable();
        t(!failed, "GL-24: tracked schedule unreadable");
        bool sovrynNoLoss = !ghosts.sovrynPriceEverFell && sovrynIToken.getExitFeeBps() == 0;
        for (uint256 a; a < 3; a++) {
            for (uint256 k; k < routes.length; k++) {
                if (!routes[k].lending) continue;
                address h = routes[k].handler;
                if (isSov(h) && !sovrynNoLoss) continue;
                if (L[a][k] > 0) gt(shares(actors[a], h), 0, "GL-24: live principal with zero shares and no loss");
            }
        }
    }

    /// @notice GL-25: unlock is at most 5 blocks ahead, and at most 5 blocks after the allowlist emptied
    function property_windowBounded() public {
        uint256 unlock = dcaManager.getUserMutationsAllowedFromBlock();
        lte(unlock, block.number + WINDOW_BLOCKS, "GL-25: unlock block more than five blocks ahead");
        if (ghosts.allowlistEmpty) {
            lte(
                unlock,
                ghosts.allowlistEmptySince + WINDOW_BLOCKS,
                "GL-25: lock outlived the revocation of every swapper"
            );
        }
    }

    /// @notice GL-26: canActivateProtectedPurchaseWindow() == (block.number >= unlock)
    function property_canActivateSync() public {
        t(
            dcaManager.canActivateProtectedPurchaseWindow()
                == (block.number >= dcaManager.getUserMutationsAllowedFromBlock()),
            "GL-26: canActivate out of sync with the unlock block"
        );
    }

    /// @notice GL-27: swappers hold nothing; the owner gains no tokens and holds no claims or shares
    function property_privilegedHoldNothing() public {
        for (uint256 i; i < swappers.length; i++) {
            address sw = swappers[i];
            eq(doc.balanceOf(sw), 0, "GL-27: swapper holds DOC");
            eq(usdrif.balanceOf(sw), 0, "GL-27: swapper holds USDRIF");
            eq(usdt0.balanceOf(sw), 0, "GL-27: swapper holds USDT0");
            eq(wrbtc.balanceOf(sw), 0, "GL-27: swapper holds WRBTC");
            eq(sw.balance, 0, "GL-27: swapper holds native rBTC");
            _checkNoBook(sw, "GL-27: swapper holds a claim", "GL-27: swapper holds shares");
            _checkNoSchedules(sw, address(doc));
            _checkNoSchedules(sw, address(usdrif));
        }
        lte(doc.balanceOf(admin), ghosts.privBaseline[address(doc)], "GL-27: owner gained DOC");
        lte(usdrif.balanceOf(admin), ghosts.privBaseline[address(usdrif)], "GL-27: owner gained USDRIF");
        lte(usdt0.balanceOf(admin), ghosts.privBaseline[address(usdt0)], "GL-27: owner gained USDT0");
        lte(wrbtc.balanceOf(admin), ghosts.privBaseline[address(wrbtc)], "GL-27: owner gained WRBTC");
        _checkNoBook(admin, "GL-27: owner holds a claim", "GL-27: owner holds shares");
    }

    /// @notice GL-28: the read surface (schedule lists, rBTC/interest previews, handler getters) never reverts
    function property_previewsNeverRevert() public {
        address[4] memory accts = _accounts();
        for (uint256 a; a < 4; a++) {
            _checkAccountPreviews(accts[a]);
        }
        uint256 len = trackedSchedules.length;
        for (uint256 i; i < len; i++) {
            try dcaManager.getDcaSchedule(trackedSchedules[i].token, trackedSchedules[i].scheduleId) {}
            catch {
                t(false, "GL-28: live schedule unreadable");
            }
        }
        for (uint256 k; k < routes.length; k++) {
            _checkHandlerGetters(routes[k].handler, accts);
        }
    }

    /// @notice GL-29: a pair whose deposits are paused is an assigned pair
    function property_depositPauseOnlyAssigned() public {
        for (uint256 k; k < routes.length; k++) {
            _checkPauseAssigned(routes[k].token, routes[k].routeIndex);
        }
        // Pairs the harness never assigns.
        _checkPauseAssigned(address(usdrif), SOVRYN_ROUTE);
        _checkPauseAssigned(address(usdt0), IDLE_ROUTE);
        _checkPauseAssigned(address(doc), SOVRYN_ROUTE + 1);
    }

    // ――――――――――――――――― Global property helpers ――――――――――――――――――

    /// @notice GL-18 body (ST-11). `adv_protectedBatchScenario` may call it inline, after it has applied
    ///         the window batch hooks for any batch it ran.
    function _checkWindowFreeze() internal {
        uint256 unlock = dcaManager.getUserMutationsAllowedFromBlock();
        if (ghosts.winEpoch == 0 || block.number >= unlock || unlock != ghosts.winUnlock) return;
        uint256 epoch = ghosts.winEpoch;
        uint256 n = ghosts.winSnap.length;
        for (uint256 i; i < n; i++) {
            _checkFrozenSchedule(epoch, i);
        }
        address[4] memory accts = _accounts();
        for (uint256 k; k < routes.length; k++) {
            if (!routes[k].lending) continue;
            address h = routes[k].handler;
            for (uint256 a; a < 4; a++) {
                gte(
                    shares(accts[a], h) + ghosts.winShareBatchDebit[epoch][accts[a]][h],
                    ghosts.winShareSnap[epoch][accts[a]][h],
                    "GL-18: shares fell inside the window beyond batch burns"
                );
            }
        }
    }

    function _checkFrozenSchedule(uint256 epoch, uint256 i) private {
        address token = ghosts.winSnapToken[i];
        uint64 id = ghosts.winSnapId[i];
        IDcaManager.DcaSchedule memory snap = ghosts.winSnap[i];
        try dcaManager.getDcaSchedule(token, id) returns (IDcaManager.DcaSchedule memory d) {
            eq(uint256(d.purchaseAmount), uint256(snap.purchaseAmount), "GL-18: purchase amount changed in window");
            eq(uint256(d.purchasePeriod), uint256(snap.purchasePeriod), "GL-18: purchase period changed in window");
            t(d.paused == snap.paused, "GL-18: pause flag changed in window");
            t(d.user == snap.user, "GL-18: owner changed in window");
            eq(uint256(d.routeIndex), uint256(snap.routeIndex), "GL-18: route changed in window");
            gte(
                uint256(d.tokenBalance) + ghosts.winBatchDebit[epoch][token][id],
                uint256(snap.tokenBalance),
                "GL-18: balance fell inside the window beyond batch debits"
            );
        } catch {
            t(false, "GL-18: schedule live at activation vanished inside the window");
        }
    }

    function _sumClaims(address h) internal view returns (uint256 sum) {
        address[4] memory accts = _accounts();
        for (uint256 a; a < 4; a++) {
            sum += claim(accts[a], h);
        }
    }

    function _sumShares(address h) internal view returns (uint256 sum) {
        address[4] memory accts = _accounts();
        for (uint256 a; a < 4; a++) {
            sum += shares(accts[a], h);
        }
    }

    /// @dev Every address the harness lets hold DOC or USDRIF (GL-13).
    function _sumKnownHolders(MockStablecoin token) internal view returns (uint256 sum) {
        address[4] memory accts = _accounts();
        for (uint256 a; a < 4; a++) {
            sum += token.balanceOf(accts[a]);
        }
        for (uint256 k; k < routes.length; k++) {
            sum += token.balanceOf(routes[k].handler);
        }
        address[13] memory others = [
            address(layerBankATokenDoc),
            address(layerBankPoolDoc),
            address(layerBankATokenUsdrif),
            address(layerBankPoolUsdrif),
            address(sovrynIToken),
            address(mocProxy),
            address(swapRouter),
            admin,
            swappers[0],
            swappers[1],
            address(dcaManager),
            address(operationsAdmin),
            address(feeProbe)
        ];
        for (uint256 i; i < others.length; i++) {
            sum += token.balanceOf(others[i]);
        }
    }

    /// @dev Receipt shares the venue would mint for `amount` at rate `r` (FizzIToken floor; LayerBank half-up).
    function _previewMint(address h, uint256 amount, uint256 r) internal view returns (uint256) {
        if (r == 0) return 0;
        if (isSov(h)) return amount * 1e18 / r;
        return (amount * RAY + r / 2) / r;
    }

    /// @return The 4-byte selector of revert data, or 0 when shorter than 4 bytes.
    function _errSelector(bytes memory err) internal pure returns (bytes4) {
        if (err.length < 4) return bytes4(0);
        return bytes4(err);
    }

    /// @return first The first 20 bytes of a Uniswap path; last The final 20 bytes (zero if too short).
    function _pathEnds(bytes memory path) internal pure returns (address first, address last) {
        if (path.length < 40) return (address(0), address(0));
        assembly {
            first := shr(96, mload(add(path, 32)))
            last := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
        }
    }

    /// @dev GL-11: checks one (account, token) id list against the live set; returns its length.
    function _checkIdList(address account, address token, TrackedSchedule[] memory tracked)
        private
        returns (uint256 len)
    {
        try dcaManager.getDcaSchedules(account, token) returns (
            uint64[] memory ids, IDcaManager.DcaSchedule[] memory scheds
        ) {
            len = ids.length;
            for (uint256 i; i < len; i++) {
                t(scheds[i].user == account, "GL-11: listed schedule owned by someone else");
                _checkListedTracked(account, token, ids[i], scheds[i].routeIndex, tracked);
                for (uint256 j; j < i; j++) {
                    t(ids[j] != ids[i], "GL-11: duplicate id in a list");
                }
            }
        } catch {
            t(false, "GL-11: getDcaSchedules reverted");
        }
    }

    function _checkListedTracked(
        address account,
        address token,
        uint64 id,
        uint256 routeIndex,
        TrackedSchedule[] memory tracked
    ) private {
        for (uint256 k; k < tracked.length; k++) {
            if (tracked[k].token != token || tracked[k].scheduleId != id) continue;
            t(tracked[k].owner == account, "GL-11: listed under the wrong owner");
            eq(routeIndex, tracked[k].routeIndex, "GL-11: listed schedule on the wrong route");
            return;
        }
        t(false, "GL-11: listed id is not a live schedule");
    }

    /// @dev GL-16: every id listed for (account, token) is in [1, nonce] and not a retired id.
    function _checkListedIdsLive(address account, address token, uint256 nonce, uint64[] memory tail) private {
        try dcaManager.getDcaSchedules(account, token) returns (uint64[] memory ids, IDcaManager.DcaSchedule[] memory) {
            for (uint256 i; i < ids.length; i++) {
                t(ids[i] >= 1 && ids[i] <= nonce, "GL-16: listed id outside [1, nonce]");
                for (uint256 j; j < tail.length; j++) {
                    t(ids[i] != tail[j], "GL-16: retired id listed again");
                }
            }
        } catch {
            t(false, "GL-16: getDcaSchedules reverted");
        }
    }

    /// @dev GL-27: `who` holds no claim on any handler and no shares on any lending handler.
    function _checkNoBook(address who, string memory claimReason, string memory shareReason) private {
        for (uint256 k; k < routes.length; k++) {
            address h = routes[k].handler;
            eq(claim(who, h), 0, claimReason);
            if (routes[k].lending) eq(shares(who, h), 0, shareReason);
        }
    }

    function _checkNoSchedules(address who, address token) private {
        try dcaManager.getDcaSchedules(who, token) returns (uint64[] memory ids, IDcaManager.DcaSchedule[] memory) {
            eq(ids.length, 0, "GL-27: swapper owns a schedule");
        } catch {
            t(false, "GL-27: getDcaSchedules reverted");
        }
    }

    /// @dev GL-28: per-account previews on DcaManager.
    function _checkAccountPreviews(address account) private {
        try dcaManager.getDcaSchedules(account, address(doc)) {}
        catch {
            t(false, "GL-28: getDcaSchedules(DOC) reverted");
        }
        try dcaManager.getDcaSchedules(account, address(usdrif)) {}
        catch {
            t(false, "GL-28: getDcaSchedules(USDRIF) reverted");
        }
        for (uint256 k; k < routes.length; k++) {
            Route storage r = routes[k];
            try dcaManager.getAccumulatedRbtcBalance(account, r.token, r.routeIndex) {}
            catch {
                t(false, "GL-28: getAccumulatedRbtcBalance reverted");
            }
            if (!r.lending) continue;
            try dcaManager.getAccruedInterest(account, r.token, r.routeIndex) {}
            catch {
                t(false, "GL-28: getAccruedInterest reverted");
            }
        }
    }

    /// @dev GL-28: handler getters (fee, shares, oracle, path, floor settings).
    function _checkHandlerGetters(address h, address[4] memory accts) private {
        try IPurchaseFees(h).getFeeSettings() {}
        catch {
            t(false, "GL-28: getFeeSettings reverted");
        }
        try IPurchaseFees(h).getFeeCollector() {}
        catch {
            t(false, "GL-28: getFeeCollector reverted");
        }
        if (isLendingHandler(h)) {
            for (uint256 a; a < 4; a++) {
                try ILendingHandler(h).getUserShares(accts[a]) {}
                catch {
                    t(false, "GL-28: getUserShares reverted");
                }
            }
        }
        if (!isDex(h)) return;
        IPurchaseUniswap u = IPurchaseUniswap(h);
        try u.getMocOracle() {}
        catch {
            t(false, "GL-28: getMocOracle reverted");
        }
        try u.getSwapPath() {}
        catch {
            t(false, "GL-28: getSwapPath reverted");
        }
        try u.getAmountOutMinimumPercent() {}
        catch {
            t(false, "GL-28: getAmountOutMinimumPercent reverted");
        }
        try u.getAmountOutMinimumSafetyCheck() {}
        catch {
            t(false, "GL-28: getAmountOutMinimumSafetyCheck reverted");
        }
    }

    function _checkPauseAssigned(address token, uint256 routeIndex) private {
        if (operationsAdmin.areDepositsPaused(token, routeIndex)) {
            t(
                operationsAdmin.getHandler(token, routeIndex) != address(0),
                "GL-29: deposits paused on an unassigned pair"
            );
        }
    }

    // ――――――――――――――――――― Specific properties ――――――――――――――――――――
    // These properties must hold after specific function calls.
    // They MUST BE INTERNAL and called at the end of the relevant handlers.
    //
    // Wiring (fizz_data/property-plan.md §8, §9): each handler funnel builds an `OpCtx`, calls
    // `snapshotBefore()`, makes ONE single-shot pranked call inside try/catch, and then runs either
    //   success: tracking hooks → `snapshotAfter()` → ghost hooks → the op's own SP checks → `_postCommon(ctx)`
    //   failure: `_onRevert(ctx, err)` (SP-12, SP-51, SP-52, and SP-35 / SP-37 / SP-50 where they apply).
    // Underflow is silent under Medusa: every subtraction below is ordered first or written with int256.

    uint8 internal constant OP_CREATE = 1;
    uint8 internal constant OP_DEPOSIT = 2;
    uint8 internal constant OP_WITHDRAW = 3;
    uint8 internal constant OP_WITHDRAW_INTEREST = 4; // withdrawTokenAndInterest
    uint8 internal constant OP_DELETE = 5;
    uint8 internal constant OP_TOPUP = 6;
    uint8 internal constant OP_UPDATE_AMOUNT = 7;
    uint8 internal constant OP_UPDATE_PERIOD = 8;
    uint8 internal constant OP_PAUSE = 9;
    uint8 internal constant OP_INTEREST_ALL = 10;
    uint8 internal constant OP_RBTC_ALL = 11;
    uint8 internal constant OP_ACTIVATE = 12;
    uint8 internal constant OP_BATCH = 13;
    uint8 internal constant OP_ACROSS = 14;
    uint8 internal constant OP_SET_PATH = 15;
    uint8 internal constant OP_SET_PATH_ALLOWED = 16;
    uint8 internal constant OP_SET_DEPOSITS_PAUSED = 17;
    uint8 internal constant OP_SWAPPER_SET = 18;
    uint8 internal constant OP_SET_MAX_SCHEDULES = 19;
    uint8 internal constant OP_ADMIN = 20; // any other owner setter
    uint8 internal constant OP_PERMISSIONLESS = 21; // restore*Approval
    uint8 internal constant OP_ENV = 22; // environment move other than a donation
    uint8 internal constant OP_DONATION = 23;

    /// @dev Route indexes in `routes` (Base._registerRoutes order; `_setupFizzHarness` pins the topology).
    uint256 internal constant K_IDLE_DOC = 0;
    uint256 internal constant K_LB_DOC = 1;
    uint256 internal constant K_SOV_DOC = 2;
    uint256 internal constant K_IDLE_DEX = 3;
    uint256 internal constant K_LB_DEX = 4;

    /// @notice What one handler call did, for the specific and common checks.
    struct OpCtx {
        uint8 op;
        address caller;
        uint256 ai; // `_accountIndex(caller)`: 0..3, or max
        address token;
        uint64 id;
        uint256 routeK; // route of the named schedule or pair, or max
        uint256 amount; // deposit / withdrawal request / top-up / new amount or period / delete index
        uint256 amount2; // create: purchaseAmount
        uint256 amount3; // create: purchasePeriod
        uint256 routeIndex; // create: route argument
        bool flag; // pause value / add (true) or revoke / deposits-paused value / path allowed
        bool preExists; // the named schedule was readable before the call
        bool donated; // `ghosts.donatedSinceDeposit[h]` before a lending create/deposit (SP-05)
        IDcaManager.DcaSchedule pre; // the named schedule before the call
        address trackedOwner; // `_trackedOwner(token, id)` before the call (SP-56)
        uint64 maxIdBefore; // `ghosts.maxIdSeen` before a create (SP-02)
        uint64[] ids0; // caller's id list for `token` before a create / delete (SP-02, SP-13)
        uint256 routeMask; // bit k: route named by an interest / rBTC claim, or touched by a batch
        uint256 target; // setter target: Dex index, route K or swapper index
        uint256 pathIdx; // harness Uniswap path 0 / 1
        uint256[5][3] ops; // share- or principal-touching operations per (actor, route) (SP-47, SP-49)
    }

    /// @notice One tracked schedule before (`stateBefore`) and after (live read) the call.
    struct SchedPair {
        address token;
        uint64 id;
        address owner;
        bool missingBefore;
        bool goneAfter;
        uint256 rows; // rows of a successful batch call that named it
        IDcaManager.DcaSchedule b;
        IDcaManager.DcaSchedule a;
    }

    /// @notice One row of a batch call, with its simulated funding weight.
    struct BRow {
        uint256 b; // batch index
        uint256 k; // route K (max if not a harness route)
        address token;
        uint64 id;
        uint256 routeIndex; // the batch's route argument
        address buyer; // pre-call owner (zero if the row is not a tracked schedule)
        uint256 ai; // account index of the buyer
        uint256 amount; // pre-call purchaseAmount
        uint256 x; // funded weight (idle: amount; lending: per-row ceil/clamp simulation)
        uint256 sp; // index in SchedPair[] (max if not tracked)
    }

    /// @notice Per-route aggregates of one batch call (H2 + plan §4 SP-24..SP-38).
    struct BatchSim {
        uint256[5] batchesOn;
        uint256[5] rowsOn;
        uint256[5] gNom; // Σ nominal purchase amounts
        uint256[5] gFund; // Σ funded weights
        uint256[5] burn; // simulated receipt-share burn T
        bool[5] clamped;
        uint256[5][4] rem; // simulated shares left per (account, route)
        uint256[5][4] rowsOf; // rows per (account, route)
        uint256[5] q; // measured rBTC asset gain
        bool[5] qFell;
        uint256[5] minOut; // Σ minRbtcOut of the batches sent to a route (saturating)
        bool foreign; // a row outside the harness routes or bought for a non-account
    }

    /// @notice Local state of `roundTrip_depositWithdraw` (SP-19..SP-22).
    struct RoundTrip {
        address token;
        uint64 id;
        uint256 k;
        address h;
        bool lending;
        bool withdrawFirst;
        bool clamped;
        uint256 cycles;
        uint256 amount;
        uint256 c0; // actor stablecoin
        uint256 s0; // actor shares
        uint256 r; // rate (constant inside the call)
        uint256 i0; // accrued interest
        bool iFailed;
        uint256 h0; // handler stablecoin
        uint256 tb0; // schedule balance
    }

    /// @notice Local state of `roundTrip_createDelete` (SP-23).
    struct CreateDeleteTrip {
        address token;
        uint256 k;
        address h;
        bool lending;
        uint64[] ids0;
        uint256 c0;
        uint256 s0;
        uint256 r;
        uint256 i0;
        bool iFailed;
        uint256 h0;
        bool clamped; // the delete's withdrawal was clamped to the floored share value
    }

    // ――――――――――――――――― Context and snapshot accessors ―――――――――――――――――

    function _newCtx(uint8 op, address caller) internal view returns (OpCtx memory ctx) {
        ctx.op = op;
        ctx.caller = caller;
        ctx.ai = _accountIndex(caller);
        ctx.routeK = type(uint256).max;
        ctx.target = type(uint256).max;
    }

    /// @dev Context for a call that names (token, id); reads the schedule before the call.
    function _schedCtx(uint8 op, address caller, address token, uint64 id) internal view returns (OpCtx memory ctx) {
        ctx = _newCtx(op, caller);
        ctx.token = token;
        ctx.id = id;
        ctx.trackedOwner = _trackedOwner(token, id);
        try dcaManager.getDcaSchedule(token, id) returns (IDcaManager.DcaSchedule memory d) {
            ctx.pre = d;
            ctx.preExists = true;
            ctx.routeK = _routeKOf(token, d.routeIndex);
        } catch {}
    }

    /// @dev Marks `n` share- or principal-touching operations of the caller on the ctx route (lending only).
    function _setOps(OpCtx memory ctx, uint256 n) internal view {
        if (ctx.ai < 3 && ctx.routeK < 5 && routes[ctx.routeK].lending) ctx.ops[ctx.ai][ctx.routeK] = n;
    }

    /// @return mask Bit k set for every harness route named by (tokens[i], routeIndexes[i]).
    function _pairMask(address[] memory tokens, uint256[] memory routeIndexes) internal view returns (uint256 mask) {
        uint256 n = tokens.length < routeIndexes.length ? tokens.length : routeIndexes.length;
        for (uint256 i; i < n; i++) {
            uint256 k = _routeKOf(tokens[i], routeIndexes[i]);
            if (k < 5) mask |= 1 << k;
        }
    }

    function _named(OpCtx memory ctx, uint256 k) internal pure returns (bool) {
        return (ctx.routeMask >> k) & 1 == 1;
    }

    function _idsOf(address user, address token) internal view returns (uint64[] memory ids) {
        try dcaManager.getDcaSchedules(user, token) returns (uint64[] memory got, IDcaManager.DcaSchedule[] memory) {
            ids = got;
        } catch {}
    }

    function _isUserOp(uint8 op) internal pure returns (bool) {
        return op >= OP_CREATE && op <= OP_RBTC_ALL;
    }

    function _isScheduleOp(uint8 op) internal pure returns (bool) {
        return op >= OP_CREATE && op <= OP_PAUSE;
    }

    function _isBatchOp(uint8 op) internal pure returns (bool) {
        return op == OP_BATCH || op == OP_ACROSS;
    }

    function _isEnvOp(uint8 op) internal pure returns (bool) {
        return op == OP_ENV || op == OP_DONATION;
    }

    /// @dev The seven calls behind `whenUserMutationsAllowed` (AGENTS.md invariant 10).
    function _isGuarded(uint8 op) internal pure returns (bool) {
        return op == OP_WITHDRAW || op == OP_WITHDRAW_INTEREST || op == OP_DELETE || op == OP_UPDATE_AMOUNT
            || op == OP_UPDATE_PERIOD || op == OP_PAUSE || op == OP_INTEREST_ALL;
    }

    /// @return 0 for DOC, 1 for USDRIF, max otherwise.
    function _tokenIdx(address token) internal view returns (uint256) {
        if (token == address(doc)) return 0;
        if (token == address(usdrif)) return 1;
        return type(uint256).max;
    }

    function _walletOf(State storage s, uint256 a, uint256 ti) internal view returns (uint256) {
        return ti == 0 ? s.doc[a] : s.usdrif[a];
    }

    function _Dk(uint256 k) internal view returns (uint256) {
        return D(routes[k].handler);
    }

    /// @notice Floored stablecoin value of account a's shares on route k at the snapshot's rate.
    function _valueOf(State storage s, uint256 a, uint256 k) internal view returns (uint256) {
        if (!routes[k].lending || s.rate[k] == 0) return 0;
        return s.shares[a][k] * s.rate[k] / _Dk(k);
    }

    function _rbtcAssetOf(State storage s, uint256 k) internal view returns (uint256) {
        return routes[k].dex ? s.handlerWrbtc[k] : s.handlerNative[k];
    }

    /// @notice max(0, principal - share value) of actor a on lending route k.
    function _shortfall(State storage s, uint256 a, uint256 k) internal view returns (uint256) {
        uint256 l = s.principal[a][k];
        uint256 v = _valueOf(s, a, k);
        return l > v ? l - v : 0;
    }

    /// @return Share debit of account a on route k across the call, or max if its shares rose.
    function _shareDebit(uint256 a, uint256 k) internal view returns (uint256) {
        uint256 sb = stateBefore.shares[a][k];
        uint256 sa = stateAfter.shares[a][k];
        return sa > sb ? type(uint256).max : sb - sa;
    }

    /// @return ok False if the router's USDRIF fell; rin = USDRIF the router took during the batch call.
    function _routerIntake() internal view returns (bool ok, uint256 rin) {
        uint256 b = stateBefore.routerUsdrif;
        uint256 a = stateAfter.routerUsdrif;
        if (a < b) return (false, 0);
        return (true, a - b);
    }

    function _satAdd(uint256 x, uint256 y) internal pure returns (uint256) {
        unchecked {
            uint256 z = x + y;
            return z < x ? type(uint256).max : z;
        }
    }

    function _effectiveWithdrawal(OpCtx memory ctx) internal pure returns (uint256) {
        if (ctx.op == OP_DELETE || ctx.amount == type(uint256).max) return ctx.pre.tokenBalance;
        return ctx.amount;
    }

    // ――――――――――――――――――――― Error helpers ―――――――――――――――――――――

    /// @return body Revert data without its 4-byte selector.
    function _errBody(bytes memory err) internal pure returns (bytes memory body) {
        if (err.length < 4) return body;
        body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; i++) {
            body[i] = err[i + 4];
        }
    }

    /// @dev Liveness failure: logs the revert data and fails with the selector in the message.
    function _failWithErr(string memory reason, bytes memory err) internal {
        Logger.logBytes(err);
        t(false, string.concat(reason, " (selector ", toString(uint256(uint32(_errSelector(err)))), ")"));
    }

    // ――――――――――――――――――――― Schedule pairs ―――――――――――――――――――――

    /// @notice Every schedule `snapshotBefore` copied, with its live value now (one getter call each).
    function _schedPairs() internal view returns (SchedPair[] memory sp) {
        uint256 n = stateBefore.schedCount;
        sp = new SchedPair[](n);
        for (uint256 i; i < n; i++) {
            SchedPair memory p = sp[i];
            p.token = stateBefore.schedToken[i];
            p.id = stateBefore.schedId[i];
            p.owner = stateBefore.schedOwner[i];
            p.missingBefore = stateBefore.schedMissing[i];
            p.b = stateBefore.sched[i];
            try dcaManager.getDcaSchedule(p.token, p.id) returns (IDcaManager.DcaSchedule memory d) {
                p.a = d;
            } catch {
                p.goneAfter = true;
            }
        }
    }

    function _spIndex(SchedPair[] memory sp, address token, uint64 id) internal pure returns (uint256) {
        for (uint256 i; i < sp.length; i++) {
            if (sp[i].id == id && sp[i].token == token) return i;
        }
        return type(uint256).max;
    }

    function _sameSched(IDcaManager.DcaSchedule memory x, IDcaManager.DcaSchedule memory y)
        internal
        pure
        returns (bool)
    {
        return keccak256(abi.encode(x)) == keccak256(abi.encode(y));
    }

    /// @dev Every schedule live before the call, other than (token, id), is still live and unchanged.
    function _othersUnchanged(SchedPair[] memory sp, address token, uint64 id, string memory reason) internal {
        for (uint256 i; i < sp.length; i++) {
            SchedPair memory p = sp[i];
            if (p.missingBefore || (p.token == token && p.id == id)) continue;
            t(!p.goneAfter && _sameSched(p.a, p.b), reason);
        }
    }

    /// @dev Every (actor, token) id list other than the caller's list for ctx.token is unchanged.
    function _otherListsUnchanged(OpCtx memory ctx, string memory reason) internal {
        uint256 cti = _tokenIdx(ctx.token);
        for (uint256 a; a < 3; a++) {
            for (uint256 ti; ti < 2; ti++) {
                if (a == ctx.ai && ti == cti) continue;
                t(stateAfter.idsHash[a][ti] == stateBefore.idsHash[a][ti], reason);
            }
        }
    }

    // ――――――――――――――――――――― Common dispatch ―――――――――――――――――――――

    /// @notice Checks every op class runs after a successful call (plan §8 table).
    function _postCommon(OpCtx memory ctx) internal {
        _postCommonWith(ctx, _schedPairs());
    }

    function _postCommonWith(OpCtx memory ctx, SchedPair[] memory sp) internal {
        uint8 op = ctx.op;
        property_rbtcBookMovesOnlyByClaimOrBatch(ctx);
        property_rbtcSentinelSlot(ctx);
        property_anchorMonotone(ctx, sp);
        property_unlockMonotone(ctx);
        property_shareChangeAttribution(ctx);
        if (op != OP_SET_PATH && op != OP_SET_PATH_ALLOWED) property_pathStateMachine(ctx, true, "");
        if (_isUserOp(op)) {
            property_noCrossUserEffect(ctx, sp);
            property_noProfitPerUserCall(ctx);
            property_windowGatesGuardedCalls(op, true, "", stateBefore.unlock);
        } else if (op != OP_DONATION) {
            property_nonUserCallsKeepWallets();
        }
        if (!_isScheduleOp(op) && !_isBatchOp(op)) property_nonScheduleCallFrame(sp);
        if (!_isEnvOp(op) && op != OP_CREATE && op != OP_DEPOSIT) property_noOpRaisesInterest();
        if (!_isEnvOp(op)) property_shortfallNotDeepened(ctx);
    }

    /// @notice Checks every wrapper runs when its call reverted (the batch funnel adds SP-35 and SP-37).
    function _onRevert(OpCtx memory ctx, bytes memory err) internal {
        property_noBurnMismatchRevert(err);
        property_windowGatesGuardedCalls(ctx.op, false, err, stateBefore.unlock);
        property_refusalAttribution(ctx, err);
        if (ctx.op == OP_ACTIVATE) property_activationSemantics(ctx, false, err);
        if (ctx.op == OP_SET_PATH || ctx.op == OP_SET_PATH_ALLOWED) property_pathStateMachine(ctx, false, err);
    }

    // ――――――――――――――――― Funding: create, deposit, top-up ―――――――――――――――――

    /// @notice SP-01: a create or deposit pulls exactly d from the actor into the one schedule and its route position
    function property_depositExact(OpCtx memory ctx) internal {
        uint256 k = ctx.routeK;
        uint256 ti = _tokenIdx(ctx.token);
        if (k >= 5 || ti > 1 || ctx.ai >= 4) return;
        uint256 wb = _walletOf(stateBefore, ctx.ai, ti);
        uint256 wa = _walletOf(stateAfter, ctx.ai, ti);
        lte(wa, wb, "SP-01: deposit raised the actor's wallet");
        if (wa <= wb) eq(wb - wa, ctx.amount, "SP-01: pulled amount != deposit");
        try dcaManager.getDcaSchedule(ctx.token, ctx.id) returns (IDcaManager.DcaSchedule memory d) {
            uint256 prior = ctx.op == OP_CREATE ? 0 : ctx.pre.tokenBalance;
            eq(uint256(d.tokenBalance), prior + ctx.amount, "SP-01: schedule balance did not rise by the deposit");
        } catch {
            t(false, "SP-01: funded schedule unreadable");
        }
        if (!routes[k].lending) {
            eq(
                stateAfter.handlerStable[k],
                stateBefore.handlerStable[k] + ctx.amount,
                "SP-01: idle cash did not rise by the deposit"
            );
            return;
        }
        uint256 sb = stateBefore.shares[ctx.ai][k];
        uint256 sa = stateAfter.shares[ctx.ai][k];
        uint256 rb = stateBefore.receipt[k];
        uint256 ra = stateAfter.receipt[k];
        gt(sa, sb, "SP-01: lending deposit credited no shares");
        gte(ra, rb, "SP-01: lending deposit lowered the receipt balance");
        if (sa > sb && ra >= rb) eq(ra - rb, sa - sb, "SP-01: receipt gain != credited shares");
        eq(stateAfter.handlerStable[k], stateBefore.handlerStable[k], "SP-01: lending deposit left cash on the handler");
    }

    /// @notice SP-02: a create takes id nonce+1 above every id seen, stores its arguments, and appends the id last
    function property_createPostconditions(OpCtx memory ctx, SchedPair[] memory sp) internal {
        eq(uint256(ctx.id), stateBefore.nonce + 1, "SP-02: new id != previous nonce + 1");
        gt(uint256(ctx.id), uint256(ctx.maxIdBefore), "SP-02: new id not above every id seen");
        try dcaManager.getDcaSchedule(ctx.token, ctx.id) returns (IDcaManager.DcaSchedule memory d) {
            eq(uint256(d.tokenBalance), ctx.amount, "SP-02: stored balance != deposit");
            eq(uint256(d.purchaseAmount), ctx.amount2, "SP-02: stored purchase amount != argument");
            eq(uint256(d.purchasePeriod), ctx.amount3, "SP-02: stored period != argument");
            eq(uint256(d.routeIndex), ctx.routeIndex, "SP-02: stored route != argument");
            t(d.user == ctx.caller, "SP-02: stored owner != caller");
            eq(uint256(d.cadenceAnchor), 0, "SP-02: new schedule already anchored");
            t(!d.paused, "SP-02: new schedule paused");
        } catch {
            t(false, "SP-02: new schedule unreadable");
        }
        uint64[] memory ids1 = _idsOf(ctx.caller, ctx.token);
        eq(ids1.length, ctx.ids0.length + 1, "SP-02: id list did not grow by one");
        if (ids1.length == ctx.ids0.length + 1) {
            eq(uint256(ids1[ids1.length - 1]), uint256(ctx.id), "SP-02: new id not appended last");
            for (uint256 i; i < ctx.ids0.length; i++) {
                eq(uint256(ids1[i]), uint256(ctx.ids0[i]), "SP-02: create reordered existing ids");
            }
        }
        _othersUnchanged(sp, ctx.token, ctx.id, "SP-02: create changed another schedule");
        _otherListsUnchanged(ctx, "SP-02: create changed another id list");
    }

    /// @notice SP-03: a lending deposit credits exactly the venue mint; interest rises by at most LayerBank's half-up dust
    function property_lendingDepositCredit(OpCtx memory ctx) internal {
        uint256 k = ctx.routeK;
        if (k >= 5 || !routes[k].lending || ctx.ai >= 3) return;
        address h = routes[k].handler;
        uint256 r = stateBefore.rate[k];
        uint256 sb = stateBefore.shares[ctx.ai][k];
        uint256 sa = stateAfter.shares[ctx.ai][k];
        gte(sa, sb, "SP-03: lending deposit lowered shares");
        if (sa >= sb) eq(sa - sb, _previewMint(h, ctx.amount, r), "SP-03: credited shares != venue mint formula");
        if (stateBefore.interestReadFailed || stateAfter.interestReadFailed) return;
        uint256 iSlack = isLB(h) ? ceilDiv(r / 2, RAY) : 0;
        lte(
            stateAfter.interest[ctx.ai][k],
            stateBefore.interest[ctx.ai][k] + iSlack,
            "SP-03: deposit raised interest beyond venue mint dust"
        );
    }

    /// @notice SP-04: a stray stablecoin or native donation moves no shares, interest, claims, schedules or receipts
    function property_donationMovesNoBook(SchedPair[] memory sp) internal {
        for (uint256 a; a < 4; a++) {
            for (uint256 k; k < 5; k++) {
                eq(stateAfter.claim[a][k], stateBefore.claim[a][k], "SP-04: donation became claimable rBTC");
                eq(stateAfter.shares[a][k], stateBefore.shares[a][k], "SP-04: donation moved virtual shares");
            }
        }
        if (!stateBefore.interestReadFailed && !stateAfter.interestReadFailed) {
            for (uint256 a; a < 3; a++) {
                for (uint256 k; k < 5; k++) {
                    eq(stateAfter.interest[a][k], stateBefore.interest[a][k], "SP-04: donation became accrued interest");
                }
            }
        }
        for (uint256 k; k < 5; k++) {
            eq(stateAfter.receipt[k], stateBefore.receipt[k], "SP-04: donation moved receipt shares");
        }
        _othersUnchanged(sp, address(0), 0, "SP-04: donation moved a schedule");
    }

    /// @notice SP-05: the first lending deposit after a donation credits exactly the market-formula shares at the pre-call rate
    function property_postDonationDepositCredit(OpCtx memory ctx) internal {
        uint256 k = ctx.routeK;
        if (k >= 5 || !routes[k].lending || ctx.ai >= 3) return;
        uint256 sb = stateBefore.shares[ctx.ai][k];
        uint256 sa = stateAfter.shares[ctx.ai][k];
        gte(sa, sb, "SP-05: post-donation deposit lowered shares");
        if (sa >= sb) {
            eq(
                sa - sb,
                _previewMint(routes[k].handler, ctx.amount, stateBefore.rate[k]),
                "SP-05: post-donation credit depends on handler balances"
            );
        }
    }

    /// @notice SP-06: setDepositsPaused flips exactly one pair's flag; create and deposit succeed only on unpaused pairs
    function property_depositPauseRespected(OpCtx memory ctx) internal {
        if (ctx.op == OP_CREATE || ctx.op == OP_DEPOSIT) {
            if (ctx.routeK < 5) t(!stateBefore.depositsPaused[ctx.routeK], "SP-06: deposit through a paused pair");
            return;
        }
        for (uint256 k; k < 5; k++) {
            t(stateAfter.handlerOf[k] == stateBefore.handlerOf[k], "SP-06: deposit pause moved a handler");
            if (k == ctx.target) {
                t(stateAfter.depositsPaused[k] == ctx.flag, "SP-06: deposit pause flag not set");
            } else {
                t(
                    stateAfter.depositsPaused[k] == stateBefore.depositsPaused[k],
                    "SP-06: deposit pause changed another pair"
                );
            }
        }
    }

    /// @notice SP-07: a create stays within the cap in force; setting the cap removes no schedule
    function property_createRespectsCap(OpCtx memory ctx) internal {
        if (ctx.op == OP_CREATE) {
            lte(
                _idsOf(ctx.caller, ctx.token).length,
                stateBefore.maxSchedules,
                "SP-07: create exceeded the schedule cap"
            );
            return;
        }
        for (uint256 a; a < 3; a++) {
            for (uint256 ti; ti < 2; ti++) {
                eq(stateAfter.idsLen[a][ti], stateBefore.idsLen[a][ti], "SP-07: cap change removed schedules");
            }
        }
    }

    // ――――――――――――――――――― Principal exits ―――――――――――――――――――

    /// @notice SP-08: a principal withdrawal debits exactly the request (whole balance for max / delete) on that schedule
    function property_withdrawExact(OpCtx memory ctx) internal {
        uint256 k = ctx.routeK;
        uint256 ti = _tokenIdx(ctx.token);
        if (k >= 5 || ti > 1 || ctx.ai >= 4 || !ctx.preExists) return;
        uint256 w = _effectiveWithdrawal(ctx);
        if (ctx.op != OP_DELETE) {
            try dcaManager.getDcaSchedule(ctx.token, ctx.id) returns (IDcaManager.DcaSchedule memory d) {
                lte(uint256(d.tokenBalance), uint256(ctx.pre.tokenBalance), "SP-08: withdrawal raised the balance");
                if (d.tokenBalance <= ctx.pre.tokenBalance) {
                    eq(uint256(ctx.pre.tokenBalance) - d.tokenBalance, w, "SP-08: principal debit != request");
                }
            } catch {
                t(false, "SP-08: schedule unreadable after a withdrawal");
            }
        }
        uint256 wb = _walletOf(stateBefore, ctx.ai, ti);
        uint256 wa = _walletOf(stateAfter, ctx.ai, ti);
        gte(wa, wb, "SP-08: withdrawal took stablecoin from the actor");
        if (!routes[k].lending) {
            if (wa >= wb) eq(wa - wb, w, "SP-08: idle payout != debit");
            uint256 hb = stateBefore.handlerStable[k];
            uint256 ha = stateAfter.handlerStable[k];
            gte(hb, ha, "SP-08: idle cash rose on a withdrawal");
            if (hb >= ha) eq(hb - ha, w, "SP-08: idle cash fell by != debit");
            return;
        }
        _checkBurnMatchesDebit(ctx.ai, k, "SP-08: receipt burn != virtual share debit");
        eq(
            stateAfter.handlerStable[k],
            stateBefore.handlerStable[k],
            "SP-08: lending withdrawal left cash on the handler"
        );
    }

    /// @dev Receipt burn on route k equals account a's share debit (a's shares and the receipt did not rise).
    function _checkBurnMatchesDebit(uint256 a, uint256 k, string memory reason) internal {
        uint256 sb = stateBefore.shares[a][k];
        uint256 sa = stateAfter.shares[a][k];
        uint256 rb = stateBefore.receipt[k];
        uint256 ra = stateAfter.receipt[k];
        if (sa > sb || ra > rb) {
            t(false, reason);
            return;
        }
        eq(rb - ra, sb - sa, reason);
    }

    /// @notice SP-09: with no loss, a lending withdrawal pays at least the debit and at most one share's rounding more
    function property_lendingPayoutNoLoss(OpCtx memory ctx) internal {
        uint256 k = ctx.routeK;
        uint256 ti = _tokenIdx(ctx.token);
        if (k >= 5 || !routes[k].lending || ti > 1 || ctx.ai >= 3 || !ctx.preExists) return;
        if (isSov(routes[k].handler) && (ghosts.sovrynPriceEverFell || stateBefore.sovrynExitFee != 0)) return;
        uint256 w = _effectiveWithdrawal(ctx);
        if (_valueOf(stateBefore, ctx.ai, k) < w) return;
        uint256 wb = _walletOf(stateBefore, ctx.ai, ti);
        uint256 wa = _walletOf(stateAfter, ctx.ai, ti);
        if (wa < wb) return; // SP-08 reports it
        gte(wa - wb, w, "SP-09: no-loss withdrawal paid less than the debit");
        lte(wa - wb, w + stateBefore.rate[k] / _Dk(k) + 2, "SP-09: withdrawal overpaid beyond one share");
    }

    /// @notice SP-10: a lending redeem debits exactly ceilDiv(w'·D, rate) shares, w' the request clamped to the floored value
    function property_redeemDebitCeil(OpCtx memory ctx) internal {
        if (ctx.ai >= 3 || stateBefore.principalReadFailed) return;
        if (ctx.op == OP_INTEREST_ALL) {
            for (uint256 k; k < 5; k++) {
                if (!routes[k].lending || !_named(ctx, k)) continue;
                eq(
                    _shareDebit(ctx.ai, k),
                    _interestDebit(ctx.ai, k),
                    "SP-10: interest debit != ceilDiv of the floored interest"
                );
            }
            return;
        }
        uint256 rk = ctx.routeK;
        if (rk >= 5 || !routes[rk].lending || !ctx.preExists) return;
        (uint256 sr1, uint256 sr2) = _expectedRedeemDebits(ctx, rk);
        eq(_shareDebit(ctx.ai, rk), sr1 + sr2, "SP-10: share debit != ceilDiv of the clamped request");
    }

    /// @dev ceilDiv(I·D, rate) for the floored interest I = max(0, V - L) before the call.
    function _interestDebit(uint256 a, uint256 k) internal view returns (uint256) {
        uint256 r = stateBefore.rate[k];
        if (r == 0) return 0;
        uint256 v = _valueOf(stateBefore, a, k);
        uint256 l = stateBefore.principal[a][k];
        if (v <= l) return 0;
        return ceilDiv((v - l) * _Dk(k), r);
    }

    /// @dev Principal debit and, for withdrawTokenAndInterest, the interest debit recomputed after it.
    function _expectedRedeemDebits(OpCtx memory ctx, uint256 k) internal view returns (uint256 sr1, uint256 sr2) {
        uint256 r = stateBefore.rate[k];
        if (r == 0) return (0, 0);
        uint256 d = _Dk(k);
        uint256 s0 = stateBefore.shares[ctx.ai][k];
        uint256 w = _effectiveWithdrawal(ctx);
        uint256 v0 = s0 * r / d;
        sr1 = ceilDiv((w < v0 ? w : v0) * d, r);
        if (ctx.op != OP_WITHDRAW_INTEREST || sr1 > s0) return (sr1, 0);
        uint256 l0 = stateBefore.principal[ctx.ai][k];
        uint256 l1 = l0 > w ? l0 - w : 0;
        uint256 v1 = (s0 - sr1) * r / d;
        if (v1 > l1) sr2 = ceilDiv((v1 - l1) * d, r);
    }

    /// @notice SP-11: a lending redeem never pays more than the burned shares are worth (+1 wei per LayerBank burn)
    function property_redeemPaysAtMostBurned(OpCtx memory ctx) internal {
        if (ctx.ai >= 3) return;
        if (ctx.op == OP_INTEREST_ALL) {
            _checkRedeemPayToken(ctx, 0);
            _checkRedeemPayToken(ctx, 1);
            return;
        }
        uint256 k = ctx.routeK;
        if (k >= 5 || !routes[k].lending) return;
        uint256 ti = _tokenIdx(routes[k].token);
        uint256 wb = _walletOf(stateBefore, ctx.ai, ti);
        uint256 wa = _walletOf(stateAfter, ctx.ai, ti);
        uint256 sr = _shareDebit(ctx.ai, k);
        if (wa < wb || sr == type(uint256).max) return; // SP-08 / SP-10 report these
        _checkRedeemPay(wa - wb, k, sr, ctx.op == OP_WITHDRAW_INTEREST ? 2 : 1, true);
    }

    /// @dev SP-11 for an interest withdrawal: per token, over the named lending routes of that token.
    function _checkRedeemPayToken(OpCtx memory ctx, uint256 ti) internal {
        uint256 wb = _walletOf(stateBefore, ctx.ai, ti);
        uint256 wa = _walletOf(stateAfter, ctx.ai, ti);
        if (wa < wb) {
            t(false, "SP-11: interest withdrawal took stablecoin from the actor");
            return;
        }
        uint256 count;
        uint256 kOnly;
        uint256 bound;
        uint256 srSum;
        for (uint256 k; k < 5; k++) {
            if (!routes[k].lending || _tokenIdx(routes[k].token) != ti || !_named(ctx, k)) continue;
            uint256 sr = _shareDebit(ctx.ai, k);
            if (sr == type(uint256).max) return; // SP-47 reports a rise
            count++;
            kOnly = k;
            srSum += sr;
            bound += sr * stateBefore.rate[k] / _Dk(k) + (isLB(routes[k].handler) ? 1 : 0);
        }
        if (srSum == 0) {
            eq(wa - wb, 0, "SP-11: zero-share redeem paid tokens");
            return;
        }
        lte(wa - wb, bound, "SP-11: redeem paid more than the burned shares (floor + LB +1)");
        if (count == 1) _checkRedeemPay(wa - wb, kOnly, srSum, 1, false);
    }

    function _checkRedeemPay(uint256 paid, uint256 k, uint256 sr, uint256 n, bool withFloorBound) internal {
        if (sr == 0) {
            eq(paid, 0, "SP-11: zero-share redeem paid tokens");
            return;
        }
        uint256 r = stateBefore.rate[k];
        uint256 d = _Dk(k);
        bool lb = isLB(routes[k].handler);
        if (withFloorBound) {
            lte(paid, sr * r / d + (lb ? n : 0), "SP-11: redeem paid more than the burned shares (floor + LB +1)");
        }
        uint256 halfUp = lb && r > 0 ? (r + 1) / 2 - 1 : 0;
        lte(paid * d, sr * r + n * halfUp, "SP-11: redeem paid above the half-up burn value");
    }

    /// @notice SP-12: no lending redeem or batch reverts with ShareConsumptionMismatch or ZeroStablecoinReceived
    function property_noBurnMismatchRevert(bytes memory err) internal {
        bytes4 s = _errSelector(err);
        t(
            s != ILendingHandler.LendingHandler__ShareConsumptionMismatch.selector,
            "SP-12: lending burn sizing missed the exact share burn"
        );
        t(
            s != ILendingHandler.LendingHandler__ZeroStablecoinReceived.selector,
            "SP-12: a positive share debit paid zero"
        );
    }

    /// @notice SP-13: a delete retires the key and swap-pops the list; nonce, other schedules and claims stay
    function property_deletePostconditions(OpCtx memory ctx, SchedPair[] memory sp) internal {
        try dcaManager.getDcaSchedule(ctx.token, ctx.id) {
            t(false, "SP-13: deleted key still live");
        } catch (bytes memory e) {
            t(
                _errSelector(e) == IDcaManager.DcaManager__InexistentSchedule.selector,
                "SP-13: deleted key reverts with an unexpected error"
            );
        }
        uint64[] memory b = ctx.ids0;
        uint64[] memory a = _idsOf(ctx.caller, ctx.token);
        if (b.length == 0) {
            t(false, "SP-13: delete succeeded on an empty list");
            return;
        }
        eq(a.length, b.length - 1, "SP-13: id list did not shrink by one");
        if (a.length == b.length - 1) {
            for (uint256 i; i < a.length; i++) {
                uint64 expected = i == ctx.amount ? b[b.length - 1] : b[i];
                eq(uint256(a[i]), uint256(expected), "SP-13: id list not swap-popped at the index");
            }
        }
        eq(stateAfter.nonce, stateBefore.nonce, "SP-13: delete moved the nonce");
        _othersUnchanged(sp, ctx.token, ctx.id, "SP-13: delete changed another schedule");
        if (ctx.ai < 4) {
            for (uint256 k; k < 5; k++) {
                eq(stateAfter.claim[ctx.ai][k], stateBefore.claim[ctx.ai][k], "SP-13: delete moved rBTC claims");
            }
        }
    }

    // ――――――――――――――――――― Interest ―――――――――――――――――――

    /// @notice SP-14: an interest withdrawal keeps principal, burns exactly the virtual debit and keeps principal backed
    function property_interestWithdrawalSafe(OpCtx memory ctx) internal {
        if (ctx.ai >= 3 || stateBefore.principalReadFailed || stateAfter.principalReadFailed) return;
        for (uint256 k; k < 5; k++) {
            if (!routes[k].lending || !_named(ctx, k)) continue;
            uint256 lb = stateBefore.principal[ctx.ai][k];
            uint256 la = stateAfter.principal[ctx.ai][k];
            if (ctx.op == OP_INTEREST_ALL) {
                eq(la, lb, "SP-14: interest withdrawal moved principal");
            } else {
                uint256 w = _effectiveWithdrawal(ctx);
                lte(w, lb, "SP-14: withdrawal above the route principal");
                if (w <= lb) eq(la, lb - w, "SP-14: principal moved beyond the withdrawal");
            }
            _checkBurnMatchesDebit(ctx.ai, k, "SP-14: receipt burn != virtual debit");
            eq(
                stateAfter.handlerStable[k],
                stateBefore.handlerStable[k],
                "SP-14: interest withdrawal left cash on the handler"
            );
            if (_valueOf(stateBefore, ctx.ai, k) >= lb) {
                gte(
                    _valueOf(stateAfter, ctx.ai, k) + stateBefore.rate[k] / _Dk(k) + 2,
                    la,
                    "SP-14: interest withdrawal spent principal"
                );
            }
        }
    }

    /// @notice SP-15: after an interest withdrawal, accrued interest is exactly zero on every lending pair named
    function property_interestIdempotent(address account, uint256 mask) internal {
        for (uint256 k; k < 5; k++) {
            if (!routes[k].lending || (mask >> k) & 1 == 0) continue;
            (uint256 v, bool failed) = _interest(account, k);
            t(!failed, "SP-15: getAccruedInterest reverted after an interest withdrawal");
            eq(v, 0, "SP-15: interest left after an interest withdrawal");
        }
    }

    /// @notice SP-15: a second interest withdrawal in the same block pays nothing and burns no shares
    function property_interestSecondCallNoop(
        bool ok,
        bytes memory err,
        uint256[2] memory walletsBefore,
        uint256[5] memory sharesBefore
    ) internal {
        if (!ok) {
            _failWithErr("SP-15: second interest withdrawal reverted", err);
            return;
        }
        eq(doc.balanceOf(actor), walletsBefore[0], "SP-15: second interest withdrawal paid DOC");
        eq(usdrif.balanceOf(actor), walletsBefore[1], "SP-15: second interest withdrawal paid USDRIF");
        for (uint256 k; k < 5; k++) {
            if (!routes[k].lending) continue;
            eq(shares(actor, routes[k].handler), sharesBefore[k], "SP-15: second interest withdrawal burned shares");
        }
    }

    /// @notice SP-16: a single-pair interest withdrawal pays between the quote and the quote plus one share (+1)
    function property_interestPayoutVsQuote(OpCtx memory ctx) internal {
        if (ctx.ai >= 3 || stateBefore.interestReadFailed) return;
        for (uint256 ti; ti < 2; ti++) {
            uint256 count;
            uint256 kOnly;
            for (uint256 k; k < 5; k++) {
                if (!routes[k].lending || _tokenIdx(routes[k].token) != ti || !_named(ctx, k)) continue;
                count++;
                kOnly = k;
            }
            if (count != 1) continue;
            uint256 wb = _walletOf(stateBefore, ctx.ai, ti);
            uint256 wa = _walletOf(stateAfter, ctx.ai, ti);
            if (wa < wb) continue; // SP-11 reports it
            uint256 i0 = stateBefore.interest[ctx.ai][kOnly];
            lte(
                wa - wb,
                i0 + stateBefore.rate[kOnly] / _Dk(kOnly) + 1,
                "SP-16: interest paid above the quote + one share"
            );
            if (isLB(routes[kOnly].handler) || stateBefore.sovrynExitFee == 0) {
                gte(wa - wb, i0, "SP-16: interest paid below the quote without an exit fee");
            }
        }
    }

    /// @notice SP-17: a top-up moves no tokens or shares, raises the schedule by amount and lowers interest by amount
    function property_topUpExact(OpCtx memory ctx) internal {
        uint256 k = ctx.routeK;
        uint256 ti = _tokenIdx(ctx.token);
        if (k >= 5 || ti > 1 || ctx.ai >= 3 || !ctx.preExists) return;
        try dcaManager.getDcaSchedule(ctx.token, ctx.id) returns (IDcaManager.DcaSchedule memory d) {
            eq(
                uint256(d.tokenBalance),
                uint256(ctx.pre.tokenBalance) + ctx.amount,
                "SP-17: top-up did not raise the balance by amount"
            );
        } catch {
            t(false, "SP-17: topped-up schedule unreadable");
        }
        eq(stateAfter.shares[ctx.ai][k], stateBefore.shares[ctx.ai][k], "SP-17: top-up moved shares");
        eq(stateAfter.receipt[k], stateBefore.receipt[k], "SP-17: top-up moved receipt shares");
        eq(stateAfter.handlerStable[k], stateBefore.handlerStable[k], "SP-17: top-up moved handler cash");
        eq(
            _walletOf(stateAfter, ctx.ai, ti),
            _walletOf(stateBefore, ctx.ai, ti),
            "SP-17: top-up moved the actor's wallet"
        );
        if (!stateBefore.interestReadFailed && !stateAfter.interestReadFailed) {
            uint256 ib = stateBefore.interest[ctx.ai][k];
            gte(ib, ctx.amount, "SP-17: top-up above the quoted interest");
            if (ib >= ctx.amount) {
                eq(stateAfter.interest[ctx.ai][k], ib - ctx.amount, "SP-17: interest did not fall by amount");
            }
        }
        if (!stateAfter.principalReadFailed) {
            lte(
                stateAfter.principal[ctx.ai][k],
                _valueOf(stateAfter, ctx.ai, k),
                "SP-17: top-up created unbacked principal"
            );
        }
    }

    /// @notice SP-18: a top-up within the quoted interest never reverts TopUpExceedsAccruedInterest or NoInterestToTopUpWith
    function property_topUpQuoteSafe(bytes memory err) internal {
        bytes4 s = _errSelector(err);
        t(
            s != IDcaManager.DcaManager__TopUpExceedsAccruedInterest.selector,
            "SP-18: quoted interest above the spendable ceiling"
        );
        t(
            s != IDcaManager.DcaManager__NoInterestToTopUpWith.selector,
            "SP-18: positive quote but no spendable interest"
        );
    }

    // ――――――――――――――――――― Round trips (C2) ―――――――――――――――――――

    /// @notice SP-19: lending deposit⇄withdraw cycles keep principal and create no value (LayerBank: under one wei per cycle)
    function property_rtLendingNoValue(RoundTrip memory rt) internal {
        _checkTripPrincipal(rt, "SP-19: round trip changed principal");
        int256 dC = int256(MockStablecoin(rt.token).balanceOf(actor)) - int256(rt.c0);
        int256 dS = int256(shares(actor, rt.h)) - int256(rt.s0);
        int256 dVal = dC * int256(D(rt.h)) + dS * int256(rt.r);
        int256 slack = isLB(rt.h) ? int256(rt.cycles) * (int256(rt.r) - 1) : int256(0);
        lte(dVal, slack, "SP-19: round trip created value for the user");
    }

    /// @notice SP-20: idle deposit⇄withdraw cycles restore the actor's cash, the handler's cash and the principal exactly
    function property_rtIdleExact(RoundTrip memory rt) internal {
        eq(MockStablecoin(rt.token).balanceOf(actor), rt.c0, "SP-20: idle round trip changed actor cash");
        eq(MockStablecoin(rt.token).balanceOf(rt.h), rt.h0, "SP-20: idle round trip changed handler cash");
        _checkTripPrincipal(rt, "SP-20: idle round trip changed principal");
    }

    function _checkTripPrincipal(RoundTrip memory rt, string memory reason) internal {
        try dcaManager.getDcaSchedule(rt.token, rt.id) returns (IDcaManager.DcaSchedule memory d) {
            eq(uint256(d.tokenBalance), rt.tb0, reason);
        } catch {
            t(false, reason);
        }
    }

    /// @notice SP-21: a lending round trip never leaves more shares and never raises accrued interest
    /// @dev The share count is checked only when no withdrawal was clamped. A clamped withdrawal debits
    ///      ceilDiv(floor(S·r/D)·D, r), which is S only when r >= D: on Sovryn below par it can leave a share
    ///      worth 0 wei that the floored deposit mint paid for (SP-19 still bounds the value).
    function property_rtNoFreeShares(RoundTrip memory rt) internal {
        if (!rt.clamped) lte(shares(actor, rt.h), rt.s0, "SP-21: round trip minted free shares");
        if (rt.iFailed) return;
        (uint256 i1, bool failed) = _interest(actor, rt.k);
        if (failed) return;
        uint256 slack = rt.withdrawFirst && isLB(rt.h) ? rt.cycles * ceilDiv(rt.r / 2, RAY) : 0;
        lte(i1, rt.i0 + slack, "SP-21: round trip raised accrued interest");
    }

    /// @notice SP-22: without a clamp, a round trip costs the actor at most one virtual share per cycle
    function property_rtMaxOneShareLoss(RoundTrip memory rt) internal {
        if (rt.clamped) return;
        gte(shares(actor, rt.h) + rt.cycles, rt.s0, "SP-22: round trip over-debited shares");
    }

    /// @notice SP-23: create+delete restores the id list, idle cash exactly, and gives no lending shares, value or interest
    /// @dev Share count checked only when the delete was not clamped (value after the create >= deposit); see SP-21.
    function property_rtCreateDelete(CreateDeleteTrip memory cd) internal {
        uint64[] memory ids1 = _idsOf(actor, cd.token);
        eq(ids1.length, cd.ids0.length, "SP-23: schedule list not restored");
        if (ids1.length == cd.ids0.length) {
            for (uint256 j; j < ids1.length; j++) {
                eq(uint256(ids1[j]), uint256(cd.ids0[j]), "SP-23: create/delete reordered other ids");
            }
        }
        int256 dC = int256(MockStablecoin(cd.token).balanceOf(actor)) - int256(cd.c0);
        if (!cd.lending) {
            eq(dC, int256(0), "SP-23: idle create/delete changed actor cash");
            eq(MockStablecoin(cd.token).balanceOf(cd.h), cd.h0, "SP-23: idle create/delete changed handler cash");
            return;
        }
        int256 dS = int256(shares(actor, cd.h)) - int256(cd.s0);
        if (!cd.clamped) lte(dS, int256(0), "SP-23: create/delete minted free shares");
        int256 slack = isLB(cd.h) ? int256(cd.r) - 1 : int256(0);
        lte(dC * int256(D(cd.h)) + dS * int256(cd.r), slack, "SP-23: create/delete created value");
        if (cd.iFailed) return;
        (uint256 i1, bool failed) = _interest(actor, cd.k);
        if (!failed) lte(i1, cd.i0, "SP-23: create/delete raised accrued interest");
    }

    // ――――――――――――――――――― Batches ―――――――――――――――――――
    // The pre-call context of a batch call comes from `stateBefore` (rates, exit fee, fee settings,
    // collectors, rBTC assets, receipts, active-oracle price/validity, floor percent, router USDRIF, unlock)
    // and from the call's own `batches` argument (rows, routes, minRbtcOut); rows' pre-batch schedules come
    // from `stateBefore`'s tracked-schedule copy. `_captureBatchCtx` holds the same facts in storage, but
    // writes ~4.4 fresh slots per row (≈7M gas for a 54-row call in a fresh Medusa sequence), which does not
    // fit the 12.5M per-transaction limit together with the two snapshots, so the funnels do not call it.

    /// @return Index of the Dex handler of route k in `dexHandlers` (snapshot Dex tables).
    function _dexIdx(uint256 k) internal view returns (uint256) {
        return routes[k].handler == dexHandlers[0] ? 0 : 1;
    }

    /// @notice Rows of a batch call with the per-row ceil/clamp simulation applied.
    /// @dev Marks `sp[i].rows` for every row that matches a tracked schedule.
    function _analyseBatch(SchedPair[] memory sp, IDcaManager.Batch[] memory batches)
        internal
        view
        returns (BRow[] memory rows, BatchSim memory s)
    {
        uint256 n;
        for (uint256 b; b < batches.length; b++) {
            n += batches[b].scheduleIds.length;
        }
        rows = new BRow[](n);
        for (uint256 a; a < 4; a++) {
            for (uint256 k; k < 5; k++) {
                s.rem[a][k] = stateBefore.shares[a][k];
            }
        }
        uint256 i;
        for (uint256 b; b < batches.length; b++) {
            i = _loadBatchRows(rows, i, b, batches[b], s, sp);
        }
        for (uint256 k; k < 5; k++) {
            if (s.batchesOn[k] == 0) continue;
            uint256 prior = _rbtcAssetOf(stateBefore, k);
            uint256 now_ = _rbtcAssetOf(stateAfter, k);
            if (now_ >= prior) s.q[k] = now_ - prior;
            else s.qFell[k] = true;
        }
    }

    function _loadBatchRows(
        BRow[] memory rows,
        uint256 i,
        uint256 b,
        IDcaManager.Batch memory batch,
        BatchSim memory s,
        SchedPair[] memory sp
    ) internal view returns (uint256) {
        uint256 k = _routeKOf(batch.token, batch.routeIndex);
        if (k < 5) {
            s.batchesOn[k]++;
        } else {
            s.foreign = true;
        }
        uint256 priorBurn = k < 5 ? s.burn[k] : 0;
        uint256 priorFund = k < 5 ? s.gFund[k] : 0;
        for (uint256 j; j < batch.scheduleIds.length; j++) {
            BRow memory r = rows[i++];
            r.b = b;
            r.k = k;
            r.token = batch.token;
            r.id = batch.scheduleIds[j];
            r.routeIndex = batch.routeIndex;
            r.sp = _spIndex(sp, r.token, r.id);
            if (r.sp >= sp.length) {
                r.ai = type(uint256).max;
                s.foreign = true;
                continue;
            }
            sp[r.sp].rows++;
            r.buyer = sp[r.sp].b.user;
            r.amount = sp[r.sp].b.purchaseAmount;
            r.ai = _accountIndex(r.buyer);
            if (k >= 5 || r.ai >= 4) {
                s.foreign = true;
                continue;
            }
            s.rowsOn[k]++;
            s.rowsOf[r.ai][k]++;
            s.gNom[k] += r.amount;
            _simRow(s, r);
        }
        if (k < 5 && batch.minRbtcOut != 0 && batch.quotedStablecoinIn != 0) {
            uint256 actualInput =
                routes[k].lending ? _cashForBurn(routes[k].handler, s.burn[k] - priorBurn) : s.gFund[k] - priorFund;
            s.minOut[k] = _satAdd(
                s.minOut[k],
                OzMath.mulDiv(batch.minRbtcOut, actualInput, batch.quotedStablecoinIn, OzMath.Rounding.Ceil)
            );
        }
        return i;
    }

    /// @dev One row of `LendingHandler._batchRetrieveStablecoin`, written from the AUDIT_GUIDE rule.
    function _simRow(BatchSim memory s, BRow memory r) internal view {
        uint256 k = r.k;
        if (!routes[k].lending) {
            r.x = r.amount;
            s.gFund[k] += r.amount;
            return;
        }
        uint256 rt = stateBefore.rate[k];
        if (rt == 0) {
            s.foreign = true;
            return;
        }
        uint256 dk = _Dk(k);
        uint256 need = ceilDiv(r.amount * dk, rt);
        uint256 have = s.rem[r.ai][k];
        if (need > have) {
            r.x = have * rt / dk;
            need = have;
            s.clamped[k] = true;
        } else {
            r.x = r.amount;
        }
        s.rem[r.ai][k] = have - need;
        s.burn[k] += need;
        s.gFund[k] += r.x;
    }

    /// @return mask Bit k set for every harness route a batch of the call names.
    function _batchRouteMask(IDcaManager.Batch[] memory batches) internal view returns (uint256 mask) {
        for (uint256 b; b < batches.length; b++) {
            uint256 k = _routeKOf(batches[b].token, batches[b].routeIndex);
            if (k < 5) mask |= 1 << k;
        }
    }

    /// @return sum Σ over ACCOUNTS of claim gains on route k, or max if any claim fell.
    function _creditSum(uint256 k) internal view returns (uint256 sum) {
        for (uint256 a; a < 4; a++) {
            uint256 b = stateBefore.claim[a][k];
            uint256 c = stateAfter.claim[a][k];
            if (c < b) return type(uint256).max;
            sum += c - b;
        }
    }

    /// @notice SP-24: per handler, Σ credits lies in [Q − rows, Q] with Q > 0; other handlers and non-participants unchanged
    function property_batchCreditsBounded(BatchSim memory s) internal {
        for (uint256 k; k < 5; k++) {
            if (s.batchesOn[k] == 0) {
                eq(
                    _rbtcAssetOf(stateAfter, k),
                    _rbtcAssetOf(stateBefore, k),
                    "SP-24: rBTC moved on a handler outside the batch"
                );
                for (uint256 a; a < 4; a++) {
                    eq(
                        stateAfter.claim[a][k],
                        stateBefore.claim[a][k],
                        "SP-24: claim moved on a handler outside the batch"
                    );
                }
                continue;
            }
            t(!s.qFell[k], "SP-24: handler rBTC fell in a batch");
            gt(s.q[k], 0, "SP-24: zero-output batch accepted");
            uint256 credited = _creditSum(k);
            if (credited == type(uint256).max) {
                t(false, "SP-24: a claim fell in a batch");
                continue;
            }
            lte(credited, s.q[k], "SP-24: credits exceed the measured output");
            gte(credited + s.rowsOn[k], s.q[k], "SP-24: more than one wei per row left uncredited");
            uint256 ci = _accountIndex(stateBefore.feeCollector[k]);
            for (uint256 a; a < 4; a++) {
                if (s.rowsOf[a][k] > 0 || a == ci) continue;
                eq(stateAfter.claim[a][k], stateBefore.claim[a][k], "SP-24: a non-participant was credited");
            }
        }
    }

    /// @notice SP-25: when the collector is not a buyer, its fee credit is at most maxFeeRate (and 5%) of the output
    function property_batchFeeCap(BatchSim memory s) internal {
        for (uint256 k; k < 5; k++) {
            if (s.batchesOn[k] == 0 || s.qFell[k]) continue;
            uint256 ci = _accountIndex(stateBefore.feeCollector[k]);
            if (ci >= 4 || s.rowsOf[ci][k] > 0) continue;
            uint256 b = stateBefore.claim[ci][k];
            uint256 c = stateAfter.claim[ci][k];
            if (c < b) continue; // SP-40 reports it
            lte(
                (c - b) * 10_000,
                s.q[k] * stateBefore.feeSettings[k].maxFeeRate,
                "SP-25: fee credit above maxFeeRate of the output"
            );
            lte((c - b) * 10_000, s.q[k] * 500, "SP-25: fee credit above the 5% cap");
        }
    }

    /// @notice SP-26: when the collector is not a buyer, buyers get >= Q·(1 − max) − rows and the collector >= Q·min − 2
    function property_batchFeeLowerBounds(BatchSim memory s) internal {
        for (uint256 k; k < 5; k++) {
            if (s.batchesOn[k] == 0 || s.qFell[k]) continue;
            uint256 ci = _accountIndex(stateBefore.feeCollector[k]);
            if (ci >= 4 || s.rowsOf[ci][k] > 0) continue;
            uint256 total = _creditSum(k);
            if (total == type(uint256).max) continue;
            uint256 fee = stateAfter.claim[ci][k] - stateBefore.claim[ci][k];
            IPurchaseFees.FeeSettings memory fs = stateBefore.feeSettings[k];
            gte(
                (total - fee + s.rowsOn[k]) * 10_000,
                s.q[k] * (10_000 - uint256(fs.maxFeeRate)),
                "SP-26: buyers credited below output minus the max fee"
            );
            gte((fee + 2) * 10_000, s.q[k] * fs.minFeeRate, "SP-26: fee credited below the min rate");
        }
    }

    /// @notice SP-27: each bought row is debited exactly its pre-batch amount; idle cash falls by the nominal sum; burn == Σ share drops
    function property_batchDebitsExact(BRow[] memory rows, BatchSim memory s, SchedPair[] memory sp) internal {
        for (uint256 i; i < rows.length; i++) {
            BRow memory r = rows[i];
            if (r.sp >= sp.length) continue; // SP-56 reports untracked rows
            SchedPair memory p = sp[r.sp];
            if (p.goneAfter || p.a.tokenBalance > p.b.tokenBalance) {
                t(false, "SP-27: bought row vanished or gained balance");
                continue;
            }
            eq(uint256(p.b.tokenBalance) - p.a.tokenBalance, r.amount, "SP-27: row debit != pre-batch purchase amount");
        }
        for (uint256 i; i < sp.length; i++) {
            SchedPair memory p = sp[i];
            if (p.rows > 0 || p.missingBefore) continue;
            t(!p.goneAfter && _sameSched(p.a, p.b), "SP-27: a schedule outside the batch changed");
        }
        for (uint256 k; k < 5; k++) {
            if (s.batchesOn[k] == 0) continue;
            if (!routes[k].lending) {
                uint256 hb = stateBefore.handlerStable[k];
                uint256 ha = stateAfter.handlerStable[k];
                gte(hb, ha, "SP-27: idle cash rose in a batch");
                if (hb >= ha) eq(hb - ha, s.gNom[k], "SP-27: idle cash fell by != the nominal sum");
            } else {
                _checkLendingBatchBurn(s, k);
            }
        }
        if (s.batchesOn[K_IDLE_DEX] > 0 && s.batchesOn[K_LB_DEX] == 0) {
            (bool ok, uint256 rin) = _routerIntake();
            t(ok, "SP-27: router USDRIF fell in a batch");
            if (ok) eq(rin, s.gNom[K_IDLE_DEX], "SP-27: router intake != idle Dex nominal sum");
        }
    }

    function _checkLendingBatchBurn(BatchSim memory s, uint256 k) internal {
        eq(stateAfter.handlerStable[k], stateBefore.handlerStable[k], "SP-27: lending batch left cash on the handler");
        uint256 drops;
        for (uint256 a; a < 4; a++) {
            uint256 sb = stateBefore.shares[a][k];
            uint256 sa = stateAfter.shares[a][k];
            if (sa > sb) {
                t(false, "SP-27: shares rose in a batch");
                return;
            }
            drops += sb - sa;
            if (s.rowsOf[a][k] == 0) eq(sa, sb, "SP-27: a non-buyer's shares moved in a batch");
        }
        uint256 rb = stateBefore.receipt[k];
        uint256 ra = stateAfter.receipt[k];
        if (ra > rb) {
            t(false, "SP-27: receipt shares rose in a batch");
            return;
        }
        eq(rb - ra, drops, "SP-27: receipt burn != sum of buyers' share drops");
    }

    /// @notice SP-28: a lending batch funds at most the debit plus one share per row; without clamp or exit fee, at least the debit
    function property_lendingBatchFunding(BatchSim memory s) internal {
        for (uint256 k; k < 5; k++) {
            if (s.batchesOn[k] == 0 || !routes[k].lending || s.qFell[k]) continue;
            uint256 slack = s.rowsOn[k] * (stateBefore.rate[k] / _Dk(k) + 2);
            bool floorApplies = !s.clamped[k] && (isLB(routes[k].handler) || stateBefore.sovrynExitFee == 0);
            if (routes[k].dex) {
                if (s.batchesOn[K_IDLE_DEX] > 0) continue; // the router intake is not separable
                (bool ok, uint256 rin) = _routerIntake();
                if (!ok) continue;
                lte(rin, s.gNom[k] + slack, "SP-28: lending batch funded more than debit + one share per row");
                if (floorApplies) gte(rin, s.gNom[k], "SP-28: lending batch under-funded without a loss");
            } else {
                lte(
                    s.q[k] * BTC_PRICE_USD,
                    s.gNom[k] + slack,
                    "SP-28: lending batch funded more than debit + one share per row"
                );
                if (floorApplies) {
                    gt((s.q[k] + 1) * BTC_PRICE_USD, s.gNom[k], "SP-28: lending batch under-funded without a loss");
                }
            }
        }
    }

    /// @notice SP-29: on idle routes the measured output equals exactly what the mock venue pays for the nominal sum
    function property_idleOutputMatchesVenue(BatchSim memory s) internal {
        for (uint256 k; k < 5; k++) {
            if (s.batchesOn[k] != 1 || routes[k].lending || s.qFell[k]) continue;
            uint256 expected = routes[k].dex ? s.gNom[k] * 997 / (1000 * dexRouterPrice) : s.gNom[k] / BTC_PRICE_USD;
            eq(s.q[k], expected, "SP-29: idle output != venue quote for the nominal sum");
        }
    }

    /// @notice SP-30: lending rows debit ceilDiv(amount·D, rate) shares or all that remain; shares and burn match the simulation
    function property_batchShareSimulation(BatchSim memory s) internal {
        if (s.foreign) return;
        for (uint256 k; k < 5; k++) {
            if (s.batchesOn[k] == 0 || !routes[k].lending) continue;
            for (uint256 a; a < 4; a++) {
                eq(stateAfter.shares[a][k], s.rem[a][k], "SP-30: shares differ from the per-row ceil/clamp simulation");
            }
            uint256 rb = stateBefore.receipt[k];
            uint256 ra = stateAfter.receipt[k];
            if (ra > rb) {
                t(false, "SP-30: receipt shares rose in a batch");
                continue;
            }
            eq(rb - ra, s.burn[k], "SP-30: receipt burn != simulated debit");
        }
    }

    /// @notice SP-31: each account's credit is exactly Σ floor(Q·(x − fee(x))/G) over its rows, plus floor(Q·ΣF/G) for the collector
    function property_batchCreditsExact(BRow[] memory rows, BatchSim memory s) internal {
        if (s.foreign) return;
        for (uint256 k; k < 5; k++) {
            if (s.batchesOn[k] != 1 || s.gFund[k] == 0 || s.qFell[k]) continue;
            uint256[4] memory expected = _expectedCredits(rows, s, k);
            for (uint256 a; a < 4; a++) {
                uint256 b = stateBefore.claim[a][k];
                uint256 c = stateAfter.claim[a][k];
                if (c < b) {
                    t(false, "SP-31: a claim fell in a batch");
                    continue;
                }
                eq(c - b, expected[a], "SP-31: rBTC credit != floor(Q * net / G)");
            }
        }
    }

    function _expectedCredits(BRow[] memory rows, BatchSim memory s, uint256 k)
        internal
        view
        returns (uint256[4] memory expected)
    {
        IPurchaseFees.FeeSettings memory fs = stateBefore.feeSettings[k];
        uint256 q = s.q[k];
        uint256 g = s.gFund[k];
        uint256 feeTotal;
        for (uint256 i; i < rows.length; i++) {
            BRow memory r = rows[i];
            if (r.k != k) continue;
            uint256 f = specFee(r.x, fs);
            if (f > r.x) f = r.x;
            feeTotal += f;
            expected[r.ai] += q * (r.x - f) / g;
        }
        uint256 ci = _accountIndex(stateBefore.feeCollector[k]);
        if (ci < 4) expected[ci] += q * feeTotal / g;
    }

    /// @notice SP-32: a single-handler Dex batch's output meets the oracle floor retrieved·percent/oraclePrice
    function property_dexOracleFloor(uint8 op, BatchSim memory s) internal {
        if (op != OP_BATCH) return;
        for (uint256 k; k < 5; k++) {
            if (s.batchesOn[k] == 0 || !routes[k].dex || s.qFell[k]) continue;
            uint256 d = _dexIdx(k);
            (bool ok, uint256 rin) = _routerIntake();
            if (!ok || stateBefore.oraclePrice[d] == 0) continue;
            gte(
                s.q[k],
                rin * stateBefore.percent[d] / stateBefore.oraclePrice[d],
                "SP-32: Dex output below the oracle floor"
            );
        }
    }

    /// @notice SP-33: every successful batch's measured output is positive and at least the swapper's minRbtcOut
    function property_minRbtcOutBinds(BatchSim memory s) internal {
        for (uint256 k; k < 5; k++) {
            if (s.batchesOn[k] == 0) continue;
            gt(s.q[k], 0, "SP-33: zero-output batch accepted");
            gte(s.q[k], s.minOut[k], "SP-33: batch filled below the swapper minimum");
        }
    }

    /// @notice SP-34: across handlers, the router's intake splits into the Dex handlers' inputs and each meets its own floor
    function property_acrossDexFloor(uint8 op, BatchSim memory s) internal {
        if (op != OP_ACROSS) return;
        bool idle = s.batchesOn[K_IDLE_DEX] > 0;
        bool lb = s.batchesOn[K_LB_DEX] > 0;
        if (!idle && !lb) return;
        (bool ok, uint256 rin) = _routerIntake();
        t(ok, "SP-34: router USDRIF fell in an across batch");
        if (!ok) return;
        uint256 gIdle = idle ? s.gNom[K_IDLE_DEX] : 0;
        gte(rin, gIdle, "SP-34: router intake below the idle Dex gross");
        if (rin < gIdle) return;
        if (idle && s.batchesOn[K_IDLE_DEX] == 1) _checkDexFloor(s, K_IDLE_DEX, gIdle);
        if (lb && s.batchesOn[K_LB_DEX] == 1) _checkDexFloor(s, K_LB_DEX, rin - gIdle);
        if (!lb) eq(rin, gIdle, "SP-34: router intake != idle Dex gross");
    }

    function _checkDexFloor(BatchSim memory s, uint256 k, uint256 gross) internal {
        uint256 d = _dexIdx(k);
        if (stateBefore.oraclePrice[d] == 0 || s.qFell[k]) return;
        gte(
            s.q[k],
            gross * stateBefore.percent[d] / stateBefore.oraclePrice[d],
            "SP-34: Dex handler below its own oracle floor in an across batch"
        );
    }

    /// @notice SP-35: a batch naming a Dex handler succeeds only with a valid active oracle; OutdatedPrice implies an invalid one
    function property_oracleValidity(IDcaManager.Batch[] memory batches, bool ok, bytes memory err) internal {
        bool anyInvalid;
        for (uint256 b; b < batches.length; b++) {
            uint256 k = _routeKOf(batches[b].token, batches[b].routeIndex);
            if (k < 5 && routes[k].dex && !stateBefore.oracleValid[_dexIdx(k)]) anyInvalid = true;
        }
        if (ok) {
            t(!anyInvalid, "SP-35: Dex batch filled against an invalid oracle");
            return;
        }
        if (_errSelector(err) == IPurchaseUniswap.PurchaseUniswap__OutdatedPrice.selector) {
            t(anyInvalid, "SP-35: OutdatedPrice with every active oracle valid");
        }
    }

    /// @notice SP-36: a batch buys only tracked, unpaused, spec-due, unique rows of its route and anchors each on the newest due slot
    function property_batchRowLegality(BRow[] memory rows, SchedPair[] memory sp) internal {
        uint256 today = _today();
        for (uint256 i; i < rows.length; i++) {
            BRow memory r = rows[i];
            if (r.sp >= sp.length) {
                t(false, "SP-36: bought a row that is not a live tracked schedule");
                continue;
            }
            SchedPair memory p = sp[r.sp];
            eq(p.rows, 1, "SP-36: a row was bought twice in one call");
            eq(uint256(p.b.routeIndex), r.routeIndex, "SP-36: row bought on another route");
            t(!p.b.paused, "SP-36: paused row bought");
            t(
                p.b.cadenceAnchor == 0 || today >= uint256(p.b.cadenceAnchor) + p.b.purchasePeriod,
                "SP-36: row bought before its due day"
            );
            if (p.goneAfter) continue; // SP-27 reports it
            _checkRowAnchor(p, today);
            eq(uint256(p.a.purchaseAmount), uint256(p.b.purchaseAmount), "SP-36: batch changed a purchase amount");
            eq(uint256(p.a.purchasePeriod), uint256(p.b.purchasePeriod), "SP-36: batch changed a period");
            t(p.a.paused == p.b.paused && p.a.user == p.b.user, "SP-36: batch changed pause flag or owner");
            eq(uint256(p.a.routeIndex), uint256(p.b.routeIndex), "SP-36: batch changed a route");
        }
    }

    function _checkRowAnchor(SchedPair memory p, uint256 today) internal {
        uint256 b = p.b.cadenceAnchor;
        uint256 a = p.a.cadenceAnchor;
        uint256 per = p.b.purchasePeriod;
        if (b == 0) {
            eq(a, today, "SP-36: first buy did not anchor today");
        } else {
            gt(a, b, "SP-36: buy did not advance the anchor");
            if (a > b && per > 0) eq((a - b) % per, 0, "SP-36: anchor left the cadence grid");
        }
        lte(a, today, "SP-36: anchor after today");
        gt(a + per, today, "SP-36: row still due after its buy");
    }

    /// @notice SP-37: cadence, pause and balance refusals agree with the spec predicate; a clean single row is never refused
    function property_cadenceRefusalsMatchSpec(
        IDcaManager.Batch[] memory batches,
        bytes memory err,
        bool cleanSingleRow
    ) internal {
        bytes4 s = _errSelector(err);
        if (cleanSingleRow) {
            t(
                s != IDcaManager.DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed.selector
                    && s != IDcaManager.DcaManager__SchedulePaused.selector
                    && s != IDcaManager.DcaManager__ScheduleBalanceNotEnoughForPurchase.selector
                    && s != IDcaManager.DcaManager__InexistentSchedule.selector
                    && s != IDcaManager.DcaManager__RouteIndexMismatch.selector,
                "SP-37: a due, unpaused, funded row was refused by DcaManager"
            );
        }
        if (s == IDcaManager.DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed.selector) {
            (address tk, uint64 id, uint256 rem) = abi.decode(_errBody(err), (address, uint64, uint256));
            (bool found, bool dup, IDcaManager.DcaSchedule memory pre) = _batchPre(batches, tk, id);
            if (!found || dup) return; // a repeated row legitimately fails its second purchase
            t(!_specDue(pre), "SP-37: CannotBuy for a spec-due row");
            gt(rem, 0, "SP-37: CannotBuy with no time remaining");
            lte(rem, uint256(pre.purchasePeriod), "SP-37: CannotBuy time remaining above the period");
        } else if (s == IDcaManager.DcaManager__SchedulePaused.selector) {
            (address tk, uint64 id) = abi.decode(_errBody(err), (address, uint64));
            (bool found,, IDcaManager.DcaSchedule memory pre) = _batchPre(batches, tk, id);
            if (found) t(pre.paused, "SP-37: SchedulePaused for an unpaused row");
        } else if (s == IDcaManager.DcaManager__ScheduleBalanceNotEnoughForPurchase.selector) {
            (address tk, uint64 id, uint256 bal) = abi.decode(_errBody(err), (address, uint64, uint256));
            (bool found,, IDcaManager.DcaSchedule memory pre) = _batchPre(batches, tk, id);
            if (found) gt(uint256(pre.purchaseAmount), bal, "SP-37: BalanceNotEnough for a funded row");
        }
    }

    /// @return found The row is a tracked schedule copied by `snapshotBefore`; dup It appears more than once in
    ///         the call; pre Its pre-call schedule.
    function _batchPre(IDcaManager.Batch[] memory batches, address token, uint64 id)
        internal
        view
        returns (bool found, bool dup, IDcaManager.DcaSchedule memory pre)
    {
        uint256 seen;
        for (uint256 b; b < batches.length; b++) {
            if (batches[b].token != token) continue;
            for (uint256 j; j < batches[b].scheduleIds.length; j++) {
                if (batches[b].scheduleIds[j] == id) seen++;
            }
        }
        dup = seen > 1;
        uint256 i = _beforeSchedIndex(token, id);
        if (i < stateBefore.schedCount && !stateBefore.schedMissing[i]) {
            found = true;
            pre = stateBefore.sched[i];
        }
    }

    /// @notice SP-38: setSchedulePaused sets only the flag and a same-value call is a no-op; paused schedules are never bought
    function property_pauseTransitions(OpCtx memory ctx, SchedPair[] memory sp) internal {
        if (_isBatchOp(ctx.op)) {
            for (uint256 i; i < sp.length; i++) {
                SchedPair memory p = sp[i];
                if (p.missingBefore || !p.b.paused) continue;
                t(
                    !p.goneAfter && p.a.tokenBalance == p.b.tokenBalance && p.a.cadenceAnchor == p.b.cadenceAnchor,
                    "SP-38: a paused schedule was bought"
                );
            }
            return;
        }
        if (!ctx.preExists) return;
        try dcaManager.getDcaSchedule(ctx.token, ctx.id) returns (IDcaManager.DcaSchedule memory d) {
            t(d.paused == ctx.flag, "SP-38: pause flag != requested value");
            eq(uint256(d.cadenceAnchor), uint256(ctx.pre.cadenceAnchor), "SP-38: pause moved the anchor");
            if (ctx.pre.paused == ctx.flag) t(_sameSched(d, ctx.pre), "SP-38: same-value pause changed the schedule");
        } catch {
            t(false, "SP-38: paused schedule unreadable");
        }
    }

    // ――――――――――――――――――― rBTC claims ―――――――――――――――――――

    /// @notice SP-39: an rBTC claim pays the caller exactly its claims on the named handlers and moves nothing else
    function property_rbtcClaimExact(OpCtx memory ctx) internal {
        uint256 a = ctx.ai;
        if (a >= 4) return;
        uint256 due;
        for (uint256 k; k < 5; k++) {
            uint256 cb = stateBefore.claim[a][k];
            uint256 ab = _rbtcAssetOf(stateBefore, k);
            uint256 aa = _rbtcAssetOf(stateAfter, k);
            if (_named(ctx, k)) {
                due += cb;
                eq(stateAfter.claim[a][k], 0, "SP-39: claim not zeroed on a named handler");
                gte(ab, aa, "SP-39: a claim raised a handler's rBTC");
                if (ab >= aa) eq(ab - aa, cb, "SP-39: handler debit != the caller's claim");
                if (routes[k].dex) {
                    eq(
                        stateAfter.handlerNative[k],
                        stateBefore.handlerNative[k],
                        "SP-39: Dex unwrap not fully forwarded"
                    );
                }
            } else {
                eq(stateAfter.claim[a][k], cb, "SP-39: claim moved on a handler not named");
                eq(aa, ab, "SP-39: rBTC moved on a handler not named");
            }
        }
        uint256 nb = stateBefore.native[a];
        uint256 na = stateAfter.native[a];
        gte(na, nb, "SP-39: a claim lowered the caller's native balance");
        if (na >= nb) eq(na - nb, due, "SP-39: payout != the claimable book");
        for (uint256 b; b < 4; b++) {
            if (b != a) eq(stateAfter.native[b], stateBefore.native[b], "SP-39: a claim paid another account");
        }
    }

    /// @notice SP-40: a claim falls only through the account's own claim (to zero) and rises only in a batch on that handler
    function property_rbtcBookMovesOnlyByClaimOrBatch(OpCtx memory ctx) internal {
        bool claimOp = ctx.op == OP_RBTC_ALL;
        bool batchOp = _isBatchOp(ctx.op);
        for (uint256 a; a < 4; a++) {
            for (uint256 k; k < 5; k++) {
                uint256 b = stateBefore.claim[a][k];
                uint256 c = stateAfter.claim[a][k];
                if (c < b) {
                    t(
                        claimOp && a == ctx.ai && _named(ctx, k),
                        "SP-40: claimable rBTC fell outside the account's own claim"
                    );
                    eq(c, 0, "SP-40: a claim left a partial balance");
                } else if (c > b) {
                    t(batchOp && _named(ctx, k), "SP-40: claimable rBTC rose outside a batch on that handler");
                }
            }
        }
    }

    /// @notice SP-41: the raw claim slot never returns to 0, equals claim + 1 while non-zero, and is exactly 1 after a claim
    function property_rbtcSentinelSlot(OpCtx memory ctx) internal {
        for (uint256 a; a < 4; a++) {
            for (uint256 k; k < 5; k++) {
                uint256 rb = stateBefore.rawAccRbtc[a][k];
                uint256 ra = stateAfter.rawAccRbtc[a][k];
                uint256 c = stateAfter.claim[a][k];
                if (rb != 0) t(ra != 0, "SP-41: raw rBTC slot returned to 0");
                if (ra != 0) eq(ra, c + 1, "SP-41: raw slot != claimable + 1");
                else eq(c, 0, "SP-41: claimable rBTC on an empty raw slot");
                if (ctx.op == OP_RBTC_ALL && a == ctx.ai && _named(ctx, k) && stateBefore.claim[a][k] > 0) {
                    eq(ra, 1, "SP-41: raw slot != 1 after a claim");
                }
            }
        }
    }

    // ――――――――――――――――――― Frames and monotonicity ―――――――――――――――――――

    /// @notice SP-42: a user's own call changes no other account's claims, shares, wallets or schedules
    function property_noCrossUserEffect(OpCtx memory ctx, SchedPair[] memory sp) internal {
        for (uint256 b; b < 4; b++) {
            if (b == ctx.ai) continue;
            eq(stateAfter.doc[b], stateBefore.doc[b], "SP-42: user call moved another account's DOC");
            eq(stateAfter.usdrif[b], stateBefore.usdrif[b], "SP-42: user call moved another account's USDRIF");
            eq(stateAfter.native[b], stateBefore.native[b], "SP-42: user call moved another account's native rBTC");
            for (uint256 k; k < 5; k++) {
                eq(stateAfter.claim[b][k], stateBefore.claim[b][k], "SP-42: user call moved another account's claim");
                eq(stateAfter.shares[b][k], stateBefore.shares[b][k], "SP-42: user call moved another account's shares");
            }
        }
        for (uint256 i; i < sp.length; i++) {
            SchedPair memory p = sp[i];
            if (p.missingBefore || p.owner == ctx.caller) continue;
            t(!p.goneAfter && _sameSched(p.a, p.b), "SP-42: user call changed another owner's schedule");
        }
    }

    /// @notice SP-43: each mutator writes only its own field, on the one schedule it names
    function property_mutatorFieldFrame(OpCtx memory ctx, SchedPair[] memory sp) internal {
        _othersUnchanged(sp, ctx.token, ctx.id, "SP-43: mutator changed another schedule");
        if (!ctx.preExists) return;
        IDcaManager.DcaSchedule memory a;
        try dcaManager.getDcaSchedule(ctx.token, ctx.id) returns (IDcaManager.DcaSchedule memory d) {
            a = d;
        } catch {
            t(false, "SP-43: mutated schedule unreadable");
            return;
        }
        IDcaManager.DcaSchedule memory b = ctx.pre;
        uint8 op = ctx.op;
        t(a.user == b.user, "SP-43: mutator changed the owner");
        eq(uint256(a.routeIndex), uint256(b.routeIndex), "SP-43: mutator changed the route");
        eq(uint256(a.cadenceAnchor), uint256(b.cadenceAnchor), "SP-43: mutator moved the anchor");
        if (op == OP_UPDATE_AMOUNT) {
            eq(uint256(a.purchaseAmount), ctx.amount, "SP-43: purchase amount != requested");
            uint256 ti = _tokenIdx(ctx.token);
            if (ti < 2) gte(ctx.amount, stateBefore.minAmount[ti], "SP-43: purchase amount below the token minimum");
            lte(uint256(a.purchaseAmount), uint256(a.tokenBalance), "SP-43: purchase amount above the balance");
        } else {
            eq(uint256(a.purchaseAmount), uint256(b.purchaseAmount), "SP-43: mutator changed the purchase amount");
        }
        if (op == OP_UPDATE_PERIOD) {
            eq(uint256(a.purchasePeriod), ctx.amount, "SP-43: period != requested");
            eq(ctx.amount % 1 days, 0, "SP-43: period not whole days");
            gte(ctx.amount, stateBefore.minPeriod, "SP-43: period below the minimum");
        } else {
            eq(uint256(a.purchasePeriod), uint256(b.purchasePeriod), "SP-43: mutator changed the period");
        }
        if (op == OP_PAUSE) t(a.paused == ctx.flag, "SP-43: pause flag != requested");
        else t(a.paused == b.paused, "SP-43: mutator changed the pause flag");
        bool balanceOp = op == OP_DEPOSIT || op == OP_WITHDRAW || op == OP_WITHDRAW_INTEREST || op == OP_TOPUP;
        if (!balanceOp) eq(uint256(a.tokenBalance), uint256(b.tokenBalance), "SP-43: mutator changed the balance");
        if (op == OP_TOPUP || op == OP_WITHDRAW_INTEREST) {
            t(ctx.routeK < 5 && routes[ctx.routeK].lending, "SP-43: lending-only call succeeded on an idle route");
        }
    }

    /// @notice SP-44: a call that names no schedule changes no schedule, id list or nonce
    function property_nonScheduleCallFrame(SchedPair[] memory sp) internal {
        _othersUnchanged(sp, address(0), 0, "SP-44: non-schedule call changed a schedule");
        for (uint256 a; a < 3; a++) {
            for (uint256 ti; ti < 2; ti++) {
                t(
                    stateAfter.idsHash[a][ti] == stateBefore.idsHash[a][ti],
                    "SP-44: non-schedule call changed an id list"
                );
            }
        }
        eq(stateAfter.nonce, stateBefore.nonce, "SP-44: non-schedule call moved the nonce");
    }

    /// @notice SP-45: a live schedule's anchor never decreases, never returns to 0, and moves only when a batch buys it
    function property_anchorMonotone(OpCtx memory ctx, SchedPair[] memory sp) internal {
        bool batchOp = _isBatchOp(ctx.op);
        for (uint256 i; i < sp.length; i++) {
            SchedPair memory p = sp[i];
            if (p.missingBefore || p.goneAfter) continue;
            uint256 b = p.b.cadenceAnchor;
            uint256 a = p.a.cadenceAnchor;
            gte(a, b, "SP-45: cadence anchor decreased");
            if (b != 0) t(a != 0, "SP-45: cadence anchor returned to 0");
            if (a != b) t(batchOp && p.rows > 0, "SP-45: anchor moved outside a batch that bought it");
        }
    }

    /// @notice SP-46: the unlock block never decreases and moves only through an activation, by at least 5
    function property_unlockMonotone(OpCtx memory ctx) internal {
        uint256 ub = stateBefore.unlock;
        uint256 ua = stateAfter.unlock;
        gte(ua, ub, "SP-46: unlock block decreased");
        if (ua != ub) {
            t(ctx.op == OP_ACTIVATE, "SP-46: unlock moved outside an activation");
            gte(ua, ub + WINDOW_BLOCKS, "SP-46: unlock rose by less than five blocks");
        }
    }

    /// @notice SP-47: shares rise only by the account's own create/deposit there and fall only by its own exits or batch rows
    function property_shareChangeAttribution(OpCtx memory ctx) internal {
        uint8 op = ctx.op;
        for (uint256 a; a < 4; a++) {
            for (uint256 k; k < 5; k++) {
                if (!routes[k].lending) continue;
                uint256 b = stateBefore.shares[a][k];
                uint256 c = stateAfter.shares[a][k];
                if (c > b) {
                    t(
                        a == ctx.ai && (op == OP_CREATE || op == OP_DEPOSIT) && ctx.routeK == k,
                        "SP-47: shares rose outside the account's own create/deposit there"
                    );
                } else if (c < b) {
                    bool ownExit = a == ctx.ai
                        && (((op == OP_WITHDRAW || op == OP_WITHDRAW_INTEREST || op == OP_DELETE) && ctx.routeK == k)
                            || (op == OP_INTEREST_ALL && _named(ctx, k)));
                    bool batchRow = _isBatchOp(op) && a < 3 && ctx.ops[a][k] > 0;
                    t(ownExit || batchRow, "SP-47: shares fell outside the account's own exit or a batch row");
                }
            }
        }
    }

    /// @notice SP-48: no non-deposit, non-environment call raises any actor's accrued interest
    function property_noOpRaisesInterest() internal {
        if (stateBefore.interestReadFailed || stateAfter.interestReadFailed) return;
        for (uint256 a; a < 3; a++) {
            for (uint256 k; k < 5; k++) {
                if (!routes[k].lending) continue;
                lte(stateAfter.interest[a][k], stateBefore.interest[a][k], "SP-48: operation raised accrued interest");
            }
        }
    }

    /// @notice SP-49: no non-environment call deepens a principal shortfall beyond per-operation rounding
    function property_shortfallNotDeepened(OpCtx memory ctx) internal {
        if (stateBefore.principalReadFailed || stateAfter.principalReadFailed) return;
        for (uint256 a; a < 3; a++) {
            for (uint256 k; k < 5; k++) {
                if (!routes[k].lending) continue;
                uint256 sb = _shortfall(stateBefore, a, k);
                uint256 sa = _shortfall(stateAfter, a, k);
                uint256 n = ctx.ops[a][k];
                if (n == 0) {
                    eq(sa, sb, "SP-49: shortfall moved for an untouched account and route");
                } else {
                    lte(
                        sa,
                        sb + n * (stateBefore.rate[k] / _Dk(k) + 2),
                        "SP-49: operation deepened a principal shortfall"
                    );
                }
            }
        }
    }

    // ――――――――――――――――――― Window, refusals, allowlist ―――――――――――――――――――

    /// @notice SP-50: activation succeeds only outside a live window and sets unlock to block + 5; a live window is never renewed
    function property_activationSemantics(OpCtx memory ctx, bool ok, bytes memory err) internal {
        uint256 ub = stateBefore.unlock;
        if (ok) {
            gte(block.number, ub, "SP-50: activation extended a live window");
            eq(stateAfter.unlock, block.number + WINDOW_BLOCKS, "SP-50: unlock != block + 5");
            t(!dcaManager.canActivateProtectedPurchaseWindow(), "SP-50: window activatable right after activation");
            return;
        }
        eq(dcaManager.getUserMutationsAllowedFromBlock(), ub, "SP-50: failed activation moved unlock");
        if (block.number < ub && operationsAdmin.isSwapper(ctx.caller)) {
            t(
                _errSelector(err) == IDcaManager.DcaManager__ProtectedPurchaseWindowStillActive.selector,
                "SP-50: in-window activation by a swapper reverted with another error"
            );
        }
    }

    /// @notice SP-51: the window gates exactly the guarded calls; nothing else ever reverts UserMutationsLocked
    function property_windowGatesGuardedCalls(uint8 op, bool ok, bytes memory err, uint256 unlock) internal {
        bool inWindow = block.number < unlock;
        bool locked = _errSelector(err) == IDcaManager.DcaManager__UserMutationsLocked.selector;
        if (_isGuarded(op)) {
            if (ok) t(!inWindow, "SP-51: guarded call succeeded inside the window");
            else if (inWindow) t(locked, "SP-51: in-window guarded call reverted with another error");
            else t(!locked, "SP-51: guarded call locked outside the window");
        } else if (!ok) {
            t(!locked, "SP-51: an unguarded call reverted UserMutationsLocked");
        }
    }

    /// @notice SP-52: each refusal comes only from the operations documented to raise it
    function property_refusalAttribution(OpCtx memory ctx, bytes memory err) internal {
        bytes4 s = _errSelector(err);
        uint8 op = ctx.op;
        if (s == IDcaManager.DcaManager__SchedulePaused.selector) {
            t(_isBatchOp(op), "SP-52: SchedulePaused outside a batch");
        }
        if (s == IDcaManager.DcaManager__DepositsPaused.selector) {
            t(op == OP_CREATE || op == OP_DEPOSIT, "SP-52: DepositsPaused outside create/deposit");
        }
        if (s == IDcaManager.DcaManager__UnauthorizedSwapper.selector) {
            t(op == OP_ACTIVATE || _isBatchOp(op), "SP-52: UnauthorizedSwapper outside activation/batches");
        }
        if (s == IDcaManager.DcaManager__ProtectedPurchaseWindowStillActive.selector) {
            t(op == OP_ACTIVATE, "SP-52: WindowStillActive outside activation");
        }
        if (op == OP_INTEREST_ALL) {
            t(
                s != IDcaManager.DcaManager__TokenIsNotLent.selector
                    && s != IDcaManager.DcaManager__TokenNotAccepted.selector,
                "SP-52: interest-all refused an idle or unassigned pair instead of skipping it"
            );
        }
        if (op == OP_RBTC_ALL) {
            t(
                s != IPurchaseRbtc.PurchaseRbtc__NoAccumulatedRbtcToWithdraw.selector,
                "SP-52: rBTC-all refused a zero-balance pair instead of skipping it"
            );
        }
    }

    /// @notice SP-53: add/revoke set exactly that key; activation, batches and path switches need an authorised caller
    function property_swapperAllowlistTransitions(OpCtx memory ctx) internal {
        if (ctx.op == OP_SWAPPER_SET) {
            uint256 i = ctx.target;
            t(stateAfter.isSwapper[i] == ctx.flag, "SP-53: add/revoke did not set the swapper flag");
            t(
                stateAfter.isSwapper[1 - i] == stateBefore.isSwapper[1 - i],
                "SP-53: add/revoke changed the other swapper"
            );
        } else if (ctx.op == OP_SET_PATH) {
            t(
                ctx.caller == admin || operationsAdmin.isSwapper(ctx.caller),
                "SP-53: path switched by an unauthorised caller"
            );
        } else {
            t(operationsAdmin.isSwapper(ctx.caller), "SP-53: swapper-only call succeeded for a non-swapper");
        }
    }

    /// @notice SP-54: path switches need an allowlisted hash and touch one handler; allowlist edits flip one hash and never revoke the active path
    function property_pathStateMachine(OpCtx memory ctx, bool ok, bytes memory err) internal {
        uint8 op = ctx.op;
        if (op != OP_SET_PATH && op != OP_SET_PATH_ALLOWED) {
            for (uint256 di; di < 2; di++) {
                t(stateAfter.pathHash[di] == stateBefore.pathHash[di], "SP-54: a non-path call changed an active path");
                t(
                    stateAfter.pathAllowed[di][0] == stateBefore.pathAllowed[di][0]
                        && stateAfter.pathAllowed[di][1] == stateBefore.pathAllowed[di][1],
                    "SP-54: a non-path call changed the path allowlist"
                );
            }
            return;
        }
        uint256 d = ctx.target;
        uint256 p = ctx.pathIdx;
        bytes32 h = keccak256(_dexPath(p));
        if (!ok) {
            bytes4 s = _errSelector(err);
            if (op == OP_SET_PATH_ALLOWED && !ctx.flag && stateBefore.pathHash[d] == h) {
                t(
                    s == IPurchaseUniswap.PurchaseUniswap__CannotRevokeActivePurchasePath.selector,
                    "SP-54: active-path revoke reverted with another error"
                );
            }
            if (op == OP_SET_PATH && !stateBefore.pathAllowed[d][p]) {
                t(
                    s == IPurchaseUniswap.PurchaseUniswap__PurchasePathNotAllowed.selector,
                    "SP-54: switch to a non-allowlisted path reverted with another error"
                );
            }
            return;
        }
        t(
            stateAfter.pathHash[1 - d] == stateBefore.pathHash[1 - d],
            "SP-54: path call touched the other Dex handler's path"
        );
        t(
            stateAfter.pathAllowed[1 - d][0] == stateBefore.pathAllowed[1 - d][0]
                && stateAfter.pathAllowed[1 - d][1] == stateBefore.pathAllowed[1 - d][1],
            "SP-54: path call touched the other Dex handler's allowlist"
        );
        if (op == OP_SET_PATH) {
            t(stateAfter.pathHash[d] == h, "SP-54: active path != the requested canonical path");
            t(stateBefore.pathAllowed[d][p], "SP-54: switched to a path that was not allowlisted");
            t(
                stateAfter.pathAllowed[d][0] == stateBefore.pathAllowed[d][0]
                    && stateAfter.pathAllowed[d][1] == stateBefore.pathAllowed[d][1],
                "SP-54: path switch changed the allowlist"
            );
        } else {
            t(stateAfter.pathAllowed[d][p] == ctx.flag, "SP-54: allowlist flag != requested");
            t(stateBefore.pathAllowed[d][p] != ctx.flag, "SP-54: an unchanged permission was accepted");
            t(
                stateAfter.pathAllowed[d][1 - p] == stateBefore.pathAllowed[d][1 - p],
                "SP-54: allowlist edit flipped another hash"
            );
            t(stateAfter.pathHash[d] == stateBefore.pathHash[d], "SP-54: allowlist edit changed the active path");
            if (!ctx.flag) t(stateBefore.pathHash[d] != h, "SP-54: the active path was revoked");
        }
    }

    /// @notice SP-55: while a window is live, a row eligible at activation and not yet bought is never refused
    function property_preparedRowSurvivesWindow(IDcaManager.Batch[] memory batches, bytes memory err, bool singleRow)
        internal
    {
        bytes4 s = _errSelector(err);
        address tk;
        uint64 id;
        if (
            s == IDcaManager.DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed.selector
                || s == IDcaManager.DcaManager__ScheduleBalanceNotEnoughForPurchase.selector
        ) {
            (tk, id,) = abi.decode(_errBody(err), (address, uint64, uint256));
        } else if (
            s == IDcaManager.DcaManager__SchedulePaused.selector
                || s == IDcaManager.DcaManager__InexistentSchedule.selector
        ) {
            (tk, id) = abi.decode(_errBody(err), (address, uint64));
        } else if (s == ILendingHandler.LendingHandler__ZeroShareValue.selector) {
            // No earlier row in a single-row batch can have consumed the buyer's shares.
            t(!singleRow, "SP-55: prepared row refused for zero share value inside the window");
            return;
        } else {
            return;
        }
        (, bool dup,) = _batchPre(batches, tk, id);
        if (dup) return; // a repeated row legitimately fails its second purchase
        t(!_preparedUnbought(tk, id), "SP-55: prepared row refused inside the window");
    }

    /// @return True if (token, id) was batch-eligible at the live window's activation and no batch has bought it since.
    function _preparedUnbought(address token, uint64 id) internal view returns (bool) {
        uint256 unlock = dcaManager.getUserMutationsAllowedFromBlock();
        if (ghosts.winEpoch == 0 || block.number >= unlock || unlock != ghosts.winUnlock) return false;
        uint256 n = ghosts.winSnap.length;
        for (uint256 i; i < n; i++) {
            if (ghosts.winSnapId[i] != id || ghosts.winSnapToken[i] != token) continue;
            return ghosts.winEligible[i] && ghosts.winBatchDebit[ghosts.winEpoch][token][id] == 0;
        }
        return false;
    }

    /// @notice SP-56: a successful mutator acted on a live key owned by the caller; a batch bought only live keys of its token
    function property_mutatorsOnlyLiveOwnedKeys(OpCtx memory ctx, BRow[] memory rows) internal {
        if (_isBatchOp(ctx.op)) {
            for (uint256 i; i < rows.length; i++) {
                t(rows[i].sp != type(uint256).max, "SP-56: batch bought a key that is not a live tracked schedule");
            }
            return;
        }
        t(
            ctx.trackedOwner != address(0) && ctx.trackedOwner == ctx.caller,
            "SP-56: mutator succeeded on a key the caller does not own"
        );
    }

    /// @notice SP-57: re-assigning a pair, reusing a handler or re-registering a route always reverts with the documented error
    function property_noRouteRemap(bool ok, bytes memory err) internal {
        if (ok) {
            t(false, "SP-57: a route or handler assignment was changed");
            return;
        }
        bytes4 s = _errSelector(err);
        t(
            s == IOperationsAdmin.OperationsAdmin__HandlerAlreadyAssigned.selector
                || s == IOperationsAdmin.OperationsAdmin__HandlerAddressAlreadyInUse.selector
                || s == IOperationsAdmin.OperationsAdmin__RouteAlreadyRegistered.selector,
            "SP-57: remap attempt reverted with an unexpected error"
        );
        for (uint256 k; k < 5; k++) {
            t(
                operationsAdmin.getHandler(routes[k].token, routes[k].routeIndex) == routes[k].handler,
                "SP-57: remap attempt moved a handler"
            );
        }
    }

    // ――――――――――――――――――― Adversarial and liveness ―――――――――――――――――――

    bytes4 internal constant OWNABLE_UNAUTHORIZED = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
    bytes4 internal constant RENOUNCE_BLOCKED = bytes4(keccak256("BitChillOwnable__OwnershipCannotBeRenounced()"));

    /// @notice Rows a swapper could send that DcaManager and the handler will both accept (plan ADV-06 `cleanRows`).
    struct CleanPlan {
        uint64[] ids;
        uint256 G; // funded weights
        uint256 SR; // receipt shares the batch will burn (lending)
        uint256 cashIn; // stablecoin the venue will receive
    }

    /// @notice Measurements around one planned protected batch (SP-64, SP-65).
    struct ExecView {
        bool sameRate;
        bool priceNotWorse;
        uint256 rcpt0;
        uint256 rin0;
        uint256 q0;
        uint256 g; // Σ nominal purchase amounts of the planned rows
    }

    /// @notice Wallets, claims, shares and schedules of every account but one (SP-62).
    struct AccountsView {
        uint256[4] doc;
        uint256[4] usdrif;
        uint256[4] native;
        uint256[5][4] claim;
        uint256[5][4] shares;
        bytes32 othersSched;
    }

    function _venueOut(Route memory r, uint256 x) internal view returns (uint256) {
        return r.dex ? x * 997 / (1000 * dexRouterPrice) : x / BTC_PRICE_USD;
    }

    /// @return floorOut The Dex oracle floor for input x; valid False if the active oracle is invalid or unreadable.
    function _dexFloorOf(address h, uint256 x) internal view returns (uint256 floorOut, bool valid) {
        uint256 price;
        (price, valid) = _oracleInfo(h);
        if (price == 0) return (0, false);
        floorOut = x * IPurchaseUniswap(h).getAmountOutMinimumPercent() / price;
    }

    /// @notice The venue fills x with positive output and, on Dex, clears the oracle floor with a rounding margin.
    function _venueOk(Route memory r, uint256 x) internal view returns (bool) {
        uint256 out = _venueOut(r, x);
        if (out == 0) return false;
        if (!r.dex) return true;
        (uint256 f, bool valid) = _dexFloorOf(r.handler, x);
        return valid && out * 1e6 >= f * (1e6 + 1);
    }

    /// @notice Stablecoin the market pays the handler for burning `burned` receipt shares now.
    function _cashForBurn(address h, uint256 burned) internal view returns (uint256) {
        if (burned == 0 || !isLendingHandler(h)) return 0;
        uint256 r = rate(h);
        if (isSov(h)) {
            uint256 gross = burned * r / 1e18;
            return gross - gross * sovrynIToken.getExitFeeBps() / 10_000;
        }
        uint256 amount = burned * r / RAY;
        if ((amount * RAY + r / 2) / r < burned) amount++;
        return amount;
    }

    /// @notice Lending batch simulator over candidate rows (plan `_simLendingBatch`): drops rows whose buyer has no value left.
    function _simLendingBatch(Route memory r, uint64[] memory cand) internal view returns (CleanPlan memory cp) {
        uint64[] memory keep = new uint64[](cand.length);
        uint256 n;
        uint256[4] memory rem;
        bool[4] memory seen;
        uint256 rt = rate(r.handler);
        uint256 dk = D(r.handler);
        for (uint256 i; i < cand.length; i++) {
            IDcaManager.DcaSchedule memory d;
            try dcaManager.getDcaSchedule(r.token, cand[i]) returns (IDcaManager.DcaSchedule memory got) {
                d = got;
            } catch {
                continue;
            }
            if (!r.lending) {
                keep[n++] = cand[i];
                cp.G += d.purchaseAmount;
                continue;
            }
            uint256 a = _accountIndex(d.user);
            if (a >= 4 || rt == 0) continue;
            if (!seen[a]) {
                rem[a] = shares(d.user, r.handler);
                seen[a] = true;
            }
            uint256 need = ceilDiv(uint256(d.purchaseAmount) * dk, rt);
            uint256 w = d.purchaseAmount;
            if (need > rem[a]) {
                w = rem[a] * rt / dk;
                if (w == 0) continue;
                need = rem[a];
            }
            rem[a] -= need;
            cp.SR += need;
            cp.G += w;
            keep[n++] = cand[i];
        }
        cp.ids = new uint64[](n);
        for (uint256 i; i < n; i++) {
            cp.ids[i] = keep[i];
        }
        cp.cashIn = r.lending ? _cashForBurn(r.handler, cp.SR) : cp.G;
    }

    function _accountsView(address exclude) internal view returns (AccountsView memory v) {
        address[4] memory accts = _accounts();
        for (uint256 a; a < 4; a++) {
            v.doc[a] = doc.balanceOf(accts[a]);
            v.usdrif[a] = usdrif.balanceOf(accts[a]);
            v.native[a] = accts[a].balance;
            for (uint256 k; k < 5; k++) {
                v.claim[a][k] = claim(accts[a], routes[k].handler);
                v.shares[a][k] = shares(accts[a], routes[k].handler);
            }
        }
        // XOR of per-schedule digests: independent of `trackedSchedules` order, which swap-pops on delete.
        uint256 len = trackedSchedules.length;
        for (uint256 i; i < len; i++) {
            TrackedSchedule storage s = trackedSchedules[i];
            if (s.owner == exclude) continue;
            try dcaManager.getDcaSchedule(s.token, s.scheduleId) returns (IDcaManager.DcaSchedule memory d) {
                v.othersSched ^= keccak256(abi.encode(s.token, s.scheduleId, d));
            } catch {
                v.othersSched ^= keccak256(abi.encode(s.token, s.scheduleId));
            }
        }
    }

    /// @notice SP-58: outside a window, an owner can always withdraw any amount in [1, balance] or the whole balance
    function property_withdrawLiveness(bool ok, bytes memory err) internal {
        if (!ok) _failWithErr("SP-58: principal withdrawal reverted outside a window", err);
    }

    /// @notice SP-59: outside a window, an owner can always delete a schedule with its correct index
    function property_deleteLiveness(bool ok, bytes memory err) internal {
        if (!ok) _failWithErr("SP-59: delete reverted outside a window", err);
    }

    /// @notice SP-60: outside a window, interest-only and principal+interest withdrawals never revert
    function property_interestExitLiveness(bool ok, bytes memory err) internal {
        if (!ok) _failWithErr("SP-60: interest exit reverted outside a window", err);
    }

    /// @notice SP-61: any account can always claim its rBTC over any route mask
    function property_claimLiveness(bool ok, bytes memory err) internal {
        if (!ok) _failWithErr("SP-61: rBTC claim reverted", err);
    }

    /// @notice SP-62: after a full exit the actor holds no schedules, claims, LayerBank shares or Sovryn value; others untouched
    function property_fullExitAndReenter(AccountsView memory prior, uint256 ai) internal {
        address a = actors[ai];
        eq(_idsOf(a, address(doc)).length, 0, "SP-62: DOC schedules left after a full exit");
        eq(_idsOf(a, address(usdrif)).length, 0, "SP-62: USDRIF schedules left after a full exit");
        for (uint256 k; k < 5; k++) {
            eq(claim(a, routes[k].handler), 0, "SP-62: rBTC claim left after a full exit");
        }
        eq(shares(a, address(layerBankDocMoc)), 0, "SP-62: DOC LayerBank shares left after a full exit");
        eq(shares(a, address(layerBankUsdrifDex)), 0, "SP-62: USDRIF LayerBank shares left after a full exit");
        lt(
            shares(a, address(sovrynDocMoc)) * sovrynIToken.tokenPrice(),
            1e18,
            "SP-62: Sovryn value left after a full exit"
        );
        AccountsView memory v = _accountsView(a);
        for (uint256 b; b < 4; b++) {
            if (b == ai) continue;
            eq(v.doc[b], prior.doc[b], "SP-62: full exit moved another account's DOC");
            eq(v.usdrif[b], prior.usdrif[b], "SP-62: full exit moved another account's USDRIF");
            eq(v.native[b], prior.native[b], "SP-62: full exit moved another account's native rBTC");
            for (uint256 k; k < 5; k++) {
                eq(v.claim[b][k], prior.claim[b][k], "SP-62: full exit moved another account's claim");
                eq(v.shares[b][k], prior.shares[b][k], "SP-62: full exit moved another account's shares");
            }
        }
        t(v.othersSched == prior.othersSched, "SP-62: full exit changed another owner's schedule");
    }

    /// @notice SP-62: re-entry after a full exit is worth at most the deposit plus one share and carries no stale interest
    function property_reenterOnEqualTerms(uint256 k, uint256 d, uint256 v0) internal {
        address h = routes[k].handler;
        uint256 v1 = V(actor, h);
        gte(v1, v0, "SP-62: re-entry lowered the position value");
        if (v1 >= v0) lte(v1 - v0, d + rate(h) / D(h) + 1, "SP-62: re-entry worth more than the deposit + one share");
        (uint256 i1, bool failed) = _interest(actor, k);
        if (!failed) lte(i1, v0 + 1 + rate(h) / (2 * D(h)), "SP-62: re-entry inherited stale interest");
    }

    /// @notice SP-63: a batch of clean rows from an allowlisted swapper with minRbtcOut 0 never reverts when the venue can fill it
    function property_cleanBatchLiveness(bool ok, bytes memory err) internal {
        if (!ok) _failWithErr("SP-63: clean batch reverted", err);
    }

    /// @notice SP-64: a successful protected purchase preserves the quoted rate against actual input changes.
    function property_protectedBatchExecutionRate(Route memory r, ExecView memory ev, bool withQuote) internal {
        if (!withQuote) return;
        uint256 q1 = rbtcAsset(r.handler);
        gte(q1, ev.q0, "SP-64: measured output fell");
        uint256 actualInput;
        if (r.dex) {
            uint256 rin = usdrif.balanceOf(address(swapRouter));
            gte(rin, ev.rin0, "SP-64: router input balance fell");
            actualInput = rin - ev.rin0;
        } else if (r.lending) {
            uint256 now_ = receipt(r.handler);
            lte(now_, ev.rcpt0, "SP-64: receipt shares rose in a batch");
            actualInput = _cashForBurn(r.handler, ev.rcpt0 - now_);
        } else {
            actualInput = ev.g;
        }
        gte(
            (q1 - ev.q0) * ghosts.plan.cashIn,
            ghosts.plan.minOut * actualInput,
            "SP-64: actual input diluted the quoted execution rate"
        );
    }

    uint256 public quoteRoundingReverts;

    /// @notice SP-65: unchanged-price execution may refuse a one-wei rounding shortfall; successful fills preserve the quoted rate.
    function property_minRbtcOutNotWeaponized(Route memory r, ExecView memory ev, bool ok, bytes memory err) internal {
        if (!ok) {
            if (ev.sameRate && ev.priceNotWorse) {
                if (_errSelector(err) == IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum.selector) {
                    t(err.length == 68, "SP-65: malformed minimum error");
                    bytes memory args = new bytes(64);
                    for (uint256 i; i < 64; ++i) {
                        args[i] = err[i + 4];
                    }
                    (uint256 received, uint256 minimum) = abi.decode(args, (uint256, uint256));
                    t(
                        minimum > received && minimum - received == 1,
                        "SP-65: unchanged-price shortfall exceeds one output wei"
                    );
                    quoteRoundingReverts++;
                }
            }
            return;
        }
        uint256 q1 = rbtcAsset(r.handler);
        if (q1 < ev.q0) return; // SP-24 reports it
        uint256 actualIn;
        if (r.dex) {
            uint256 rin = usdrif.balanceOf(address(swapRouter));
            if (rin < ev.rin0) return;
            actualIn = rin - ev.rin0;
        } else if (r.lending) {
            uint256 now_ = receipt(r.handler);
            if (now_ > ev.rcpt0) return;
            actualIn = _cashForBurn(r.handler, ev.rcpt0 - now_);
        } else {
            actualIn = ev.g;
        }
        Plan storage pl = ghosts.plan;
        gte((q1 - ev.q0) * pl.cashIn, pl.minOut * actualIn, "SP-65: minimum diluted by a larger batch input");
    }

    /// @notice SP-66: swapper, owner, permissionless and environment calls leave every account's DOC, USDRIF and native unchanged
    function property_nonUserCallsKeepWallets() internal {
        for (uint256 a; a < 4; a++) {
            eq(stateAfter.doc[a], stateBefore.doc[a], "SP-66: a non-user call moved an account's DOC");
            eq(stateAfter.usdrif[a], stateBefore.usdrif[a], "SP-66: a non-user call moved an account's USDRIF");
            eq(stateAfter.native[a], stateBefore.native[a], "SP-66: a non-user call moved an account's native rBTC");
        }
    }

    /// @notice SP-67: no user call profits its caller: rBTC net worth unchanged, stablecoin net worth up only by LayerBank dust
    function property_noProfitPerUserCall(OpCtx memory ctx) internal {
        uint256 a = ctx.ai;
        if (a >= 4) return;
        eq(_navR(stateAfter, a), _navR(stateBefore, a), "SP-67: a user call changed the caller's rBTC net worth");
        if (a >= 3 || stateBefore.principalReadFailed || stateAfter.principalReadFailed) return;
        for (uint256 ti; ti < 2; ti++) {
            lte(
                _navS(stateAfter, a, ti),
                _navS(stateBefore, a, ti) + _navEps(ctx, ti),
                "SP-67: a user call raised the caller's stablecoin net worth"
            );
        }
    }

    function _navR(State storage s, uint256 a) internal view returns (uint256 v) {
        v = s.native[a];
        for (uint256 k; k < 5; k++) {
            v += s.claim[a][k];
        }
    }

    /// @dev Wallet + idle principal + floored lending share value of actor a in token ti.
    function _navS(State storage s, uint256 a, uint256 ti) internal view returns (uint256 v) {
        v = _walletOf(s, a, ti);
        for (uint256 k; k < 5; k++) {
            if (_tokenIdx(routes[k].token) != ti) continue;
            v += routes[k].lending ? _valueOf(s, a, k) : s.principal[a][k];
        }
    }

    /// @dev LayerBank allowance: +1 per redeem, +1 + idx/(2·RAY) per deposit (plan SP-67).
    function _navEps(OpCtx memory ctx, uint256 ti) internal view returns (uint256 eps) {
        uint8 op = ctx.op;
        for (uint256 k; k < 5; k++) {
            if (!isLB(routes[k].handler) || _tokenIdx(routes[k].token) != ti) continue;
            if (op == OP_INTEREST_ALL) {
                if (_named(ctx, k)) eps += 1;
            } else if (ctx.routeK == k) {
                if (op == OP_WITHDRAW_INTEREST) eps += 2;
                else if (op == OP_WITHDRAW || op == OP_DELETE) eps += 1;
                else if (op == OP_CREATE || op == OP_DEPOSIT) eps += 1 + stateBefore.rate[k] / (2 * RAY);
            }
        }
    }

    /// @notice SP-68: a caller that is not an allowlisted swapper cannot activate, batch or switch a Dex path
    function property_nonSwapperCannotActAsSwapper(bool ok, bytes memory err, bool pathCall, uint256 unlockBefore)
        internal
    {
        eq(dcaManager.getUserMutationsAllowedFromBlock(), unlockBefore, "SP-68: a non-swapper moved the unlock block");
        if (ok) {
            t(false, "SP-68: a non-swapper used a swapper power");
            return;
        }
        bytes4 s = _errSelector(err);
        if (pathCall) {
            t(
                s == IPurchaseUniswap.PurchaseUniswap__UnauthorizedPurchasePathSetter.selector
                    || s == IPurchaseUniswap.PurchaseUniswap__PurchasePathNotAllowed.selector,
                "SP-68: non-swapper path switch reverted with an unexpected error"
            );
        } else {
            t(
                s == IDcaManager.DcaManager__UnauthorizedSwapper.selector,
                "SP-68: non-swapper refused with an unexpected error"
            );
        }
    }

    /// @notice SP-69: direct actor calls to a handler's fund-moving or interest functions revert OnlyDcaManagerCanCall
    function property_handlersOnlyFromManager(bool ok, bytes memory err) internal {
        if (ok) {
            t(false, "SP-69: a handler accepted a direct call from an actor");
            return;
        }
        t(
            _errSelector(err) == IDcaManagerAccessControl.DcaManagerAccessControl__OnlyDcaManagerCanCall.selector,
            "SP-69: direct handler call reverted with an unexpected error"
        );
    }

    /// @notice SP-70: an actor cannot mutate another owner's schedule: NotScheduleOwner, or UserMutationsLocked when guarded in a window
    function property_noForeignScheduleMutation(bool ok, bytes memory err, bool guarded) internal {
        if (ok) {
            t(false, "SP-70: a foreign schedule mutation succeeded");
            return;
        }
        bytes4 s = _errSelector(err);
        bool locked = guarded && block.number < dcaManager.getUserMutationsAllowedFromBlock()
            && s == IDcaManager.DcaManager__UserMutationsLocked.selector;
        t(
            s == IDcaManager.DcaManager__NotScheduleOwner.selector || locked,
            "SP-70: foreign mutation refused with an unexpected error"
        );
    }

    /// @notice SP-71: owner-only setters revert for actors and swappers, and renounceOwnership reverts even for the owner
    function property_nonOwnerSettersRevert(bool ok, bytes memory err, bool renounce) internal {
        if (ok) {
            t(false, renounce ? "SP-71: ownership was renounced" : "SP-71: a non-owner changed a setting");
            return;
        }
        bytes4 expected = renounce ? RENOUNCE_BLOCKED : OWNABLE_UNAUTHORIZED;
        t(_errSelector(err) == expected, "SP-71: owner-only call refused with an unexpected error");
    }

    uint256 public intermediatePathChecks;

    /// @notice SP-72: USDT0 donated to the shared router never makes a clean Dex batch on the alternative path revert
    function property_intermediateDonationNoDos(bool ok, bytes memory err) internal {
        intermediatePathChecks++;
        if (ok) return;
        t(
            _errSelector(err) != IPurchaseUniswap.PurchaseUniswap__IntermediateBalanceChangedInRouter.selector,
            "SP-72: a router donation blocked a Dex purchase"
        );
    }

    /// @notice SP-73: valid creates, deposits and top-ups succeed in any reachable state, including inside a window
    function property_fundingLiveness(bool ok, bytes memory err) internal {
        if (!ok) _failWithErr("SP-73: a valid funding call reverted", err);
    }

    /// @notice SP-74: a re-entrant claimant collects exactly its claims (SP-39) and every re-entry attempt fails
    function property_reentrantClaimSafe(uint256 successesBefore, uint256 successesAfter) internal {
        eq(successesAfter, successesBefore, "SP-74: a re-entry during an rBTC claim succeeded");
    }

    /// @notice SP-75: an approval restorer only resets the handler's allowance to its fixed spender; nothing else moves
    function property_approvalRestorersHarmless(address h, address token, address spender) internal {
        eq(
            MockStablecoin(token).allowance(h, spender),
            type(uint256).max,
            "SP-75: restorer did not reset the allowance"
        );
        for (uint256 k; k < 5; k++) {
            eq(stateAfter.handlerStable[k], stateBefore.handlerStable[k], "SP-75: restorer moved handler cash");
            eq(stateAfter.receipt[k], stateBefore.receipt[k], "SP-75: restorer moved receipt shares");
            eq(_rbtcAssetOf(stateAfter, k), _rbtcAssetOf(stateBefore, k), "SP-75: restorer moved handler rBTC");
            t(stateAfter.feeCollector[k] == stateBefore.feeCollector[k], "SP-75: restorer changed a fee collector");
            t(
                keccak256(abi.encode(stateAfter.feeSettings[k])) == keccak256(abi.encode(stateBefore.feeSettings[k])),
                "SP-75: restorer changed fee settings"
            );
        }
        for (uint256 d; d < 2; d++) {
            eq(stateAfter.percent[d], stateBefore.percent[d], "SP-75: restorer changed the floor percent");
            t(stateAfter.oracle[d] == stateBefore.oracle[d], "SP-75: restorer changed an oracle");
        }
    }

    /// @notice SP-76: the fee equals the spec's single-floor formula, is monotone, bounded by the min/max rates and priced per row
    function property_feeCurveMatchesSpec(IPurchaseFees.FeeSettings memory fs, uint256 x1, uint256 x2) internal {
        (uint256 f1, bool ok1) = _probeFee(x1);
        (uint256 f2, bool ok2) = _probeFee(x2);
        t(ok1 && ok2, "SP-76: fee function reverted");
        if (!ok1 || !ok2) return;
        eq(f1, specFee(x1, fs), "SP-76: fee != the spec single-floor formula");
        eq(f2, specFee(x2, fs), "SP-76: fee != the spec single-floor formula");
        lte(f1, f2, "SP-76: fee decreased as the amount grew");
        lte(f1, x1 * fs.maxFeeRate / 10_000, "SP-76: fee above the max rate");
        gte(f1, x1 * fs.minFeeRate / 10_000, "SP-76: fee below the min rate");
        if (f1 <= x1 && f2 <= x2) lte(x1 - f1, x2 - f2, "SP-76: net weight decreased as the amount grew");
        uint256[] memory both = new uint256[](2);
        both[0] = x1;
        both[1] = x2;
        try feeProbe.calc(both) returns (uint256 tf, uint256[] memory net, uint256 sum) {
            eq(tf, f1 + f2, "SP-76: batch fee is not the sum of per-row fees");
            eq(net[0] + net[1] + tf, sum, "SP-76: net weights plus fee != the sum");
            eq(sum, x1 + x2, "SP-76: purchase sum != sum of amounts");
        } catch {
            t(false, "SP-76: two-row fee call reverted");
        }
    }

    /// @notice SP-77: splitting a purchase into two rows never lowers the total fee by more than 1 wei
    function property_feeSplitNoGain(uint256 x1, uint256 x2) internal {
        if (x2 <= x1) return;
        (uint256 fa, bool oka) = _probeFee(x1);
        (uint256 fb, bool okb) = _probeFee(x2 - x1);
        (uint256 fw, bool okw) = _probeFee(x2);
        if (!oka || !okb || !okw) return; // SP-76 reports reverts
        gte(fa + fb + 1, fw, "SP-77: splitting a purchase saves more than 1 wei of fee");
    }

    function _probeFee(uint256 x) internal view returns (uint256 fee, bool ok) {
        uint256[] memory one = new uint256[](1);
        one[0] = x;
        try feeProbe.calc(one) returns (uint256 tf, uint256[] memory, uint256) {
            return (tf, true);
        } catch {
            return (0, false);
        }
    }
}
