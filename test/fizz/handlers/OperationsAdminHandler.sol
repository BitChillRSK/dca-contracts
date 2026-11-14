// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with OperationsAdmin
abstract contract OperationsAdminHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @dev Swapper changes act on the two harness keepers only; pauses act on assigned pairs only.
    function operationsAdmin_secondary(uint8 selector, uint256 arg0, bool flag) public {
        selector = uint8(selector % 3);
        OpCtx memory ctx;
        if (selector == 2) {
            uint256 k = arg0 % routes.length;
            Route memory r = routes[k];
            if (operationsAdmin.areDepositsPaused(r.token, r.routeIndex) == flag) return;
            ctx = _newCtx(OP_SET_DEPOSITS_PAUSED, admin);
            ctx.target = k;
            ctx.flag = flag;
            snapshotBefore();
            _operationsAdmin_setDepositsPaused(r.token, r.routeIndex, flag);
            snapshotAfter();
            property_depositPauseRespected(ctx);
        } else {
            ctx = _newCtx(OP_SWAPPER_SET, admin);
            ctx.target = arg0 % swappers.length;
            ctx.flag = selector == 0;
            snapshotBefore();
            if (selector == 0) _operationsAdmin_addSwapper(swappers[ctx.target]);
            else _operationsAdmin_revokeSwapper(swappers[ctx.target]);
            snapshotAfter();
            _ghostSwapperSetChanged();
            property_swapperAllowlistTransitions(ctx);
        }
        _postCommon(ctx);
    }

    /// @dev H6: as the owner, tries to re-assign an assigned pair, reuse an assigned handler on a free pair,
    ///      or re-register a registered route index. Each attempt must revert (SP-57). It never targets a
    ///      new route, so GL-19 stays a constant. A revert leaves no state change, so no snapshot is taken.
    function operationsAdmin_remapAttempt(uint8 which, uint256 a, uint256 b) public {
        which = uint8(which % 3);
        bool ok;
        bytes memory err;
        if (which == 0) {
            Route memory pair = routes[a % routes.length];
            address h = routes[b % routes.length].handler;
            try operationsAdmin.assignHandler(pair.token, pair.routeIndex, h) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else if (which == 1) {
            (address token, uint256 routeIndex) = _freePair(a);
            address h = routes[b % routes.length].handler;
            try operationsAdmin.assignHandler(token, routeIndex, h) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            try operationsAdmin.registerRoute(a % 3, b % 2 == 0) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        }
        property_noRouteRemap(ok, err);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function _operationsAdmin_addSwapper(address account) internal asAdmin {
        operationsAdmin.addSwapper(account);
    }

    function _operationsAdmin_revokeSwapper(address account) internal asAdmin {
        operationsAdmin.revokeSwapper(account);
    }

    function _operationsAdmin_setDepositsPaused(address token, uint256 routeIndex, bool paused) internal asAdmin {
        operationsAdmin.setDepositsPaused(token, routeIndex, paused);
    }

    // ―――――――――――――――――――――――― Helpers ―――――――――――――――――――――――――――

    /// @dev Unassigned pairs on registered routes (0..2): the only failure left for them is the reused handler.
    function _freePair(uint256 seed) internal view returns (address token, uint256 routeIndex) {
        uint256 i = seed % 4;
        if (i == 0) return (address(usdrif), SOVRYN_ROUTE);
        return (address(usdt0), i - 1);
    }
}
