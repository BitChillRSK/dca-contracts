// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IDcaManager
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice User and swapper entry point: create and manage dollar-cost-averaging schedules.
 * @dev Users talk only to this contract. A swapper (EOA or `SwapperBatcher`) triggers purchases.
 *      Handlers hold the stablecoin and accumulated rBTC; this contract never custody them.
 */
interface IDcaManager {
    ////////////////////////
    // Type declarations ///
    ////////////////////////
    /// @notice One user's recurring purchase of rBTC with one stablecoin on one OperationsAdmin route.
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
    /// @notice A schedule's stablecoin principal changed after a deposit, withdrawal, or purchase debit.
    event DcaManager__TokenBalanceUpdated(address indexed token, uint64 indexed scheduleId, uint256 amount);
    /// @notice The caller replaced a schedule's periodic purchase amount.
    event DcaManager__PurchaseAmountUpdated(
        address indexed user, uint64 indexed scheduleId, uint256 previousAmount, uint256 newAmount
    );
    /// @notice The caller replaced a schedule's purchase period.
    event DcaManager__PurchasePeriodUpdated(
        address indexed user, uint64 indexed scheduleId, uint256 previousPeriod, uint256 newPeriod
    );
    /// @notice A new schedule was created and funded. `scheduleId` is the creation nonce (starts at 1).
    event DcaManager__DcaScheduleCreated(
        address indexed user,
        address indexed token,
        uint64 indexed scheduleId,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 routeIndex
    );
    /// @notice The caller paused or resumed purchases on one of their schedules.
    /// @dev Filterable by user and scheduleId only, matching PurchaseAmountUpdated / PurchasePeriodUpdated.
    ///      Token is recovered by joining on scheduleId; it is not a third topic.
    event DcaManager__SchedulePauseSet(address indexed user, uint64 indexed scheduleId, bool paused);
    /// @notice A schedule was deleted. `refundedAmount` is what left the handler, which may be less than
    ///         the schedule's `tokenBalance` if the lending protocol haircut the redemption.
    event DcaManager__DcaScheduleDeleted(
        address indexed user, address indexed token, uint64 indexed scheduleId, uint256 refundedAmount
    );
    /// @notice Owner changed the per-token schedule cap.
    event DcaManager__MaxSchedulesPerTokenModified(uint256 newMaxSchedulesPerToken);
    /// @notice Owner changed the protocol minimum purchase period (never below one UTC day).
    event DcaManager__MinPurchasePeriodModified(uint256 newMinPurchasePeriod);
    /// @notice A purchase updated a schedule's `lastPurchaseTimestamp` cadence anchor.
    /// @dev The next due boundary is the UTC day of `lastPurchaseTimestamp + purchasePeriod`, not
    ///      this emitted value itself.
    event DcaManager__LastPurchaseTimestampUpdated(address indexed token, uint64 indexed scheduleId, uint256 lastPurchaseTimestamp);
    /// @notice Owner changed the default minimum purchase amount used when a token has no override.
    event DcaManager__DefaultMinPurchaseAmountModified(uint256 newDefaultMinPurchaseAmount);
    /// @notice Owner set a per-token minimum purchase amount. Zero clears the override.
    event DcaManager__TokenMinPurchaseAmountSet(address indexed token, uint256 minPurchaseAmount);

