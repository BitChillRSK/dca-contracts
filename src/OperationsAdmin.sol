// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IOperationsAdmin} from "./interfaces/IOperationsAdmin.sol";
import {ITokenHandler} from "./interfaces/ITokenHandler.sol";
import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OperationsAdmin
 * @notice Governance registry for route classes, token handlers, and swappers.
 * @dev One owner. Route indexes are add-only: a class is recorded once and is never
 *      mutated or deregistered. Old routes stay resolvable so users can exit the handler
 *      that holds their funds. `(token, routeIndex)` handler assignment is likewise
 *      add-only. There is no cooperative migration on these handler versions.
 */
contract OperationsAdmin is IOperationsAdmin, Ownable {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    mapping(address token => mapping(uint256 routeIndex => address handler)) private s_tokenHandler;
    mapping(uint256 routeIndex => RouteClass) private s_routeClass;
    mapping(address swapper => bool) private s_swappers;

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Index 0 is the default idle route. Additional idle or lending indexes are
     *      registered through `registerRoute`.
     */
    constructor() Ownable() {
        s_routeClass[0] = RouteClass.Idle;
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
     */
    function assignTokenHandler(address token, uint256 routeIndex, address handler) external onlyOwner {
        if (handler.code.length == 0) revert OperationsAdmin__EoaCannotBeHandler(handler);
        if (s_routeClass[routeIndex] == RouteClass.Unregistered) {
            revert OperationsAdmin__RouteNotRegistered(routeIndex);
        }
        if (s_tokenHandler[token][routeIndex] != address(0)) {
            revert OperationsAdmin__HandlerAlreadyAssigned(token, routeIndex);
        }

        IERC165 tokenHandler = IERC165(handler);
        if (!tokenHandler.supportsInterface(type(ITokenHandler).interfaceId)) {
            revert OperationsAdmin__ContractIsNotTokenHandler(handler);
        }

        s_tokenHandler[token][routeIndex] = handler;
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
