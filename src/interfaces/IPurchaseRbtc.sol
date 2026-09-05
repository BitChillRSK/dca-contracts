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
    /// @notice The batch retrieved no more stablecoin than the fee it owes, so there is nothing left to spend.
    error PurchaseRbtc__StablecoinRetrievedBelowFee(uint256 stablecoinRetrieved, uint256 aggregatedFee);
    /// @notice The measured rBTC this batch bought is below the minimum the caller attached to it.
    /// @dev `requiredMinimum` is `minRbtcOutRate * actualStablecoinSpent / 1e18`, rounded up — the rate
    ///      applied to what this batch actually spent, not a pre-computed absolute figure.
    error PurchaseRbtc__BelowSwapperMinimum(uint256 rbtcReceived, uint256 requiredMinimum);

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Spend each buyer's stablecoin and credit their accumulated rBTC.
     * @param buyers Users to buy for. An address may appear more than once.
     * @param scheduleIds Schedule id for each row, used only in `RbtcBought`.
     * @param purchaseAmounts Gross stablecoin each row spends before the protocol fee.
     * @param minRbtcOutRate Minimum rBTC this batch as a whole must buy per raw unit of stablecoin
     *        actually spent, in rBTC/WRBTC wei (18 decimals) per stablecoin wei, scaled by `1e18`.
     *        `0` disables this check.
     * @dev Called only by DcaManager after it has debited each schedule. Fees are aggregated and
     *      transferred once; each buyer is credited a pro-rata share of the measured rBTC.
     *      `minRbtcOutRate` is applied to the stablecoin this handler actually measures itself
     *      spending — never to a planned or pre-fee figure — and the resulting minimum is compared
     *      against the rBTC this handler measures itself receiving, so it applies to every purchase
     *      venue and never trusts an integrator return value. Where the venue applies a floor of its
     *      own — `PurchaseUniswap` does, derived from the same rate against the same actual spend;
     *      `PurchaseMoc` has no venue floor of its own but still enforces this same shared check — the
     *      stricter of the two decides the outcome.
     */
    function batchBuyRbtc(
        address[] memory buyers,
        uint64[] memory scheduleIds,
        uint256[] memory purchaseAmounts,
        uint256 minRbtcOutRate
    ) external;

    /**
     * @notice Pay `user` the rBTC this handler has accumulated for them.
     * @param user Account whose balance is paid. DcaManager always passes `msg.sender`; there is
     *        no `to` parameter and no owner rescue of another account's rBTC.
     */
    function withdrawAccumulatedRbtc(address user) external;

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice rBTC this handler has accumulated for `user` and not yet withdrawn.
     * @param user Account to query.
     * @return Accumulated rBTC in wei.
     */
    function getAccumulatedRbtcBalance(address user) external view returns (uint256);
}
