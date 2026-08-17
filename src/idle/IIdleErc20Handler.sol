// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IIdleErc20Handler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the idle (non-lending) ERC20 handler.
 */
interface IIdleErc20Handler {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event IdleErc20Handler__AmountAdjusted(
        address indexed user, uint256 indexed originalAmount, uint256 indexed adjustedAmount
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error IdleErc20Handler__ZeroStablecoinReceived();

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice get the user's idle stablecoin balance tracked by this handler
     * @param user the address of the user
     * @return the user's idle stablecoin balance
     */
    function getUsersIdleTokenBalance(address user) external view returns (uint256);
}
