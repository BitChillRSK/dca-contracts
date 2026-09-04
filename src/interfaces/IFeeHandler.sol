// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IFeeHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Linear purchase-fee settings and collector. Inherited by TokenHandler and PurchaseRbtc.
 */
interface IFeeHandler {
    /*//////////////////////////////////////////////////////////////
                           TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice The four parameters that interpolate a purchase fee between `maxFeeRate` and `minFeeRate`.
    /// @dev Widths match FeeHandler storage: rates are capped at 5% (`MAX_FEE_RATE_CAP`) so they fit
    ///      uint16, and the bounds are purchase amounts, so they carry the schedule's uint128.
    ///      The constructor takes this struct and assigns each field straight through, so these
    ///      types are the check; `setFeeRateParams` takes uint256 and SafeCasts at the write.
    ///      Either way `_validateFeeSettings` runs on the values first.
    struct FeeSettings {
        uint16 minFeeRate; // the lowest possible fee
        uint16 maxFeeRate; // the highest possible fee
        uint128 feePurchaseLowerBound; // the purchase amount below which max fee is applied
        uint128 feePurchaseUpperBound; // the purchase amount above which min fee is applied
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Owner set the minimum fee rate.
    event FeeHandler__MinFeeRateSet(uint256 minFeeRate);
    /// @notice Owner set the maximum fee rate.
    event FeeHandler__MaxFeeRateSet(uint256 maxFeeRate);
    /// @notice Owner set the purchase amount below which the maximum fee rate applies.
    event FeeHandler__PurchaseLowerBoundSet(uint256 feePurchaseLowerBound);
    /// @notice Owner set the purchase amount above which the minimum fee rate applies.
    event FeeHandler__PurchaseUpperBoundSet(uint256 feePurchaseUpperBound);
    /// @notice Owner set the address that receives purchase fees.
    event FeeHandler__FeeCollectorAddressSet(address indexed feeCollector);
    /// @notice A purchase fee was transferred to the collector.
    /// @dev One log per batch for the aggregated fee. A zero fee is not logged.
    event FeeHandler__FeeTransferred(address indexed token, address indexed collector, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice `minFeeRate` cannot exceed `maxFeeRate`.
    error FeeHandler__MinFeeRateCannotBeHigherThanMax();
    /// @notice `feePurchaseLowerBound` must be strictly less than `feePurchaseUpperBound`.
    error FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound();
    /// @notice Fee collector cannot be the zero address.
    error FeeHandler__InvalidFeeCollector();
    /// @notice A fee rate exceeds the 5% cap.
    error FeeHandler__MaxFeeRateExceedsCap();

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set all four fee parameters atomically.
     * @param minFeeRate Lowest fee rate (basis points / 10_000).
     * @param maxFeeRate Highest fee rate. Must be ≥ `minFeeRate` and ≤ 5%.
     * @param feePurchaseLowerBound Purchase amount at or below which `maxFeeRate` applies.
     * @param feePurchaseUpperBound Purchase amount at or above which `minFeeRate` applies.
     * @dev The only mutation path for these four values: there are no individual bound or rate
     *      setters. Writes each field that changed and emits only those events.
     */
    function setFeeRateParams(uint256 minFeeRate, uint256 maxFeeRate, uint256 feePurchaseLowerBound, uint256 feePurchaseUpperBound)
        external;

    /**
     * @notice Set the address that receives purchase fees.
     * @param feeCollector New collector. Cannot be zero.
     */
    function setFeeCollectorAddress(address feeCollector) external;

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Address that currently receives purchase fees.
     * @return The fee collector.
     */
    function getFeeCollectorAddress() external view returns (address);

    /**
     * @notice The four fee settings used to interpolate a purchase fee.
     * @return The current min/max rates and purchase-amount bounds.
     */
    function getFeeSettings() external view returns (FeeSettings memory);
}
