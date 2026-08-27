// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IPurchaseRbtc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the RBTC purchase related functions
 */
interface IPurchaseRbtc {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event PurchaseRbtc__rBtcWithdrawn(address indexed user, uint256 indexed amount);
    event PurchaseRbtc__RbtcBought(
        address indexed user,
        address indexed tokenSpent,
        uint256 rBtcBought,
        bytes32 indexed scheduleId,
        uint256 amountSpent
    );
    event PurchaseRbtc__SuccessfulRbtcBatchPurchase(
        address indexed token, uint256 indexed totalPurchasedRbtc, uint256 indexed totalStablecoinAmountSpent
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PurchaseRbtc__NoAccumulatedRbtcToWithdraw();
    error PurchaseRbtc__rBtcWithdrawalFailed();
    error PurchaseRbtc__RbtcBatchPurchaseFailed(address tokenSpent);
    /// @notice the batch retrieved less stablecoin than the fee it owes, so there is nothing left to spend
    error PurchaseRbtc__StablecoinRetrievedBelowFee(uint256 stablecoinRetrieved, uint256 aggregatedFee);

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @param buyers: the users on behalf of which the contract is making the rBTC purchases
     * @param scheduleIds: the IDs of the DCA schedules to which the purchases belong
     * @param purchaseAmounts: the amounts of the token to be spent on BTC
     * @notice this function will be called periodically through a CRON job running on a web server
     */
    function batchBuyRbtc(
        address[] memory buyers,
        bytes32[] memory scheduleIds,
        uint256[] memory purchaseAmounts
    ) external;

    /**
     * @notice the user can at any time withdraw the rBTC that has been accumulated through periodical purchases
     */
    function withdrawAccumulatedRbtc(address user) external;

    /**
     * @dev returns the rBTC that has been accumulated by the user through periodical purchases
     * @param user the address of the user to check the accumulated rBTC balance for
     */
    function getAccumulatedRbtcBalance(address user) external view returns (uint256);
}
