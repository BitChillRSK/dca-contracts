// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FeeHandler} from "./FeeHandler.sol";
import {PurchaseRbtc} from "./PurchaseRbtc.sol";
import {IWRBTC} from "./interfaces/IWRBTC.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {ICoinPairPrice} from "./interfaces/ICoinPairPrice.sol";
import {IPurchaseUniswap} from "./interfaces/IPurchaseUniswap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PurchaseUniswap
 * @notice This contract handles swaps of stablecoin for rBTC using Uniswap V3
 */
abstract contract PurchaseUniswap is
    FeeHandler,
    PurchaseRbtc,
    IPurchaseUniswap
{
    using SafeERC20 for IERC20;

    //////////////////////
    // State variables ///
    //////////////////////
    IERC20 public immutable i_purchasingToken;
    IWRBTC public immutable i_wrBtcToken;
    ISwapRouter02 public immutable i_swapRouter02;
    ICoinPairPrice public s_mocOracle;
    uint256 constant HUNDRED_PERCENT = 1 ether;
    uint256 internal s_amountOutMinimumPercent;
    uint256 internal s_amountOutMinimumSafetyCheck;
    bytes internal s_swapPath;

    /**
     * @param stableTokenAddress the address of the stablecoin token on the blockchain of deployment
     * @param uniswapSettings the settings for the uniswap router
     * @param amountOutMinimumPercent The minimum percentage of rBTC that must be received from the swap (default: 99.7%)
     * @param amountOutMinimumSafetyCheck The safety check percentage for minimum rBTC output (default: 99%)
     */
    constructor(
        address stableTokenAddress,
        UniswapSettings memory uniswapSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck
    ) 
    {
        i_purchasingToken = IERC20(stableTokenAddress);
        i_swapRouter02 = uniswapSettings.swapRouter02;
        i_wrBtcToken = uniswapSettings.wrBtcToken;
        s_mocOracle = uniswapSettings.mocOracle;
        
        if (amountOutMinimumPercent > HUNDRED_PERCENT) {
            revert PurchaseUniswap__AmountOutMinimumPercentTooHigh();
        }
        if (amountOutMinimumSafetyCheck > HUNDRED_PERCENT) {
            revert PurchaseUniswap__AmountOutMinimumSafetyCheckTooHigh();
        }
        if (amountOutMinimumPercent < amountOutMinimumSafetyCheck) {
            revert PurchaseUniswap__AmountOutMinimumPercentTooLow();
        }
        
        s_amountOutMinimumPercent = amountOutMinimumPercent;
        s_amountOutMinimumSafetyCheck = amountOutMinimumSafetyCheck;
        
        setPurchasePath(uniswapSettings.swapIntermediateTokens, uniswapSettings.swapPoolFeeRates);
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @param buyer: the user on behalf of which the contract is making the rBTC purchase
     * @param purchaseAmount: the amount to spend on rBTC
     * @notice this function will be called periodically through a CRON job running on a web server
     */
    function buyRbtc(address buyer, bytes32 scheduleId, uint256 purchaseAmount)
        external
        override
        onlyDcaManager
    {
        // Retrieve the stablecoin to spend
        purchaseAmount = _retrieveStablecoin(buyer, purchaseAmount);

        // Charge fee
        uint256 fee = _calculateFee(purchaseAmount);
        uint256 netPurchaseAmount = purchaseAmount - fee;
        _transferFee(i_purchasingToken, fee);

        // Swap stablecoin for WRBTC
        uint256 wrBtcPurchased = _swapStablecoinForWrbtc(netPurchaseAmount);

        if (wrBtcPurchased > 0) {
            s_usersAccumulatedRbtc[buyer] += wrBtcPurchased;
            emit PurchaseRbtc__RbtcBought(
                buyer, address(i_purchasingToken), wrBtcPurchased, scheduleId, netPurchaseAmount
            );
        } else {
            revert PurchaseRbtc__RbtcPurchaseFailed(buyer, address(i_purchasingToken));
        }
    }

    /**
     * @notice batch buy rBTC
     * @param buyers: the users on behalf of which the contract is making the rBTC purchase
     * @param scheduleIds: the schedule ids
     * @param purchaseAmounts: the amounts to spend on rBTC
     */
    function batchBuyRbtc(
        address[] memory buyers,
        bytes32[] memory scheduleIds,
        uint256[] memory purchaseAmounts
    ) external override onlyDcaManager {
        uint256 numOfPurchases = buyers.length;

        // Calculate net amounts
        (uint256 aggregatedFee, uint256[] memory netStablecoinAmountsToSpend, uint256 totalNetStablecoinPlanned) =
            _calculateFeeAndNetAmounts(purchaseAmounts);

        // Retrieve the stablecoin to spend
        // @notice we spend the stablecoin we actually received, never the gross amount we asked the lending protocol for
        uint256 totalStablecoinAmountToSpend = _batchRetrieveStablecoin(buyers, purchaseAmounts, totalNetStablecoinPlanned + aggregatedFee); // totalNetStablecoinPlanned (on rBTC) + aggregatedFee (charged by BitChill)
        if (totalStablecoinAmountToSpend <= aggregatedFee) {
            revert PurchaseRbtc__StablecoinRetrievedBelowFee(totalStablecoinAmountToSpend, aggregatedFee);
        }
        totalStablecoinAmountToSpend -= aggregatedFee;

        // Charge fees
        _transferFee(i_purchasingToken, aggregatedFee);

        // Swap stablecoin for wrBTC
        uint256 wrBtcPurchased = _swapStablecoinForWrbtc(totalStablecoinAmountToSpend);
        if (wrBtcPurchased == 0) revert PurchaseRbtc__RbtcBatchPurchaseFailed(address(i_purchasingToken));

        for (uint256 i; i < numOfPurchases; ++i) {
            // @notice the planned net amounts are only allocation weights: they sum to totalNetStablecoinPlanned,
            // so the shares below sum to exactly 1 even when the redemption paid less. Both the rBTC credited
            // and the stablecoin reported as spent are shares of what actually moved.
            uint256 usersPurchasedWrbtc = wrBtcPurchased * netStablecoinAmountsToSpend[i] / totalNetStablecoinPlanned;
            uint256 usersStablecoinSpent = totalStablecoinAmountToSpend * netStablecoinAmountsToSpend[i] / totalNetStablecoinPlanned;
            s_usersAccumulatedRbtc[buyers[i]] += usersPurchasedWrbtc;
            emit PurchaseRbtc__RbtcBought(
                buyers[i], address(i_purchasingToken), usersPurchasedWrbtc, scheduleIds[i], usersStablecoinSpent
            );
        }
        emit PurchaseRbtc__SuccessfulRbtcBatchPurchase(
            address(i_purchasingToken), wrBtcPurchased, totalStablecoinAmountToSpend
        );
    }

    /**
     * @param user: the user to withdraw the rBTC to
     * @notice the user can at any time withdraw the rBTC that has been accumulated through periodical purchases
     */
    function withdrawAccumulatedRbtc(address user) external override onlyDcaManager {
        uint256 rbtcBalance = _withdrawRbtcChecksEffects(user);

        // Unwrap rBTC
        i_wrBtcToken.withdraw(rbtcBalance);

        // Transfer RBTC from this contract back to the user
        _withdrawRbtc(user, rbtcBalance);
    }

    /**
     * @notice Sets a new swap path.
     *  @param intermediateTokens The array of intermediate token addresses in the path.
     * @param poolFeeRates The array of pool fees for each swap step.
     */
    function setPurchasePath(address[] memory intermediateTokens, uint24[] memory poolFeeRates)
        public
        override
        onlyOwner
    {
        if (poolFeeRates.length != intermediateTokens.length + 1) {
            revert PurchaseUniswap__WrongNumberOfTokensOrFeeRates(intermediateTokens.length, poolFeeRates.length);
        }

        bytes memory newPath = abi.encodePacked(address(i_purchasingToken));
        for (uint256 i = 0; i < intermediateTokens.length; i++) {
            newPath = abi.encodePacked(newPath, poolFeeRates[i], intermediateTokens[i]);
        }

        newPath = abi.encodePacked(newPath, poolFeeRates[poolFeeRates.length - 1], address(i_wrBtcToken));

        s_swapPath = newPath;
        emit PurchaseUniswap_NewPathSet(intermediateTokens, poolFeeRates, s_swapPath);
    }

    /**
     * @notice Set the minimum percentage of rBTC that must be received from the swap.
     * @param amountOutMinimumPercent The minimum percentage of rBTC that must be received from the swap.
     */
    function setAmountOutMinimumPercent(uint256 amountOutMinimumPercent) external onlyOwner {
        if (amountOutMinimumPercent > HUNDRED_PERCENT) {
            revert PurchaseUniswap__AmountOutMinimumPercentTooHigh();
        }
        if (amountOutMinimumPercent < s_amountOutMinimumSafetyCheck) {
            revert PurchaseUniswap__AmountOutMinimumPercentTooLow();
        }
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(s_amountOutMinimumPercent, amountOutMinimumPercent);
        s_amountOutMinimumPercent = amountOutMinimumPercent;
    }

    /**
     * @notice Set the minimum percentage of rBTC that must be received from the swap.
     * @param amountOutMinimumSafetyCheck The minimum percentage of rBTC that must be received from the swap.
     */
    function setAmountOutMinimumSafetyCheck(uint256 amountOutMinimumSafetyCheck) external onlyOwner {
        if (amountOutMinimumSafetyCheck > HUNDRED_PERCENT) {
            revert PurchaseUniswap__AmountOutMinimumSafetyCheckTooHigh();
        }
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(s_amountOutMinimumSafetyCheck, amountOutMinimumSafetyCheck);
        s_amountOutMinimumSafetyCheck = amountOutMinimumSafetyCheck;
    }

    /**
     * @notice Updates the oracle address to a new one.
     * @param newOracle The address of the new oracle to use.
     */
    function updateMocOracle(address newOracle) external override onlyOwner {
        if (newOracle == address(0)) {
            revert PurchaseUniswap__InvalidOracleAddress();
        }
        emit PurchaseUniswap_OracleUpdated(address(s_mocOracle), newOracle);
        s_mocOracle = ICoinPairPrice(newOracle);
    }

    /**
     * @notice Get the minimum percentage of rBTC that must be received from the swap.
     * @return The minimum percentage of rBTC that must be received from the swap.
     */     
    function getAmountOutMinimumPercent() external view returns (uint256) {
        return s_amountOutMinimumPercent;
    }

    /**
     * @notice Get the minimum percentage of rBTC that must be received from the swap.
     * @return The minimum percentage of rBTC that must be received from the swap.
     */
    function getAmountOutMinimumSafetyCheck() external view returns (uint256) {
        return s_amountOutMinimumSafetyCheck;
    }

    /**
     * @notice Get the oracle used for price checks.
     * @return The oracle used for price checks.
     */
    function getMocOracle() external view returns (ICoinPairPrice) {
        return s_mocOracle;
    }

    /**
     * @notice Get the current swap path.
     * @return The current swap path.
     */
    function getSwapPath() external view returns (bytes memory) {
        return s_swapPath;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @param stablecoinAmountToSpend the amount of stablecoin to swap for rBTC
     * @return amountOut the amount of WRBTC this contract actually received
     * @dev The router's return value is treated as success/failure only; the measured WRBTC balance delta is
     * the amount we can credit. amountOutMinimum still bounds the swap.
     */
    function _swapStablecoinForWrbtc(uint256 stablecoinAmountToSpend) internal returns (uint256 amountOut) {
        // Approve the router to spend stablecoin.
        TransferHelper.safeApprove(address(i_purchasingToken), address(i_swapRouter02), stablecoinAmountToSpend);

        // Set up the swap parameters
        IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter.ExactInputParams({
            path: s_swapPath,
            recipient: address(this),
            amountIn: stablecoinAmountToSpend,
            amountOutMinimum: _getAmountOutMinimum(stablecoinAmountToSpend)
        });

        uint256 wrBtcBalanceBefore = i_wrBtcToken.balanceOf(address(this));
        i_swapRouter02.exactInput(params);
        amountOut = i_wrBtcToken.balanceOf(address(this)) - wrBtcBalanceBefore;
    }

    /**
     * @param stablecoinAmountToSpend the amount of stablecoin to swap for rBTC
     * @return minimumRbtcAmount the minimum amount of rBTC that must be received
     * @dev Verifies that the oracle price is valid and up-to-date before using it
     */
    function _getAmountOutMinimum(uint256 stablecoinAmountToSpend) internal view returns (uint256 minimumRbtcAmount) {
        (uint256 currentPrice, bool isValid, ) = s_mocOracle.getPriceInfo();
        if (!isValid) revert PurchaseUniswap__OutdatedPrice();
        minimumRbtcAmount = (stablecoinAmountToSpend * s_amountOutMinimumPercent) / currentPrice;
    }

}
