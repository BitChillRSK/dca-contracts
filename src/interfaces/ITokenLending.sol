// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenHandler} from "./ITokenHandler.sol";

/**
 * @title ITokenLending
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Lending-handler surface: per-user virtual shares, interest, and share-transition events.
 * @dev Idle handlers do not implement this. OperationsAdmin requires it on lending routes and
 *      rejects it on idle routes.
 */
interface ITokenLending is ITokenHandler {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical per-user virtual lending-share balance after a successful mint or burn.
    /// @dev Only `user` is indexed. `newShares` equals `getUserShares(user)` after the call.
    ///      Reverted mutations produce no lasting log. Idle handlers do not emit this.
    event TokenLending__UserSharesUpdated(address indexed user, uint256 previousShares, uint256 newShares);
    /// @notice Shares were redeemed for one user. In a batch this fires per user with that user's
    ///         planned share; `SharesRedeemedBatch` carries the total the handler measured.
    event TokenLending__SharesRedeemed(
        address indexed user, uint256 underlyingAmount, uint256 sharesAmountRedeemed
    );
    /// @notice A batch redemption's measured stablecoin and share totals.
    event TokenLending__SharesRedeemedBatch(uint256 underlyingAmount, uint256 sharesAmountRedeemed);
    /// @notice Interest was paid out to `user` in `token`.
    event TokenLending__InterestWithdrawn(
        address indexed user, address indexed token, uint256 underlyingAmountWithdrawn
    );
    /// @notice A withdrawal was clamped to the user's share-backed stablecoin.
    event TokenLending__WithdrawalAmountAdjusted(
        address indexed user, uint256 originalAmount, uint256 adjustedAmount
    );
    /// @notice A single-user redeem was clamped to the shares this handler books for that user.
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

    /// @notice The lending protocol accepted a deposit call but this handler gained no shares.
    error TokenLending__LendingProtocolDepositFailed();
    /// @notice The lending protocol's redemption call reported failure with a non-zero error code.
    error TokenLending__LendingProtocolRedeemFailed(uint256 errorCode);
    /// @notice A positive share redemption produced no stablecoin; the call is rolled back.
    error TokenLending__ZeroStablecoinReceived(uint256 stablecoinAttempted);
    /// @notice Batch redeem asked for more of this user's shares than the handler tracks.
    /// @dev Same outcome as a 0.8 underflow on `s_shares[user] -=`; the named error is for the swapper.
    error TokenLending__InsufficientShares(address user, uint256 requested, uint256 available);

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice This user's virtual lending-share balance on this handler.
     * @param user Account to query.
     * @return The booked share balance. Equals `newShares` on the latest `UserSharesUpdated` for `user`.
     */
    function getUserShares(address user) external view returns (uint256);

    /**
     * @notice Pay `user` the stablecoin interest above `stablecoinLockedInDcaSchedules`.
     * @param user The address receiving the interest.
     * @param stablecoinLockedInDcaSchedules Principal DcaManager still locks for this user on this
     *        handler's route. Interest is `share-backed stablecoin - this amount`, or zero.
     * @dev Called only by DcaManager. No-op when there is no interest.
     */
    function withdrawInterest(address user, uint256 stablecoinLockedInDcaSchedules) external;

    /**
     * @notice Interest `user` has accrued above locked principal, without withdrawing it.
     * @param user Account to query.
     * @param stablecoinLockedInDcaSchedules Principal DcaManager still locks for this user on this
     *        handler's route.
     * @return Accrued interest in stablecoin units, or zero.
     * @dev Not a view: the figure is taken at the market's current exchange rate, which on a market
     *      that accrues lazily is a call that updates that rate. This is the figure a caller may
     *      spend against, so it must not sit a poke behind what a withdrawal would pay. Reachable
     *      only by DcaManager, so its mutability never reaches a generated client.
     */
    function getAccruedInterest(address user, uint256 stablecoinLockedInDcaSchedules) external returns (uint256);

    /**
     * @notice The same figure as `getAccruedInterest`, read without poking the market.
     * @param user Account to query.
     * @param stablecoinLockedInDcaSchedules Principal DcaManager still locks for this user on this
     *        handler's route.
     * @return Accrued interest in stablecoin units, or zero.
     * @dev The display quote, and what keeps `IDcaManager.getInterestAccrued` a `view`. On a market
     *      that accrues lazily this can sit below what `getAccruedInterest` reports, never above,
     *      because a stored rate only trails a current one. So a caller may always spend the quoted
     *      figure; the most a stale quote costs is a slice left for the next call.
     */
    function quoteAccruedInterest(address user, uint256 stablecoinLockedInDcaSchedules)
        external
        view
        returns (uint256);
}
