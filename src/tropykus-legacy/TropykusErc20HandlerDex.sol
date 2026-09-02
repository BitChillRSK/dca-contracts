// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseUniswap} from "src/PurchaseUniswap.sol";
import {TropykusErc20Handler} from "./TropykusErc20Handler.sol";

/**
 * @title TropykusErc20HandlerDex
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Tropykus lending + Uniswap V3 purchases. Legacy only: no live deploy path.
 */
contract TropykusErc20HandlerDex is TropykusErc20Handler, PurchaseUniswap {
    /**
     * @param dcaManagerAddress The DcaManager allowed to call this handler.
     * @param stablecoinAddress The stablecoin this handler lends.
     * @param kTokenAddress Tropykus kToken for that stablecoin.
     * @param uniswapSettings Router, WRBTC, path, and MoC oracle.
     * @param feeCollector Address that receives purchase fees.
     * @param feeSettings Linear fee parameters.
     * @param amountOutMinimumPercent Swap-time oracle floor, 1e18-scaled.
     * @param amountOutMinimumSafetyCheck Lowest floor the owner may configure, 1e18-scaled.
     * @param initialOwner Address that owns fee/oracle configuration immediately after deploy.
     */
    constructor(
        address dcaManagerAddress,
        address stablecoinAddress,
        address kTokenAddress,
        UniswapSettings memory uniswapSettings,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck,
        address initialOwner
    )
        TropykusErc20Handler(
            dcaManagerAddress, stablecoinAddress, kTokenAddress, feeCollector, feeSettings, initialOwner
        )
        PurchaseUniswap(uniswapSettings, amountOutMinimumPercent, amountOutMinimumSafetyCheck)
    {}
}
