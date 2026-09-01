// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IWRBTC} from "./IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "./ICoinPairPrice.sol";

/**
 * @title IPurchaseUniswap
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Uniswap V3 purchase configuration: encoded path, slippage percents, and MoC BTC/USD oracle.
 */
interface IPurchaseUniswap {
    /*//////////////////////////////////////////////////////////////
                           TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Constructor bundle for the Uniswap router, wrapped rBTC, path, and MoC BTC/USD oracle.
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

    /// @notice An approved Uniswap V3 path was activated by construction, a swapper, or this handler's owner.
    event PurchaseUniswap_NewPathSet(
        address[] intermediateTokens, uint24[] poolFeeRates, bytes newPath
    );
    /// @notice Exact encoded path derived from `intermediateTokens` / `poolFeeRates` was allowed or revoked.
    /// @dev Construction emits `allowed = true` for the initial path. Later writes are owner-only.
    event PurchaseUniswap_PurchasePathAllowedSet(
        bytes32 pathHash, bytes encodedPath, address[] intermediateTokens, uint24[] poolFeeRates, bool allowed
    );
    /// @notice Owner changed the swap-time slippage fraction.
    event PurchaseUniswap_AmountOutMinimumPercentUpdated(uint256 oldValue, uint256 newValue);
    /// @notice Owner changed the config-only floor that bounds `amountOutMinimumPercent`.
    event PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(uint256 oldValue, uint256 newValue);
    /// @notice Owner pointed the min-out oracle at a new MoC BTC/USD feed.
    event PurchaseUniswap_OracleUpdated(address indexed oldOracle, address indexed newOracle);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Path encoding requires `poolFeeRates.length == intermediateTokens.length + 1`.
    error PurchaseUniswap__WrongNumberOfTokensOrFeeRates(uint256 numberOfIntermediateTokens, uint256 numberOfFeeRates);
    /// @notice Slippage percent cannot exceed 100%.
    error PurchaseUniswap__AmountOutMinimumPercentTooHigh();
    /// @notice Slippage percent cannot be set below the safety-check floor.
    error PurchaseUniswap__AmountOutMinimumPercentTooLow();
    /// @notice Safety-check floor cannot exceed 100%.
    error PurchaseUniswap__AmountOutMinimumSafetyCheckTooHigh();
    /// @notice Oracle address cannot be zero.
    error PurchaseUniswap__InvalidOracleAddress();
    /// @notice MoC oracle `getPriceInfo` reported an invalid price.
    error PurchaseUniswap__OutdatedPrice();
    /// @notice The handler's stablecoin is still the zero address, so a path cannot be built.
    error PurchaseUniswap__ZeroPurchaseToken();
    /// @notice The handler's stablecoin has more than 18 decimals, so min-out cannot be scaled.
    error PurchaseUniswap__UnsupportedStablecoinDecimals(uint8 stablecoinDecimals);
    /// @notice The allow/revoke write would not change stored permission.
    error PurchaseUniswap__PurchasePathPermissionUnchanged(bytes32 pathHash, bool allowed);
    /// @notice The currently active path cannot be revoked; activate another allowed path first.
    error PurchaseUniswap__CannotRevokeActivePurchasePath(bytes32 pathHash);
    /// @notice `caller` is neither this handler's owner nor an OperationsAdmin swapper.
    error PurchaseUniswap__UnauthorizedPurchasePathSetter(address caller);
    /// @notice `pathHash` is not allowlisted on this handler.
    error PurchaseUniswap__PurchasePathNotAllowed(bytes32 pathHash);

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allow or revoke the exact Uniswap V3 path built from these components.
     * @param intermediateTokens Intermediate token addresses (empty for a direct pair).
     * @param poolFeeRates Pool fee for each hop. Length must be `intermediateTokens.length + 1`.
     * @param allowed True to approve the derived path, false to revoke it.
     * @dev Owner-only. Encodes through the same pinned stablecoin and WRBTC as `setPurchasePath`.
     *      Emits the derived bytes and hash. The active path cannot be revoked. A repeated write reverts.
     *      New paths after construction are approved here; the constructor path is approved at deploy.
     */
    function setPurchasePathAllowed(
        address[] memory intermediateTokens,
        uint24[] memory poolFeeRates,
        bool allowed
    ) external;

    /**
     * @notice Whether `pathHash` is an approved encoded path on this handler.
     * @param pathHash `keccak256` of the exact encoded path bytes.
     */
    function isPurchasePathAllowed(bytes32 pathHash) external view returns (bool);

    /**
     * @notice Replace the Uniswap V3 path from this handler's stablecoin to WRBTC.
     * @param intermediateTokens Intermediate token addresses in the path (empty for a direct pair).
     * @param poolFeeRates Pool fee for each hop. Length must be `intermediateTokens.length + 1`.
     * @dev Builds the canonical path from this handler's pinned stablecoin and WRBTC. `msg.sender` must
     *      be this handler's owner or an OperationsAdmin swapper, and the derived path must already be
     *      allowlisted. Constructor installation does not use this function; it self-allowlists the
     *      initial path.
     */
    function setPurchasePath(address[] memory intermediateTokens, uint24[] memory poolFeeRates) external;

    /**
     * @notice Set the swap-time minimum as a 1e18-scaled fraction of the oracle-implied rBTC.
     * @param amountOutMinimumPercent New fraction. Cannot exceed 100% or fall below the safety-check floor.
     */
    function setAmountOutMinimumPercent(uint256 amountOutMinimumPercent) external;

    /**
     * @notice Current swap-time slippage fraction, 1e18-scaled.
     * @return The fraction applied to the oracle-implied rBTC when building `amountOutMinimum`.
     */
    function getAmountOutMinimumPercent() external view returns (uint256);

    /**
     * @notice Set the lowest `amountOutMinimumPercent` the owner may configure.
     * @param amountOutMinimumSafetyCheck New floor, 1e18-scaled. Config-only: it never enters swap math.
     * @dev Raising the floor above the active percent reverts without changing state. Widening
     *      slippage therefore takes two owner transactions — lower this floor first, then the percent.
     */
    function setAmountOutMinimumSafetyCheck(uint256 amountOutMinimumSafetyCheck) external;

    /**
     * @notice The config-only floor that bounds `setAmountOutMinimumPercent`. Not used at swap time.
     * @return The lowest value `setAmountOutMinimumPercent` accepts.
     */
    function getAmountOutMinimumSafetyCheck() external view returns (uint256);

    /**
     * @notice Point min-out at a new MoC BTC/USD oracle.
     * @param newOracle New oracle. Cannot be zero.
     */
    function updateMocOracle(address newOracle) external;

    /**
     * @notice Oracle currently used to build `amountOutMinimum`.
     * @return The MoC BTC/USD feed.
     */
    function getMocOracle() external view returns (ICoinPairPrice);

    /**
     * @notice Encoded Uniswap V3 path from this handler's stablecoin to WRBTC.
     * @return The current path bytes.
     */
    function getSwapPath() external view returns (bytes memory);
}
