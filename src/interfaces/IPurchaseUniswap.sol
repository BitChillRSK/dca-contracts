// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IWRBTC} from "./IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "./ICoinPairPrice.sol";

/**
 * @title IPurchaseUniswap
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for DEX swapping
 */
interface IPurchaseUniswap {
    /*//////////////////////////////////////////////////////////////
                           TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/
    struct UniswapSettings {
        IWRBTC wrBtcToken;
        ISwapRouter02 swapRouter02;
        address[] swapIntermediateTokens;
        uint24[] swapPoolFeeRates;
        ICoinPairPrice mocOracle;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PurchaseUniswap_NewPathSet(
        address[] indexed intermediateTokens, uint24[] indexed poolFeeRates, bytes indexed newPath
    );
    event PurchaseUniswap_AmountOutMinimumPercentUpdated(uint256 oldValue, uint256 newValue);
    event PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(uint256 oldValue, uint256 newValue);
    event PurchaseUniswap_OracleUpdated(address oldOracle, address newOracle);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PurchaseUniswap__WrongNumberOfTokensOrFeeRates(uint256 numberOfIntermediateTokens, uint256 numberOfFeeRates);
    error PurchaseUniswap__AmountOutMinimumPercentTooHigh();
    error PurchaseUniswap__AmountOutMinimumPercentTooLow();
    error PurchaseUniswap__AmountOutMinimumSafetyCheckTooHigh();
    error PurchaseUniswap__InvalidOracleAddress();
    error PurchaseUniswap__OutdatedPrice();
    error PurchaseUniswap__ZeroPurchaseToken();
    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets a new swap path.
     *  @param intermediateTokens The array of intermediate token addresses in the path.
     * @param poolFeeRates The array of pool fees for each swap step.
     */
    function setPurchasePath(address[] memory intermediateTokens, uint24[] memory poolFeeRates) external;

    /**
     * @notice Set the minimum percentage of rBTC that must be received from the swap.
     * @param amountOutMinimumPercent The minimum percentage of rBTC that must be received from the swap.
     */
    function setAmountOutMinimumPercent(uint256 amountOutMinimumPercent) external;
    
    /**
     * @notice Get the minimum percentage of rBTC that must be received from the swap.
     * @return The minimum percentage of rBTC that must be received from the swap.
     */
    function getAmountOutMinimumPercent() external view returns (uint256);

    /**
     * @notice Set the minimum percentage of rBTC that must be received from the swap.
     * @param amountOutMinimumSafetyCheck The minimum percentage of rBTC that must be received from the swap.
     */
    function setAmountOutMinimumSafetyCheck(uint256 amountOutMinimumSafetyCheck) external;

    /**
     * @notice Get the minimum percentage of rBTC that must be received from the swap.
     * @return The minimum percentage of rBTC that must be received from the swap.
     */
    function getAmountOutMinimumSafetyCheck() external view returns (uint256);
    
    /**
     * @notice Updates the oracle address to a new one.
     * @param newOracle The address of the new oracle to use.
     */
    function updateMocOracle(address newOracle) external;

    /**
     * @notice Get the oracle used for price checks.
     * @return The oracle used for price checks.
     */
    function getMocOracle() external view returns (ICoinPairPrice);

    /**
     * @notice Get the current swap path.
     * @return The current swap path.
     */
    function getSwapPath() external view returns (bytes memory);
}