    //////////////////////
    // Errors ////////////
    //////////////////////
    /// @notice No handler is assigned for this token and route.
    error DcaManager__TokenNotAccepted(address token, uint256 routeIndex);
    /// @notice Deposit amount must be greater than zero.
    error DcaManager__DepositAmountMustBeGreaterThanZero();
    /// @notice Withdrawal amount must be greater than zero (after resolving `type(uint256).max`).
    error DcaManager__WithdrawalAmountMustBeGreaterThanZero();
    /// @notice Requested withdrawal exceeds this schedule's `tokenBalance`.
    error DcaManager__WithdrawalAmountExceedsBalance(address token, uint256 amount, uint256 balance);
    /// @notice Purchase amount is below the token's (or default) minimum.
    error DcaManager__PurchaseAmountMustBeGreaterThanMinimum(address token, uint256 minPurchaseAmount);
    /// @notice Purchase period is below the protocol minimum.
    error DcaManager__PurchasePeriodMustBeGreaterThanMinimum();
    /// @notice Protocol minimum purchase period cannot be set below one UTC day.
    error DcaManager__MinPurchasePeriodMustBeAtLeastOneDay();
    /// @notice Purchase amount exceeds the schedule's current `tokenBalance`.
    error DcaManager__PurchaseAmountExceedsBalance(address token, uint256 purchaseAmount, uint256 tokenBalance);
    /// @notice The UTC day of `lastPurchaseTimestamp + purchasePeriod` has not started.
    error DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed(uint256 timeRemaining);
    /// @notice `scheduleIndex` is out of range for this user and token.
    error DcaManager__InexistentScheduleIndex();
    /// @notice `scheduleId` does not match the schedule at `scheduleIndex`.
    error DcaManager__ScheduleIdAndIndexMismatch();
    /// @notice The schedule's remaining principal cannot cover one purchase.
    error DcaManager__ScheduleBalanceNotEnoughForPurchase(uint256 scheduleIndex, uint64 scheduleId, address token, uint256 remainingBalance);
    /// @notice Parallel arrays (batch purchase or withdraw-all pairs) have different lengths.
    error DcaManager__ArraysLengthMismatch();
    /// @notice `batchBuyRbtc` was called with empty buyer/index/id/amount arrays.
    error DcaManager__EmptyBatchPurchaseArrays();
    /// @notice A withdraw-all call was given empty token/route arrays.
    error DcaManager__EmptyWithdrawalArrays();
    /// @notice The user already has the maximum number of schedules for this token.
    error DcaManager__MaxSchedulesPerTokenReached(address token);
    /// @notice Interest was requested on a route that is not registered as lending.
    error DcaManager__TokenDoesNotYieldInterest(address token);
    /// @notice Caller is not on the OperationsAdmin swapper allowlist.
    error DcaManager__UnauthorizedSwapper(address sender);
    /// @notice A batch row's `purchaseAmounts[i]` does not match the schedule's stored amount.
    error DcaManager__PurchaseAmountMismatch(address user, address token, uint64 scheduleId, uint256 scheduleIndex, uint256 actualPurchaseAmount, uint256 expectedPurchaseAmount);
    /// @notice A batch row's schedule is on a different route than this batch's `routeIndex`.
    error DcaManager__RouteIndexMismatch(address user, address token, uint64 scheduleId, uint256 scheduleIndex, uint256 actualRouteIndex, uint256 expectedRouteIndex);
    /// @notice Constructor `operationsAdmin` has no code.
    error DcaManager__OperationsAdminIsNotAContract(address operationsAdmin);
    /// @notice Governance paused new deposits for this token and route.
    error DcaManager__DepositsPaused(address token, uint256 routeIndex);
    /// @notice A named schedule is purchase-paused, so the whole `batchBuyRbtc` reverts.
    error DcaManager__SchedulePaused(address user, address token, uint64 scheduleId, uint256 scheduleIndex);

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit more stablecoin into an existing schedule.
     * @param token The stablecoin of the schedule.
     * @param scheduleIndex Index of the schedule in the caller's array for `token`.
     * @param scheduleId Id of that schedule, checked against storage.
     * @param depositAmount Amount requested from the caller. The handler reverts unless it receives
     *        exactly this amount, so the schedule is credited with the full request.
     * @dev Reverts `DcaManager__DepositsPaused` before any transfer if governance paused deposits
     *      on this schedule's route. Purchases, edits, withdrawals, and deletion ignore that pause.
     */
    function depositToken(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 depositAmount) external;

    /**
     * @notice Withdraw stablecoin principal from one schedule.
     * @param token The stablecoin of the schedule.
     * @param scheduleIndex Index of the schedule in the caller's array for `token`.
     * @param scheduleId Id of that schedule, checked against storage.
     * @param withdrawalAmount Amount to withdraw. Pass `type(uint256).max` for this schedule's
     *        whole `tokenBalance`.
     * @dev Principal is reduced by the requested amount, not by what the lending protocol paid.
     *      A redemption fee consumes principal rather than leaving it behind.
     */
    function withdrawToken(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 withdrawalAmount) external;

    /**
     * @notice Create a new schedule and fund it in the same call.
     * @param token The stablecoin to deposit.
     * @param depositAmount Amount requested from the caller. The handler reverts unless it receives
     *        exactly this amount, so the schedule is credited with the full request.
     * @param purchaseAmount Stablecoin to spend periodically on rBTC. Validated against the credited
     *        balance, which equals `depositAmount` once the handler pull succeeds.
     * @param purchasePeriod Seconds between purchases. Must be at least the protocol minimum (one UTC day
     *        or higher if the owner raised it).
     * @param routeIndex OperationsAdmin route that will hold the funds (idle or lending).
     * @dev Ids are the creation nonce, starting at 1. Reverts `DcaManager__DepositsPaused` before any
     *      transfer if governance paused deposits on `token` × `routeIndex`.
     */
    function createDcaSchedule(
        address token,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 routeIndex
    ) external;

