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
     * @return depositedAmount The amount this contract actually received, measured as a `balanceOf` delta around `transferFrom`.
     * Credit this amount, not `amount`. A fee-on-transfer token may deliver less than requested.
     */
    function depositToken(address user, uint256 amount) external returns (uint256 depositedAmount);

    /**
     * @notice Withdraw a specified amount of a stablecoin from the contract.
     * @param amount The amount of the stablecoin to withdraw.
     * @param user The user making the withdrawal.
     * @return withdrawnAmount The amount that left this contract, measured as a `balanceOf(address(this))` delta around
     * `safeTransfer`. Do not measure the user: invariant 1 is handler cash, and `balanceOf(user)` is not received-by-us.
     * A lending handler may clamp to the user's position first; this return is then the post-redeem transfer
     * delta. Do not debit a schedule's principal with this amount. Principal is reduced by the amount
     * requested, because a redemption fee consumes principal rather than leaving it behind.
     */
    function withdrawToken(address user, uint256 amount) external returns (uint256 withdrawnAmount);
}
