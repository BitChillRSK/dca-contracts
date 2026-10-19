// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {ILendingHandler} from "src/interfaces/ILendingHandler.sol";

/// @notice Handles the per-handler owner and permissionless setters.
/// @dev Generated for LayerBankHandlerDex, the leaf that carries every one of them, but each call is
///      routed to a deployed handler picked by seed: fee setters reach all five handlers, Uniswap
///      setters the two Dex handlers, and `restoreLendingApproval` the three lending handlers.
abstract contract LayerBankHandlerDexHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function layerBankHandlerDex_secondary(
        uint8 selector,
        uint256 handlerSeed,
        uint256 arg0,
        uint256 arg1,
        uint256 arg2
    ) public {
        selector = uint8(selector % 9);
        if (selector == 7 || selector == 8) {
            _pathCall(selector, handlerSeed, arg0, arg1);
            return;
        }
        if (selector == 0 && !_route(handlerSeed).lending) return;
        OpCtx memory ctx = _newCtx(selector <= 1 ? OP_PERMISSIONLESS : OP_ADMIN, selector <= 1 ? actor : admin);
        snapshotBefore();
        if (selector == 0) {
            _layerBankHandlerDex_restoreLendingApproval(_route(handlerSeed).handler);
        } else if (selector == 1) {
            _layerBankHandlerDex_restoreSwapRouterApproval(_dexHandler(handlerSeed));
        } else if (selector == 2) {
            address h = _dexHandler(handlerSeed);
            uint256 safety = IPurchaseUniswap(h).getAmountOutMinimumSafetyCheck();
            _layerBankHandlerDex_setAmountOutMinimumPercent(h, clampBetween(arg0, safety, 1 ether));
        } else if (selector == 3) {
            address h = _dexHandler(handlerSeed);
            uint256 percent = IPurchaseUniswap(h).getAmountOutMinimumPercent();
            _layerBankHandlerDex_setAmountOutMinimumSafetyCheck(h, clampLte(arg0, percent));
        } else if (selector == 4) {
            _layerBankHandlerDex_setFeeCollector(_route(handlerSeed).handler, _collectorCandidate(arg0));
        } else if (selector == 5) {
            uint256 maxFeeRate = clampLte(arg1, 500);
            uint256 minFeeRate = clampLte(arg0, maxFeeRate);
            _layerBankHandlerDex_setFeeRateParams(
                _route(handlerSeed).handler, minFeeRate, maxFeeRate, clampLte(arg2, 10_000 ether)
            );
        } else {
            address oracle = arg0 % 2 == 0 ? address(mocOracle) : address(mocOracleAlt);
            _layerBankHandlerDex_setMocOracle(_dexHandler(handlerSeed), oracle);
        }
        snapshotAfter();
        if (selector == 0) {
            address h = _route(handlerSeed).handler;
            property_approvalRestorersHarmless(h, _route(handlerSeed).token, _lendingSpenderOf(h));
        } else if (selector == 1) {
            address h = _dexHandler(handlerSeed);
            property_approvalRestorersHarmless(h, address(usdrif), address(swapRouter));
        }
        _postCommon(ctx);
    }

    /// @dev Selector 7 (`setPurchasePath`, owner or a swapper) and 8 (`setPurchasePathAllowed`, owner), in try/catch.
    function _pathCall(uint8 selector, uint256 handlerSeed, uint256 arg0, uint256 arg1) internal {
        uint256 d = handlerSeed % dexHandlers.length;
        address h = dexHandlers[d];
        (address[] memory tokens, uint24[] memory fees) = _path(arg0);
        OpCtx memory ctx;
        if (selector == 7) {
            // Owner or an allowlisted swapper may switch to an allowlisted path.
            ctx = _newCtx(OP_SET_PATH, arg1 % 2 == 0 ? admin : swappers[arg1 % swappers.length]);
        } else {
            ctx = _newCtx(OP_SET_PATH_ALLOWED, admin);
            ctx.flag = arg1 % 2 == 0;
        }
        ctx.target = d;
        ctx.pathIdx = arg0 % 2;
        snapshotBefore();
        bool ok;
        bytes memory err;
        vm.prank(ctx.caller);
        if (selector == 7) {
            try IPurchaseUniswap(h).setPurchasePath(tokens, fees) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        } else {
            try IPurchaseUniswap(h).setPurchasePathAllowed(tokens, fees, ctx.flag) {
                ok = true;
            } catch (bytes memory e) {
                err = e;
            }
        }
        if (!ok) {
            _onRevert(ctx, err);
            return;
        }
        snapshotAfter();
        property_pathStateMachine(ctx, true, "");
        if (selector == 7) property_swapperAllowlistTransitions(ctx);
        _postCommon(ctx);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function _layerBankHandlerDex_restoreLendingApproval(address handler) internal asActor {
        ILendingHandler(handler).restoreLendingApproval();
    }

    function _layerBankHandlerDex_restoreSwapRouterApproval(address handler) internal asActor {
        IPurchaseUniswap(handler).restoreSwapRouterApproval();
    }

    function _layerBankHandlerDex_setAmountOutMinimumPercent(address handler, uint256 amountOutMinimumPercent)
        internal
        asAdmin
    {
        IPurchaseUniswap(handler).setAmountOutMinimumPercent(amountOutMinimumPercent);
    }

    function _layerBankHandlerDex_setAmountOutMinimumSafetyCheck(address handler, uint256 amountOutMinimumSafetyCheck)
        internal
        asAdmin
    {
        IPurchaseUniswap(handler).setAmountOutMinimumSafetyCheck(amountOutMinimumSafetyCheck);
    }

    function _layerBankHandlerDex_setFeeCollector(address handler, address newCollector) internal asAdmin {
        IPurchaseFees(handler).setFeeCollector(newCollector);
    }

    function _layerBankHandlerDex_setFeeRateParams(
        address handler,
        uint256 minFeeRate,
        uint256 maxFeeRate,
        uint256 feePurchaseLowerBound
    ) internal asAdmin {
        IPurchaseFees(handler).setFeeRateParams(minFeeRate, maxFeeRate, feePurchaseLowerBound);
    }

    function _layerBankHandlerDex_setMocOracle(address handler, address newOracle) internal asAdmin {
        IPurchaseUniswap(handler).setMocOracle(newOracle);
    }

    // ―――――――――――――――――――――――― Helpers ―――――――――――――――――――――――――――

    /// @dev The fixed spender `restoreLendingApproval` approves: the LayerBank pool or the Sovryn iToken.
    function _lendingSpenderOf(address h) internal view returns (address) {
        if (h == address(layerBankDocMoc)) return address(layerBankPoolDoc);
        if (h == address(layerBankUsdrifDex)) return address(layerBankPoolUsdrif);
        return address(sovrynIToken);
    }

    function _dexHandler(uint256 seed) internal view returns (address) {
        return dexHandlers[seed % dexHandlers.length];
    }

    /// @dev The initial collector or any actor, so a collector can also be a buyer.
    function _collectorCandidate(uint256 seed) internal view returns (address) {
        uint256 i = seed % (actors.length + 1);
        return i == actors.length ? feeCollector : actors[i];
    }

    /// @dev Path 0 is the constructor's direct pool; path 1 hops through USDT0.
    function _path(uint256 seed) internal view returns (address[] memory tokens, uint24[] memory fees) {
        if (seed % 2 == 0) {
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
}
