// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/**
 * @title IDcaManager
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the DcaManager contract.
 */
interface IDcaManager {
    ////////////////////////
    // Type declarations ///
    ////////////////////////
    struct DcaDetails {
        uint256 tokenBalance; // Stablecoin amount deposited by the user
        uint256 purchaseAmount; // Stablecoin amount to spend periodically on rBTC
        uint256 purchasePeriod; // Time between purchases in seconds
        uint256 lastPurchaseTimestamp; // Timestamp of the latest purchase
        bytes32 scheduleId; // Unique identifier of each DCA schedule
        uint256 lendingProtocolIndex;
    }

    //////////////////////
    // Events ////////////
    //////////////////////
    event DcaManager__TokenBalanceUpdated(address indexed token, bytes32 indexed scheduleId, uint256 indexed amount);
    event DcaManager__PurchaseAmountSet(
        address indexed user, bytes32 indexed scheduleId, uint256 indexed purchaseAmount
    );
    event DcaManager__PurchasePeriodSet(
        address indexed user, bytes32 indexed scheduleId, uint256 indexed purchasePeriod
    );
    event DcaManager__DcaScheduleCreated(
        address indexed user,
        address indexed token,
        bytes32 indexed scheduleId,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 lendingProtocolIndex
    );
    event DcaManager__DcaScheduleUpdated(
        address indexed user,
        address indexed token,
        bytes32 indexed scheduleId,
        uint256 updatedTokenBalance,
        uint256 updatedPurchaseAmount,
        uint256 updatedPurchasePeriod
    );
    event DcaManager__DcaScheduleDeleted(address user, address token, bytes32 scheduleId, uint256 refundedAmount);
    event DcaManager__MaxSchedulesPerTokenModified(uint256 indexed newMaxSchedulesPerToken);
    event DcaManager__OperationsAdminUpdated(address indexed newOperationsAdmin);
    event DcaManager__MinPurchasePeriodModified(uint256 indexed newMinPurchasePeriod);
    event DcaManager__LastPurchaseTimestampUpdated(address indexed token, bytes32 indexed scheduleId, uint256 indexed lastPurchaseTimestamp);
    event DcaManager__DefaultMinPurchaseAmountModified(uint256 indexed newDefaultMinPurchaseAmount);
    event DcaManager__TokenMinPurchaseAmountSet(address indexed token, uint256 indexed minPurchaseAmount);

    //////////////////////
    // Errors ////////////
    //////////////////////
    error DcaManager__TokenNotAccepted(address token, uint256 lendingProtocolIndex);
    error DcaManager__DepositAmountMustBeGreaterThanZero();
    error DcaManager__WithdrawalAmountMustBeGreaterThanZero();
    error DcaManager__WithdrawalAmountExceedsBalance(address token, uint256 amount, uint256 balance);
    error DcaManager__PurchaseAmountMustBeGreaterThanMinimum(address token, uint256 minPurchaseAmount);
    error DcaManager__PurchasePeriodMustBeGreaterThanMinimum();
    error DcaManager__PurchaseAmountMustBeLowerThanHalfOfBalance();
    error DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed(uint256 timeRemaining);
    error DcaManager__InexistentScheduleIndex();
    error DcaManager__ScheduleIdAndIndexMismatch();
    error DcaManager__ScheduleBalanceNotEnoughForPurchase(uint256 scheduleIndex, bytes32 scheduleId, address token, uint256 remainingBalance);
    error DcaManager__BatchPurchaseArraysLengthMismatch();
    error DcaManager__EmptyBatchPurchaseArrays();
    error DcaManager__MaxSchedulesPerTokenReached(address token);
    error DcaManager__TokenDoesNotYieldInterest(address token);
    error DcaManager__UnauthorizedSwapper(address sender);
    error DcaManager__PurchaseAmountMismatch(address user, address token, bytes32 scheduleId, uint256 scheduleIndex, uint256 actualPurchaseAmount, uint256 expectedPurchaseAmount);

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit a specified amount of a stablecoin into the contract for DCA operations.
     * @param token The token address of the stablecoin to deposit.
     * @param scheduleIndex The index of the DCA schedule
     * @param scheduleId The schedule id for validation
     * @param depositAmount The amount of the stablecoin to deposit.
     */
    function depositToken(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 depositAmount) external;

    /**
     * @notice Withdraw a specified amount of a stablecoin from the contract.
     * @param token The token address of the stablecoin to deposit.
     * @param scheduleIndex The index of the DCA schedule
     * @param scheduleId The schedule id for validation
     * @param withdrawalAmount The amount of the stablecoin to withdraw.
     */
    function withdrawToken(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 withdrawalAmount) external;

    /**
     * @notice Create a new DCA schedule depositing a specified amount of a stablecoin into the contract.
     * @param token The token address of the stablecoin to deposit.
     * @param depositAmount The amount of the stablecoin to deposit.
     * @param purchaseAmount The amount of to spend periodically in buying rBTC
     * @param purchasePeriod The period for recurrent purchases
     * @param lendingProtocolIndex: the index in the OperationsAdmin contract of the lending protocol, if any, where the token will be deposited to generate yield
     */
    function createDcaSchedule(
        address token,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 lendingProtocolIndex
    ) external;

