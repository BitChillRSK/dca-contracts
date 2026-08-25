// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseUniswap} from "src/PurchaseUniswap.sol";
import {PurchaseRbtc} from "src/PurchaseRbtc.sol";
import {LendingErc20Handler} from "src/LendingErc20Handler.sol";
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
        uint256 amountOutMinimumSafetyCheck
    )
        SovrynErc20Handler(dcaManagerAddress, stableTokenAddress, iSusdTokenAddress, feeCollector, feeSettings)
        PurchaseUniswap(stableTokenAddress, uniswapSettings, amountOutMinimumPercent, amountOutMinimumSafetyCheck)
    {}

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Override the _retrieveStablecoin hook to resolve ambiguity between parent contracts
     * @param user The address of the user whose stablecoin is being retrieved
     * @param amount The amount of stablecoin wanted
     */
    function _retrieveStablecoin(address user, uint256 amount)
        internal
        override(LendingErc20Handler, PurchaseRbtc)
        returns (uint256)
    {
        return LendingErc20Handler._retrieveStablecoin(user, amount);
    }

    /**
     * @notice Override the _batchRetrieveStablecoin hook to resolve ambiguity between parent contracts
     * @param users The array of user addresses whose stablecoin is being retrieved
     * @param purchaseAmounts The array of amounts of stablecoin charged to each user
     * @param totalStablecoinToRetrieve The total amount of stablecoin wanted
     */
    function _batchRetrieveStablecoin(address[] memory users, uint256[] memory purchaseAmounts, uint256 totalStablecoinToRetrieve)
        internal
        override(LendingErc20Handler, PurchaseRbtc)
        returns (uint256)
    {
        return LendingErc20Handler._batchRetrieveStablecoin(users, purchaseAmounts, totalStablecoinToRetrieve);
    }
}
