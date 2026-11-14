// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/**
 * @title IPurchaseFees
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Purchase-fee configuration: the rate limits, discount threshold, and fee collector.
 */
interface IPurchaseFees {
    /*//////////////////////////////////////////////////////////////
                           TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice The three parameters defining the purchase fee curve.
     * @dev One uint112 bound plus two uint16 rates occupy one storage word. The bound remains wider
     *      than a schedule's uint96 purchase amount. `setFeeRateParams` accepts uint256 values for
     *      owner ergonomics and checked-casts them at the write; `_validateFeeSettings` runs first.
     *      For x <= L, fee = floor(x * maxFeeRate / 10000). Otherwise fee is
     *      floor((minFeeRate*x*x + (maxFeeRate-minFeeRate)*L*(2*x-L)) / (x*10000)).
     *      x and L are token base units. The absolute fee never decreases with x; the unrounded
     *      effective rate approaches minFeeRate asymptotically. L=0 applies minFeeRate for x>0.
     */
    struct FeeSettings {
        uint16 minFeeRate; // asymptotic minimum rate, in basis points
        uint16 maxFeeRate; // rate at or below the lower bound, in basis points
        uint112 feePurchaseLowerBound; // the purchase amount at or below which max fee rate is applied
    }

    /**
     * @notice Fee-domain constructor inputs: collector and the three curve parameters.
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
    /// @notice Owner set the purchase amount at or below which the maximum fee rate applies.
    event PurchaseFees__PurchaseLowerBoundSet(uint256 feePurchaseLowerBound);
    /// @notice Owner set the address that receives purchase fees.
    event PurchaseFees__FeeCollectorAddressSet(address indexed feeCollector);
    /**
     * @notice Non-zero purchase fee credited to the collector's accumulated rBTC.
     * @dev `rbtcAmount` is `floor(Q × F / G)`; `stablecoinAmount` is `floor(retrieved × F / G)`.
     *      Independent floors; their ratio is an approximate all-in price.
     */
    event PurchaseFees__FeeCredited(address indexed collector, uint256 rbtcAmount, uint256 stablecoinAmount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice `minFeeRate` cannot exceed `maxFeeRate`.
    error PurchaseFees__MinFeeRateCannotBeHigherThanMax();
    /// @notice Fee collector cannot be the zero address.
    error PurchaseFees__InvalidFeeCollector();
    /// @notice A fee rate exceeds the 5% cap.
    error PurchaseFees__MaxFeeRateExceedsCap();

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set all three fee parameters atomically.
     * @param minFeeRate Asymptotic minimum fee rate, in basis points.
     * @param maxFeeRate Highest fee rate. Must be ≥ `minFeeRate` and ≤ 5%.
     * @param feePurchaseLowerBound Purchase amount at or below which `maxFeeRate` applies.
     * @dev The only mutation path for these three values: there are no individual bound or rate
     *      setters. Writes each field that changed and emits only those events.
     */
    function setFeeRateParams(uint256 minFeeRate, uint256 maxFeeRate, uint256 feePurchaseLowerBound) external;

    /// @notice Set the address that receives purchase fees on the accumulated-rBTC books.
    function setFeeCollector(address feeCollector) external;

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Address that currently receives purchase fees on the accumulated-rBTC books.
    function getFeeCollector() external view returns (address);

    /**
     * @notice The three settings defining the purchase fee curve.
     * @return The current min/max rates and lower purchase bound.
     */
    function getFeeSettings() external view returns (FeeSettings memory);
}
