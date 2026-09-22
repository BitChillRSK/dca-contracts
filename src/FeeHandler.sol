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

    /// @dev Two slots. The collector starts its own word because it cannot fit in the 12 bytes left by
    ///      Ownable2Step's `_pendingOwner`. A uint112 bound then starts the next word; both bounds and
    ///      both uint16 rates fill that word exactly. The bound width remains wider than the uint96
    ///      purchase amount of any schedule.
    address internal s_feeCollector; // Address to which the fees charged to the user will be sent
    uint112 internal s_feePurchaseLowerBound; // Spending below lower bound gets the maximum fee rate
    uint112 internal s_feePurchaseUpperBound; // Spending above upper bound gets the minimum fee rate
    uint16 internal s_minFeeRate; // Minimum fee rate
    uint16 internal s_maxFeeRate; // Maximum fee rate
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
        s_feePurchaseLowerBound = uint256(feeSettings.feePurchaseLowerBound).toUint112();
        s_feePurchaseUpperBound = uint256(feeSettings.feePurchaseUpperBound).toUint112();
        s_minFeeRate = feeSettings.minFeeRate;
        s_maxFeeRate = feeSettings.maxFeeRate;
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
            s_feePurchaseLowerBound = feePurchaseLowerBound.toUint112();
            emit FeeHandler__PurchaseLowerBoundSet(feePurchaseLowerBound);
        }
        if (s_feePurchaseUpperBound != feePurchaseUpperBound) {
            s_feePurchaseUpperBound = feePurchaseUpperBound.toUint112();
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
        uint16 minFeeRate = s_minFeeRate;
        uint16 maxFeeRate = s_maxFeeRate;

        if (minFeeRate == maxFeeRate) {
            return _calculateFlatFeeAndNetAmounts(purchaseAmounts, minFeeRate);
        }

        return _calculateVariableFeeAndNetAmounts(
            purchaseAmounts,
            minFeeRate,
            maxFeeRate,
            s_feePurchaseLowerBound,
            s_feePurchaseUpperBound
        );
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
    function _calculateFeeWithParams(
        uint256 purchaseAmount,
        uint256 minFeeRate,
        uint256 maxFeeRate,
        uint256 feePurchaseLowerBound,
        uint256 feePurchaseUpperBound
    )
        internal
        pure
        returns (uint256)
    {
        if (minFeeRate == maxFeeRate || purchaseAmount >= feePurchaseUpperBound) {
            return _calculateFeeAtRate(purchaseAmount, minFeeRate);
        }

        if (purchaseAmount <= feePurchaseLowerBound) {
            return _calculateFeeAtRate(purchaseAmount, maxFeeRate);
        }

        uint256 feeRate;
        unchecked {
            feeRate = maxFeeRate
                - ((purchaseAmount - feePurchaseLowerBound)
                    * (maxFeeRate - minFeeRate))
                    / (feePurchaseUpperBound - feePurchaseLowerBound);
        }
        return _calculateFeeAtRate(purchaseAmount, feeRate);
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

    /// @dev Flat batches choose one loop and skip the per-row curve branch.
    function _calculateFlatFeeAndNetAmounts(
        uint256[] memory purchaseAmounts,
        uint256 feeRate
    )
        private
        pure
        returns (uint256 aggregatedFee, uint256[] memory netAmountsToSpend, uint256 totalAmountToSpend)
    {
        uint256 len = purchaseAmounts.length;
        netAmountsToSpend = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            uint256 amount = purchaseAmounts[i];
            uint256 fee = _calculateFeeAtRate(amount, feeRate);
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

    /// @dev Apply one basis-point rate. Shared by the flat batch and variable curve paths.
    function _calculateFeeAtRate(uint256 amount, uint256 feeRate) private pure returns (uint256) {
        return amount * feeRate / BPS_DENOMINATOR;
    }

    /// @dev Variable batches load the settings once and keep the four scalars on the stack across rows.
    function _calculateVariableFeeAndNetAmounts(
        uint256[] memory purchaseAmounts,
        uint256 minFeeRate,
        uint256 maxFeeRate,
        uint256 feePurchaseLowerBound,
        uint256 feePurchaseUpperBound
    )
        private
        pure
        returns (uint256 aggregatedFee, uint256[] memory netAmountsToSpend, uint256 totalAmountToSpend)
    {
        uint256 len = purchaseAmounts.length;
        netAmountsToSpend = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            uint256 amount = purchaseAmounts[i];
            uint256 fee = _calculateFeeWithParams(
                amount,
                minFeeRate,
                maxFeeRate,
                feePurchaseLowerBound,
                feePurchaseUpperBound
            );
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
