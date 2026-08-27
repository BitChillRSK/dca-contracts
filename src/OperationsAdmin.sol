// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IOperationsAdmin} from "./interfaces/IOperationsAdmin.sol";
import {ITokenHandler} from "./interfaces/ITokenHandler.sol";
import {ITokenLending} from "./interfaces/ITokenLending.sol";
import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {BitChillOwnable} from "./BitChillOwnable.sol";

/**
 * @title OperationsAdmin
 * @notice Governance registry for route classes, token handlers, and swappers.
 * @dev One owner. Route indexes are add-only: a class is recorded once and is never
 *      mutated or deregistered. Old routes stay resolvable so users can exit the handler
 *      that holds their funds. `(token, routeIndex)` handler assignment is likewise
 *      add-only, and a handler address may be assigned at most once: none of a handler's
 *      per-user accounting is route-keyed, so sharing one instance across two pairs would let
 *      one route's principal be read as another's yield. There is no cooperative migration on
 *      these handler versions.
 */
contract OperationsAdmin is IOperationsAdmin, BitChillOwnable {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    mapping(address token => mapping(uint256 routeIndex => address handler)) private s_tokenHandler;
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
        if (s_routeClass[index] != RouteClass.Unregistered) {
            revert OperationsAdmin__RouteAlreadyRegistered(index);
        }
        s_routeClass[index] = lends ? RouteClass.Lending : RouteClass.Idle;
        emit OperationsAdmin__RouteRegistered(index, lends);
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
        if (handler.code.length == 0) revert OperationsAdmin__EoaCannotBeHandler(handler);
        if (s_routeClass[routeIndex] == RouteClass.Unregistered) {
            revert OperationsAdmin__RouteNotRegistered(routeIndex);
        }
        if (s_tokenHandler[token][routeIndex] != address(0)) {
            revert OperationsAdmin__HandlerAlreadyAssigned(token, routeIndex);
        }
        if (s_handlerAssigned[handler]) revert OperationsAdmin__HandlerAddressAlreadyInUse(handler);

        IERC165 tokenHandler = IERC165(handler);
        if (!tokenHandler.supportsInterface(type(ITokenHandler).interfaceId)) {
            revert OperationsAdmin__ContractIsNotTokenHandler(handler);
        }

        bool isLending = s_routeClass[routeIndex] == RouteClass.Lending;
        bool supportsLending = tokenHandler.supportsInterface(type(ITokenLending).interfaceId);
        if (isLending) {
            if (!supportsLending) revert OperationsAdmin__ContractIsNotTokenLending(handler);
        } else if (supportsLending) {
            revert OperationsAdmin__LendingHandlerOnIdleRoute(handler);
        }

        s_tokenHandler[token][routeIndex] = handler;
        s_handlerAssigned[handler] = true;
        emit OperationsAdmin__TokenHandlerAssigned(token, routeIndex, handler);
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
        return s_routeClass[index] == RouteClass.Lending;
    }

    /**
     * @inheritdoc IOperationsAdmin
     */
    function getRouteClass(uint256 index) external view returns (RouteClass) {
        return s_routeClass[index];
    }

    /**
     * @inheritdoc IOperationsAdmin
     */
    function getTokenHandler(address token, uint256 routeIndex) external view returns (address) {
        return s_tokenHandler[token][routeIndex];
    }
}
