// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IOperationsAdmin
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Governance registry for route classes, token handlers, swappers, and per-pair deposit pause.
 * @dev One owner. Route indexes and handler assignments are add-only. A handler address may be
 *      assigned at most once. There is no cooperative migration on these handler versions.
 */
interface IOperationsAdmin {
    /**
     * @notice Classification recorded when a route index is registered.
     * @dev `Unregistered` is the mapping default. Once an index is `Idle` or `Lending`, it is never mutated.
     */
    enum RouteClass {
        Unregistered,
        Idle,
        Lending
    }

    /**
     * @notice The per-`(token, routeIndex)` pair state: who holds the funds, and whether new
     *         deposits are accepted.
     * @dev One slot (21 of 32 bytes). An unassigned pair reads as `(address(0), false)`.
     */
    struct TokenRoute {
        address handler;
        bool depositsPaused;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice A handler was assigned to a `(token, routeIndex)` pair. Add-only.
    event OperationsAdmin__TokenHandlerAssigned(
        address indexed token, uint256 routeIndex, address indexed handler
    );
    /// @notice A route index was classified as idle (`lends == false`) or lending. One-shot.
    event OperationsAdmin__RouteRegistered(uint256 index, bool lends);
    /// @notice `swapper` was added to the allowlist. Idempotent.
    event OperationsAdmin__SwapperAdded(address indexed swapper);
    /// @notice `swapper` was removed from the allowlist.
    event OperationsAdmin__SwapperRevoked(address indexed swapper);
    /// @notice New deposits for this pair were paused or unpaused. Every emit is a real transition.
    event OperationsAdmin__DepositsPauseSet(address indexed token, uint256 routeIndex, bool paused);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice A handler must be a contract, not an EOA.
    error OperationsAdmin__EoaCannotBeHandler(address newHandler);
    /// @notice `handler` does not ERC-165 advertise `ITokenHandler`.
    error OperationsAdmin__ContractIsNotTokenHandler(address newHandler);
    /// @notice A lending route requires ERC-165 `ITokenLending`.
    error OperationsAdmin__ContractIsNotTokenLending(address handler);
    /// @notice An idle route rejects a handler that advertises `ITokenLending`.
    error OperationsAdmin__LendingHandlerOnIdleRoute(address handler);
    /// @notice This route index is already classified and cannot be changed.
    error OperationsAdmin__RouteAlreadyRegistered(uint256 index);
    /// @notice Handler assignment requires a registered route index.
    error OperationsAdmin__RouteNotRegistered(uint256 index);
    /// @notice This `(token, routeIndex)` already has a handler.
    error OperationsAdmin__HandlerAlreadyAssigned(address token, uint256 routeIndex);
    /// @notice This handler address already backs another pair.
    error OperationsAdmin__HandlerAddressAlreadyInUse(address handler);
    /// @notice Deposit pause requires a pair that already has a handler.
    error OperationsAdmin__HandlerNotAssigned(address token, uint256 routeIndex);
    /// @notice `setDepositsPaused` must change the flag; a repeated write reverts.
    error OperationsAdmin__DepositsPauseUnchanged(address token, uint256 routeIndex, bool paused);

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register a route index as idle or lending. One-shot: the class is never changed or deleted.
     * @param index The route index to register. Must fit `uint32`, the width the packed schedule
     *        stores. Index 0 is pre-registered as idle by the constructor, which emits
     *        `RouteRegistered(0, false)` like any other registration.
     * @param lends True to classify the route as lending; false to classify it as idle.
     */
    function registerRoute(uint256 index, bool lends) external;

    /**
     * @notice Assign the token handler for a `(token, routeIndex)` pair. Add-only: reassignment reverts.
     * @param token The stablecoin whose handler is being assigned.
     * @param routeIndex The registered route index (idle or lending). Must fit `uint32`.
     * @param handler The TokenHandler for that token and route, not yet assigned anywhere in this admin.
     * @dev Requires ERC-165 `ITokenHandler`. Lending routes also require `ITokenLending`;
     *      idle routes reject it. A lending handler at an idle index would strand
     *      `withdrawInterest` (`DcaManager` gates it on `isLendingRoute`). One handler address
     *      backs at most one pair: a handler is built for one stablecoin and keys its per-user
     *      accounting by user alone, so a second pair sharing it reverts with
     *      `OperationsAdmin__HandlerAddressAlreadyInUse` whatever its token or route class.
     */
    function assignTokenHandler(address token, uint256 routeIndex, address handler) external;

    /**
     * @notice Pause or unpause new stablecoin deposits for one assigned `(token, routeIndex)` pair.
     * @param token The stablecoin whose deposits are being paused.
     * @param routeIndex The route index whose deposits are being paused. Must fit `uint32`.
     * @param paused True to block new deposits, false to allow them again.
     * @dev Incident control only: `DcaManager` consults this before `createDcaSchedule` and
     *      `depositToken` move cash, and nowhere else. Purchases, schedule edits, deletion, and
     *      every withdrawal (stablecoin, rBTC, interest) ignore it, so a paused route can always
     *      be exited. The pair must already have a handler, and the flag must change, so every
     *      emitted event is a real transition. There is no multi-pair form: closing a token across
     *      several routes is one transaction per pair, and a pair already paused reverts, so a sweep
     *      must read `areDepositsPaused` first rather than firing blind.
     */
    function setDepositsPaused(address token, uint256 routeIndex, bool paused) external;

    /**
     * @notice Add `swapper` to the swapper allowlist. Idempotent; does not replace other swappers.
     * @param swapper The swapper address.
     */
    function addSwapper(address swapper) external;

    /**
     * @notice Remove `swapper` from the swapper allowlist.
     * @param swapper The swapper address.
     */
    function revokeSwapper(address swapper) external;

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Whether `account` is an authorized swapper.
     * @param account Address to query.
     * @return True if `account` is on the swapper allowlist.
     */
    function isSwapper(address account) external view returns (bool);

    /**
     * @notice Whether `index` was registered as a lending route.
     * @param index The route index. Must fit `uint32`.
     * @return True if the index is classified as lending.
     * @dev False for idle routes (including the constructor's index 0) and for unregistered indexes.
     */
    function isLendingRoute(uint256 index) external view returns (bool);

    /**
     * @notice Recorded class of `index`.
     * @param index The route index. Must fit `uint32`.
     * @return The registered class, or `Unregistered` if it has never been classified.
     */
    function getRouteClass(uint256 index) external view returns (RouteClass);

    /**
     * @notice Handler registered for a token and route index.
     * @param token The stablecoin.
     * @param routeIndex The route index. Must fit `uint32`.
     * @return handler The TokenHandler, or `address(0)` if none is assigned.
     */
    function getTokenHandler(address token, uint256 routeIndex) external view returns (address handler);

    /**
     * @notice Whether new deposits to `(token, routeIndex)` are currently blocked.
     * @param token The stablecoin.
     * @param routeIndex The route index. Must fit `uint32`.
     * @return paused True when `DcaManager` must reject new deposits for this pair.
     * @dev False for unassigned pairs: only an assigned pair can be paused.
     */
    function areDepositsPaused(address token, uint256 routeIndex) external view returns (bool paused);
}
