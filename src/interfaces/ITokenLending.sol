// SPDX-License-Identifier: BUSL-1.1
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
    /// @notice One user's shares were redeemed for measured stablecoin.
    /// @dev Emitted only on single-user redeems (`withdraw` / interest). `underlyingAmount` is the
    ///      stablecoin this handler measured receiving for that user. Batch purchases do not emit
    ///      this: each row's exact share debit is `UserSharesUpdated`, and measured cash for the
    ///      whole redeem is `SharesRedeemedBatch`.
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
    /// @notice The lending protocol did not consume exactly the receipt shares BitChill debited.
    /// @dev `balanceBefore` / `balanceAfter` are the handler's external receipt-share balances
    ///      around the protocol call (iToken/kToken `balanceOf`, or aToken `scaledBalanceOf`).
    ///      Covers zero, partial, excessive, and increasing balances without an arithmetic panic.
    error TokenLending__ShareConsumptionMismatch(
        uint256 intendedDecrease, uint256 balanceBefore, uint256 balanceAfter
    );

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
     * @dev Deliberately not a `view`, and do not make it one: the figure is taken at the market's
     *      current exchange rate, which on a market that accrues lazily is a call that updates that
     *      rate. This is the figure a caller may spend against, so it must not sit a poke behind what
     *      a withdrawal would pay. The non-view mutability costs consumers nothing because only
     *      DcaManager can reach this function; `quoteAccruedInterest` is the `view` display read.
     */
    function getAccruedInterest(address user, uint256 stablecoinLockedInDcaSchedules) external returns (uint256);

    /**
     * @notice Re-grant the lending spender the unbounded stablecoin allowance set at construction.
     * @dev Anyone may call it: it re-grants `max` to the constructor's own immutable spender, so it
     *      authorizes nothing new. The constructor grant is otherwise one-shot.
     */
    function restoreLendingApproval() external;

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice This user's virtual lending-share balance on this handler.
     * @param user Account to query.
     * @return The booked share balance. Equals `newShares` on the latest `UserSharesUpdated` for `user`.
     */
    function getUserShares(address user) external view returns (uint256);

    /**
     * @notice The same figure as `getAccruedInterest`, read without poking the market.
     * @param user Account to query.
     * @param stablecoinLockedInDcaSchedules Principal DcaManager still locks for this user on this
     *        handler's route.
     * @return Accrued interest in stablecoin units, or zero.
     * @dev The display quote, and what keeps `IDcaManager.getInterestAccrued` a `view`. On a market
     *      that accrues lazily this can sit below what `getAccruedInterest` reports, never above,
     *      because a stored rate only trails a current one. The quote therefore never exceeds the
     *      top-up ceiling; DcaManager separately enforces its minimum purchase-boundary rule.
     */
    function quoteAccruedInterest(address user, uint256 stablecoinLockedInDcaSchedules)
        external
        view
        returns (uint256);
}
