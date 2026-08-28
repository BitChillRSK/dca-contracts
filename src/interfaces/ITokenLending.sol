// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenHandler} from "./ITokenHandler.sol";

/**
 * @title ITokenLending
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 */
interface ITokenLending is ITokenHandler {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical per-user virtual lending-share balance after a successful mint or burn.
    /// @dev Only `user` is indexed. `newShares` equals `getUserShares(user)` after the call.
    ///      Reverted mutations produce no lasting log. Idle handlers do not emit this.
    event TokenLending__UserSharesUpdated(address indexed user, uint256 previousShares, uint256 newShares);
    /// @notice in a batch this fires per user with that user's planned share; the batch event
    /// below carries the total the handler measured
    event TokenLending__SharesRedeemed(
        address indexed user, uint256 underlyingAmount, uint256 sharesAmountRedeemed
    );
    event TokenLending__SharesRedeemedBatch(uint256 underlyingAmount, uint256 sharesAmountRedeemed);
    event TokenLending__InterestWithdrawn(
        address indexed user, address indexed token, uint256 underlyingAmountWithdrawn
    );
    event TokenLending__WithdrawalAmountAdjusted(
        address indexed user, uint256 originalAmount, uint256 adjustedAmount
    );
    event TokenLending__AmountToRedeemAdjusted(
        address indexed user,
        uint256 originalSharesAmount,
        uint256 adjustedSharesAmount,
        uint256 originalStablecoinAmount,
        uint256 adjustedStablecoinAmount
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error TokenLending__LendingProtocolDepositFailed();
    /// @notice the lending protocol's redemption call reported failure with a non-zero error code
    error TokenLending__LendingProtocolRedeemFailed(uint256 errorCode);
    /// @notice a positive share redemption produced no stablecoin; the call is rolled back
    error TokenLending__ZeroStablecoinReceived(uint256 stablecoinAttempted);
    /// @notice batch redeem asked for more of this user's shares than the handler tracks. Same
    /// outcome as a 0.8 underflow on `s_*Balances[user] -=`; the named error is for the swapper.
    error TokenLending__InsufficientShares(address user, uint256 requested, uint256 available);

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the shares balance of the user
     * @param user The user whose balance is checked
     */
    function getUserShares(address user) external view returns (uint256);

    /**
     * @dev Withdraws the interest earned for a user.
     * @notice This function needs to be in this interface (even though it is not implemented in the TokenHandler abstract contract) because it is called by the DCA Manager contract
     * @param user The address of the user withdrawing the interest.
     * @param stablecoinLockedInDcaSchedules The amount of stablecoin locked in DCA schedules by the user.
     */
    function withdrawInterest(address user, uint256 stablecoinLockedInDcaSchedules) external;

    /**
     * @dev Checks the interest earned by a user in total.
     * @param user The address of the user.
     * @param stablecoinLockedInDcaSchedules The amount of stablecoin locked in DCA schedules by the user in total.
     * @return The amount of accrued interest.
     */
    function getAccruedInterest(address user, uint256 stablecoinLockedInDcaSchedules) external view returns (uint256);
}
