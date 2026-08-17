// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseUniswap} from "src/PurchaseUniswap.sol";
import {PurchaseRbtc} from "src/PurchaseRbtc.sol";
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
     * @param minPurchaseAmount  the minimum amount of stablecoin for periodic purchases
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     * @param amountOutMinimumPercent The minimum percentage of rBTC that must be received from the swap (default: 99.7%)
     * @param amountOutMinimumSafetyCheck The safety check percentage for minimum rBTC output (default: 99%)
     */
    constructor(
        address dcaManagerAddress,
        address stablecoinAddress,
        address kTokenAddress,
        UniswapSettings memory uniswapSettings,
        uint256 minPurchaseAmount,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck,
        uint256 exchangeRateDecimals
    )
        TropykusErc20Handler(
            dcaManagerAddress,
            stablecoinAddress,
            kTokenAddress,
            feeCollector,
            feeSettings,
            exchangeRateDecimals
        )
        PurchaseUniswap(
            stablecoinAddress, 
            uniswapSettings, 
            amountOutMinimumPercent, 
            amountOutMinimumSafetyCheck
        )
    {}

    /**
     * @notice Override the _redeemStablecoin function to resolve ambiguity between parent contracts
     * @param user The address of the user for whom the stablecoin is being redeemed
     * @param amount The amount of stablecoin to redeem
     */
    function _redeemStablecoin(address user, uint256 amount)
        internal
        override(TropykusErc20Handler, PurchaseRbtc)
        returns (uint256)
    {
        // Call TropykusErc20Handler's version of _redeemStablecoin
        return TropykusErc20Handler._redeemStablecoin(user, amount);
    }

    /**
     * @notice Override the _batchRedeemStablecoin function to resolve ambiguity between parent contracts
     * @param users The array of user addresses for whom the stablecoin is being redeemed
     * @param purchaseAmounts The array of amounts of stablecoin to redeem for each user
     * @param totalStablecoinAmountToRedeem The total amount of stablecoin to redeem from Tropykus
     */
    function _batchRedeemStablecoin(address[] memory users, uint256[] memory purchaseAmounts, uint256 totalStablecoinAmountToRedeem)
        internal
        override(TropykusErc20Handler, PurchaseRbtc)
        returns (uint256)
    {
        // Call TropykusErc20Handler's version of _batchRedeemStablecoin
        return TropykusErc20Handler._batchRedeemStablecoin(users, purchaseAmounts, totalStablecoinAmountToRedeem);
    }
}
