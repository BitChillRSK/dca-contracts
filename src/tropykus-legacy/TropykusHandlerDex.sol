// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PurchaseUniswap} from "../PurchaseUniswap.sol";
import {TropykusHandler} from "./TropykusHandler.sol";

/**
 * @title TropykusHandlerDex
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Test-only Tropykus lending + Uniswap V3 handler; excluded from production deployment.
 * @dev Constructor-only leaf. Only its immutable DcaManager moves principal, buys, or withdraws rBTC;
 *      the owner controls fees, oracle, path allowlist, and floor. Holds standing max stablecoin
 *      approvals to SwapRouter02 and the kToken, restorable by anyone.
 */
contract TropykusHandlerDex is TropykusHandler, PurchaseUniswap {
    /**
     * @param dcaManager The DcaManager allowed to call this handler.
     * @param stablecoin The stablecoin this handler lends.
     * @param kToken Tropykus kToken for that stablecoin.
     * @param uniswapSettings Router, WRBTC, path, and MoC oracle.
     * @param feeCollector Address that receives purchase fees.
     * @param feeSettings Purchase fee parameters.
     * @param amountOutMinimumPercent Swap-time oracle floor, 1e18-scaled.
     * @param amountOutMinimumSafetyCheck Lowest floor the owner may configure, 1e18-scaled.
     * @param initialOwner Address that owns fee/oracle configuration immediately after deploy.
     */
    constructor(
        address dcaManager,
        address stablecoin,
        address kToken,
        UniswapSettings memory uniswapSettings,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck,
        address initialOwner
    )
        TropykusHandler(dcaManager, stablecoin, kToken)
        PurchaseUniswap(
            uniswapSettings,
            FeeConfig({feeCollector: feeCollector, feeSettings: feeSettings}),
            amountOutMinimumPercent,
            amountOutMinimumSafetyCheck,
            initialOwner
        )
    {}
}
