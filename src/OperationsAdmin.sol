// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IOperationsAdmin} from "./interfaces/IOperationsAdmin.sol";
import {ITokenHandler} from "./interfaces/ITokenHandler.sol";
import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title OperationsAdmin
 * @dev Contract to manage administrative tasks and token handlers
 */
contract OperationsAdmin is IOperationsAdmin, Ownable, AccessControl {
    using Address for address;
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN");
    bytes32 public constant SWAPPER_ROLE = keccak256("SWAPPER");

    mapping(bytes32 tokenProtocolHash => address tokenHandlerContract) private s_tokenHandler;
    mapping(string lowerCaseProtocolName => uint256 protocolIndex) private s_protocolIndexes;
    mapping(uint256 protocolIndex => string lowerCaseProtocolName) private s_protocolNames;

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor() Ownable() {}

    /**
     * @dev Assigns a new TokenHandler to a token.
     * @param token The address of the token.
     * @param lendingProtocolIndex The index of the protocol where (if) the token is lent
     * @param handler The address of the TokenHandler.
     * @notice lendingProtocolIndex == 0 means the token is not lent
     */
    function assignOrUpdateTokenHandler(address token, uint256 lendingProtocolIndex, address handler)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (!address(handler).isContract()) revert OperationsAdmin__EoaCannotBeHandler(handler);
        if (lendingProtocolIndex != 0 && bytes(s_protocolNames[lendingProtocolIndex]).length == 0) {
            revert OperationsAdmin__LendingProtocolNotAllowed(lendingProtocolIndex);
        }

        IERC165 tokenHandler = IERC165(handler);

        if (tokenHandler.supportsInterface(type(ITokenHandler).interfaceId)) {
            bytes32 key = _encodeKey(token, lendingProtocolIndex);
            s_tokenHandler[key] = handler;
            emit OperationsAdmin__TokenHandlerUpdated(token, lendingProtocolIndex, handler);
        } else {
            revert OperationsAdmin__ContractIsNotTokenHandler(handler);
        }
    }

    /**
     * @dev Adds a lending protocol to the system by assigning an index to its name
     * @param lowerCaseName The name of the lending protocol in lower case
     * @param index The index to be assigned to it
     * @notice The index cannot be zero, since all elements in a mapping map to 0 by default
     */
    function addOrUpdateLendingProtocol(string calldata lowerCaseName, uint256 index) external onlyRole(ADMIN_ROLE) {
        if (index == 0) revert OperationsAdmin__LendingProtocolIndexCannotBeZero();
        if (bytes(lowerCaseName).length == 0) revert OperationsAdmin__LendingProtocolNameNotSet();
        s_protocolIndexes[lowerCaseName] = index;
        s_protocolNames[index] = lowerCaseName;
        emit OperationsAdmin__LendingProtocolAdded(index, lowerCaseName);
    }

    /**
     * @dev Assigns a new address to the swapper role.
     * @param swapper The swapper address.
     */
    function setSwapperRole(address swapper) external onlyRole(ADMIN_ROLE) {
        _grantRole(SWAPPER_ROLE, swapper);
        emit OperationsAdmin__SwapperRoleGranted(swapper);
    }

    /**
     * @dev Revokes the swapper role from an address.
     * @param swapper The address to revoke the swapper role from.
     */
    function revokeSwapperRole(address swapper) external onlyRole(ADMIN_ROLE) {
        _revokeRole(SWAPPER_ROLE, swapper);
        emit OperationsAdmin__SwapperRoleRevoked(swapper);
    }

    /**
     * @dev Assigns a new address to the admin role.
     * @param admin The admin address.
     */
    function setAdminRole(address admin) external onlyOwner {
        _grantRole(ADMIN_ROLE, admin);
        emit OperationsAdmin__AdminRoleGranted(admin);
    }

    /**
     * @dev Revokes the admin role from an address.
     * @param admin The address to revoke the admin role from.
     */
    function revokeAdminRole(address admin) external onlyOwner {
        _revokeRole(ADMIN_ROLE, admin);
        emit OperationsAdmin__AdminRoleRevoked(admin);
    }

    /*//////////////////////////////////////////////////////////////
                           PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Encodes the token and lending protocol
     * @param token The address of the token.
     * @param lendingProtocolIndex The name of the lending protocol (empty string if token will not be lent)
     */
    function _encodeKey(address token, uint256 lendingProtocolIndex) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(token, lendingProtocolIndex));
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Retrieves the index of the lending protocol
     * @param lowerCaseName The name of the lending protocol in lower case
     * @return The index of the lending protocol
     */
    function getLendingProtocolIndex(string calldata lowerCaseName) external view returns (uint256) {
        return s_protocolIndexes[lowerCaseName];
    }

    /**
     * @dev Retrieves the index of the lending protocol
     * @param index The index of the lending protocol in lower case
     * @return The name of the lending protocol
     */
    function getLendingProtocolName(uint256 index) external view returns (string memory) {
        return s_protocolNames[index];
    }

    /**
     * @dev Retrieves the handler for a given token.
     * @param token The address of the token.
     * @param lendingProtocolIndex The index of the lending protocol (empty string if token will not be lent)
     * @return The address of the TokenHandler. If address(0) is returned, the tuple token-protocol is not correct
     */
    function getTokenHandler(address token, uint256 lendingProtocolIndex) external view returns (address) {
        bytes32 key = _encodeKey(token, lendingProtocolIndex);
        return s_tokenHandler[key];
    }
}
