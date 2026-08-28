// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IFeeHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the FeeHandler contract.
 */
interface IFeeHandler {
    ////////////////////////
    // Type declarations ///
    ////////////////////////
    /// @dev Widths match FeeHandler storage: rates are capped at 5% (MAX_FEE_RATE_CAP) so they fit
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

    //////////////////////
    // Events ////////////
    //////////////////////
    event FeeHandler__MinFeeRateSet(uint256 indexed minFeeRate);
    event FeeHandler__MaxFeeRateSet(uint256 indexed maxFeeRate);
    event FeeHandler__PurchaseLowerBoundSet(uint256 indexed feePurchaseLowerBound);
    event FeeHandler__PurchaseUpperBoundSet(uint256 indexed feePurchaseUpperBound);
    event FeeHandler__FeeCollectorAddressSet(address indexed feeCollector);

    //////////////////////
    // Custom errors /////
    //////////////////////

    error FeeHandler__MinFeeRateCannotBeHigherThanMax();
    error FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound();
    error FeeHandler__InvalidFeeCollector();
    error FeeHandler__MaxFeeRateExceedsCap();

    ///////////////////////////////
    // External functions /////////
    ///////////////////////////////

    /**
     * @dev Sets the parameters for the fee rate.
     * @param minFeeRate The minimum fee rate.
     * @param maxFeeRate The maximum fee rate.
     * @param feePurchaseLowerBound Purchase amount below which the maximum fee rate is applied.
     * @param feePurchaseUpperBound Purchase amount above which the minimum fee rate is applied.
     */
    function setFeeRateParams(uint256 minFeeRate, uint256 maxFeeRate, uint256 feePurchaseLowerBound, uint256 feePurchaseUpperBound)
        external;

    /**
     * @dev Sets the address of the fee collector.
     * @param feeCollector The address of the fee collector.
     */
    function setFeeCollectorAddress(address feeCollector) external;

    /**
     * @dev Gets the fee collector address
     */
    function getFeeCollectorAddress() external returns (address);

    /**
     * @dev Gets the four fee settings used for purchase fee calculation.
     */
    function getFeeSettings() external view returns (FeeSettings memory);
}
