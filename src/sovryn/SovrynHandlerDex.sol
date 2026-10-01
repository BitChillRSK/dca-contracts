// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PurchaseUniswap} from "../PurchaseUniswap.sol";
import {SovrynHandler} from "./SovrynHandler.sol";

/**
 * @title SovrynHandlerDex
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Sovryn lending + Uniswap V3 purchases.
 * @dev Constructor-only leaf. Only its immutable DcaManager moves principal, buys, or withdraws rBTC;
 *      the owner controls fees, oracle, path allowlist, and floor. Holds standing max stablecoin
 *      approvals to SwapRouter02 and the iSUSD token, restorable by anyone.
 */
contract SovrynHandlerDex is SovrynHandler, PurchaseUniswap {
    /**
     * @param dcaManager The DcaManager allowed to call this handler.
     * @param stablecoin The stablecoin this handler lends.
     * @param iToken Sovryn iToken for that stablecoin.
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
        address iToken,
        UniswapSettings memory uniswapSettings,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck,
        address initialOwner
    )
        SovrynHandler(dcaManager, stablecoin, iToken)
        PurchaseUniswap(
            uniswapSettings,
            FeeConfig({feeCollector: feeCollector, feeSettings: feeSettings}),
            amountOutMinimumPercent,
            amountOutMinimumSafetyCheck,
            initialOwner
        )
    {}
}
