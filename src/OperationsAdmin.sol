// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IOperationsAdmin} from "./interfaces/IOperationsAdmin.sol";
import {ITokenHandler} from "./interfaces/ITokenHandler.sol";
import {ITokenLending} from "./interfaces/ITokenLending.sol";
import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {BitChillOwnable} from "./BitChillOwnable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title OperationsAdmin
 * @notice Governance registry for route classes, token handlers, and swappers.
 * @dev One owner. Route indexes are add-only: a class is recorded once and is never
 *      mutated or deregistered. Old routes stay resolvable so users can exit the handler
 *      that holds their funds. `(token, routeIndex)` handler assignment is likewise
 *      add-only, and a handler address may be assigned at most once: none of a handler's
 *      per-user accounting is route-keyed, so sharing one instance across two pairs would let
 *      one route's principal be read as another's yield. There is no cooperative migration on
 *      these handler versions. The one mutable flag here is a per-pair deposit pause, a circuit
 *      breaker that blocks new inflows without touching purchases or any exit path.
 */
contract OperationsAdmin is IOperationsAdmin, BitChillOwnable {
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev Handler and deposit pause share one mapping value, so assigning a handler and pausing
    ///      its pair dirty the same slot. Every route-index argument below is bounded to `uint32`,
    ///      the width a packed `DcaSchedule` can store, so no caller can read or write a route no
    ///      schedule could ever name.
    mapping(address token => mapping(uint256 routeIndex => TokenRoute)) private s_tokenRoute;
    mapping(uint256 routeIndex => RouteClass) private s_routeClass;
    mapping(address swapper => bool) private s_swappers;
    mapping(address handler => bool assigned) private s_handlerAssigned;

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @param initialOwner the address that owns this contract immediately after deploy
     * @dev Index 0 is the default idle route. Additional idle or lending indexes are
     *      registered through `registerRoute`. Emits `RouteRegistered` so indexers see
     *      the same class write as every later `registerRoute` call.
     */
    constructor(address initialOwner) BitChillOwnable(initialOwner) {
        s_routeClass[0] = RouteClass.Idle;
        emit OperationsAdmin__RouteRegistered(0, false);
    }

    /**
     * @inheritdoc IOperationsAdmin
     * @dev Recovery from a mistaken class is a new index, not a mutation of this one.
     */
    function registerRoute(uint256 index, bool lends) external onlyOwner {
        uint32 routeIndex = index.toUint32();
        if (s_routeClass[routeIndex] != RouteClass.Unregistered) {
            revert OperationsAdmin__RouteAlreadyRegistered(index);
        }
        s_routeClass[routeIndex] = lends ? RouteClass.Lending : RouteClass.Idle;
        emit OperationsAdmin__RouteRegistered(routeIndex, lends);
    }

    /**
     * @inheritdoc IOperationsAdmin
     * @dev Recovery from a mistaken assignment is a new `(token, index)`, even when this
     *      handler has never held funds: this contract cannot prove a handler is empty.
     *      Lending routes require ERC-165 `ITokenLending`; idle routes reject it so a
     *      lending handler cannot be parked at an idle index (including constructor index 0).
     *      A handler address that already backs a pair is rejected before the interface checks:
     *      it passed them on its first assignment, and re-running them would not make the second
     *      pair safe. Only a successful assignment marks the address as used, so a handler whose
     *      assignment reverted stays available.
     */
    function assignTokenHandler(address token, uint256 routeIndex, address handler) external onlyOwner {
        uint32 route = routeIndex.toUint32();
        if (handler.code.length == 0) revert OperationsAdmin__EoaCannotBeHandler(handler);
        if (s_routeClass[route] == RouteClass.Unregistered) {
            revert OperationsAdmin__RouteNotRegistered(routeIndex);
        }
        if (s_tokenRoute[token][route].handler != address(0)) {
            revert OperationsAdmin__HandlerAlreadyAssigned(token, routeIndex);
        }
        if (s_handlerAssigned[handler]) revert OperationsAdmin__HandlerAddressAlreadyInUse(handler);

        IERC165 tokenHandler = IERC165(handler);
        if (!tokenHandler.supportsInterface(type(ITokenHandler).interfaceId)) {
            revert OperationsAdmin__ContractIsNotTokenHandler(handler);
        }

        bool isLending = s_routeClass[route] == RouteClass.Lending;
        bool supportsLending = tokenHandler.supportsInterface(type(ITokenLending).interfaceId);
        if (isLending) {
            if (!supportsLending) revert OperationsAdmin__ContractIsNotTokenLending(handler);
        } else if (supportsLending) {
            revert OperationsAdmin__LendingHandlerOnIdleRoute(handler);
        }

        s_tokenRoute[token][route].handler = handler;
        s_handlerAssigned[handler] = true;
        emit OperationsAdmin__TokenHandlerAssigned(token, route, handler);
    }

    /**
     * @inheritdoc IOperationsAdmin
     * @dev Deposits are the only user action this registry can stop. It is a circuit breaker
     *      for one lending market going bad, not a protocol pause: existing positions keep
     *      purchasing and can always be withdrawn, and every other `(token, routeIndex)` pair is
     *      untouched. The flag lives here rather than on the handler so governance can stop deposits
     *      without a handler that must be trusted to unpause itself.
     */
    function setDepositsPaused(address token, uint256 routeIndex, bool paused) external onlyOwner {
        uint32 route = routeIndex.toUint32();
        TokenRoute storage tokenRoute = s_tokenRoute[token][route];
        if (tokenRoute.handler == address(0)) {
            revert OperationsAdmin__HandlerNotAssigned(token, routeIndex);
        }
        if (tokenRoute.depositsPaused == paused) {
            revert OperationsAdmin__DepositsPauseUnchanged(token, routeIndex, paused);
        }
        tokenRoute.depositsPaused = paused;
        emit OperationsAdmin__DepositsPauseSet(token, route, paused);
    }

    /**
     * @inheritdoc IOperationsAdmin
     */
    function addSwapper(address swapper) external onlyOwner {
        s_swappers[swapper] = true;
        emit OperationsAdmin__SwapperAdded(swapper);
    }

    /**
     * @inheritdoc IOperationsAdmin
     */
    function revokeSwapper(address swapper) external onlyOwner {
        s_swappers[swapper] = false;
        emit OperationsAdmin__SwapperRevoked(swapper);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IOperationsAdmin
     */
    function isSwapper(address account) external view returns (bool) {
        return s_swappers[account];
    }

    /**
     * @inheritdoc IOperationsAdmin
     */
    function isLendingRoute(uint256 index) external view returns (bool) {
        return s_routeClass[index.toUint32()] == RouteClass.Lending;
    }

    /**
     * @inheritdoc IOperationsAdmin
     */
    function getRouteClass(uint256 index) external view returns (RouteClass) {
        return s_routeClass[index.toUint32()];
    }

    /**
     * @inheritdoc IOperationsAdmin
     */
    function getTokenHandler(address token, uint256 routeIndex) external view returns (address) {
        return s_tokenRoute[token][routeIndex.toUint32()].handler;
    }

    /**
     * @inheritdoc IOperationsAdmin
     */
    function areDepositsPaused(address token, uint256 routeIndex) external view returns (bool) {
        return s_tokenRoute[token][routeIndex.toUint32()].depositsPaused;
    }
}
