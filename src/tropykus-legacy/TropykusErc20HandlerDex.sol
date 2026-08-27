// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseUniswap} from "src/PurchaseUniswap.sol";
import {TropykusErc20Handler} from "./TropykusErc20Handler.sol";

/**
 * @title TropykusErc20HandlerDex
 * @notice This contract handles swaps of stablecoin for rBTC using Uniswap V3
 */
contract TropykusErc20HandlerDex is TropykusErc20Handler, PurchaseUniswap {
    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param stablecoinAddress the address of the stablecoin token
     * @param kTokenAddress the address of Tropykus' kToken contract
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     * @param amountOutMinimumPercent The minimum percentage of rBTC that must be received from the swap
     *        (deploy default: `DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT`, 99.5%)
     * @param amountOutMinimumSafetyCheck The lowest percent the owner may later configure
     *        (deploy default: `DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK`, 95%)
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