    /**
     * @notice Delete a schedule and return its remaining principal to the caller.
     * @param token The stablecoin of the schedule.
     * @param scheduleIndex Index of the schedule in the caller's array for `token`.
     * @param scheduleId Id of that schedule, checked against storage.
     * @dev Swap-pops the array. The deleted event reports what left the handler, which may be less
     *      than `tokenBalance` if the lending protocol haircut the redemption. Accumulated rBTC and
     *      lending interest are not claimed here — withdraw those first.
     */
    function deleteDcaSchedule(address token, uint256 scheduleIndex, uint64 scheduleId) external;

    /**
     * @notice Replace the periodic purchase amount on an existing schedule.
     * @param token The stablecoin of the schedule.
     * @param scheduleIndex Index of the schedule in the caller's array for `token`.
     * @param scheduleId Id of that schedule, checked against storage.
     * @param newPurchaseAmount New amount to spend periodically on rBTC. Cannot exceed the schedule's
     *        current `tokenBalance` or fall below the token minimum.
     * @dev Emits `DcaManager__PurchaseAmountUpdated` with the replaced amount and the new one.
     */
    function updatePurchaseAmount(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 newPurchaseAmount)
        external;

    /**
     * @notice Replace the purchase period on an existing schedule.
     * @param token The stablecoin of the schedule.
     * @param scheduleIndex Index of the schedule in the caller's array for `token`.
     * @param scheduleId Id of that schedule, checked against storage.
     * @param newPurchasePeriod New seconds between purchases. Cannot be shorter than the protocol minimum.
     * @dev Emits `DcaManager__PurchasePeriodUpdated` with the replaced period and the new one.
     */
    function updatePurchasePeriod(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 newPurchasePeriod)
        external;

    /**
     * @notice Pause or resume rBTC purchases for one of the caller's schedules.
     * @param token The stablecoin of the schedule.
     * @param scheduleIndex Index of the schedule in the caller's array for `token`.
     * @param scheduleId Id of that schedule, checked against storage.
     * @param paused True to stop purchases, false to resume them.
     * @dev A paused schedule keeps its funds on its route and stays open to deposits, amount and
     *      period edits, withdrawals, interest and rBTC claims, and deletion. Setting the state it
     *      already holds is a no-op and emits nothing, so every emitted event is a real transition.
     *      A paused row in `batchBuyRbtc` reverts the whole batch.
     */
    function setSchedulePaused(address token, uint256 scheduleIndex, uint64 scheduleId, bool paused) external;

    /**
     * @notice Buy rBTC for every named due schedule that shares one token and one route.
     * @param buyers Users to buy for. The same address may appear more than once when several of
     *        that user's schedules are due.
     * @param token Stablecoin every row in this batch spends.
     * @param scheduleIndexes Schedule array index for each row, paired with `buyers[i]`.
     * @param scheduleIds Schedule id for each row, paired with `buyers[i]`.
     * @param purchaseAmounts Amount each row must spend; must equal that schedule's stored amount.
     * @param routeIndex Route every named schedule must share.
     * @dev Only a swapper on the OperationsAdmin allowlist (EOA or `SwapperBatcher`) may call.
     *      Reverts `DcaManager__SchedulePaused` if any named schedule is paused, which fails the
     *      whole batch: the swapper must filter paused schedules out before composing the call.
     *      Mixing tokens or routes in one call is rejected per row (`RouteIndexMismatch`); the
     *      token is taken from the argument, not from storage, so the swapper must not mix tokens.
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
     * @notice Withdraw lending interest the caller has accrued on each named token×route pair.
     * @param tokens The token of each pair.
     * @param routeIndexes The route of each pair. Idle routes are skipped.
     * @dev The two arrays are positional pairs: `tokens[i]` is only withdrawn from `routeIndexes[i]`.
     *      The arrays must be the same length and non-empty; an unassigned or non-lending pair is skipped.
     */
    function withdrawAllAccumulatedInterest(address[] calldata tokens, uint256[] calldata routeIndexes) external;

    /**
     * @notice Withdraw principal from one schedule and all lending interest that token has earned on that route.
     * @param token The stablecoin of the schedule.
     * @param scheduleIndex Index of the schedule in the caller's array for `token`.
     * @param scheduleId Id of that schedule, checked against storage.
     * @param withdrawalAmount Principal to withdraw, or `type(uint256).max` for this schedule's whole
     *        `tokenBalance`.
     * @dev Interest is withdrawn from the schedule's stored lending route. An idle schedule reverts
     *      because that route does not yield.
     */
    function withdrawTokenAndInterest(
        address token,
        uint256 scheduleIndex,
        uint64 scheduleId,
        uint256 withdrawalAmount
    ) external;

