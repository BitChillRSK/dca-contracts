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

    //////////////////////
    // Errors ////////////
    //////////////////////
    /// @notice A positive deposit request credited nothing after transferFrom (fee-on-transfer took the whole amount).
    error TokenHandler__ZeroStablecoinReceived();

    ///////////////////////////////
    // External functions /////////
    ///////////////////////////////

    /**
     * @notice Deposit a specified amount of a stablecoin into the contract for DCA operations.
     * @param user The user making the deposit.
     * @param amount The amount of the stablecoin requested from the user.
     * @return The amount this contract actually received, measured as a `balanceOf` delta around `transferFrom`.
     * Credit this amount, not `amount`. A fee-on-transfer token may deliver less than requested.
     */
    function depositToken(address user, uint256 amount) external returns (uint256);

    /**
     * @notice Withdraw a specified amount of a stablecoin from the contract.
     * @param amount The amount of the stablecoin to withdraw.
     * @param user The user making the withdrawal.
     * @return The amount actually paid to the user, which a lending handler may clamp to the user's position
     * or reduce by a redemption fee charged by the lending protocol. Report this amount; do not debit a
     * schedule's principal with it. Principal is reduced by the amount requested, because a redemption fee
     * consumes principal rather than leaving it behind.
     */
    function withdrawToken(address user, uint256 amount) external returns (uint256);
}
