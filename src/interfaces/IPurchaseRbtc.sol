// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IPurchaseRbtc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Shared rBTC purchase and signer-withdrawal surface. Called only by DcaManager.
 */
interface IPurchaseRbtc {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Accumulated rBTC was paid to `user` (`msg.sender` on DcaManager).
    event PurchaseRbtc__rBtcWithdrawn(address indexed user, uint256 amount);
    /// @notice One schedule in a batch bought rBTC. `amountSpent` is that row's share of net stablecoin.
    event PurchaseRbtc__RbtcBought(
        address indexed user,
        address indexed tokenSpent,
        uint256 rBtcBought,
        uint64 indexed scheduleId,
        uint256 amountSpent
    );
    /// @notice A batch purchase completed. Totals are measured cash, not planned gross.
    event PurchaseRbtc__SuccessfulRbtcBatchPurchase(
        address indexed token, uint256 totalPurchasedRbtc, uint256 totalStablecoinAmountSpent
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice `user` has no accumulated rBTC to withdraw.
    error PurchaseRbtc__NoAccumulatedRbtcToWithdraw();
    /// @notice Native rBTC transfer to the signer failed.
    error PurchaseRbtc__rBtcWithdrawalFailed();
    /// @notice The purchase path returned no rBTC for this batch.
    error PurchaseRbtc__RbtcBatchPurchaseFailed(address tokenSpent);
    /// @notice The batch retrieved less stablecoin than the fee it owes, so there is nothing left to spend.
    error PurchaseRbtc__StablecoinRetrievedBelowFee(uint256 stablecoinRetrieved, uint256 aggregatedFee);

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Spend each buyer's stablecoin and credit their accumulated rBTC.
     * @param buyers Users to buy for. An address may appear more than once.
     * @param scheduleIds Schedule id for each row, used only in `RbtcBought`.
     * @param purchaseAmounts Gross stablecoin each row spends before the protocol fee.
     * @dev Called only by DcaManager after it has debited each schedule. Fees are aggregated and
     *      transferred once; each buyer is credited a pro-rata share of the measured rBTC.
     */
    function batchBuyRbtc(
        address[] memory buyers,
        uint64[] memory scheduleIds,
        uint256[] memory purchaseAmounts
    ) external;

    /**
     * @notice Pay `user` the rBTC this handler has accumulated for them.
     * @param user Account whose balance is paid. DcaManager always passes `msg.sender`; there is
     *        no `to` parameter and no owner rescue of another account's rBTC.
     */
    function withdrawAccumulatedRbtc(address user) external;

    /**
     * @notice rBTC this handler has accumulated for `user` and not yet withdrawn.
     * @param user Account to query.
     * @return Accumulated rBTC in wei.
     */
    function getAccumulatedRbtcBalance(address user) external view returns (uint256);
}
