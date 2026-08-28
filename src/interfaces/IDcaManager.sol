// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IDcaManager
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the DcaManager contract.
 */
interface IDcaManager {
    ////////////////////////
    // Type declarations ///
    ////////////////////////
    /// @dev Two storage slots, ordered so the two fields a purchase writes (`tokenBalance` and
    ///      `lastPurchaseTimestamp`) share slot 0 with `paused` (23 of 32 bytes). Without IR,
    ///      those updates remain two `SSTORE`s; the second is a cheap dirty write because both
    ///      target the same slot. Slot 1 holds `purchaseAmount` + `purchasePeriod` + `routeIndex`
    ///      + `scheduleId`, filling all 32 bytes. `scheduleId` remains the final ABI field.
    struct DcaSchedule {
        uint128 tokenBalance; // Stablecoin amount deposited by the user
        uint48 lastPurchaseTimestamp; // Timestamp of the latest purchase
        bool paused; // Owner-set: purchases are refused while true; every other path stays open
        uint128 purchaseAmount; // Stablecoin amount to spend periodically on rBTC
        uint32 purchasePeriod; // Time between purchases in seconds
        uint32 routeIndex; // OperationsAdmin route that holds this schedule's funds (idle or lending)
        uint64 scheduleId; // Unique identifier of each DCA schedule: the value of the creation nonce
    }

    /**
     * @notice The protocol scalars every create reads, plus the id counter it writes.
     * @dev One slot (30 of 32 bytes): `createDcaSchedule` loads all four together and stores the
     *      bumped nonce back into the same word. Owner setters take `uint256` and SafeCast at the write.
     * @dev `scheduleNonce` is a strictly increasing counter and is the schedule id itself. Ids must not
     *      be derived from array state: swap-pop on delete can restore a previous array shape within a
     *      block, which would let two live schedules share an id.
     * @dev Internal storage shape, not an ABI type: the scalars are read through their own getters.
     */
    struct ProtocolSettings {
        uint32 minPurchasePeriod; // Minimum time between purchases
        uint16 maxSchedulesPerToken; // Maximum number of schedules per stablecoin
        uint128 defaultMinPurchaseAmount; // Default minimum purchase amount for all tokens
        uint64 scheduleNonce; // Last assigned schedule id; 0 before the first schedule is created
    }

    //////////////////////
    // Events ////////////
    //////////////////////
    event DcaManager__TokenBalanceUpdated(address indexed token, uint64 indexed scheduleId, uint256 indexed amount);
    event DcaManager__PurchaseAmountUpdated(
        address indexed user, uint64 indexed scheduleId, uint256 previousAmount, uint256 newAmount
    );
    event DcaManager__PurchasePeriodUpdated(
        address indexed user, uint64 indexed scheduleId, uint256 previousPeriod, uint256 newPeriod
    );
    event DcaManager__DcaScheduleCreated(
        address indexed user,
        address indexed token,
        uint64 indexed scheduleId,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 routeIndex
    );
    event DcaManager__SchedulePauseSet(address indexed user, uint64 indexed scheduleId, bool paused);
    event DcaManager__DcaScheduleDeleted(address user, address token, uint64 scheduleId, uint256 refundedAmount);
    event DcaManager__MaxSchedulesPerTokenModified(uint256 indexed newMaxSchedulesPerToken);
    event DcaManager__MinPurchasePeriodModified(uint256 indexed newMinPurchasePeriod);
    event DcaManager__LastPurchaseTimestampUpdated(address indexed token, uint64 indexed scheduleId, uint256 indexed lastPurchaseTimestamp);
    event DcaManager__DefaultMinPurchaseAmountModified(uint256 indexed newDefaultMinPurchaseAmount);
    event DcaManager__TokenMinPurchaseAmountSet(address indexed token, uint256 indexed minPurchaseAmount);

