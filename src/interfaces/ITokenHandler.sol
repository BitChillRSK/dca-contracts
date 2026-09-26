// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/**
 * @title ITokenHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Deposit and withdraw the handler's stablecoin. Called only by DcaManager.
 */
interface ITokenHandler {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Stablecoin was pulled from `user` onto this handler.
    event TokenHandler__TokenDeposited(address indexed token, address indexed user, uint256 amount);
    /// @notice Stablecoin left this handler to `user`.
    event TokenHandler__TokenWithdrawn(address indexed token, address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice The handler measured something other than the requested amount after `transferFrom`.
     * @dev Fee-on-transfer is not a supported token class, so any shortfall (including a zero receipt) or
     *      over-delivery reverts instead of crediting a schedule the user did not ask for.
     * @param requested The amount the DCA manager asked this handler to pull from the user.
     * @param received The `balanceOf(address(this))` delta measured around `transferFrom`.
     */
    error TokenHandler__DepositAmountMismatch(uint256 requested, uint256 received);

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pull `amount` of this handler's stablecoin from `user` for DCA.
     * @param user The user making the deposit. Must have approved this handler.
     * @param amount The amount requested from the user.
     * @dev Measures a `balanceOf` delta around `transferFrom` and reverts `TokenHandler__DepositAmountMismatch`
     *      unless it equals `amount`. Callers credit `amount`; a successful call never received something else.
     */
    function depositToken(address user, uint256 amount) external;

    /**
     * @notice Send `amount` of this handler's stablecoin to `user`.
     * @param user The user receiving the withdrawal.
     * @param amount The amount requested. A lending handler may clamp first to the user's position;
     *        an idle handler pays the requested amount from pooled cash (schedule liability is the book).
     * @return withdrawnAmount The amount that left this contract, measured as a `balanceOf(address(this))`
     *         delta around `safeTransfer`. This measures handler cash, not the user's balance, and it is
     *         not what a schedule's principal is debited by: principal is reduced by the amount requested.
     *         On a lending route a successful call guarantees the external receipt-share claim for that
     *         request was fully consumed, so a cash shortfall is a fee or realized loss with no unpaid
     *         claim left withdrawable — not a reason to re-credit principal.
     */
    function withdrawToken(address user, uint256 amount) external returns (uint256 withdrawnAmount);
}
