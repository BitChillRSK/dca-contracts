// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/**
 * @title IPurchaseFees
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Purchase-fee configuration: the rate bounds, the purchase amounts they interpolate
 *         between, and the address fees are paid to.
 */
interface IPurchaseFees {
    /*//////////////////////////////////////////////////////////////
                           TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice The four parameters that interpolate a purchase fee between `maxFeeRate` and `minFeeRate`.
     * @dev Two uint112 bounds plus two uint16 rates occupy one storage word. The bounds remain wider
     *      than a schedule's uint96 purchase amount. `setFeeRateParams` accepts uint256 values for
     *      owner ergonomics and checked-casts them at the write; `_validateFeeSettings` runs first.
     */
    struct FeeSettings {
        uint16 minFeeRate; // the lowest possible fee
        uint16 maxFeeRate; // the highest possible fee
        uint112 feePurchaseLowerBound; // the purchase amount below which max fee is applied
        uint112 feePurchaseUpperBound; // the purchase amount above which min fee is applied
    }

    /**
     * @notice Fee-domain constructor inputs: collector and the four interpolated rate parameters.
     * @dev One memory pointer on the purchase-base constructor call, so Dex leaves stay under the
     *      legacy-codegen stack limit. Ownership stays a separate `initialOwner` argument — it is
     *      contract-level authority and may govern settings beyond fees.
     */
    struct FeeConfig {
        address feeCollector;
        FeeSettings feeSettings;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Owner set the minimum fee rate.
    event PurchaseFees__MinFeeRateSet(uint256 minFeeRate);
    /// @notice Owner set the maximum fee rate.
    event PurchaseFees__MaxFeeRateSet(uint256 maxFeeRate);
    /// @notice Owner set the purchase amount below which the maximum fee rate applies.
    event PurchaseFees__PurchaseLowerBoundSet(uint256 feePurchaseLowerBound);
    /// @notice Owner set the purchase amount above which the minimum fee rate applies.
    event PurchaseFees__PurchaseUpperBoundSet(uint256 feePurchaseUpperBound);
    /// @notice Owner set the address that receives purchase fees.
    event PurchaseFees__FeeCollectorAddressSet(address indexed feeCollector);
    /**
     * @notice A non-zero purchase fee was paid to the collector (native rBTC on MoC, WRBTC on Dex).
     * @dev Emitted once per batch after buyer credits. The asset is implied by the emitting handler;
     *      Dex also logs a WRBTC `Transfer`.
     */
    event PurchaseFees__FeeTransferred(address indexed collector, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice `minFeeRate` cannot exceed `maxFeeRate`.
    error PurchaseFees__MinFeeRateCannotBeHigherThanMax();
    /// @notice `feePurchaseLowerBound` must be strictly less than `feePurchaseUpperBound`.
    error PurchaseFees__FeeLowerBoundMustBeLowerThanUpperBound();
    /// @notice Fee collector cannot be the zero address.
    error PurchaseFees__InvalidFeeCollector();
    /// @notice A fee rate exceeds the 5% cap.
    error PurchaseFees__MaxFeeRateExceedsCap();
    /// @notice Native rBTC fee payment to the collector failed.
    error PurchaseFees__FeePaymentFailed();

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set all four fee parameters atomically.
     * @param minFeeRate Lowest fee rate, in basis points.
     * @param maxFeeRate Highest fee rate. Must be ≥ `minFeeRate` and ≤ 5%.
     * @param feePurchaseLowerBound Purchase amount at or below which `maxFeeRate` applies.
     * @param feePurchaseUpperBound Purchase amount at or above which `minFeeRate` applies.
     * @dev The only mutation path for these four values: there are no individual bound or rate
     *      setters. Writes each field that changed and emits only those events.
     */
    function setFeeRateParams(
        uint256 minFeeRate,
        uint256 maxFeeRate,
        uint256 feePurchaseLowerBound,
        uint256 feePurchaseUpperBound
    ) external;

    /**
     * @notice Set the address that receives purchase fees.
     * @param feeCollector New collector. Cannot be zero.
     */
    function setFeeCollector(address feeCollector) external;

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Address that currently receives purchase fees (native rBTC on MoC, WRBTC on Dex).
     * @return The fee collector.
     */
    function getFeeCollector() external view returns (address);

    /**
     * @notice The four fee settings used to interpolate a purchase fee.
     * @return The current min/max rates and purchase-amount bounds.
     */
    function getFeeSettings() external view returns (FeeSettings memory);
}