    //////////////////////
    // Errors ////////////
    //////////////////////
    error DcaManager__TokenNotAccepted(address token, uint256 routeIndex);
    error DcaManager__DepositAmountMustBeGreaterThanZero();
    error DcaManager__WithdrawalAmountMustBeGreaterThanZero();
    error DcaManager__WithdrawalAmountExceedsBalance(address token, uint256 amount, uint256 balance);
    error DcaManager__PurchaseAmountMustBeGreaterThanMinimum(address token, uint256 minPurchaseAmount);
    error DcaManager__PurchasePeriodMustBeGreaterThanMinimum();
    error DcaManager__MinPurchasePeriodMustBeAtLeastOneDay();
    error DcaManager__PurchaseAmountExceedsBalance(address token, uint256 purchaseAmount, uint256 tokenBalance);
    error DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed(uint256 timeRemaining);
    error DcaManager__InexistentScheduleIndex();
    error DcaManager__ScheduleIdAndIndexMismatch();
    error DcaManager__ScheduleBalanceNotEnoughForPurchase(uint256 scheduleIndex, uint64 scheduleId, address token, uint256 remainingBalance);
    error DcaManager__BatchPurchaseArraysLengthMismatch();
    error DcaManager__EmptyBatchPurchaseArrays();
    error DcaManager__MaxSchedulesPerTokenReached(address token);
    error DcaManager__TokenDoesNotYieldInterest(address token);
    error DcaManager__UnauthorizedSwapper(address sender);
    error DcaManager__PurchaseAmountMismatch(address user, address token, uint64 scheduleId, uint256 scheduleIndex, uint256 actualPurchaseAmount, uint256 expectedPurchaseAmount);
    error DcaManager__RouteIndexMismatch(address user, address token, uint64 scheduleId, uint256 scheduleIndex, uint256 actualRouteIndex, uint256 expectedRouteIndex);
    error DcaManager__OperationsAdminIsNotAContract(address operationsAdmin);
    error DcaManager__DepositsPaused(address token, uint256 routeIndex);
    error DcaManager__SchedulePaused(address user, address token, uint64 scheduleId, uint256 scheduleIndex);

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit a specified amount of a stablecoin into the contract for DCA operations.
     * @param token The token address of the stablecoin to deposit.
     * @param scheduleIndex The index of the DCA schedule
     * @param scheduleId The schedule id for validation
     * @param depositAmount The amount of the stablecoin requested from the user. The handler reverts unless it receives exactly this amount, so the schedule is credited with the full request.
     */
    function depositToken(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 depositAmount) external;

    /**
     * @notice Withdraw a specified amount of a stablecoin from the contract.
     * @param token The token address of the stablecoin to deposit.
     * @param scheduleIndex The index of the DCA schedule
     * @param scheduleId The schedule id for validation
     * @param withdrawalAmount The amount of the stablecoin to withdraw. Pass type(uint256).max to withdraw this schedule’s whole token balance.
     */
    function withdrawToken(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 withdrawalAmount) external;

    /**
     * @notice Create a new DCA schedule depositing a specified amount of a stablecoin into the contract.
     * @param token The token address of the stablecoin to deposit.
     * @param depositAmount The amount of the stablecoin requested from the user. The handler reverts unless it receives exactly this amount, so the schedule is credited with the full request.
     * @param purchaseAmount The amount to spend periodically in buying rBTC. Validated against the credited token balance, which equals the requested deposit once the handler pull succeeds.
     * @param purchasePeriod The period for recurrent purchases
     * @param routeIndex The OperationsAdmin route index for this schedule (idle or lending)
     */
    function createDcaSchedule(
        address token,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 routeIndex
    ) external;

    /**
     * @dev function to delete a DCA schedule: cancels DCA and retrieves the funds
     * @param token the token used for DCA in the schedule to be deleted
     * @param scheduleIndex the index of the schedule to delete
     * @param scheduleId the unique identifier of the schedule to be deleted for validation
     */
    function deleteDcaSchedule(address token, uint256 scheduleIndex, uint64 scheduleId) external;

    /**
     * @notice Update the purchase amount of an existing DCA schedule.
     * @param token The token address of the stablecoin.
     * @param scheduleIndex The index of the DCA schedule
     * @param scheduleId The schedule id for validation
     * @param newPurchaseAmount The new amount to spend periodically in buying rBTC
     * @dev emits DcaManager__PurchaseAmountUpdated with the replaced amount and the new one
     */
    function updatePurchaseAmount(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 newPurchaseAmount)
        external;

    /**
     * @notice Update the purchase period of an existing DCA schedule.
     * @param token The token address of the stablecoin.
     * @param scheduleIndex The index of the DCA schedule
     * @param scheduleId The schedule id for validation
     * @param newPurchasePeriod The new period for recurrent purchases
     * @dev emits DcaManager__PurchasePeriodUpdated with the replaced period and the new one
     */
    function updatePurchasePeriod(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 newPurchasePeriod)
        external;

    /**
     * @notice Pause or resume rBTC purchases for one of the caller's DCA schedules.
     * @param token The token address of the stablecoin.
     * @param scheduleIndex The index of the DCA schedule
     * @param scheduleId The schedule id for validation
     * @param paused True to stop purchases, false to resume them
     * @dev A paused schedule keeps its funds on its route and stays open to deposits, amount and
     *      period edits, withdrawals, interest and rBTC claims, and deletion. Setting the state it
     *      already holds is a no-op and emits nothing, so every emitted event is a real transition.
     */
    function setSchedulePaused(address token, uint256 scheduleIndex, uint64 scheduleId, bool paused) external;

