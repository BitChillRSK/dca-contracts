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

    /// @notice in a batch this fires per user with that user's planned share; the batch event
    /// below carries the total the handler measured
    event TokenLending__LendingTokenRedeemed(
        address indexed user, uint256 indexed underlyingAmount, uint256 indexed lendingTokenAmountRedeemed
    );
    event TokenLending__LendingTokenRedeemedBatch(uint256 indexed underlyingAmount, uint256 indexed lendingTokenAmountRedeemed);
    event TokenLending__InterestWithdrawn(
        address indexed user, address indexed token, uint256 indexed underlyingAmountWithdrawn
    );
    event TokenLending__WithdrawalAmountAdjusted(
        address indexed user, uint256 indexed originalAmount, uint256 indexed adjustedAmount
    );
    event TokenLending__AmountToRedeemAdjusted(
        address indexed user, 
        uint256 indexed originalLendingTokenAmount, 
        uint256 indexed adjustedLendingTokenAmount, 
        uint256 originalStablecoinAmount, 
        uint256 adjustedStablecoinAmount
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error TokenLending__LendingProtocolDepositFailed();
    /// @notice the lending protocol's redemption call reported failure with a non-zero error code
    error TokenLending__LendingProtocolRedeemFailed(uint256 errorCode);
    /// @notice the redemption burnt the user's shares but produced no stablecoin, so revert
    /// instead of paying out zero. `stablecoinAttempted` is the amount the redemption asked the
    /// protocol for, after any clamp to the shares the user actually holds.
    error TokenLending__ZeroStablecoinReceived(uint256 stablecoinAttempted);
    /// @notice batch redeem asked for more of this user's shares than the handler tracks. Same
    /// outcome as a 0.8 underflow on `s_*Balances[user] -=`; the named error is for the swapper.
    error TokenLending__InsufficientLendingTokenBalance(address user, uint256 requested, uint256 available);

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the lending token balance of the user
     * @param user The user whose balance is checked
     */
    function getUsersLendingTokenBalance(address user) external view returns (uint256);

    /**
     * @dev Withdraws the interest earned for a user.
     * @notice This function needs to be in this interface (even though it is not implemented in the TokenHandler abstract contract) because it is called by the DCA Manager contract
     * @param user The address of the user withdrawing the interest.
     * @param tokenLockedInDcaSchedules The amount of stablecoin locked in DCA schedules by the user.
     */
    function withdrawInterest(address user, uint256 tokenLockedInDcaSchedules) external;

    /**
     * @dev Checks the interest earned by a user in total.
     * @param user The address of the user.
     * @param tokenLockedInDcaSchedules The amount of stablecoin locked in DCA schedules by the user in total.
     * @return The amount of accrued interest.
     */
    function getAccruedInterest(address user, uint256 tokenLockedInDcaSchedules) external view returns (uint256);
}
