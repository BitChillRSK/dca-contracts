// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IPurchaseFees} from "./interfaces/IPurchaseFees.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BitChillOwnable} from "./BitChillOwnable.sol";

/**
 * @title PurchaseFees
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Fee-rate config for the purchase branch; `PurchaseRbtc` credits the collector.
 */
abstract contract PurchaseFees is IPurchaseFees, BitChillOwnable {
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BPS_DENOMINATOR = 10_000; // rates are basis points, so a rate times an amount divides by this denominator
    /// @notice Hard ceiling on fee rates (5%). Owner cannot set max (or a flat min==max) above this.
    uint256 internal constant MAX_FEE_RATE_CAP = 500;

    /**
     * @dev Two slots. The collector starts its own word because it cannot fit in the 12 bytes left by
     *      Ownable2Step's `_pendingOwner`. A uint112 bound then starts the next word alongside
     *      both uint16 rates. The bound width remains wider than the uint96
     *      purchase amount of any schedule.
     */
    address internal s_feeCollector;
    uint112 internal s_feePurchaseLowerBound;
    uint16 internal s_minFeeRate;
    uint16 internal s_maxFeeRate;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address feeCollector, FeeSettings memory feeSettings, address initialOwner)
        BitChillOwnable(initialOwner)
    {
        if (feeCollector == address(0)) revert PurchaseFees__InvalidFeeCollector();
        _validateFeeSettings(feeSettings.minFeeRate, feeSettings.maxFeeRate);

        s_feeCollector = feeCollector;
        s_feePurchaseLowerBound = feeSettings.feePurchaseLowerBound;
        s_minFeeRate = feeSettings.minFeeRate;
        s_maxFeeRate = feeSettings.maxFeeRate;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPurchaseFees
    function setFeeRateParams(uint256 minFeeRate, uint256 maxFeeRate, uint256 feePurchaseLowerBound)
        external
        override
        onlyOwner
    {
        _validateFeeSettings(minFeeRate, maxFeeRate);

        if (s_minFeeRate != minFeeRate) {
            s_minFeeRate = minFeeRate.toUint16();
            emit PurchaseFees__MinFeeRateSet(minFeeRate);
        }
        if (s_maxFeeRate != maxFeeRate) {
            s_maxFeeRate = maxFeeRate.toUint16();
            emit PurchaseFees__MaxFeeRateSet(maxFeeRate);
        }
        if (s_feePurchaseLowerBound != feePurchaseLowerBound) {
            s_feePurchaseLowerBound = feePurchaseLowerBound.toUint112();
            emit PurchaseFees__PurchaseLowerBoundSet(feePurchaseLowerBound);
        }
    }

    /// @inheritdoc IPurchaseFees
    function setFeeCollector(address feeCollector) external override onlyOwner {
        if (feeCollector == address(0)) revert PurchaseFees__InvalidFeeCollector();
        s_feeCollector = feeCollector;
        emit PurchaseFees__FeeCollectorAddressSet(feeCollector);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPurchaseFees
    function getFeeCollector() external view override returns (address) {
        return s_feeCollector;
    }

    /// @inheritdoc IPurchaseFees
    function getFeeSettings() external view override returns (FeeSettings memory) {
        return FeeSettings({
            minFeeRate: s_minFeeRate, maxFeeRate: s_maxFeeRate, feePurchaseLowerBound: s_feePurchaseLowerBound
        });
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Fee and net weight per row. Callers allocate measured output over `purchaseAmountsSum`;
     *      these are not venue spend amounts.
     * @param purchaseAmounts May contain clamped amounts.
     * @return totalFee Sum of per-row fees in stablecoin units.
     * @return netWeights Per-row net (amount − fee), as allocation weights.
     * @return purchaseAmountsSum Sum of `purchaseAmounts` (allocation denominator).
     */
    function _calculateFeeAndNetWeights(uint256[] memory purchaseAmounts)
        internal
        view
        returns (uint256 totalFee, uint256[] memory netWeights, uint256 purchaseAmountsSum)
    {
        uint16 minFeeRate = s_minFeeRate;
        uint16 maxFeeRate = s_maxFeeRate;

        if (minFeeRate == maxFeeRate) {
            return _calculateFlatFeeAndNetWeights(purchaseAmounts, minFeeRate);
        }

        return _calculateVariableFeeAndNetWeights(purchaseAmounts, minFeeRate, maxFeeRate, s_feePurchaseLowerBound);
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev When the variable fee rate is not in use, apply the flat fee rate to all amounts.
    function _calculateFlatFeeAndNetWeights(uint256[] memory purchaseAmounts, uint256 feeRate)
        private
        pure
        returns (uint256 totalFee, uint256[] memory netWeights, uint256 purchaseAmountsSum)
    {
        uint256 len = purchaseAmounts.length;
        netWeights = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            uint256 amount = purchaseAmounts[i];
            uint256 fee = _calculateFeeAtRate(amount, feeRate);

            uint256 net;
            // The fee is at most 5% of a uint96 amount, so neither the subtraction nor the sums can overflow.
            unchecked {
                net = amount - fee;
                totalFee += fee;
                purchaseAmountsSum += amount;
            }
            netWeights[i] = net;
        }
    }

    /**
     * @dev When the variable fee rate is in use, batches load the settings once and keep the
     *      three scalars on the stack across rows.
     */
    function _calculateVariableFeeAndNetWeights(
        uint256[] memory purchaseAmounts,
        uint256 minFeeRate,
        uint256 maxFeeRate,
        uint256 feePurchaseLowerBound
    ) private pure returns (uint256 totalFee, uint256[] memory netWeights, uint256 purchaseAmountsSum) {
        uint256 len = purchaseAmounts.length;
        netWeights = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            uint256 amount = purchaseAmounts[i];
            uint256 fee = _calculateVariableFee(amount, minFeeRate, maxFeeRate, feePurchaseLowerBound);

            uint256 net;
            // The fee is at most 5% of a uint96 amount, so neither the subtraction nor the sums can overflow.
            unchecked {
                net = amount - fee;
                totalFee += fee;
                purchaseAmountsSum += amount;
            }
            netWeights[i] = net;
        }
    }

    /// @dev Round the absolute fee once so increasing the purchase amount cannot reduce its fee.
    function _calculateVariableFee(uint256 amount, uint256 minFeeRate, uint256 maxFeeRate, uint256 lowerBound)
        private
        pure
        returns (uint256)
    {
        if (amount <= lowerBound) {
            return _calculateFeeAtRate(amount, maxFeeRate);
        }

        unchecked {
            // Here L < x <= uint96.max and L*(2*x-L) <= x*x, so the entire numerator
            // is at most maxFeeRate*x*x < 2^201. The denominator is nonzero and < 2^110.
            return (minFeeRate * amount * amount + (maxFeeRate - minFeeRate) * lowerBound * (2 * amount - lowerBound))
                / (amount * BPS_DENOMINATOR);
        }
    }

    /**
     * @dev Apply one basis-point rate. Shared by the flat and variable fee rate paths. The product cannot
     *      overflow: the amount is a uint96 purchase amount and the rate is at most `MAX_FEE_RATE_CAP`.
     */
    function _calculateFeeAtRate(uint256 amount, uint256 feeRate) private pure returns (uint256) {
        unchecked {
            return amount * feeRate / BPS_DENOMINATOR;
        }
    }

    /// @dev Validate the fee settings.
    function _validateFeeSettings(uint256 minFeeRate, uint256 maxFeeRate) private pure {
        if (maxFeeRate > MAX_FEE_RATE_CAP) revert PurchaseFees__MaxFeeRateExceedsCap();
        if (minFeeRate > maxFeeRate) revert PurchaseFees__MinFeeRateCannotBeHigherThanMax();
    }
}
