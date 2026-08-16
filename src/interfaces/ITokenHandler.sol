// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title ITokenHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the TokenHandler contract.
 */
interface ITokenHandler {
    //////////////////////
    // Events ////////////
    //////////////////////
    event TokenHandler__TokenDeposited(address indexed token, address indexed user, uint256 indexed amount);
    event TokenHandler__TokenWithdrawn(address indexed token, address indexed user, uint256 indexed amount);

    ///////////////////////////////
    // External functions /////////
    ///////////////////////////////

    /**
     * @notice Deposit a specified amount of a stablecoin into the contract for DCA operations.
     * @param amount The amount of the stablecoin to deposit.
     * @param user The user making the deposit.
     */
    function depositToken(address user, uint256 amount) external;

    /**
     * @notice Withdraw a specified amount of a stablecoin from the contract.
     * @param amount The amount of the stablecoin to withdraw.
     * @param user The user making the withdrawal.
     * @return The amount actually paid to the user, which a lending handler may clamp to the user's position
     * or reduce by a redemption fee charged by the lending protocol. Callers must account for this amount,
     * never for the requested one.
     */
    function withdrawToken(address user, uint256 amount) external returns (uint256);
}
