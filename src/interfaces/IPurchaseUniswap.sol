// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IWRBTC} from "./IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "./ICoinPairPrice.sol";

/**
 * @title IPurchaseUniswap
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Uniswap V3 purchase configuration: encoded path, slippage band, and MoC BTC/USD oracle.
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
    /// @notice Owner changed the swap-time oracle floor.
    event PurchaseUniswap_AmountOutMinimumPercentUpdated(uint256 oldValue, uint256 newValue);
    /// @notice Owner changed the lower bound on the swap-time oracle floor.
    event PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(uint256 oldValue, uint256 newValue);
    /// @notice Owner pointed the min-out oracle at a new MoC BTC/USD feed.
    event PurchaseUniswap_OracleUpdated(address indexed oldOracle, address indexed newOracle);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Path encoding requires `poolFeeRates.length == intermediateTokens.length + 1`.
    error PurchaseUniswap__WrongNumberOfTokensOrFeeRates(uint256 numberOfIntermediateTokens, uint256 numberOfFeeRates);
    /// @notice Swap-time oracle floor cannot exceed 100%.
    error PurchaseUniswap__AmountOutMinimumPercentTooHigh();
    /// @notice Swap-time oracle floor cannot be set below the safety-check bound.
    error PurchaseUniswap__AmountOutMinimumPercentTooLow();
    /// @notice Safety-check bound cannot exceed 100%.
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
    /// @notice The swap left stablecoin on the handler: the pools did not take the whole requested input.
    /// @dev Emitted as a revert when the handler's stablecoin balance did not fall by exactly the requested
    ///      amount. Fees and schedule balances are debited before the swap, so a partial fill would otherwise
    ///      credit rBTC for stablecoin that was never spent.
    error PurchaseUniswap__InputAmountNotFullySpent(
        uint256 expectedAmount, uint256 balanceBefore, uint256 balanceAfter
    );
    /// @notice A later hop stopped short and left an intermediate token in the shared router.
    /// @dev The comparison is against the router's own pre-swap balance, not zero, so dust anyone can send
    ///      to a public contract does not block purchases.
    error PurchaseUniswap__IntermediateTokenBalanceChanged(
        address token, uint256 balanceBefore, uint256 balanceAfter
    );

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
     * @notice Set the swap-time oracle floor as a 1e18-scaled fraction of the oracle-implied rBTC.
     * @param amountOutMinimumPercent New fraction. Cannot exceed 100% or fall below the safety check.
     * @dev Uniswap `amountOutMinimum` is `max(thisFloor, minRbtcOut)`, so the swapper's quote-derived
     *      `minRbtcOut` sets operational tightness and this value is the bound that holds when that
     *      minimum is absent, stale, or hostile. Deploy it loose enough that a healthy batch never
     *      reverts on it; the swapper, not this setter, is the weekly knob.
     */
    function setAmountOutMinimumPercent(uint256 amountOutMinimumPercent) external;

    /**
     * @notice Current swap-time oracle floor, 1e18-scaled.
     * @return The fraction applied to the oracle-implied rBTC when building `amountOutMinimum`.
     */
    function getAmountOutMinimumPercent() external view returns (uint256);

    /**
     * @notice Set the lowest `amountOutMinimumPercent` the owner may configure.
     * @param amountOutMinimumSafetyCheck New bound, 1e18-scaled. Never enters swap math.
     * @dev This is the wall a single owner transaction cannot cross: widening the live floor past it
     *      takes two transactions, lowering this bound first. Raising it above the active floor reverts
     *      without changing state.
     */
    function setAmountOutMinimumSafetyCheck(uint256 amountOutMinimumSafetyCheck) external;

    /**
     * @notice The bound that limits how far `setAmountOutMinimumPercent` may widen the live floor.
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
