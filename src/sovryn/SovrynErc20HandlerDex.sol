// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseUniswap} from "src/PurchaseUniswap.sol";
import {SovrynErc20Handler} from "./SovrynErc20Handler.sol";

/**
 * @title SovrynErc20HandlerDex
 * @dev Implementation of the ISovrynErc20HandlerDex interface.
 */
contract SovrynErc20HandlerDex is SovrynErc20Handler, PurchaseUniswap {
    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param stableTokenAddress the address of the stablecoin on the blockchain of deployment
     * @param iSusdTokenAddress the address of Sovryn' iSUSD token contract
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     * @param amountOutMinimumPercent The minimum percentage of rBTC that must be received from the swap (default: 99.7%)
     * @param amountOutMinimumSafetyCheck The safety check percentage for minimum rBTC output (default: 99%)
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address iSusdTokenAddress,
        UniswapSettings memory uniswapSettings,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck,
        address initialOwner
    )
        SovrynErc20Handler(
            dcaManagerAddress, stableTokenAddress, iSusdTokenAddress, feeCollector, feeSettings, initialOwner
        )
        PurchaseUniswap(uniswapSettings, amountOutMinimumPercent, amountOutMinimumSafetyCheck)
    {}
}