    /**
     * @param buyers the array of addresses of the users on behalf of whom rBTC is going to be bought
     * @notice a buyer may be featured more than once in the buyers array if two or more their schedules are due for a purchase
     * @notice we need to take extra care in the back end to not mismatch a user's address with a wrong DCA schedule
     * @param token the stablecoin that all users in the array will spend to purchase rBTC
     * @param scheduleIndexes the indexes of the DCA schedules that correspond to each user's purchase
     * @param scheduleIds the IDs of the DCA schedules that correspond to each user's purchase
     * @param purchaseAmounts the purchase amount that corresponds to each user's purchase
     * @param routeIndex the route all schedules in this batch must share
     * @dev reverts DcaManager__SchedulePaused if any named schedule is paused, which fails the whole
     *      batch: the swapper must filter paused schedules out before composing the call
     */
    function batchBuyRbtc(
        address[] calldata buyers,
        address token,
        uint256[] calldata scheduleIndexes,
        uint64[] calldata scheduleIds,
        uint256[] calldata purchaseAmounts,
        uint256 routeIndex
    ) external;

    /**
     * @notice Withdraw the token accumulated by a user as interest through all the DCA strategies using that token
     * @param tokens Array of token addresses which the user has deposited
     * @param routeIndexes Route indexes to withdraw interest from. Idle routes are skipped.
     */
    function withdrawAllAccumulatedInterest(address[] calldata tokens, uint256[] calldata routeIndexes) external;

    /**
     * @notice Withdraw a specified amount of a stablecoin from the contract as well as all the yield generated with it across all DCA schedules
     * @param token The token address of the stablecoin to deposit.
     * @param scheduleIndex The index of the DCA schedule
     * @param scheduleId The schedule id for validation
     * @param withdrawalAmount The amount of the stablecoin to withdraw, or type(uint256).max for this schedule's whole token balance.
     * @dev Interest is withdrawn from the schedule's stored lending route. An idle schedule reverts because that route does not yield.
     */
    function withdrawTokenAndInterest(
        address token,
        uint256 scheduleIndex,
        uint64 scheduleId,
        uint256 withdrawalAmount
    ) external;

    /**
     * @notice Withdraw the rBtc accumulated by a user through all the DCA strategies created using a given stablecoin
     * @param token The token address of the stablecoin
     * @param routeIndex The route whose handler holds the user's accumulated rBTC
     */
    function withdrawRbtcFromTokenHandler(address token, uint256 routeIndex) external;

    /**
     * @notice Withdraw all of the rBTC accumulated by a user through their various DCA strategies
     * @param tokens Array of token addresses which the user has deposited
     * @param routeIndexes Route indexes whose handlers may hold the user's accumulated rBTC
     */
    function withdrawAllAccumulatedRbtc(address[] calldata tokens, uint256[] calldata routeIndexes) external;

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
     * @notice get one DCA schedule for a user and token
     * @param user the user address
     * @param token the token address
     * @param scheduleIndex the index of the schedule
     * @return the DCA schedule
     */
    function getDcaSchedule(address user, address token, uint256 scheduleIndex) external view returns (DcaSchedule memory);

    /**
     * @notice get the DCA schedules for a specific user and token
     * @param user the user address
     * @param token the token address
     * @return the DCA schedules for the user and the token
     */
    function getDcaSchedules(address user, address token) external view returns (DcaSchedule[] memory);

    /**
     * @notice get the OperationsAdmin this manager is permanently pinned to
     * @return the constructor-supplied OperationsAdmin address
     */
    function getOperationsAdminAddress() external view returns (address);

    /**
     * @notice get the interest accrued by a user for a token and a route index
     * @param user the user address
     * @param token the token address
     * @param routeIndex the route index
     * @return the interest accrued by the user for the token and the route index
     */
    function getInterestAccrued(address user, address token, uint256 routeIndex)
        external
        view
        returns (uint256);

    /**
     * @notice get the rBTC accumulated by a user on the handler for a token and route index
     * @param user the user address
     * @param token the token address
     * @param routeIndex the route index
     * @return the accumulated rBTC balance
     */
    function getAccumulatedRbtcBalance(address user, address token, uint256 routeIndex)
        external
        view
        returns (uint256);

    /**
     * @dev returns the minimum period that can be set for purchases
     */
    function getMinPurchasePeriod() external view returns (uint256);

    /**
     * @dev returns the maximum number of schedules per token
     */
    function getMaxSchedulesPerToken() external view returns (uint256);

    /**
     * @dev returns the lifetime count of DCA schedules created across all users and tokens.
     * Equals the last `scheduleId` assigned, since ids are that counter. Never decreases;
     * deletions do not decrement it.
     */
    function getSchedulesCreatedCount() external view returns (uint256);

    /**
     * @dev returns the default minimum purchase amount for all tokens
     */
    function getDefaultMinPurchaseAmount() external view returns (uint256);

    /**
     * @dev returns the minimum purchase amount for a specific token (0 if not set)
     */
    function getTokenMinPurchaseAmount(address token) external view returns (uint256 minPurchaseAmount, bool customMinAmountSet);
}
