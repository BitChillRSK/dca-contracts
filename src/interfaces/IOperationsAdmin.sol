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

    //////////////////////
    // Errors ////////////
    //////////////////////
    error OperationsAdmin__EoaCannotBeHandler(address newHandler);
    error OperationsAdmin__ContractIsNotTokenHandler(address newHandler);
    error OperationsAdmin__RouteAlreadyRegistered(uint256 index);
    error OperationsAdmin__RouteNotRegistered(uint256 index);
    error OperationsAdmin__HandlerAlreadyAssigned(address token, uint256 routeIndex);
    error OperationsAdmin__OwnershipCannotBeRenounced();

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
     * @param handler The TokenHandler for that token and route.
     * @dev Does not check that the handler implements `ITokenLending` when `routeIndex`
     *      is lending, or that it does not when idle. A lending handler at an idle
     *      index strands accrued interest with no recovery on that route.
     */
    function assignTokenHandler(address token, uint256 routeIndex, address handler) external;

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