    /**
     * @notice Withdraw all rBTC the caller has accumulated on one token×route handler.
     * @param token The stablecoin whose handler holds the rBTC.
     * @param routeIndex The route whose handler holds the rBTC.
     */
    function withdrawRbtcFromTokenHandler(address token, uint256 routeIndex) external;

    /**
     * @notice Withdraw all rBTC the caller has accumulated on each named token×route pair.
     * @param tokens The token of each pair.
     * @param routeIndexes The route of each pair.
     * @dev The two arrays are positional pairs: `tokens[i]` is only withdrawn from `routeIndexes[i]`.
     *      The arrays must be the same length and non-empty; an unassigned or zero-balance pair is skipped.
     */
    function withdrawAllAccumulatedRbtc(address[] calldata tokens, uint256[] calldata routeIndexes) external;

    /**
     * @notice Set the protocol minimum purchase period. Cannot be below one UTC day.
     * @param minPurchasePeriod New minimum in seconds.
     */
    function modifyMinPurchasePeriod(uint256 minPurchasePeriod) external;

    /**
     * @notice Set the maximum number of schedules a user may hold per token.
     * @param maxSchedulesPerToken New cap.
     */
    function modifyMaxSchedulesPerToken(uint256 maxSchedulesPerToken) external;

    /**
     * @notice Set the default minimum purchase amount used when a token has no override.
     * @param defaultMinPurchaseAmount New default, in the stablecoin's native units.
     */
    function modifyDefaultMinPurchaseAmount(uint256 defaultMinPurchaseAmount) external;

    /**
     * @notice Set or clear a per-token minimum purchase amount.
     * @param token The stablecoin.
     * @param minPurchaseAmount New minimum in that token's native units. Zero clears the override
     *        so the default applies.
     */
    function setTokenMinPurchaseAmount(address token, uint256 minPurchaseAmount) external;

    //////////////////////
    // Getter functions //
    //////////////////////

    /**
     * @notice One DCA schedule for a user and token.
     * @param user Schedule owner.
     * @param token Stablecoin of the schedule.
     * @param scheduleIndex Index in that user's array for `token`.
     * @return The schedule at that index.
     */
    function getDcaSchedule(address user, address token, uint256 scheduleIndex) external view returns (DcaSchedule memory);

    /**
     * @notice Every DCA schedule a user holds for a token.
     * @param user Schedule owner.
     * @param token Stablecoin of the schedules.
     * @return The user's schedules for `token`.
     */
    function getDcaSchedules(address user, address token) external view returns (DcaSchedule[] memory);

    /**
     * @notice The OperationsAdmin this manager is permanently pinned to.
     * @return The constructor-supplied OperationsAdmin address.
     */
    function getOperationsAdminAddress() external view returns (address);

    /**
     * @notice Lending interest a user has accrued on one token and route, above locked principal.
     * @param user Account to query.
     * @param token Stablecoin of the route.
     * @param routeIndex Route to query. Reverts if the route is not lending.
     * @return Accrued interest in stablecoin units.
     */
    function getInterestAccrued(address user, address token, uint256 routeIndex)
        external
        view
        returns (uint256);

    /**
     * @notice rBTC a user has accumulated on the handler for a token and route.
     * @param user Account to query.
     * @param token Stablecoin of the handler.
     * @param routeIndex Route of the handler.
     * @return Accumulated rBTC balance in wei.
     */
    function getAccumulatedRbtcBalance(address user, address token, uint256 routeIndex)
        external
        view
        returns (uint256);

    /**
     * @notice Protocol minimum purchase period in seconds.
     * @return The current minimum, never below one UTC day.
     */
    function getMinPurchasePeriod() external view returns (uint256);

    /**
     * @notice Maximum number of schedules a user may hold per token.
     * @return The current cap.
     */
    function getMaxSchedulesPerToken() external view returns (uint256);

    /**
     * @notice Lifetime count of schedules created across all users and tokens.
     * @dev Equals the last `scheduleId` assigned, since ids are that counter. Never decreases;
     *      deletions do not decrement it.
     * @return The creation nonce (last assigned id, or 0 before the first create).
     */
    function getSchedulesCreatedCount() external view returns (uint256);

    /**
     * @notice Default minimum purchase amount for tokens with no override.
     * @return The default, in the stablecoin's native units.
     */
    function getDefaultMinPurchaseAmount() external view returns (uint256);

    /**
     * @notice Minimum purchase amount that applies to `token`.
     * @param token The stablecoin.
     * @return minPurchaseAmount The effective minimum (custom if set, otherwise the default).
     * @return customMinAmountSet True when a per-token override is stored (nonzero).
     */
    function getTokenMinPurchaseAmount(address token) external view returns (uint256 minPurchaseAmount, bool customMinAmountSet);
}
