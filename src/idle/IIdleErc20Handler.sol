// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IIdleErc20Handler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Idle (non-lending) handler: deposits stay on the contract; no shares are minted.
 * @dev A deposit stays on the handler as the stablecoin itself, and a per-user balance is booked
 *      against it. That balance is the ceiling on every payout: a withdrawal or a single purchase
 *      above it is clamped down to it and reported through `IdleErc20Handler__AmountAdjusted`, so a
 *      DcaManager accounting error cannot spend another user's pooled stablecoin.
 */
interface IIdleErc20Handler {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice A withdrawal or single purchase was clamped to the user's idle balance.
    event IdleErc20Handler__AmountAdjusted(address indexed user, uint256 originalAmount, uint256 adjustedAmount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice A requested payout debited nothing from the idle mapping.
    error IdleErc20Handler__ZeroStablecoinPaid(uint256 requested);

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice This user's idle stablecoin balance tracked by this handler.
     * @param user Account to query.
     * @return The booked idle balance.
     */
    function getUsersIdleTokenBalance(address user) external view returns (uint256);
}
