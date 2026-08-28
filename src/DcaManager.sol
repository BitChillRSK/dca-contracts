// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDcaManager} from "./interfaces/IDcaManager.sol";
import {BitChillOwnable} from "./BitChillOwnable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ITokenHandler} from "./interfaces/ITokenHandler.sol";
import {ITokenLending} from "./interfaces/ITokenLending.sol";
import {OperationsAdmin} from "./OperationsAdmin.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";

/**
 * @title DCA Manager
 * @author BitChill team: Ynyesto (GitHub: @ynyesto)
 * @notice Entry point for the DCA dApp. Create and manage DCA schedules. 
 */
contract DcaManager is IDcaManager, BitChillOwnable, ReentrancyGuard {
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev Constructor-pinned registry. There is no setter: swapping this address
    ///      would redirect every live schedule and bypass add-only route assignment.
    OperationsAdmin private immutable i_operationsAdmin;

    /**
     * @notice Each user may create different schedules with one or more stablecoins
     */
    mapping(address user => mapping(address tokenDeposited => DcaSchedule[] usersDcaSchedules)) private s_dcaSchedules;

    ProtocolSettings private s_protocolSettings;
    mapping(address token => uint256) private s_tokenMinPurchaseAmounts; // Custom minimum purchase amounts per token

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice validate the schedule index
     * @param user the user address to validate the schedule for
     * @param token the token address
     * @param scheduleIndex the schedule index
     */
    modifier validateScheduleIndex(address user, address token, uint256 scheduleIndex) {
        if (scheduleIndex >= s_dcaSchedules[user][token].length) {
            revert DcaManager__InexistentScheduleIndex();
        }
        _;
    }

    /**
     * @notice protocol minimum purchase period cannot be below one UTC day
     * @param minPurchasePeriod the minimum purchase period to validate
     */
    modifier validateMinPurchasePeriod(uint256 minPurchasePeriod) {
        if (minPurchasePeriod < 1 days) revert DcaManager__MinPurchasePeriodMustBeAtLeastOneDay();
        _;
    }

    /**
     * @notice only allow addresses on the OperationsAdmin swapper allowlist
     */
    modifier onlySwapper() {
        if (!i_operationsAdmin.isSwapper(msg.sender)) {
            revert DcaManager__UnauthorizedSwapper(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @param operationsAdminAddress the OperationsAdmin this manager is permanently pinned to
     * @param minPurchasePeriod the minimum time between purchases (in seconds)
     * @param maxSchedulesPerToken the maximum number of schedules allowed per token
     * @param defaultMinPurchaseAmount the default minimum purchase amount for all tokens
     * @param initialOwner the address that owns this contract immediately after deploy
     */
    constructor(
        address operationsAdminAddress,
        uint256 minPurchasePeriod,
        uint256 maxSchedulesPerToken,
        uint256 defaultMinPurchaseAmount,
        address initialOwner
    ) BitChillOwnable(initialOwner) validateMinPurchasePeriod(minPurchasePeriod) {
        if (operationsAdminAddress.code.length == 0) {
            revert DcaManager__OperationsAdminIsNotAContract(operationsAdminAddress);
        }
        i_operationsAdmin = OperationsAdmin(operationsAdminAddress);
        s_protocolSettings = ProtocolSettings({
            minPurchasePeriod: minPurchasePeriod.toUint32(),
            maxSchedulesPerToken: maxSchedulesPerToken.toUint16(),
            defaultMinPurchaseAmount: defaultMinPurchaseAmount.toUint128(),
            scheduleNonce: 0
        });
    }

    /**
     * @notice deposit the full stablecoin amount for DCA on the contract
     * @param token the token address
     * @param scheduleIndex the schedule index
     * @param scheduleId the schedule id for validation
     * @param depositAmount the amount of stablecoin requested from the user; the handler reverts unless it receives exactly this, so the schedule is credited with the full request
     * @notice reverts before any transfer if governance paused deposits on this schedule's route
     */
    function depositToken(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 depositAmount)
        external
        override
        nonReentrant
        validateScheduleIndex(msg.sender, token, scheduleIndex)
    {
        _validateDeposit(depositAmount);
        DcaSchedule storage dcaSchedule = s_dcaSchedules[msg.sender][token][scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
        // Widths are checked before the handler pull so an overflowing credit cannot move tokens.
        uint128 newTokenBalance = (uint256(dcaSchedule.tokenBalance) + depositAmount.toUint128()).toUint128();
        _handlerForDeposit(token, dcaSchedule.routeIndex).depositToken(msg.sender, depositAmount);
        dcaSchedule.tokenBalance = newTokenBalance;
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, newTokenBalance);
    }

    /**
     * @param token the token address
     * @param scheduleIndex the schedule index
     * @param scheduleId the schedule id for validation
     * @param newPurchaseAmount the new amount of stablecoin to swap periodically for rBTC
     * @notice the amount cannot exceed the schedule's current token balance
     * @notice the emitted event carries both the amount replaced and the new one
     */
    function updatePurchaseAmount(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 newPurchaseAmount)
        external
        override
        nonReentrant
        validateScheduleIndex(msg.sender, token, scheduleIndex)
    {
        DcaSchedule storage dcaSchedule = s_dcaSchedules[msg.sender][token][scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
        uint128 newAmount = newPurchaseAmount.toUint128();
        _validatePurchaseAmount(token, newAmount, dcaSchedule.tokenBalance);
        uint256 previousPurchaseAmount = dcaSchedule.purchaseAmount;
        dcaSchedule.purchaseAmount = newAmount;
        emit DcaManager__PurchaseAmountUpdated(msg.sender, scheduleId, previousPurchaseAmount, newPurchaseAmount);
    }

    /**
     * @param token the token address
     * @param scheduleIndex the schedule index
     * @param scheduleId the schedule id for validation
     * @param newPurchasePeriod the new time (in seconds) between rBTC purchases for this schedule
     * @notice the period cannot be shorter than the minimum purchase period
     * @notice the emitted event carries both the period replaced and the new one
     */
    function updatePurchasePeriod(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 newPurchasePeriod)
        external
        override
        nonReentrant
        validateScheduleIndex(msg.sender, token, scheduleIndex)
    {
        DcaSchedule storage dcaSchedule = s_dcaSchedules[msg.sender][token][scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
        _validatePurchasePeriod(newPurchasePeriod);
        uint256 previousPurchasePeriod = dcaSchedule.purchasePeriod;
        dcaSchedule.purchasePeriod = newPurchasePeriod.toUint32();
        emit DcaManager__PurchasePeriodUpdated(msg.sender, scheduleId, previousPurchasePeriod, newPurchasePeriod);
    }

    /**
     * @param token the token address
     * @param scheduleIndex the schedule index
     * @param scheduleId the schedule id for validation
     * @param paused true to stop rBTC purchases for this schedule, false to resume them
     * @notice pausing keeps the funds on the schedule's route: deposits, amount and period edits,
     * withdrawals, interest and rBTC claims, and deletion all remain available while paused
     * @notice writing the state the schedule already holds changes nothing and emits nothing
     */
    function setSchedulePaused(address token, uint256 scheduleIndex, uint64 scheduleId, bool paused)
        external
        override
        nonReentrant
        validateScheduleIndex(msg.sender, token, scheduleIndex)
    {
        DcaSchedule storage dcaSchedule = s_dcaSchedules[msg.sender][token][scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
        if (dcaSchedule.paused == paused) return;
        dcaSchedule.paused = paused;
        emit DcaManager__SchedulePauseSet(msg.sender, scheduleId, paused);
    }

    /**
     * @notice deposit the full stablecoin amount for DCA on the contract, set the period and the amount for purchases
     * @param token: the token address of stablecoin to deposit
     * @param depositAmount: the amount of stablecoin requested from the user; the handler reverts unless it receives exactly this, so the schedule is credited with the full request
     * @param purchaseAmount: the amount of stablecoin to swap periodically for rBTC (validated against the credited request)
     * @param purchasePeriod: the time (in seconds) between rBTC purchases for each user
     * @param routeIndex: the OperationsAdmin route index for this schedule (idle or lending)
     * @notice reverts before any transfer if governance paused deposits on this token and route
     */
    function createDcaSchedule(
        address token,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 routeIndex
    ) external override nonReentrant {
        // Checked widths first: overflow reverts with SafeCast data before any token moves.
        uint128 deposit = depositAmount.toUint128();
        uint128 purchase = purchaseAmount.toUint128();
        uint32 period = purchasePeriod.toUint32();
        uint32 route = routeIndex.toUint32();

        // One load of the packed scalars, and the id this schedule will carry. The nonce is bumped
        // through SafeCast here so an exhausted counter reverts before the deposit is pulled.
        ProtocolSettings memory settings = s_protocolSettings;
        uint64 scheduleId = (uint256(settings.scheduleNonce) + 1).toUint64();

        _validatePurchasePeriod(purchasePeriod);
        _validateDeposit(depositAmount);
        _handlerForDeposit(token, route).depositToken(msg.sender, depositAmount);
        // The remaining two checks follow the pull by construction or by history: the minimum
        // purchase amount is validated against the credited request (the handler reverts unless
        // the pull matches), and the max-schedules bound has sat here since the count check was
        // fixed. Both revert the whole call, so a failure returns the deposit with it.
        _validatePurchaseAmount(token, purchaseAmount, depositAmount);

        DcaSchedule[] storage schedules = s_dcaSchedules[msg.sender][token];
        uint256 numOfSchedules = schedules.length;
        if (numOfSchedules >= settings.maxSchedulesPerToken) {
            revert DcaManager__MaxSchedulesPerTokenReached(token);
        }

        s_protocolSettings.scheduleNonce = scheduleId;

        schedules.push(
            DcaSchedule({
                tokenBalance: deposit,
                lastPurchaseTimestamp: 0,
                paused: false,
                purchaseAmount: purchase,
                purchasePeriod: period,
                routeIndex: route,
                scheduleId: scheduleId
            })
        );
        emit DcaManager__DcaScheduleCreated(
            msg.sender,
            token,
            scheduleId,
            depositAmount,
            purchaseAmount,
            purchasePeriod,
            routeIndex
        );
    }

    /**
     * @notice delete a DCA schedule
     * @param token: the token of the schedule to delete
     * @param scheduleIndex: the index of the schedule to delete
     * @param scheduleId: the id of the schedule to delete for validation
     */
    function deleteDcaSchedule(address token, uint256 scheduleIndex, uint64 scheduleId) external override 
        validateScheduleIndex(msg.sender, token, scheduleIndex)
        nonReentrant
    {
        DcaSchedule[] storage schedules = s_dcaSchedules[msg.sender][token];
        
        DcaSchedule memory dcaSchedule = schedules[scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);

        uint256 tokenBalance = dcaSchedule.tokenBalance;
        uint256 routeIndex = dcaSchedule.routeIndex;

        // Remove the schedule by poping the last one and overwriting the one to delete with it
        uint256 lastIndex = schedules.length - 1;
        if (scheduleIndex != lastIndex) {
            schedules[scheduleIndex] = schedules[lastIndex];
        }
        schedules.pop();

        uint256 amountWithdrawn;
        if (tokenBalance > 0) {
            amountWithdrawn = _handler(token, routeIndex).withdrawToken(msg.sender, tokenBalance);
        }

        // @notice the event reports what left the handler, which may be less than the schedule's tokenBalance
        emit DcaManager__DcaScheduleDeleted(msg.sender, token, scheduleId, amountWithdrawn);
    }

    /**
     * @notice withdraw amount for DCA from the contract
     * @param token: the token to withdraw
     * @param scheduleIndex: the index of the schedule to withdraw from
     * @param scheduleId: the schedule id for validation
     * @param withdrawalAmount: the amount to withdraw
     */
    function withdrawToken(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 withdrawalAmount)
        external
        override
        nonReentrant
    {
        _withdrawToken(token, scheduleIndex, scheduleId, withdrawalAmount);
    }

    /**
     * @param buyers the array of addresses of the users on behalf of whom rBTC is going to be bought
     * @notice a buyer may be featured more than once in the buyers array if two or more their schedules are due for a purchase
     * @notice we need to take extra care in the back end to not mismatch a user's address with a wrong DCA schedule
     * @param token the stablecoin that all users in the array will spend to purchase rBTC
     * @param scheduleIndexes the indexes of the DCA schedules that correspond to each user's purchase
     * @param purchaseAmounts the purchase amount that corresponds to each user's purchase
     * @param routeIndex the route all schedules in this batch must share
     * @notice the token and route are the same for all dca schedules in the batch.
     * @notice SWAPPER MUST NOT MIX SCHEDULES WITH DIFFERENT TOKENS OR ROUTES IN THE SAME BATCH
     * @notice This is unchecked to save gas because access to this function is controlled by the onlySwapper modifier
     * @notice a paused schedule reverts the whole batch, so the swapper must drop paused rows before composing it
     */
    function batchBuyRbtc(
        address[] calldata buyers,
        address token,
        uint256[] calldata scheduleIndexes,
        uint64[] calldata scheduleIds,
        uint256[] calldata purchaseAmounts,
        uint256 routeIndex
    ) external override onlySwapper {
        uint256 numOfPurchases = buyers.length;
        if (numOfPurchases == 0) revert DcaManager__EmptyBatchPurchaseArrays();
        if (
            numOfPurchases != scheduleIndexes.length || numOfPurchases != scheduleIds.length
                || numOfPurchases != purchaseAmounts.length
        ) revert DcaManager__BatchPurchaseArraysLengthMismatch();
        for (uint256 i; i < numOfPurchases; ++i) {
            (uint256 schedulePurchaseAmount, uint256 scheduleRouteIndex) = _rBtcPurchaseChecksEffects(buyers[i], token, scheduleIndexes[i], scheduleIds[i]);
            if (schedulePurchaseAmount != purchaseAmounts[i]) revert DcaManager__PurchaseAmountMismatch(buyers[i], token, scheduleIds[i], scheduleIndexes[i], schedulePurchaseAmount, purchaseAmounts[i]);
            if (scheduleRouteIndex != routeIndex) revert DcaManager__RouteIndexMismatch(buyers[i], token, scheduleIds[i], scheduleIndexes[i], scheduleRouteIndex, routeIndex);
        }
        IPurchaseRbtc(address(_handler(token, routeIndex))).batchBuyRbtc(
            buyers, scheduleIds, purchaseAmounts
        );
    }

    /**
     * @notice Users can withdraw the rBtc accumulated through all the DCA strategies created using a given stablecoin
     * @param token The token address of the stablecoin
     * @param routeIndex The route whose handler holds the user's accumulated rBTC
     */
    function withdrawRbtcFromTokenHandler(address token, uint256 routeIndex) external override nonReentrant {
        IPurchaseRbtc(address(_handler(token, routeIndex))).withdrawAccumulatedRbtc(msg.sender);
    }

    /**
     * @notice Withdraw all of the rBTC accumulated by a user through their various DCA strategies
     * @param tokens The token of each route to withdraw rBTC from
     * @param routeIndexes The route index of each route to withdraw rBTC from
     * @notice the two arrays are positional pairs: `tokens[i]` is only withdrawn from `routeIndexes[i]`,
     *         so a caller names the exact routes it holds a balance on and no other handler is called
     * @dev a pair with no handler assigned, or with no accumulated rBTC, is skipped rather than reverted
     */
    function withdrawAllAccumulatedRbtc(address[] calldata tokens, uint256[] calldata routeIndexes) external override nonReentrant {
        uint256 numOfRoutes = tokens.length;
        if (numOfRoutes == 0) revert DcaManager__EmptyWithdrawalArrays();
        if (numOfRoutes != routeIndexes.length) revert DcaManager__WithdrawalArraysLengthMismatch();
        for (uint256 i; i < numOfRoutes; ++i) {
            address tokenHandlerAddress = i_operationsAdmin.getTokenHandler(tokens[i], routeIndexes[i]);
            if (tokenHandlerAddress == address(0)) continue;
            IPurchaseRbtc handler = IPurchaseRbtc(tokenHandlerAddress);
            if (handler.getAccumulatedRbtcBalance(msg.sender) == 0) continue;
            handler.withdrawAccumulatedRbtc(msg.sender);
        }
    }

    /**
     * @notice withdraw amount for DCA from the contract, as well as the yield generated across all DCA schedules
     * @param token: the token of which to withdraw the specified amount and yield
     * @param scheduleIndex: the index of the schedule to withdraw from
     * @param scheduleId: the schedule id for validation
     * @param withdrawalAmount: the amount to withdraw
     * @dev Interest is withdrawn from the same stored route used to pay this schedule's principal.
     *      That index is captured from the schedule before the handler call. An idle schedule reverts
     *      because that route does not yield.
     */
    function withdrawTokenAndInterest(
        address token,
        uint256 scheduleIndex,
        uint64 scheduleId,
        uint256 withdrawalAmount
    ) external override nonReentrant {
        uint256 routeIndex = _withdrawToken(token, scheduleIndex, scheduleId, withdrawalAmount);
        _checkTokenYieldsInterest(token, routeIndex);
        _withdrawInterest(ITokenLending(address(_handler(token, routeIndex))), token, routeIndex);
    }

    /**
     * @dev Users can withdraw the stablecoin interests accrued by the deposits they made
     * @param tokens The token of each route to withdraw interest from
     * @param routeIndexes The route index of each route to withdraw interest from. Idle routes are skipped.
     * @notice the two arrays are positional pairs: `tokens[i]` is only withdrawn from `routeIndexes[i]`,
     *         so a caller names the exact routes it holds a balance on and no other handler is called
     * @dev a pair with no handler assigned, or on a route that does not lend, is skipped rather than reverted
     */
    function withdrawAllAccumulatedInterest(address[] calldata tokens, uint256[] calldata routeIndexes)
        external
        override
        nonReentrant
    {
        uint256 numOfRoutes = tokens.length;
        if (numOfRoutes == 0) revert DcaManager__EmptyWithdrawalArrays();
        if (numOfRoutes != routeIndexes.length) revert DcaManager__WithdrawalArraysLengthMismatch();
        for (uint256 i; i < numOfRoutes; ++i) {
            address tokenHandlerAddress = i_operationsAdmin.getTokenHandler(tokens[i], routeIndexes[i]);
            if (tokenHandlerAddress == address(0)) continue;
            // Skip idle and unregistered routes so a mixed idle+lending call still
            // withdraws interest from the indexes that yield.
            if (!_tokenYieldsInterest(routeIndexes[i])) continue;
            _withdrawInterest(ITokenLending(tokenHandlerAddress), tokens[i], routeIndexes[i]);
        }
    }

    /**
     * @notice modify the minimum period between purchases
     * @param minPurchasePeriod: the new period
     */
    function modifyMinPurchasePeriod(uint256 minPurchasePeriod)
        external
        override
        onlyOwner
        validateMinPurchasePeriod(minPurchasePeriod)
    {
        s_protocolSettings.minPurchasePeriod = minPurchasePeriod.toUint32();
        emit DcaManager__MinPurchasePeriodModified(minPurchasePeriod);
    }

    /**
     * @notice modify the maximum number of schedules per token
     * @param maxSchedulesPerToken: the new maximum number of schedules per token
     */
    function modifyMaxSchedulesPerToken(uint256 maxSchedulesPerToken) external override onlyOwner {
        s_protocolSettings.maxSchedulesPerToken = maxSchedulesPerToken.toUint16();
        emit DcaManager__MaxSchedulesPerTokenModified(maxSchedulesPerToken);
    }

    /**
     * @notice modify the default minimum purchase amount for all tokens
     * @param defaultMinPurchaseAmount: the new default minimum purchase amount
     */
    function modifyDefaultMinPurchaseAmount(uint256 defaultMinPurchaseAmount) external override onlyOwner {
        s_protocolSettings.defaultMinPurchaseAmount = defaultMinPurchaseAmount.toUint128();
        emit DcaManager__DefaultMinPurchaseAmountModified(defaultMinPurchaseAmount);
    }

    /**
     * @notice set a custom minimum purchase amount for a specific token
     * @param token: the token address
     * @param minPurchaseAmount: the custom minimum purchase amount for this token
     */
    function setTokenMinPurchaseAmount(address token, uint256 minPurchaseAmount) external override onlyOwner {
        s_tokenMinPurchaseAmounts[token] = minPurchaseAmount;
        emit DcaManager__TokenMinPurchaseAmountSet(token, minPurchaseAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice validate that the schedule id matches the schedule at the given index
     * @param scheduleId: the schedule id to validate
     * @param dcaScheduleScheduleId: the schedule id to validate against
     */
    function _validateScheduleId(uint64 scheduleId, uint64 dcaScheduleScheduleId) private pure {
        if (scheduleId != dcaScheduleScheduleId) revert DcaManager__ScheduleIdAndIndexMismatch();
    }

    /**
     * @notice validate that the purchase amount to be set is valid
     * @param token: the token spent on DCA
     * @param purchaseAmount: the purchase amount to validate
     * @param tokenBalance: the current balance of the token in that DCA schedule
     */
    function _validatePurchaseAmount(
        address token,
        uint256 purchaseAmount,
        uint256 tokenBalance
    ) private view {
        uint256 minPurchaseAmount = s_tokenMinPurchaseAmounts[token];
        if (minPurchaseAmount == 0) {
            minPurchaseAmount = s_protocolSettings.defaultMinPurchaseAmount;
        }
        
        if (purchaseAmount < minPurchaseAmount) {
            revert DcaManager__PurchaseAmountMustBeGreaterThanMinimum(token, minPurchaseAmount);
        }
        if (purchaseAmount > tokenBalance) {
            revert DcaManager__PurchaseAmountExceedsBalance(token, purchaseAmount, tokenBalance);
        }
    }

    /**
     * @notice validate the purchase period
     * @param purchasePeriod the purchase period to validate
     */
    function _validatePurchasePeriod(uint256 purchasePeriod) private view {
        if (purchasePeriod < s_protocolSettings.minPurchasePeriod) {
            revert DcaManager__PurchasePeriodMustBeGreaterThanMinimum();
        }
    }

    /**
     * @notice deposit the full stablecoin amount for DCA on the contract
     * @param depositAmount: the amount to deposit
     */
    function _validateDeposit(uint256 depositAmount) private pure {
        if (depositAmount == 0) revert DcaManager__DepositAmountMustBeGreaterThanZero();
    }

    /**
     * @notice get the token handler for a token and route index
     * @param token: the token
     * @param routeIndex: the route index
     * @return the token handler
     */
    function _handler(address token, uint256 routeIndex) private view returns (ITokenHandler) {
        address tokenHandlerAddress = i_operationsAdmin.getTokenHandler(token, routeIndex);
        if (tokenHandlerAddress == address(0)) revert DcaManager__TokenNotAccepted(token, routeIndex);
        return ITokenHandler(tokenHandlerAddress);
    }

    /**
     * @notice get the token handler for a deposit, rejecting the call if governance paused deposits
     * @param token: the token
     * @param routeIndex: the route index
     * @return the token handler
     * @dev Only `depositToken` and `createDcaSchedule` route through here, and both do so before
     *      any token moves, so a paused pair never takes cash it would have to refund. Every other
     *      caller keeps using `_handler`: purchases, edits, deletion, and withdrawals must stay
     *      available on a paused route.
     */
    function _handlerForDeposit(address token, uint256 routeIndex) private view returns (ITokenHandler) {
        ITokenHandler tokenHandler = _handler(token, routeIndex);
        if (i_operationsAdmin.areDepositsPaused(token, routeIndex)) {
            revert DcaManager__DepositsPaused(token, routeIndex);
        }
        return tokenHandler;
    }

    /**
     * @notice checks and effects of the purchase, before interactions take place
     * @param buyer: the address of the buyer
     * @param token: the token
     * @param scheduleIndex: the index of the schedule
     * @param scheduleId: the id of the schedule
     * @return the purchase amount and route index
     */
    function _rBtcPurchaseChecksEffects(address buyer, address token, uint256 scheduleIndex, uint64 scheduleId)
        private
        validateScheduleIndex(buyer, token, scheduleIndex)
        returns (uint256, uint256)
    {
        DcaSchedule storage dcaScheduleStorage = s_dcaSchedules[buyer][token][scheduleIndex];
        DcaSchedule memory dcaSchedule = dcaScheduleStorage;

        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);

        if (dcaSchedule.paused) revert DcaManager__SchedulePaused(buyer, token, scheduleId, scheduleIndex);

        uint256 lastPurchaseTimestamp = dcaSchedule.lastPurchaseTimestamp;
        uint256 purchasePeriod = dcaSchedule.purchasePeriod;

        // @notice: After the first purchase, the schedule is eligible once the UTC day of last + period has started
        if (lastPurchaseTimestamp != 0) {
            uint256 currentDayStart = block.timestamp - (block.timestamp % 1 days);
            uint256 nextDueTimestamp = lastPurchaseTimestamp + purchasePeriod;
            uint256 nextPurchaseDayStart = nextDueTimestamp - (nextDueTimestamp % 1 days);
            if (currentDayStart < nextPurchaseDayStart) {
                revert DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed(nextPurchaseDayStart - block.timestamp);
            }
        }

        if (dcaSchedule.purchaseAmount > dcaSchedule.tokenBalance) {
            revert DcaManager__ScheduleBalanceNotEnoughForPurchase(scheduleIndex, scheduleId, token, dcaSchedule.tokenBalance);
        }
        dcaSchedule.tokenBalance -= dcaSchedule.purchaseAmount;
        dcaScheduleStorage.tokenBalance = dcaSchedule.tokenBalance;
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, dcaSchedule.tokenBalance);

        // @notice: this way purchases are possible with the wanted periodicity even if
        // - a previous purchase was delayed
        // - the schedule run out of stablecoin and was resumed later with a new deposit
        // Floor periodsElapsed at 1 so an early UTC-day buy still consumes a slot
        uint256 newTimestamp;
        if (lastPurchaseTimestamp == 0) {
            newTimestamp = block.timestamp;
        } else {
            uint256 periodsElapsed = (block.timestamp - lastPurchaseTimestamp) / purchasePeriod;
            if (periodsElapsed == 0) periodsElapsed = 1;
            newTimestamp = lastPurchaseTimestamp + periodsElapsed * purchasePeriod;
        }
        dcaScheduleStorage.lastPurchaseTimestamp = newTimestamp.toUint48();
        emit DcaManager__LastPurchaseTimestampUpdated(token, scheduleId, newTimestamp);

        return (dcaSchedule.purchaseAmount, dcaSchedule.routeIndex);
    }

    /**
     * @notice withdraw a token from a DCA schedule
     * @param token: the token to withdraw
     * @param scheduleIndex: the index of the schedule
     * @param scheduleId: the schedule id for validation
     * @param withdrawalAmount: the amount to withdraw, or type(uint256).max for this schedule's whole token balance
     * @return routeIndex the schedule's stored route, captured before the handler call
     */
    function _withdrawToken(address token, uint256 scheduleIndex, uint64 scheduleId, uint256 withdrawalAmount)
        private
        validateScheduleIndex(msg.sender, token, scheduleIndex)
        returns (uint256 routeIndex)
    {
        DcaSchedule storage dcaSchedule = s_dcaSchedules[msg.sender][token][scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
        uint256 tokenBalance = dcaSchedule.tokenBalance;
        if (withdrawalAmount == type(uint256).max) withdrawalAmount = tokenBalance;
        if (withdrawalAmount == 0) revert DcaManager__WithdrawalAmountMustBeGreaterThanZero();
        if (withdrawalAmount > tokenBalance) {
            revert DcaManager__WithdrawalAmountExceedsBalance(token, withdrawalAmount, tokenBalance);
        }
        // @notice subtract the requested withdrawal amount from the token balance, not the amount the lending protocol paid
        uint256 newTokenBalance = tokenBalance - withdrawalAmount;
        routeIndex = dcaSchedule.routeIndex;
        dcaSchedule.tokenBalance = newTokenBalance.toUint128();
        // @notice ignore `withdrawToken()`'s return value (amount actually paid back by the lending protocol)
        _handler(token, routeIndex).withdrawToken(msg.sender, withdrawalAmount);
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, newTokenBalance);
    }

    /**
     * @notice sum locked principal for one user, token, and route without copying the schedule array
     * @param user: the user whose schedules to read
     * @param token: the token to read schedules for
     * @param routeIndex: only balances on this route are included
     * @return lockedTokenAmount the sum of matching `tokenBalance`s
     */
    function _lockedPrincipal(address user, address token, uint256 routeIndex)
        private
        view
        returns (uint256 lockedTokenAmount)
    {
        DcaSchedule[] storage schedules = s_dcaSchedules[user][token];
        for (uint256 i; i < schedules.length; ++i) {
            if (schedules[i].routeIndex == routeIndex) {
                lockedTokenAmount += schedules[i].tokenBalance;
            }
        }
    }

    /**
     * @notice withdraw interest from an already-resolved lending handler
     * @param tokenLending: the lending handler that holds this route's funds
     * @param token: the token to withdraw interest from
     * @param routeIndex: the route whose locked principal to subtract
     * @dev Callers must already have established that `routeIndex` is a lending
     *      route (`_checkTokenYieldsInterest` to revert, or `_tokenYieldsInterest`
     *      to skip). This helper does not re-check.
     */
    function _withdrawInterest(ITokenLending tokenLending, address token, uint256 routeIndex) private {
        tokenLending.withdrawInterest(msg.sender, _lockedPrincipal(msg.sender, token, routeIndex));
    }

    /**
     * @notice whether a route index was registered as lending
     * @param routeIndex: the route index
     */
    function _tokenYieldsInterest(uint256 routeIndex) private view returns (bool) {
        return i_operationsAdmin.isLendingRoute(routeIndex);
    }

    /**
     * @notice check if a token yields interest
     * @param token: the token to check
     * @param routeIndex: the route index
     */
    function _checkTokenYieldsInterest(address token, uint256 routeIndex) private view {
        if (!_tokenYieldsInterest(routeIndex)) revert DcaManager__TokenDoesNotYieldInterest(token);
    }

    /*//////////////////////////////////////////////////////////////
                            GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice get one DCA schedule for a user and token
     * @param user: the user to get the schedule for
     * @param token: the token to get the schedule for
     * @param scheduleIndex: the index of the schedule
     * @return the DCA schedule
     */
    function getDcaSchedule(address user, address token, uint256 scheduleIndex)
        external
        view
        override
        validateScheduleIndex(user, token, scheduleIndex)
        returns (DcaSchedule memory)
    {
        return s_dcaSchedules[user][token][scheduleIndex];
    }

    /**
     * @notice get all DCA schedules for a specific user
     * @param user: the user to get schedules for
     * @param token: the token to get schedules for
     * @return the DCA schedules
     */
    function getDcaSchedules(address user, address token) external view override returns (DcaSchedule[] memory) {
        return s_dcaSchedules[user][token];
    }

    /**
     * @notice get the OperationsAdmin this manager is permanently pinned to
     * @return the constructor-supplied OperationsAdmin address
     */
    function getOperationsAdminAddress() external view override returns (address) {
        return address(i_operationsAdmin);
    }

    /**
     * @notice get the minimum purchase period
     * @return the minimum purchase period
     */
    function getMinPurchasePeriod() external view override returns (uint256) {
        return s_protocolSettings.minPurchasePeriod;
    }

    /**
     * @notice get the maximum number of schedules per token
     * @return the maximum number of schedules per token
     */
    function getMaxSchedulesPerToken() external view override returns (uint256) {
        return s_protocolSettings.maxSchedulesPerToken;
    }

    /**
     * @notice get the total number of DCA schedules ever created, across all users and tokens
     * @dev This is the id counter itself, so it is also the last `scheduleId` handed out. Never
     * decreases: deleting a schedule does not decrement it. Compare against the number of
     * DcaManager__DcaScheduleCreated events an indexer has ingested to detect missed events.
     * @return the lifetime count of created schedules
     */
    function getSchedulesCreatedCount() external view override returns (uint256) {
        return s_protocolSettings.scheduleNonce;
    }

    /**
     * @notice get the default minimum purchase amount for all tokens
     * @return the default minimum purchase amount
     */
    function getDefaultMinPurchaseAmount() external view override returns (uint256) {
        return s_protocolSettings.defaultMinPurchaseAmount;
    }

    /**
     * @notice get the minimum purchase amount for a specific token
     * @param token: the token address
     * @return minPurchaseAmount the minimum purchase amount for this token
     * @return customMinAmountSet whether a custom amount is set (false means using default)
     */
    function getTokenMinPurchaseAmount(address token) external view override returns (uint256 minPurchaseAmount, bool customMinAmountSet) {
        uint256 customAmount = s_tokenMinPurchaseAmounts[token];
        customMinAmountSet = customAmount != 0;
        minPurchaseAmount = customMinAmountSet ? customAmount : s_protocolSettings.defaultMinPurchaseAmount;
    }

    /**
     * @notice get the rBTC accumulated by a user on the handler for a token and route
     * @param user: the user to get the accumulated rBTC for
     * @param token: the token
     * @param routeIndex: the route index
     * @return the accumulated rBTC balance
     */
    function getAccumulatedRbtcBalance(address user, address token, uint256 routeIndex)
        external
        view
        override
        returns (uint256)
    {
        return IPurchaseRbtc(address(_handler(token, routeIndex))).getAccumulatedRbtcBalance(user);
    }

    /**
     * @notice get the interest accrued by a user with a given stablecoin on a given lending route
     * @param user: the user to get the interest for
     * @param token: the token to get the interest for
     * @param routeIndex: the route index to get the interest for
     * @return the interest accrued
     */
    function getInterestAccrued(address user, address token, uint256 routeIndex)
        external
        view
        override
        returns (uint256)
    {
        _checkTokenYieldsInterest(token, routeIndex);
        return ITokenLending(address(_handler(token, routeIndex))).getAccruedInterest(
            user, _lockedPrincipal(user, token, routeIndex)
        );
    }
}
