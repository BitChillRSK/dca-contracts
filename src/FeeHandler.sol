// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IFeeHandler} from "./interfaces/IFeeHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BitChillOwnable} from "./BitChillOwnable.sol";

/**
 * @title TokenHandler
 * @dev Base contract for handling various tokens.
 */
abstract contract FeeHandler is IFeeHandler, BitChillOwnable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    //////////////////////
    // State variables ///
    //////////////////////

    /// @dev Two slots. Rates never exceed MAX_FEE_RATE_CAP, so they fit uint16 beside the collector:
    ///      the word every purchase already loads for the fee rates is the one `_transferFee` needs.
    ///      The collector is declared first so it starts the word rather than being pushed out of the
    ///      12 bytes Ownable2Step leaves free next to `_pendingOwner`. Bounds are purchase amounts, so
    ///      they share the schedule's uint128.
    address internal s_feeCollector; // Address to which the fees charged to the user will be sent
    uint16 internal s_minFeeRate; // Minimum fee rate
    uint16 internal s_maxFeeRate; // Maximum fee rate
    uint128 internal s_feePurchaseLowerBound; // Spending below lower bound gets the maximum fee rate
    uint128 internal s_feePurchaseUpperBound; // Spending above upper bound gets the minimum fee rate
    uint256 constant FEE_PERCENTAGE_DIVISOR = 10_000; // feeRate will belong to [100, 200], so we need to divide by 10,000 (100 * 100)
    /// @notice Hard ceiling on fee rates (5%). Owner cannot set max (or a flat min==max) above this.
    uint256 internal constant MAX_FEE_RATE_CAP = 500;

    constructor(address feeCollector, FeeSettings memory feeSettings, address initialOwner)
        BitChillOwnable(initialOwner)
    {
        if (feeCollector == address(0)) revert FeeHandler__InvalidFeeCollector();
        _validateFeeSettings(
            feeSettings.minFeeRate,
            feeSettings.maxFeeRate,
            feeSettings.feePurchaseLowerBound,
            feeSettings.feePurchaseUpperBound
        );

        s_feeCollector = feeCollector;
        s_minFeeRate = feeSettings.minFeeRate;
        s_maxFeeRate = feeSettings.maxFeeRate;
        s_feePurchaseLowerBound = feeSettings.feePurchaseLowerBound;
        s_feePurchaseUpperBound = feeSettings.feePurchaseUpperBound;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice set the fee rate parameters
     * @param minFeeRate: the minimum fee rate
     * @param maxFeeRate: the maximum fee rate
     * @param feePurchaseLowerBound: the purchase lower bound
     * @param feePurchaseUpperBound: the purchase upper bound
     */
    function setFeeRateParams(uint256 minFeeRate, uint256 maxFeeRate, uint256 feePurchaseLowerBound, uint256 feePurchaseUpperBound)
        external
        override
        onlyOwner
    {
        _validateFeeSettings(minFeeRate, maxFeeRate, feePurchaseLowerBound, feePurchaseUpperBound);

        if (s_minFeeRate != minFeeRate) {
            s_minFeeRate = minFeeRate.toUint16();
            emit FeeHandler__MinFeeRateSet(minFeeRate);
        }
        if (s_maxFeeRate != maxFeeRate) {
            s_maxFeeRate = maxFeeRate.toUint16();
            emit FeeHandler__MaxFeeRateSet(maxFeeRate);
        }
        if (s_feePurchaseLowerBound != feePurchaseLowerBound) {
            s_feePurchaseLowerBound = feePurchaseLowerBound.toUint128();
            emit FeeHandler__PurchaseLowerBoundSet(feePurchaseLowerBound);
        }
        if (s_feePurchaseUpperBound != feePurchaseUpperBound) {
            s_feePurchaseUpperBound = feePurchaseUpperBound.toUint128();
            emit FeeHandler__PurchaseUpperBoundSet(feePurchaseUpperBound);
        }
    }

    /**
     * @notice set the fee collector address
     * @param feeCollector: the fee collector address
     */
    function setFeeCollectorAddress(address feeCollector) external override onlyOwner {
        if (feeCollector == address(0)) revert FeeHandler__InvalidFeeCollector();
        s_feeCollector = feeCollector;
        emit FeeHandler__FeeCollectorAddressSet(feeCollector);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice get the fee collector address
     * @return the fee collector address
     */
    function getFeeCollectorAddress() external view override returns (address) {
        return s_feeCollector;
    }

    /**
     * @notice get the fee settings used for purchase fee calculation
     */
    function getFeeSettings() external view override returns (FeeSettings memory) {
        return _feeSettings();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _validateFeeSettings(
        uint256 minFeeRate,
        uint256 maxFeeRate,
        uint256 feePurchaseLowerBound,
        uint256 feePurchaseUpperBound
    ) private pure {
        if (maxFeeRate > MAX_FEE_RATE_CAP) revert FeeHandler__MaxFeeRateExceedsCap();
        if (minFeeRate > maxFeeRate) revert FeeHandler__MinFeeRateCannotBeHigherThanMax();
        if (feePurchaseLowerBound >= feePurchaseUpperBound) revert FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound();
    }

    /**
     * @dev Calculates the fee based on the purchase amount.
     * @param purchaseAmount The amount of stablecoin to be swapped for rBTC in each purchase.
     * @return The fee amount to be deducted from the purchase amount.
     */
    function _calculateFee(uint256 purchaseAmount) internal view returns (uint256) {
        return _calculateFeeWithParams(purchaseAmount, _feeSettings());
    }

    /**
     * @notice Calculate the fee and net amounts for a batch of purchase amounts.
     * @param purchaseAmounts The array with the raw purchase amounts specified by users.
     * @return aggregatedFee      The total fee to be collected for all purchases.
     * @return netAmountsToSpend  An array with the net amounts (purchase amount minus fee) for each user.
     * @return totalAmountToSpend The aggregated net amount that will actually be used to buy rBTC after fee is charged.
     */
    function _calculateFeeAndNetAmounts(uint256[] memory purchaseAmounts)
        internal
        view
        returns (uint256 aggregatedFee, uint256[] memory netAmountsToSpend, uint256 totalAmountToSpend)
    {
        uint256 len = purchaseAmounts.length;
        netAmountsToSpend = new uint256[](len);
        FeeSettings memory feeSettings = _feeSettings();

        for (uint256 i; i < len; ++i) {
            uint256 amount = purchaseAmounts[i];
            uint256 fee = _calculateFeeWithParams(amount, feeSettings);
            aggregatedFee += fee;

            uint256 net = amount - fee;
            netAmountsToSpend[i] = net;
            totalAmountToSpend += net;
        }
    }

    /**
     * @dev Pack the four fee storage fields for two loads per batch: the rate word (already warm for
     *      `_transferFee`, which reads the collector beside them) and the bounds word.
     */
    function _feeSettings() internal view returns (FeeSettings memory) {
        return FeeSettings({
            minFeeRate: s_minFeeRate,
            maxFeeRate: s_maxFeeRate,
            feePurchaseLowerBound: s_feePurchaseLowerBound,
            feePurchaseUpperBound: s_feePurchaseUpperBound
        });
    }

    /**
     * @dev Same interpolation as `_calculateFee`, using already-loaded fee settings.
     */
    function _calculateFeeWithParams(uint256 purchaseAmount, FeeSettings memory feeSettings)
        internal
        pure
        returns (uint256)
    {
        uint256 minFeeRate = feeSettings.minFeeRate;
        uint256 maxFeeRate = feeSettings.maxFeeRate;
        uint256 feePurchaseLowerBound = feeSettings.feePurchaseLowerBound;
        uint256 feePurchaseUpperBound = feeSettings.feePurchaseUpperBound;

        if (minFeeRate == maxFeeRate || purchaseAmount >= feePurchaseUpperBound) {
            return purchaseAmount * minFeeRate / FEE_PERCENTAGE_DIVISOR;
        }

        if (purchaseAmount <= feePurchaseLowerBound) {
            return purchaseAmount * maxFeeRate / FEE_PERCENTAGE_DIVISOR;
        }

        uint256 feeRate;
        unchecked {
            feeRate = maxFeeRate
                - ((purchaseAmount - feePurchaseLowerBound)
                    * (maxFeeRate - minFeeRate))
                    / (feePurchaseUpperBound - feePurchaseLowerBound);
        }
        return purchaseAmount * feeRate / FEE_PERCENTAGE_DIVISOR;
    }

    /**
     * @notice transfer the fee to the fee collector
     * @param token: the token to transfer the fee to
     * @param fee: the fee to transfer
     */
    function _transferFee(IERC20 token, uint256 fee) internal {
        token.safeTransfer(s_feeCollector, fee);
    }
}
