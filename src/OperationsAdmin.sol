// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IOperationsAdmin} from "./interfaces/IOperationsAdmin.sol";
import {ITokenHandler} from "./interfaces/ITokenHandler.sol";
import {ITokenLending} from "./interfaces/ITokenLending.sol";
import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {BitChillOwnable} from "./BitChillOwnable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev Dex handlers expose this view. Kept local so the registry does not import PurchaseUniswap's
///      Uniswap router / WRBTC / oracle types.
interface IDexSwapPath {
    function getSwapPath() external view returns (bytes memory);
}

/**
 * @title OperationsAdmin
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Governance registry for route classes, token handlers, and swappers.
 * @dev One owner. Route indexes are add-only: a class is recorded once and is never
 *      mutated or deregistered. Old routes stay resolvable so users can exit the handler
 *      that holds their funds. `(token, routeIndex)` handler assignment is likewise
 *      add-only, and a handler address may be assigned at most once: none of a handler's
 *      per-user accounting is route-keyed, so sharing one instance across two pairs would let
 *      one route's principal be read as another's yield. There is no cooperative migration on
 *      these handler versions. Mutable flags here are a per-pair deposit pause (circuit breaker
 *      for new inflows) and per-handler Dex path allowlisting (exact encoded Uniswap V3 paths).
 */
contract OperationsAdmin is IOperationsAdmin, BitChillOwnable {
    using SafeCast for uint256;

    /// @dev Uniswap V3 path: 20-byte token, then n hops of 3-byte fee + 20-byte token (`n >= 1`).
    uint256 private constant V3_PATH_ADDRESS_SIZE = 20;
    uint256 private constant V3_PATH_HOP_SIZE = 23;

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
    /// @dev Exact-path allowlist. The purchase path itself is not re-checked on every swap; this
    ///      mapping is consulted only when activating a path, so the active path must stay allowed.
    mapping(address handler => mapping(bytes32 pathHash => bool allowed)) private s_purchasePathAllowed;

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
     * @dev Always reads `getSwapPath` so a non-Dex contract cannot enter the allowlist, and so
     *      revocation of the live path is rejected without storing a separate "active hash".
     */
    function setPurchasePathAllowed(address handler, bytes calldata encodedPath, bool allowed) external onlyOwner {
        if (handler.code.length == 0) revert OperationsAdmin__EoaCannotBeHandler(handler);
        if (!_isCanonicalV3Path(encodedPath)) revert OperationsAdmin__InvalidPurchasePath(encodedPath);

        bytes memory activePath = _readActiveSwapPath(handler);
        bytes32 pathHash = keccak256(encodedPath);
        if (!allowed && keccak256(activePath) == pathHash) {
            revert OperationsAdmin__CannotRevokeActivePurchasePath(handler, pathHash);
        }
        if (s_purchasePathAllowed[handler][pathHash] == allowed) {
            revert OperationsAdmin__PurchasePathPermissionUnchanged(handler, pathHash, allowed);
        }

        s_purchasePathAllowed[handler][pathHash] = allowed;
        emit OperationsAdmin__PurchasePathAllowedSet(handler, pathHash, encodedPath, allowed);
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

    /**
     * @inheritdoc IOperationsAdmin
     */
    function isPurchasePathAllowed(address handler, bytes32 pathHash) external view returns (bool) {
        return s_purchasePathAllowed[handler][pathHash];
    }

    /**
     * @inheritdoc IOperationsAdmin
     */
    function requirePurchasePathSetter(address caller, bytes32 pathHash) external view {
        if (caller != owner() && !s_swappers[caller]) {
            revert OperationsAdmin__UnauthorizedPurchasePathSetter(caller);
        }
        if (!s_purchasePathAllowed[msg.sender][pathHash]) {
            revert OperationsAdmin__PurchasePathNotAllowed(msg.sender, pathHash);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _isCanonicalV3Path(bytes memory encodedPath) private pure returns (bool) {
        uint256 length = encodedPath.length;
        if (length < V3_PATH_ADDRESS_SIZE + V3_PATH_HOP_SIZE) return false;
        return (length - V3_PATH_ADDRESS_SIZE) % V3_PATH_HOP_SIZE == 0;
    }

    function _readActiveSwapPath(address handler) private view returns (bytes memory path) {
        (bool success, bytes memory data) =
            handler.staticcall(abi.encodeWithSelector(IDexSwapPath.getSwapPath.selector));
        if (!success) revert OperationsAdmin__InvalidDexHandler(handler);
        path = _decodeReturnedBytes(handler, data);
        if (!_isCanonicalV3Path(path)) revert OperationsAdmin__InvalidDexHandler(handler);
    }

    /// @dev ABI-decode `bytes` returndata without `abi.decode`, which panics on a bad offset/length
    ///      with empty data. Named `InvalidDexHandler` is the only allowed failure.
    function _decodeReturnedBytes(address handler, bytes memory data) private pure returns (bytes memory decoded) {
        if (data.length < 64) revert OperationsAdmin__InvalidDexHandler(handler);
        uint256 offset;
        assembly {
            offset := mload(add(data, 32))
        }
        if (offset > data.length - 32) revert OperationsAdmin__InvalidDexHandler(handler);
        uint256 innerLength;
        assembly {
            innerLength := mload(add(add(data, 32), offset))
        }
        if (innerLength > data.length - 32 - offset) revert OperationsAdmin__InvalidDexHandler(handler);
        decoded = new bytes(innerLength);
        assembly {
            let src := add(add(data, 64), offset)
            let dest := add(decoded, 32)
            for { let i := 0 } lt(i, innerLength) { i := add(i, 32) } {
                mstore(add(dest, i), mload(add(src, i)))
            }
        }
    }
}
