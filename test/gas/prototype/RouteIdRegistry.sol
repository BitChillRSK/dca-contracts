// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title RouteIdRegistry
 * @notice The registry design F needs: `OperationsAdmin`'s add-only `(token, routeIndex)` pair, given
 *         a compact `uint32` name so a schedule can carry a four-byte route reference instead of a
 *         twenty-byte token address.
 * @dev Test-only. Never deployed, never imported by `src/`.
 *
 *      This is not a new trust model. `OperationsAdmin` already registers routes add-only, already
 *      assigns `(token, routeIndex) -> handler` exactly once, and already refuses to reuse a handler
 *      address across pairs. The pair is therefore immutable from its first assignment, and giving an
 *      immutable pair a shorter name changes nothing about who may write it. `depositsPaused` stays
 *      the one mutable flag, as it is there.
 *
 *      Only the surface the benchmark exercises is reproduced, at the same call granularity the
 *      shipped manager pays, so the comparison prices the keying rather than an incidental merge of
 *      two registry calls into one.
 */
contract RouteIdRegistry {
    struct Route {
        address handler; // slot 0
        bool depositsPaused;
        address token; // slot 1
        uint32 routeIndex;
    }

    /// @dev Ids start at 1: zero means "no such route", which is what makes a missing pair detectable.
    uint32 private s_nextRouteId = 1;

    mapping(uint32 routeId => Route) private s_routes;
    mapping(address token => mapping(uint32 routeIndex => uint32 routeId)) private s_routeIds;
    mapping(address swapper => bool) private s_swappers;

    error RouteIdRegistry__PairAlreadyRegistered(address token, uint32 routeIndex);

    function addSwapper(address swapper) external {
        s_swappers[swapper] = true;
    }

    /// @dev Mints the compact id for a pair. Add-only, exactly as `assignTokenHandler` is.
    function assignTokenHandler(address token, uint32 routeIndex, address handler) external returns (uint32 routeId) {
        if (s_routeIds[token][routeIndex] != 0) revert RouteIdRegistry__PairAlreadyRegistered(token, routeIndex);
        routeId = s_nextRouteId++;
        s_routes[routeId] = Route({handler: handler, depositsPaused: false, token: token, routeIndex: routeIndex});
        s_routeIds[token][routeIndex] = routeId;
    }

    function isSwapper(address account) external view returns (bool) {
        return s_swappers[account];
    }

    /// @dev What the user-facing paths resolve once, so `(token, routeIndex)` never leaves the ABI.
    function getRouteId(address token, uint256 routeIndex) external view returns (uint32) {
        return s_routeIds[token][uint32(routeIndex)];
    }

    /// @dev The batch path's single lookup: one mapping, no token address to hash.
    ///      It returns the token as well as the handler because the events a purchase emits name the
    ///      stablecoin, and a schedule that carries only a `routeId` cannot supply it. That is a second
    ///      slot read once per batch, which is the honest cost of the compression and is measured.
    function getHandlerAndToken(uint32 routeId) external view returns (address handler, address token) {
        Route storage route = s_routes[routeId];
        return (route.handler, route.token);
    }

    function getHandler(uint32 routeId) external view returns (address) {
        return s_routes[routeId].handler;
    }

    /// @dev How a stored `routeId` becomes legible again at the surface, and how enumeration by token
    ///      is reached from a schedule that only carries the id.
    function getRoute(uint32 routeId) external view returns (address token, uint32 routeIndex) {
        Route storage route = s_routes[routeId];
        return (route.token, route.routeIndex);
    }

    function areDepositsPaused(uint32 routeId) external view returns (bool) {
        return s_routes[routeId].depositsPaused;
    }
}
