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
    /// @notice The handler measured something other than the requested amount after `transferFrom`.
    /// @dev Fee-on-transfer is not a supported token class, so any shortfall (including a zero receipt) or
    /// over-delivery reverts instead of crediting a schedule the user did not ask for.
    /// @param requested The amount the DCA manager asked this handler to pull from the user.
    /// @param received The `balanceOf(address(this))` delta measured around `transferFrom`.
    error TokenHandler__DepositAmountMismatch(uint256 requested, uint256 received);

    ///////////////////////////////
    // External functions /////////
    ///////////////////////////////

    /**
     * @notice Deposit a specified amount of a stablecoin into the contract for DCA operations.
     * @param user The user making the deposit.
     * @param amount The amount of the stablecoin requested from the user.
     * @dev Measures a `balanceOf` delta around `transferFrom` and reverts `TokenHandler__DepositAmountMismatch`
     * unless it equals `amount`. Callers credit `amount`; a successful call never received something else.
     */
    function depositToken(address user, uint256 amount) external;

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