    /**
     * @notice Update an existing DCA schedule.
     * @param token The token address of the stablecoin to deposit.
     * @param scheduleIndex The index of the DCA schedule
     * @param scheduleId The schedule id for validation
     * @param depositAmount The amount of the stablecoin to deposit.
     * @param purchaseAmount The amount of to spend periodically in buying rBTC
     * @param purchasePeriod The period for recurrent purchases
     */
    function updateDcaSchedule(
        address token,
        uint256 scheduleIndex,
        bytes32 scheduleId,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod
    ) external;

    /**
     * @dev function to delete a DCA schedule: cancels DCA and retrieves the funds
     * @param token the token used for DCA in the schedule to be deleted
     * @param scheduleIndex the index of the schedule to delete
     * @param scheduleId the unique identifier of the schedule to be deleted for validation
     */
    function deleteDcaSchedule(address token, uint256 scheduleIndex, bytes32 scheduleId) external;

    /**
     * @notice Set the purchase amount for a DCA schedule.
     * @param token The token address of the stablecoin.
     * @param scheduleIndex The index of the DCA schedule
     * @param scheduleId The schedule id for validation
     * @param purchaseAmount The amount of to spend periodically in buying rBTC
     */
    function setPurchaseAmount(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 purchaseAmount) external;

    /**
     * @notice Set the purchase period for a DCA schedule.
     * @param token The token address of the stablecoin.
     * @param scheduleIndex The index of the DCA schedule
     * @param scheduleId The schedule id for validation
     * @param purchasePeriod The period for recurrent purchases
     */
    function setPurchasePeriod(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 purchasePeriod) external;

    /**
     * @notice Withdraw a specified amount of a stablecoin from the contract.
     * @param tokenHandlerFactoryAddress The address of the new token handler factory contract
     */
    function setOperationsAdmin(address tokenHandlerFactoryAddress) external;

    /**
     * @param buyer The address of the user on behalf of whom rBTC is going to be bought
     * @param token the stablecoin that all users in the array will spend to purchase rBTC
     * @param scheduleIndex the index of the DCA schedule
     * @param scheduleId the ID of the schedule to which the purchase corresponds
     */
    function buyRbtc(address buyer, address token, uint256 scheduleIndex, bytes32 scheduleId) external;

    /**
     * @param buyers the array of addresses of the users on behalf of whom rBTC is going to be bought
     * @notice a buyer may be featured more than once in the buyers array if two or more their schedules are due for a purchase
     * @notice we need to take extra care in the back end to not mismatch a user's address with a wrong DCA schedule
     * @param token the stablecoin that all users in the array will spend to purchase rBTC
     * @param scheduleIndexes the indexes of the DCA schedules that correspond to each user's purchase
     * @param scheduleIds the IDs of the DCA schedules that correspond to each user's purchase
     * @param purchaseAmounts the purchase amount that corresponds to each user's purchase
     * @param lendingProtocolIndex the lending protocol to withdraw the tokens from before purchasing
     */
    function batchBuyRbtc(
        address[] calldata buyers,
        address token,
        uint256[] calldata scheduleIndexes,
        bytes32[] calldata scheduleIds,
        uint256[] calldata purchaseAmounts,
        uint256 lendingProtocolIndex
    ) external;

    /**
     * @notice Withdraw the token accumulated by a user as interest through all the DCA strategies using that token
     * @param tokens Array of token addresses which the user has deposited
     * @param lendingProtocolIndexes Array of lending protocol indexes to withdraw interest from
     */
    function withdrawAllAccumulatedInterest(address[] calldata tokens, uint256[] calldata lendingProtocolIndexes) external;

    /**
     * @notice Withdraw a specified amount of a stablecoin from the contract as well as all the yield generated with it across all DCA schedules
     * @param token The token address of the stablecoin to deposit.
     * @param scheduleIndex The index of the DCA schedule
     * @param scheduleId The schedule id for validation
     * @param withdrawalAmount The amount of the stablecoin to withdraw.
     * @param lendingProtocolIndex: the lending protocol index
     */
    function withdrawTokenAndInterest(
        address token,
        uint256 scheduleIndex,
        bytes32 scheduleId,
        uint256 withdrawalAmount,
        uint256 lendingProtocolIndex
    ) external;

    /**
     * @notice Withdraw the rBtc accumulated by a user through all the DCA strategies created using a given stablecoin
     * @param token The token address of the stablecoin
     * @param lendingProtocolIndex The index of the lending protocol where the stablecoin is lent (0 if it is not lent)
     */
    function withdrawRbtcFromTokenHandler(address token, uint256 lendingProtocolIndex) external;

    /**
     * @notice Withdraw all of the rBTC accumulated by a user through their various DCA strategies
     * @param tokens Array of token addresses which the user has deposited
     * @param lendingProtocolIndexes Array of lending protocol indexes where the user has positions
     */
    function withdrawAllAccumulatedRbtc(address[] calldata tokens, uint256[] calldata lendingProtocolIndexes) external;

