// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IFeeHandler} from "./interfaces/IFeeHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BitChillOwnable} from "./BitChillOwnable.sol";

/**
 * @title FeeHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Interpolates a purchase fee between the configured rate bounds and pays it to the
 *         collector. Inherited by TokenHandler and PurchaseRbtc.
 */
abstract contract FeeHandler is IFeeHandler, BitChillOwnable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

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
    uint256 internal constant BPS_DENOMINATOR = 10_000; // rates are basis points, so a rate times an amount divides by this denominator
    /// @notice Hard ceiling on fee rates (5%). Owner cannot set max (or a flat min==max) above this.
    uint256 internal constant MAX_FEE_RATE_CAP = 500;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

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
     * @inheritdoc IFeeHandler
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
     * @inheritdoc IFeeHandler
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
     * @inheritdoc IFeeHandler
     */
    function getFeeCollectorAddress() external view override returns (address) {
        return s_feeCollector;
    }

    /**
     * @inheritdoc IFeeHandler
     */
    function getFeeSettings() external view override returns (FeeSettings memory) {
        return _feeSettings();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
        uint16 minFeeRate = s_minFeeRate;
        uint16 maxFeeRate = s_maxFeeRate;

        if (minFeeRate == maxFeeRate) {
            (aggregatedFee, totalAmountToSpend) =
                _calculateFlatFeeAndNetAmounts(purchaseAmounts, netAmountsToSpend, minFeeRate);
            return (aggregatedFee, netAmountsToSpend, totalAmountToSpend);
        }

        FeeSettings memory feeSettings = FeeSettings({
            minFeeRate: minFeeRate,
            maxFeeRate: maxFeeRate,
            feePurchaseLowerBound: s_feePurchaseLowerBound,
            feePurchaseUpperBound: s_feePurchaseUpperBound
        });

        for (uint256 i; i < len; ++i) {
            uint256 amount = purchaseAmounts[i];
            uint256 fee = _calculateFeeWithParams(amount, feeSettings);
            aggregatedFee += fee;

            // maxFeeRate is capped at MAX_FEE_RATE_CAP (5%) by `_validateFeeSettings`, the only write path
            // for the fee rates, so `_calculateFeeWithParams` can never return a fee above its input amount.
            uint256 net;
            unchecked {
                net = amount - fee;
            }
            netAmountsToSpend[i] = net;
            totalAmountToSpend += net;
        }
    }

    /**
     * @dev Return all four fee parameters as one settings value for the external getter.
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
     * @dev Apply the variable-fee interpolation using already-loaded fee settings. The flat-rate
     *      branch also keeps this helper correct for standalone callers.
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
            return purchaseAmount * minFeeRate / BPS_DENOMINATOR;
        }

        if (purchaseAmount <= feePurchaseLowerBound) {
            return purchaseAmount * maxFeeRate / BPS_DENOMINATOR;
        }

        uint256 feeRate;
        unchecked {
            feeRate = maxFeeRate
                - ((purchaseAmount - feePurchaseLowerBound)
                    * (maxFeeRate - minFeeRate))
                    / (feePurchaseUpperBound - feePurchaseLowerBound);
        }
        return purchaseAmount * feeRate / BPS_DENOMINATOR;
    }

    /**
     * @dev Transfer `fee` of `token` to the collector and emit `FeeTransferred`. No-op when `fee` is 0.
     */
    function _transferFee(IERC20 token, uint256 fee) internal {
        if (fee == 0) return;
        address collector = s_feeCollector;
        token.safeTransfer(collector, fee);
        emit FeeHandler__FeeTransferred(address(token), collector, fee);
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Flat batches need no curve: fill `netAmountsToSpend` in place and leave the
    ///      purchase-bound storage word unread.
    function _calculateFlatFeeAndNetAmounts(
        uint256[] memory purchaseAmounts,
        uint256[] memory netAmountsToSpend,
        uint256 feeRate
    ) private pure returns (uint256 aggregatedFee, uint256 totalAmountToSpend) {
        uint256 len = purchaseAmounts.length;
        for (uint256 i; i < len; ++i) {
            uint256 amount = purchaseAmounts[i];
            uint256 fee = amount * feeRate / BPS_DENOMINATOR;
            aggregatedFee += fee;

            uint256 net;
            unchecked {
                // Fee rates are capped at 5%, so the fee cannot exceed its input amount.
                net = amount - fee;
            }
            netAmountsToSpend[i] = net;
            totalAmountToSpend += net;
        }
    }

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
}
