// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IOperationsAdmin} from "./IOperationsAdmin.sol";

/**
 * @title IDcaManager
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice User and swapper entry point: create and manage dollar-cost-averaging schedules.
 * @dev Users talk only to this contract. An allowlisted swapper triggers purchases. Handlers custody
 *      both the deposited stablecoin and the rBTC bought with it; this contract holds neither and keeps
 *      only the schedule ledger. User mutators resolve ownership from the `(token, scheduleId)` key.
 *      A schedule's cadence is a grid of UTC midnights: purchases become eligible at 00:00 on the due
 *      day and skip, rather than recover, every slot missed before them.
 */
interface IDcaManager {
    /*//////////////////////////////////////////////////////////////
                           TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice One user's recurring purchase of rBTC with one stablecoin on one OperationsAdmin route.
    /// @dev The stablecoin and id are the storage key, so neither is repeated in the two-slot value:
    ///
    ///        slot 0  tokenBalance, cadenceAnchor, paused, purchasePeriod, routeIndex
    ///        slot 1  user, purchaseAmount
    ///
    ///      The purchase path writes only slot 0. A live schedule has a non-zero `user`, its existence
    ///      sentinel. `getDcaSchedules` returns ids alongside these values.
    struct DcaSchedule {
        uint128 tokenBalance; // Stablecoin amount deposited by the user
        uint48 cadenceAnchor; // UTC midnight of the newest consumed cadence slot; zero before the first purchase
        bool paused; // Set by the schedule's user: purchases are refused while true, every other path stays open
        uint32 purchasePeriod; // Time between cadence slots in seconds; always whole UTC days
        uint32 routeIndex; // OperationsAdmin route that holds this schedule's funds (idle or lending)
        address user; // The account that owns this schedule and receives what it buys
        uint96 purchaseAmount; // Stablecoin amount to spend periodically on rBTC
    }

    /// @notice One handler's purchase batch.
    /// @dev Every id shares `token` and `routeIndex`, which resolve to one handler. Buyer and amount come
    ///      from storage, so caller data cannot redirect or resize a purchase. `minRbtcOut` is a batch-wide
    ///      minimum in rBTC wei, checked against the handler's measured receipt. Uniswap also enforces its
    ///      oracle floor; MoC redeems at its protocol price and has no pool-slippage floor.
    struct Batch {
        uint64[] scheduleIds;
        address token;
        uint256 routeIndex;
        uint256 minRbtcOut;
    }

    /**
     * @notice The protocol scalars every create reads, plus the id counter it writes.
     * @dev One slot (14 of 32 bytes): `createDcaSchedule` loads all three together and stores the bumped
     *      nonce back into the same word. Owner setters take `uint256` and SafeCast at the write. This is
     *      an internal storage shape rather than an ABI type — the scalars are read through their own
     *      getters. `scheduleNonce` is a strictly increasing counter and is the schedule id itself: ids
     *      must not be derived from array state, because swap-pop on delete can restore a previous array
     *      shape within a block and let two live schedules share an id. Per-token purchase mins live in
     *      their own mapping; a protocol-wide default in raw units is unsafe across stablecoin decimals.
     */
    struct ProtocolSettings {
        uint32 minPurchasePeriod; // Minimum time between purchases
        uint16 maxSchedulesPerToken; // Maximum number of schedules per stablecoin
        uint64 scheduleNonce; // Last assigned schedule id; 0 before the first schedule is created
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
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
    /// @notice An authorized swapper opened a five-block protected purchase window.
    /// @dev `userMutationsAllowedFromBlock` is not indexed: it is a scalar rather than an address or
    ///      schedule id. Guarded user mutations are refused before this block and available from it.
    event DcaManager__ProtectedPurchaseWindowActivated(
        address indexed swapper, uint256 userMutationsAllowedFromBlock
    );
    /// @notice Accrued lending interest was credited to one schedule's spendable balance.
    /// @dev No tokens move: the position stays in the lending protocol and only this schedule's
    ///      `tokenBalance` claim over it grows. `interest` is what was credited, which may be less
    ///      than everything the caller had accrued on that route.
    event DcaManager__ScheduleToppedUpFromInterest(
        address indexed user, address indexed token, uint64 indexed scheduleId, uint256 interest
    );
    /// @notice A schedule was deleted. `refundedAmount` is what left the handler, which may be less than
    ///         the schedule's `tokenBalance` if the handler paid out less than it was asked for.
    event DcaManager__DcaScheduleDeleted(
        address indexed user, address indexed token, uint64 indexed scheduleId, uint256 refundedAmount
    );
    /// @notice Owner changed the per-token schedule cap.
    event DcaManager__MaxSchedulesPerTokenModified(uint256 newMaxSchedulesPerToken);
    /// @notice Owner changed the protocol minimum purchase period (whole UTC days, never below one).
    event DcaManager__MinPurchasePeriodModified(uint256 newMinPurchasePeriod);
    /// @notice Owner set a per-token minimum purchase amount. Zero is not allowed.
    event DcaManager__TokenMinPurchaseAmountSet(address indexed token, uint256 minPurchaseAmount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice No handler is assigned for this token and route.
    error DcaManager__TokenNotAccepted(address token, uint256 routeIndex);
    /// @notice Deposit amount must be greater than zero.
    error DcaManager__DepositAmountMustBeGreaterThanZero();
    /// @notice Withdrawal amount must be greater than zero (after resolving `type(uint256).max`).
    error DcaManager__WithdrawalAmountMustBeGreaterThanZero();
    /// @notice Requested withdrawal exceeds this schedule's `tokenBalance`.
    error DcaManager__WithdrawalAmountExceedsBalance(address token, uint256 amount, uint256 balance);
    /// @notice Purchase amount is below the token's configured minimum.
    error DcaManager__PurchaseAmountMustBeGreaterThanMinimum(address token, uint256 minPurchaseAmount);
    /// @notice No minimum purchase amount has been set for this token.
    error DcaManager__TokenMinPurchaseAmountNotSet(address token);
    /// @notice Per-token minimum purchase amount must be greater than zero.
    error DcaManager__TokenMinPurchaseAmountMustBeGreaterThanZero(address token);
    /// @notice Purchase period is below the protocol minimum.
    error DcaManager__PurchasePeriodMustBeGreaterThanMinimum();
    /// @notice Protocol minimum purchase period cannot be set below one UTC day.
    error DcaManager__MinPurchasePeriodMustBeAtLeastOneDay();
    /// @notice Purchase period must be a whole number of UTC days.
    error DcaManager__PurchasePeriodMustBeWholeDays();
    /// @notice Purchase amount exceeds the schedule's current `tokenBalance`.
    error DcaManager__PurchaseAmountExceedsBalance(address token, uint256 purchaseAmount, uint256 tokenBalance);
    /// @notice The next cadence boundary has not been reached.
    /// @dev Names the row like every other purchase-path revert, so a batch that a mid-flight
    ///      `updatePurchasePeriod` unwound tells the caller which schedule to drop before retrying.
    error DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed(address token, uint64 scheduleId, uint256 timeRemaining);
    /// @notice No live schedule of this stablecoin holds this id. The pair is the storage key, so a
    ///         right id named with the wrong stablecoin reads the same as one that never existed.
    error DcaManager__InexistentSchedule(address token, uint64 scheduleId);
    /// @notice The schedule exists but belongs to somebody else. `owner` is who it belongs to.
    error DcaManager__NotScheduleOwner(address token, uint64 scheduleId, address owner);
    /// @notice `deleteDcaSchedule`'s index doesn't name this id in the caller's enumeration list.
    /// @dev The index is wrong or stale, not a sign of a missing schedule — `deleteDcaSchedule` already
    ///      confirmed the id exists and belongs to the caller. Re-read `getDcaSchedules` and retry.
    error DcaManager__ScheduleIdIndexMismatch(address token, uint64 scheduleId, uint256 scheduleIdIndex);
    /// @notice The schedule's remaining principal cannot cover one purchase.
    error DcaManager__ScheduleBalanceNotEnoughForPurchase(address token, uint64 scheduleId, uint256 remainingBalance);
    /// @notice Parallel arrays (batch purchase or withdraw-all pairs) have different lengths.
    error DcaManager__ArraysLengthMismatch();
    /// @notice `batchBuyRbtc` was called with empty id/buyer arrays.
    error DcaManager__EmptyBatchPurchaseArrays();
    /// @notice `batchBuyRbtcAcrossHandlers` was called without any handler batches.
    error DcaManager__EmptyHandlerBatches();
    /// @notice A withdraw-all call was given empty token/route arrays.
    error DcaManager__EmptyWithdrawalArrays();
    /// @notice The user already has the maximum number of schedules for this token.
    error DcaManager__MaxSchedulesPerTokenReached(address token);
    /// @notice Interest was requested on a route that is not registered as lending.
    error DcaManager__TokenDoesNotYieldInterest(address token);
    /// @notice Caller is not on the OperationsAdmin swapper allowlist.
    error DcaManager__UnauthorizedSwapper(address sender);
    /// @notice A new protected purchase window cannot start until the current one ends.
    error DcaManager__ProtectedPurchaseWindowStillActive(uint256 userMutationsAllowedFromBlock);
    /// @notice This user mutation is unavailable until the protected purchase window ends.
    error DcaManager__UserMutationsLocked(uint256 userMutationsAllowedFromBlock);
    /// @notice A batch row's schedule is on a different route than this batch's `routeIndex`.
    error DcaManager__RouteIndexMismatch(address token, uint64 scheduleId, uint256 actualRouteIndex, uint256 expectedRouteIndex);
    /// @notice Constructor `operationsAdmin` has no code.
    error DcaManager__OperationsAdminIsNotAContract(address operationsAdmin);
    /// @notice Governance paused new deposits for this token and route.
    error DcaManager__DepositsPaused(address token, uint256 routeIndex);
    /// @notice A named schedule is purchase-paused. That reverts `batchBuyRbtc`, and if the row is
    ///         in `batchBuyRbtcAcrossHandlers`, every handler in the bundle.
    error DcaManager__SchedulePaused(address token, uint64 scheduleId);
    /// @notice The caller has accrued no interest on this schedule's route, so there is nothing to credit.
    error DcaManager__NoInterestToTopUpWith(address token, uint256 routeIndex);
    /// @notice The requested top-up is more interest than the caller has accrued on this route.
    error DcaManager__TopUpExceedsAccruedInterest(address token, uint256 routeIndex, uint256 amount, uint256 accruedInterest);
    /// @notice The requested top-up would not raise the schedule's balance past another whole purchase.
    error DcaManager__TopUpDoesNotFundAnotherPurchase(address token, uint64 scheduleId, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // User operations: schedule lifecycle, funding, withdrawals, and rBTC claims.

    /**
     * @notice Create a new schedule and fund it in the same call.
     * @param token The stablecoin to deposit.
     * @param depositAmount Amount requested from the caller. The handler reverts unless it receives
     *        exactly this amount, so the schedule is credited with the full request.
     * @param purchaseAmount Stablecoin to spend periodically on rBTC. Validated against the credited
     *        balance, which equals `depositAmount` once the handler pull succeeds.
     * @param purchasePeriod Seconds between purchases. Must be a whole number of UTC days and at least
     *        the protocol minimum.
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
     * @notice Deposit more stablecoin into an existing schedule.
     * @param token The stablecoin the schedule spends, which is half its storage key.
     * @param scheduleId The schedule to fund. Must belong to the caller.
     * @param depositAmount Amount requested from the caller. The handler reverts unless it receives
     *        exactly this amount, so the schedule is credited with the full request.
     * @dev The route is read from the schedule. A deposit pause is checked before token transfer and
     *      does not pause purchases, edits, withdrawals, or deletion.
     */
    function depositToken(address token, uint64 scheduleId, uint256 depositAmount) external;

    /**
     * @notice Replace the periodic purchase amount on an existing schedule.
     * @param token The stablecoin the schedule spends, which is half its storage key.
     * @param scheduleId The schedule to edit. Must belong to the caller.
     * @param newPurchaseAmount New amount to spend periodically on rBTC. Cannot exceed the schedule's
     *        current `tokenBalance` or fall below the token minimum, and is stored as `uint96`.
     * @dev Emits `DcaManager__PurchaseAmountUpdated` only after validation.
     */
    function updatePurchaseAmount(address token, uint64 scheduleId, uint256 newPurchaseAmount) external;

    /**
     * @notice Replace the purchase period on an existing schedule.
     * @param token The stablecoin the schedule spends, which is half its storage key.
     * @param scheduleId The schedule to edit. Must belong to the caller.
     * @param newPurchasePeriod New seconds between purchases. Must be a whole number of UTC days and at
     *        least the protocol minimum.
     * @dev Emits `DcaManager__PurchasePeriodUpdated` only after validation.
     */
    function updatePurchasePeriod(address token, uint64 scheduleId, uint256 newPurchasePeriod) external;

    /**
     * @notice Pause or resume rBTC purchases for one of the caller's schedules.
     * @param token The stablecoin the schedule spends, which is half its storage key.
     * @param scheduleId The schedule to pause or resume. Must belong to the caller.
     * @param paused True to stop purchases, false to resume them.
     * @dev A paused schedule keeps its funds on its route and stays open to deposits, amount and
     *      period edits, withdrawals, interest and rBTC claims, and deletion. Setting the state it
     *      already holds is a no-op and emits nothing, so every emitted event is a real transition.
     *      A paused row in `batchBuyRbtc` reverts that handler's batch. The same row in
     *      `batchBuyRbtcAcrossHandlers` reverts every handler in the bundle.
     */
    function setSchedulePaused(address token, uint64 scheduleId, bool paused) external;

    /**
     * @notice Delete a schedule and return its remaining principal to the caller.
     * @param token The stablecoin the schedule spends, which is half its storage key.
     * @param scheduleId The schedule to delete. Must belong to the caller.
     * @param scheduleIdIndex The id's current index in the caller's list returned by getDcaSchedules;
     *        a mismatch reverts.
     * @dev Clears the schedule and swap-pops its id out of the owner's list for that stablecoin, so the
     *      id is retired rather than reused: ids come from a strictly increasing counter. The deleted
     *      event reports what left the handler, which may be less than `tokenBalance` if the handler
     *      paid out less than it was asked for. Accumulated rBTC and lending interest are not claimed
     *      here — withdraw those first.
     */
    function deleteDcaSchedule(address token, uint64 scheduleId, uint256 scheduleIdIndex) external;

    /**
     * @notice Withdraw stablecoin principal from one schedule.
     * @param token The stablecoin the schedule spends, which is half its storage key.
     * @param scheduleId The schedule to withdraw from. Must belong to the caller.
     * @param withdrawalAmount Amount to withdraw. Pass `type(uint256).max` for this schedule's
     *        whole `tokenBalance`.
     * @dev Principal is reduced by the requested amount, not by what the handler paid out. On a lending
     *      route a successful handler call guarantees the external receipt-share claim for that request
     *      was fully consumed, so a cash shortfall is a fee or realized loss with nothing left to
     *      re-credit: restoring it would invent principal this route can no longer redeem. An idle route
     *      pays short only if the handler's own ledger disagrees with this one, which is a condition to
     *      surface rather than to paper over.
     */
    function withdrawToken(address token, uint64 scheduleId, uint256 withdrawalAmount) external;

    /**
     * @notice Withdraw principal from one schedule and all lending interest that token has earned on that route.
     * @param token The stablecoin the schedule spends, which is half its storage key.
     * @param scheduleId The schedule to withdraw from. Must belong to the caller.
     * @param withdrawalAmount Principal to withdraw, or `type(uint256).max` for this schedule's whole
     *        `tokenBalance`.
     * @dev Interest is withdrawn from the schedule's stored lending route. An idle schedule reverts.
     */
    function withdrawTokenAndInterest(address token, uint64 scheduleId, uint256 withdrawalAmount) external;

    /**
     * @notice Credit lending interest the caller has accrued to one schedule's spendable balance.
     * @param token The stablecoin the schedule spends, which is half its storage key.
     * @param scheduleId The schedule to credit. Must belong to the caller.
     * @param amount Interest to credit, at most the spendable accrued-interest ceiling computed at
     *        the market's current rate. `getInterestAccrued` can quote less on a lazily-accruing market.
     * @dev Interest belongs to a user-token-route position, so the caller chooses which schedule on that
     *      route receives it. No tokens move; this raises the schedule's claim over funds already lent and
     *      remains available while deposits are paused. The amount must be accrued and fund at least one
     *      additional purchase, preventing dust top-ups.
     */
    function topUpFromInterest(address token, uint64 scheduleId, uint256 amount) external;

    /**
     * @notice Withdraw lending interest the caller has accrued on each named token×route pair.
     * @param tokens The token of each pair.
     * @param routeIndexes The route of each pair. Idle routes are skipped.
     * @dev The two arrays are positional pairs: `tokens[i]` is only withdrawn from `routeIndexes[i]`.
     *      The arrays must be the same length and non-empty; an unassigned or non-lending pair is skipped.
     */
    function withdrawAllAccumulatedInterest(address[] calldata tokens, uint256[] calldata routeIndexes) external;

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

    // Swapper-only operations: protected-window activation and batch execution.

    /**
     * @notice Open a five-block window for preparing and submitting purchases against fixed user state.
     * @dev Only an allowlisted swapper may call. Activation in block `N` blocks amount/period/pause edits,
     *      deletion, principal withdrawal, principal-plus-interest withdrawal, and bulk interest withdrawal
     *      through `N + 4`; all resume at `N + 5`. Other calls remain available. A live window cannot be
     *      extended; after expiry another may begin. The bot waits for activation, refreshes or simulates,
     *      then submits against the locked state.
     */
    function activateProtectedPurchaseWindow() external;

    /**
     * @notice Buy rBTC for every named due schedule on one handler.
     * @param batch One handler's purchase batch. Every row must share `token` and `routeIndex`.
     * @dev Only a swapper on the OperationsAdmin allowlist may call.
     *      Eligibility starts at 00:00 UTC on the due day, leaving that day for retries. A buy consumes
     *      its due slot and skips earlier missed slots, preventing catch-up or a second buy that UTC day.
     *      An established weekly Monday schedule bought Tuesday remains due the following Monday.
     *      Any paused row fails the whole batch or multi-handler bundle. The token is part of each
     *      schedule key and the route is checked, so rows cannot cross handlers. A measured receipt below
     *      `minRbtcOut` reverts the purchase and all schedule debits.
     */
    function batchBuyRbtc(Batch calldata batch) external;

    /**
     * @notice Buy rBTC through several handlers atomically in one transaction.
     * @param batches Each element is one handler's purchase batch (`token` + `routeIndex`).
     * @dev Authenticates the caller once, then purchases each handler's batch in order through the
     *      same one-handler helper. A failure in any batch — including a paused row or a batch that
     *      bought less than its own `minRbtcOut` — reverts every handler, so a later batch's minimum
     *      undoes an earlier handler's purchase. `batchBuyRbtc` remains available for one-handler
     *      retries (same `Batch` type).
     */
    function batchBuyRbtcAcrossHandlers(Batch[] calldata batches) external;

    // Owner-only operations: protocol configuration.

    /**
     * @notice Set the protocol minimum purchase period.
     * @param minPurchasePeriod New minimum in seconds; at least one whole UTC day.
     */
    function modifyMinPurchasePeriod(uint256 minPurchasePeriod) external;

    /**
     * @notice Set the maximum number of schedules a user may hold per token.
     * @param maxSchedulesPerToken New cap.
     */
    function modifyMaxSchedulesPerToken(uint256 maxSchedulesPerToken) external;

    /**
     * @notice Set the minimum purchase amount for a stablecoin.
     * @param token The stablecoin.
     * @param minPurchaseAmount New minimum in that token's native units. Must be greater than zero;
     *        there is no protocol-wide default.
     */
    function setTokenMinPurchaseAmount(address token, uint256 minPurchaseAmount) external;

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The OperationsAdmin this manager is permanently pinned to.
     * @return The constructor-supplied OperationsAdmin.
     */
    function i_operationsAdmin() external view returns (IOperationsAdmin);

    /**
     * @notice One DCA schedule, by the stablecoin it spends and its id.
     * @param token The stablecoin the schedule spends.
     * @param scheduleId The schedule to read. Any account may read any schedule.
     * @return The schedule that pair addresses, including the account that owns it.
     * @dev Reverts `DcaManager__InexistentSchedule` unless that pair addresses a live schedule.
     */
    function getDcaSchedule(address token, uint64 scheduleId) external view returns (DcaSchedule memory);

    /**
     * @notice Every DCA schedule a user holds for a token, with the ids that address them.
     * @param user Schedule owner.
     * @param token Stablecoin of the schedules.
     * @return scheduleIds The id of each schedule, in the same positions as `schedules`.
     * @return schedules The user's schedules for `token`.
     * @dev The two arrays are positionally aligned: `scheduleIds[i]` addresses `schedules[i]`, together
     *      with `token`. They are returned side by side rather than as one self-describing struct
     *      because an id that lives in the storage key is not repeated in the value it addresses.
     *      The order is the owner's list order, which delete does not preserve: removing a schedule
     *      moves the last one into the freed position. Address a schedule by its id, never by where it
     *      appeared in a previous read of this list.
     */
    function getDcaSchedules(address user, address token)
        external
        view
        returns (uint64[] memory scheduleIds, DcaSchedule[] memory schedules);

    /**
     * @notice Lifetime count of schedules created across all users and tokens.
     * @dev Equals the last `scheduleId` assigned, since ids are that counter. Never decreases;
     *      deletions do not decrement it.
     * @return The creation nonce (last assigned id, or 0 before the first create).
     */
    function getSchedulesCreatedCount() external view returns (uint256);

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
     * @notice Lending interest a user has accrued on one token and route, above locked principal.
     * @param user Account to query.
     * @param token Stablecoin of the route.
     * @param routeIndex Route to query. Reverts if the route is not lending.
     * @return Accrued interest in stablecoin units.
     * @dev A quote, read at the market's rate as a plain read. On a market that accrues lazily this
     *      can trail the spendable ceiling, never exceed it. This guarantees the quote satisfies the
     *      upper bound; `topUpFromInterest` still requires it to cross the next purchase boundary.
     */
    function getInterestAccrued(address user, address token, uint256 routeIndex)
        external
        view
        returns (uint256);

    /**
     * @notice Block from which guarded user mutations are allowed after the latest protected window.
     * @return The latest activation block plus five, or zero before the first activation.
     * @dev Compare with `block.number`: mutations are locked while the current block is lower.
     */
    function getUserMutationsAllowedFromBlock() external view returns (uint256);

    /**
     * @notice Whether an authorized swapper could activate a protected purchase window now.
     * @return True when no window is currently active.
     */
    function canActivateProtectedPurchaseWindow() external view returns (bool);

    /**
     * @notice Protocol minimum purchase period in seconds.
     * @return The current minimum, always a whole number of UTC days and never below one.
     */
    function getMinPurchasePeriod() external view returns (uint256);

    /**
     * @notice Maximum number of schedules a user may hold per token.
     * @return The current cap.
     */
    function getMaxSchedulesPerToken() external view returns (uint256);

    /**
     * @notice Minimum purchase amount configured for `token`.
     * @param token The stablecoin.
     * @return The configured minimum in that token's native units, or zero when none has been set.
     */
    function getTokenMinPurchaseAmount(address token) external view returns (uint256);
}
