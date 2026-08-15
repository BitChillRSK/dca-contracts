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

    event TokenLending__UnderlyingRedeemed(
        address indexed user, uint256 indexed underlyingAmountRedeemed, uint256 indexed lendingTokenAmountRepayed
    );
    event TokenLending__UnderlyingRedeemedBatch(uint256 indexed underlyingAmountRedeemed, uint256 indexed lendingTokenAmountRepayed);
    event TokenLending__InterestWithdrawn(
        address indexed user, address indexed token, uint256 indexed underlyingAmountRedeemed
    );
    event TokenLending__WithdrawalAmountAdjusted(
        address indexed user, uint256 indexed originalAmount, uint256 indexed adjustedAmount
    );
    event TokenLending__AmountToRepayAdjusted(
        address indexed user, 
        uint256 indexed originalLendingTokenAmount, 
        uint256 indexed adjustedLendingTokenAmount, 
        uint256 originalStablecoinAmount, 
        uint256 adjustedStablecoinAmount
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error TokenLending__UnderlyingRedeemAmountExceedsBalance(uint256 redeemAmount, uint256 balance);
    error TokenLending__LendingProtocolDepositFailed();
    error TokenLending__BatchRedeemUnderlyingFailed();

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