    /**
     * @dev modifies the minimum period that can be set for purchases
     */
    function modifyMinPurchasePeriod(uint256 minPurchasePeriod) external;

    /**
     * @dev modifies the maximum number of schedules per token
     */
    function modifyMaxSchedulesPerToken(uint256 maxSchedulesPerToken) external;

    /**
     * @dev modifies the default minimum purchase amount for all tokens
     */
    function modifyDefaultMinPurchaseAmount(uint256 defaultMinPurchaseAmount) external;

    /**
     * @dev sets a custom minimum purchase amount for a specific token
     */
    function setTokenMinPurchaseAmount(address token, uint256 minPurchaseAmount) external;

    //////////////////////
    // Getter functions //
    //////////////////////

    /**
     * @notice get the DCA schedules for a user and a token
     * @param token the token address
     * @return the DCA schedules for the user and the token
     */
    function getMyDcaSchedules(address token) external view returns (DcaDetails[] memory);

    /**
     * @notice get the DCA schedules for a specific user and token
     * @param user the user address
     * @param token the token address
     * @return the DCA schedules for the user and the token
     */
    function getDcaSchedules(address user, address token) external view returns (DcaDetails[] memory);

    /**
     * @notice get the balance of a schedule for the caller
     * @param token the token address
     * @param scheduleIndex the index of the schedule
     * @return the balance of the schedule
     */
    function getMyScheduleTokenBalance(address token, uint256 scheduleIndex) external view returns (uint256);

    /**
     * @notice get the balance of a schedule for a specific user
     * @param user the user address
     * @param token the token address
     * @param scheduleIndex the index of the schedule
     * @return the balance of the schedule
     */
    function getScheduleTokenBalance(address user, address token, uint256 scheduleIndex) external view returns (uint256);

    /**
     * @notice get the purchase amount of a schedule for the caller
     * @param token the token address
     * @param scheduleIndex the index of the schedule
     * @return the purchase amount of the schedule
     */
    function getMySchedulePurchaseAmount(address token, uint256 scheduleIndex) external view returns (uint256);

    /**
     * @notice get the purchase amount of a schedule for a specific user
     * @param user the user address
     * @param token the token address
     * @param scheduleIndex the index of the schedule
     * @return the purchase amount of the schedule
     */
    function getSchedulePurchaseAmount(address user, address token, uint256 scheduleIndex) external view returns (uint256);

    /**
     * @notice get the purchase period of a schedule for the caller
     * @param token the token address
     * @param scheduleIndex the index of the schedule
     * @return the purchase period of the schedule
     */
    function getMySchedulePurchasePeriod(address token, uint256 scheduleIndex) external view returns (uint256);

    /**
     * @notice get the purchase period of a schedule for a specific user
     * @param user the user address
     * @param token the token address
     * @param scheduleIndex the index of the schedule
     * @return the purchase period of the schedule
     */
    function getSchedulePurchasePeriod(address user, address token, uint256 scheduleIndex) external view returns (uint256);

    /**
     * @notice get the schedule ID of a schedule
     * @param user the user address
     * @param token the token address
     * @param scheduleIndex the index of the schedule
     * @return the schedule ID of the schedule
     */
    function getScheduleId(address user, address token, uint256 scheduleIndex) external view returns (bytes32);

    /**
     * @notice get the schedule ID of a schedule for the caller
     * @param token the token address
     * @param scheduleIndex the index of the schedule
     * @return the schedule ID of the schedule
     */
    function getMyScheduleId(address token, uint256 scheduleIndex) external view returns (bytes32);

    /**
     * @notice get the admin operations contract's address
     * @return the admin operations contract's address
     */
    function getOperationsAdminAddress() external view returns (address);

    /**
     * @notice get the interest accrued by a user for a token and a lending protocol index
     * @param user the user address
     * @param token the token address
     * @param lendingProtocolIndex the lending protocol index
     * @return the interest accrued by the user for the token and the lending protocol index
     */
    function getInterestAccrued(address user, address token, uint256 lendingProtocolIndex)
        external
        view
        returns (uint256);

    /**
     * @notice get the interest accrued by a user for a token and lending protocol index (caller's schedule)
     * @param token the token address
     * @param lendingProtocolIndex the lending protocol index
     * @return the interest accrued by the user for the token and lending protocol index
     */
    function getMyInterestAccrued(address token, uint256 lendingProtocolIndex) external view returns (uint256);

    /**
     * @dev returns the minimum period that can be set for purchases
     */
    function getMinPurchasePeriod() external view returns (uint256);

    /**
     * @dev returns the maximum number of schedules per token
     */
    function getMaxSchedulesPerToken() external view returns (uint256);

    /**
     * @dev returns the default minimum purchase amount for all tokens
     */
    function getDefaultMinPurchaseAmount() external view returns (uint256);

    /**
     * @dev returns the minimum purchase amount for a specific token (0 if not set)
     */
    function getTokenMinPurchaseAmount(address token) external view returns (uint256 minPurchaseAmount, bool customMinAmountSet);
}
