// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IStablecoinSource} from "./IStablecoinSource.sol";

/**
 * @title IPurchaseRbtc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Shared rBTC purchase and signer-withdrawal surface. Called only by DcaManager.
 */
interface IPurchaseRbtc is IStablecoinSource {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Accumulated rBTC was paid to `user` (`msg.sender` on DcaManager).
    event PurchaseRbtc__rBtcWithdrawn(address indexed user, uint256 amount);
    /// @notice One schedule in a batch bought rBTC. `amountSpent` is that row's share of gross stablecoin.
    event PurchaseRbtc__RbtcBought(
        address indexed user,
        address indexed tokenSpent,
        uint256 rBtcBought,
        uint64 indexed scheduleId,
        uint256 amountSpent
    );
    /**
     * @notice A batch purchase completed. Totals are measured cash, not the amounts requested.
     * @dev `totalPurchasedRbtc` is gross measured output (includes the collector share; generally
     *      exceeds ∑ `RbtcBought.rBtcBought`). `totalStablecoinAmountSpent` is retrieved gross.
     */
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
    /// @notice The measured rBTC this batch bought is below the minimum the caller attached to it.
    error PurchaseRbtc__BelowSwapperMinimum(uint256 rbtcReceived, uint256 minRbtcOut);
    /// @notice Venue did not reduce the handler's purchase-token balance by exactly `expectedAmount`.
    error PurchaseRbtc__InputAmountNotFullySpent(uint256 expectedAmount, uint256 balanceBefore, uint256 balanceAfter);

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Spend each buyer's stablecoin and credit their accumulated rBTC.
     * @param buyers Users to buy for. An address may appear more than once.
     * @param scheduleIds Schedule id for each row, used only in `RbtcBought`.
     * @param purchaseAmounts Nominal stablecoin requested per row. Lending may reduce the funding weights.
     * @param minRbtcOut Minimum rBTC this batch must buy (rBTC/WRBTC wei). `0` disables. Binds
     *        gross measured output before the protocol fee is taken from that output.
     * @dev DcaManager has already debited the schedules. Venue spends full retrieved stablecoin.
     *      If a lending row exceeds its buyer's remaining shares, use those shares' stablecoin value
     *      as that row's funding weight. A zero-value row reverts. Fees use the funded weights.
     *      Measured output `Q` splits over the adjusted funding sum (`G`): buyers
     *      `floor(Q × netᵢ / G)`, collector `floor(Q × F / G)`, floor dust uncredited.
     *      `amountSpent` is each row's share of retrieved gross. Exact stablecoin consumption
     *      required. Collector fee credited last on the same accumulated-rBTC books.
     */
    function batchBuyRbtc(
        address[] calldata buyers,
        uint64[] calldata scheduleIds,
        uint256[] calldata purchaseAmounts,
        uint256 minRbtcOut
    ) external;

    /**
     * @notice Pay `user` the rBTC this handler has accumulated for them.
     * @param user Account paid. DcaManager always passes `msg.sender` — no `to`, no owner rescue.
     *        The fee collector withdraws here too.
     * @dev The account must accept native rBTC with empty calldata, including after WRBTC unwrap on
     *      Dex routes. A rejected payment reverts and restores the credit. An account that permanently
     *      rejects native transfers cannot claim through this surface.
     */
    function withdrawAccumulatedRbtc(address user) external;

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice rBTC this handler has accumulated for `user` and not yet withdrawn.
     * @param user Account to query.
     * @return Accumulated rBTC in wei — the full amount a withdrawal would pay.
     */
    function getAccumulatedRbtcBalance(address user) external view returns (uint256);
}
