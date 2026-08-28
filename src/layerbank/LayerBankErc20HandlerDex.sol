// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseUniswap} from "src/PurchaseUniswap.sol";
import {LayerBankErc20Handler} from "./LayerBankErc20Handler.sol";

/**
 * @title LayerBankErc20HandlerDex
 * @notice LayerBank lending + Uniswap V3 purchases. One bytecode, two deployments (USDRIF and USDT0).
 * @dev Constructor-only leaf, same shape as `SovrynErc20HandlerDex`. The funding base is listed
 *      first so `i_stableToken` is set before `PurchaseUniswap` builds the swap path.
 */
contract LayerBankErc20HandlerDex is LayerBankErc20Handler, PurchaseUniswap {
    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param stableTokenAddress the address of the stablecoin on the blockchain of deployment
     * @param aTokenAddress the address of LayerBank's aToken for this stablecoin
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     * @param amountOutMinimumPercent The minimum percentage of rBTC that must be received from the swap
     *        (deploy default: `DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT`, 99.5%)
     * @param amountOutMinimumSafetyCheck The lowest percent the owner may later configure
     *        (deploy default: `DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK`, 95%)
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address aTokenAddress,
        UniswapSettings memory uniswapSettings,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck,
        address initialOwner
    )
        LayerBankErc20Handler(
            dcaManagerAddress, stableTokenAddress, aTokenAddress, feeCollector, feeSettings, initialOwner
        )
        PurchaseUniswap(uniswapSettings, amountOutMinimumPercent, amountOutMinimumSafetyCheck)
    {}
}
