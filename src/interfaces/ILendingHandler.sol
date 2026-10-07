// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ITokenHandler} from "./ITokenHandler.sol";

/**
 * @title ILendingHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Lending-handler surface: per-user virtual shares, interest, and share-transition events.
 * @dev Idle handlers do not implement this. OperationsAdmin requires it on lending routes and
 *      rejects it on idle routes.
 */
interface ILendingHandler is ITokenHandler {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Canonical per-user virtual lending-share balance after a successful mint or burn.
     * @dev Only `user` is indexed. `newShares` is the balance immediately after this transition.
     *      Batch purchases combine repeated rows and emit one transition per unique buyer.
     *      Its `newShares` equals `getUserShares(user)` after that batch.
     *      Reverted mutations produce no lasting log. Idle handlers do not emit this.
     */
    event LendingHandler__UserSharesUpdated(address indexed user, uint256 previousShares, uint256 newShares);
    /**
     * @notice One user's shares were redeemed for measured stablecoin.
     * @dev Emitted only on single-user redeems (`withdraw` / interest). `underlyingAmount` is the
     *      stablecoin this handler measured receiving for that user. Batch purchases do not emit
     *      this: each buyer's exact share debit is `UserSharesUpdated`, and measured cash for the
     *      whole redeem is `SharesRedeemedBatch`.
     */
    event LendingHandler__SharesRedeemed(address indexed user, uint256 underlyingAmount, uint256 sharesAmountRedeemed);
    /// @notice A batch redemption's measured stablecoin and share totals.
    event LendingHandler__SharesRedeemedBatch(uint256 underlyingAmount, uint256 sharesAmountRedeemed);
    /// @notice Interest was paid out to `user` in `token`.
    event LendingHandler__InterestWithdrawn(
        address indexed user, address indexed token, uint256 underlyingAmountWithdrawn
    );
    /// @notice A withdrawal was clamped to shares available above the remaining principal reserve.
    event LendingHandler__WithdrawalAmountAdjusted(
        address indexed user, uint256 originalAmount, uint256 adjustedAmount
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The receipt token's underlying is not the stablecoin this handler was constructed with.
    error LendingHandler__UnderlyingMismatch();
    /// @notice The lending protocol accepted a deposit call but this handler gained no shares.
    error LendingHandler__LendingProtocolDepositFailed();
    /// @notice A zero-cash redemption reports its consumed receipt shares before the call rolls back.
    error LendingHandler__ZeroStablecoinReceived(uint256 sharesRedeemed);
    /**
     * @notice A buyer has no shares available above the remaining principal reserve.
     * @dev `requested` is the rounded-up combined purchase; `available` excludes reserved shares.
     *      Positive available funding is adjusted before fee and output allocation instead of reverting.
     */
    error LendingHandler__InsufficientShares(address user, uint256 requested, uint256 available);
    /**
     * @notice The lending protocol did not consume exactly the receipt shares BitChill debited.
     * @dev `balanceBefore` / `balanceAfter` are the handler's external receipt-share balances
     *      around the protocol call (iToken/kToken `balanceOf`, or aToken `scaledBalanceOf`).
     *      Covers zero, partial, excessive, and increasing balances without an arithmetic panic.
     */
    error LendingHandler__ShareConsumptionMismatch(
        uint256 intendedDecrease, uint256 balanceBefore, uint256 balanceAfter
    );

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pay `user` the stablecoin interest above `stablecoinLockedInDcaSchedules`.
     * @param user The address receiving the interest.
     * @param stablecoinLockedInDcaSchedules Principal DcaManager still locks for this user on this
     *        handler's route. Reserve its rounded-up shares before valuing the shares available as interest.
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
     *      current rate after reserving rounded-up shares for locked principal. This can be slightly
     *      smaller than subtracting principal from the value of all shares.
     *      On a market that accrues lazily the exchange-rate call updates that
     *      rate. This is the figure a caller may spend against, so it must not sit a poke behind what
     *      a withdrawal would pay. The non-view mutability costs consumers nothing because only
     *      DcaManager can reach this function; `quoteAccruedInterest` is the `view` display read.
     */
    function getAccruedInterest(address user, uint256 stablecoinLockedInDcaSchedules) external returns (uint256);

    /**
     * @notice Re-grant the lending spender the unbounded stablecoin allowance set at construction.
     * @dev Anyone may call it: it re-grants `max` to the constructor's own immutable spender, so it
     *      authorizes nothing new.
     */
    function restoreLendingApproval() external;

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice This user's virtual lending-share balance on this handler.
     * @param user Account to query.
     * @return The booked share balance. Equals `newShares` on the latest `UserSharesUpdated` for
     *         that user (intermediate emits in the same call may differ).
     */
    function getUserShares(address user) external view returns (uint256);

    /**
     * @notice The same figure as `getAccruedInterest`, read without poking the market.
     * @param user Account to query.
     * @param stablecoinLockedInDcaSchedules Principal DcaManager still locks for this user on this
     *        handler's route.
     * @return Accrued interest in stablecoin units, or zero.
     * @dev The display quote, and what keeps `IDcaManager.getAccruedInterest` a `view`. On a market
     *      that accrues lazily this can sit below what `getAccruedInterest` reports, never above,
     *      because a stored rate only trails a current one. The quote therefore never exceeds the
     *      top-up ceiling; DcaManager separately enforces its minimum purchase-boundary rule.
     */
    function quoteAccruedInterest(address user, uint256 stablecoinLockedInDcaSchedules) external view returns (uint256);
}
