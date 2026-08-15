// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IAdminOperation
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the OperationsAdmin contract.
 */
interface IOperationsAdmin {
    //////////////////////
    // Events ////////////
    //////////////////////
    event OperationsAdmin__TokenHandlerUpdated(
        address indexed token, uint256 indexed lendingProtocolIndex, address indexed newHandler
    );
    event OperationsAdmin__LendingProtocolAdded(uint256 indexed index, string indexed name);
    event OperationsAdmin__AdminRoleGranted(address indexed admin);
    event OperationsAdmin__AdminRoleRevoked(address indexed admin);
    event OperationsAdmin__SwapperRoleGranted(address indexed swapper);
    event OperationsAdmin__SwapperRoleRevoked(address indexed swapper);

    //////////////////////
    // Errors ////////////
    //////////////////////
    error OperationsAdmin__EoaCannotBeHandler(address newHandler);
    error OperationsAdmin__ContractIsNotTokenHandler(address newHandler);
    error OperationsAdmin__LendingProtocolIndexCannotBeZero();
    error OperationsAdmin__LendingProtocolNameNotSet();
    error OperationsAdmin__LendingProtocolNotAllowed(uint256 index);

    ///////////////////////////////
    // External functions /////////
    ///////////////////////////////

    /**
     * @notice Registers token handler for a given stablecoin token address
     * @param token The address of the stablecoin for which the token handler is created.
     * @param lendingProtocolIndex The index of the lending protocol (empty string if token will not be lent)
     * @param handler The handler corresponding to the token and lending protocol (if any)
     */
    function assignOrUpdateTokenHandler(address token, uint256 lendingProtocolIndex, address handler) external;

    /**
     * @dev Retrieves the handler for a given token and lending protocol.
     * @param token The address of the token.
     * @param lendingProtocolIndex The name of the lending protocol (empty string if token will not be lent)
     * @return handler The address of the TokenHandler. If address(0) is returned, the tuple token-protocol is not correct
     */
    function getTokenHandler(address token, uint256 lendingProtocolIndex) external view returns (address handler);

    /**
     * @dev Assigns a new address to the swapper role.
     * @param swapper The swapper address.
     */
    function setSwapperRole(address swapper) external;

    /**
     * @dev Assigns a new address to the admin role.
     * @param admin The admin address.
     */
    function setAdminRole(address admin) external;

    /**
     * @dev Adds a lending protocol to the system by assigining an index to its name
     * @param lowerCaseName The name of the lending protocol in lower case
     * @param index The index to be assigned to it
     * @notice The index cannot be zero, since all elements in a mapping map to 0 by default
     */
    function addOrUpdateLendingProtocol(string calldata lowerCaseName, uint256 index) external;

    /**
     * @dev Retrieves the index of the lending protocol
     * @param lowerCaseName The name of the lending protocol in lower case
     * @return The address index of the lending protocol
     */
    function getLendingProtocolIndex(string calldata lowerCaseName) external returns (uint256);
}
