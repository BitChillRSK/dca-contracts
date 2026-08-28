// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IOperationsAdmin
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the OperationsAdmin contract.
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

    //////////////////////
    // Events ////////////
    //////////////////////
    event OperationsAdmin__TokenHandlerAssigned(
        address indexed token, uint256 indexed routeIndex, address indexed handler
    );
    event OperationsAdmin__RouteRegistered(uint256 indexed index, bool lends);
    event OperationsAdmin__SwapperAdded(address indexed swapper);
    event OperationsAdmin__SwapperRevoked(address indexed swapper);
    event OperationsAdmin__DepositsPauseSet(address indexed token, uint256 indexed routeIndex, bool paused);

    //////////////////////
    // Errors ////////////
    //////////////////////
    error OperationsAdmin__EoaCannotBeHandler(address newHandler);
    error OperationsAdmin__ContractIsNotTokenHandler(address newHandler);
    error OperationsAdmin__ContractIsNotTokenLending(address handler);
    error OperationsAdmin__LendingHandlerOnIdleRoute(address handler);
    error OperationsAdmin__RouteAlreadyRegistered(uint256 index);
    error OperationsAdmin__RouteNotRegistered(uint256 index);
    error OperationsAdmin__HandlerAlreadyAssigned(address token, uint256 routeIndex);
    error OperationsAdmin__HandlerAddressAlreadyInUse(address handler);
    error OperationsAdmin__HandlerNotAssigned(address token, uint256 routeIndex);
    error OperationsAdmin__DepositsPauseUnchanged(address token, uint256 routeIndex, bool paused);

    ///////////////////////////////
    // External functions /////////
    ///////////////////////////////

    /**
     * @notice Register a route index as idle or lending. One-shot: the class is never changed or deleted.
     * @param index The route index to register. Index 0 is pre-registered as idle by the constructor, which also emits `RouteRegistered(0, false)`.
     * @param lends True to classify the route as lending; false to classify it as idle.
     */
    function registerRoute(uint256 index, bool lends) external;

    /**
     * @notice Assign the token handler for a `(token, routeIndex)` pair. Add-only: reassignment reverts.
     * @param token The stablecoin whose handler is being assigned.
     * @param routeIndex The registered route index (idle or lending).
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
     * @param routeIndex The route index whose deposits are being paused.
     * @param paused True to block new deposits, false to allow them again.
     * @dev Incident control only: `DcaManager` consults this before `createDcaSchedule` and
     *      `depositToken` move cash, and nowhere else. Purchases, schedule edits, deletion, and
     *      every withdrawal (stablecoin, rBTC, interest) ignore it, so a paused route can always
     *      be exited. The pair must already have a handler — pausing deposits on a route nobody can
     *      deposit into is a no-op that would only mislead an operator — and the flag must change,
     *      so every emitted event is a real transition. There is no multi-pair form: closing a token
     *      across several routes is one transaction per pair, and a pair already paused reverts, so a
     *      sweep script must read `areDepositsPaused` first rather than firing blind.
     */
    function setDepositsPaused(address token, uint256 routeIndex, bool paused) external;

    /**
     * @notice Whether new deposits to `(token, routeIndex)` are currently blocked.
     * @param token The stablecoin.
     * @param routeIndex The route index.
     * @return paused True when `DcaManager` must reject new deposits for this pair.
     * @dev False for unassigned pairs: only an assigned pair can be paused.
     */
    function areDepositsPaused(address token, uint256 routeIndex) external view returns (bool paused);

    /**
     * @notice Handler registered for a token and route index.
     * @param token The stablecoin.
     * @param routeIndex The route index.
     * @return handler The TokenHandler, or `address(0)` if none is assigned.
     */
    function getTokenHandler(address token, uint256 routeIndex) external view returns (address handler);

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

    /**
     * @notice Whether `account` is an authorized swapper.
     */
    function isSwapper(address account) external view returns (bool);

    /**
     * @notice Whether `index` was registered as a lending route.
     * @dev False for idle routes (including the constructor's index 0) and for unregistered indexes.
     */
    function isLendingRoute(uint256 index) external view returns (bool);

    /**
     * @notice Recorded class of `index`.
     */
    function getRouteClass(uint256 index) external view returns (RouteClass);
}
