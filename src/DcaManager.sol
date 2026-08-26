// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDcaManager} from "./interfaces/IDcaManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ITokenHandler} from "./interfaces/ITokenHandler.sol";
import {ITokenLending} from "./interfaces/ITokenLending.sol";
import {OperationsAdmin} from "./OperationsAdmin.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";

/**
 * @title DCA Manager
 * @author BitChill team: Ynyesto (GitHub: @ynyesto)
 * @notice Entry point for the DCA dApp. Create and manage DCA schedules. 
 */
contract DcaManager is IDcaManager, Ownable, ReentrancyGuard {
    
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    OperationsAdmin private s_operationsAdmin;

    /**
     * @notice Each user may create different schedules with one or more stablecoins
     */
    mapping(address user => mapping(address tokenDeposited => DcaDetails[] usersDcaSchedules)) private s_dcaSchedules;
    uint256 private s_minPurchasePeriod; // Minimum time between purchases
    uint256 private s_maxSchedulesPerToken; // Maximum number of schedules per stablecoin
    uint256 private s_defaultMinPurchaseAmount; // Default minimum purchase amount for all tokens
    mapping(address token => uint256) private s_tokenMinPurchaseAmounts; // Custom minimum purchase amounts per token
    /**
     * @notice Strictly increasing counter used to derive schedule ids.
     * @dev Ids must not be derived from array state: swap-pop on delete can restore a previous
     * array shape within a block, which would let two live schedules share an id.
     */
    uint256 private s_scheduleNonce = 1;

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
        if (!s_operationsAdmin.isSwapper(msg.sender)) {
            revert DcaManager__UnauthorizedSwapper(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @param operationsAdminAddress the address of the admin operations contract
     * @param minPurchasePeriod the minimum time between purchases (in seconds)
     * @param maxSchedulesPerToken the maximum number of schedules allowed per token
     * @param defaultMinPurchaseAmount the default minimum purchase amount for all tokens
     */
    constructor(address operationsAdminAddress, uint256 minPurchasePeriod, uint256 maxSchedulesPerToken, uint256 defaultMinPurchaseAmount)
        Ownable()
        validateMinPurchasePeriod(minPurchasePeriod)
    {
        s_operationsAdmin = OperationsAdmin(operationsAdminAddress);
        s_minPurchasePeriod = minPurchasePeriod;
        s_maxSchedulesPerToken = maxSchedulesPerToken;
        s_defaultMinPurchaseAmount = defaultMinPurchaseAmount;
    }

    /**
     * @notice deposit the full stablecoin amount for DCA on the contract
     * @param token the token address
     * @param scheduleIndex the schedule index
     * @param scheduleId the schedule id for validation
     * @param depositAmount the amount of stablecoin requested from the user; the schedule is credited with what the handler received
     */
    function depositToken(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 depositAmount)
        external
        override
        nonReentrant
        validateScheduleIndex(msg.sender, token, scheduleIndex)
    {
        _validateDeposit(depositAmount);
        DcaDetails storage dcaSchedule = s_dcaSchedules[msg.sender][token][scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
        uint256 received = _handler(token, dcaSchedule.routeIndex).depositToken(msg.sender, depositAmount);
        uint256 newTokenBalance = dcaSchedule.tokenBalance + received;
        dcaSchedule.tokenBalance = newTokenBalance;
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, newTokenBalance);
    }

    /**
     * @param token the token address
     * @param scheduleIndex the schedule index
     * @param scheduleId the schedule id for validation
     * @param purchaseAmount the amount of stablecoin to swap periodically for rBTC
     * @notice the amount cannot exceed the schedule's current token balance
     */
    function setPurchaseAmount(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 purchaseAmount)
        external
        override
        nonReentrant
        validateScheduleIndex(msg.sender, token, scheduleIndex)
    {
        DcaDetails storage dcaSchedule = s_dcaSchedules[msg.sender][token][scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
        _validatePurchaseAmount(token, purchaseAmount, dcaSchedule.tokenBalance);
        dcaSchedule.purchaseAmount = purchaseAmount;
        emit DcaManager__PurchaseAmountSet(msg.sender, scheduleId, purchaseAmount);
    }

    /**
     * @param token the token address
     * @param scheduleIndex the schedule index
     * @param scheduleId the schedule id for validation
     * @param purchasePeriod the time (in seconds) between rBTC purchases for each user
     * @notice the period
     */
    function setPurchasePeriod(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 purchasePeriod)
        external
        override
        nonReentrant
        validateScheduleIndex(msg.sender, token, scheduleIndex)
    {
        DcaDetails storage dcaSchedule = s_dcaSchedules[msg.sender][token][scheduleIndex];
        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);
        _validatePurchasePeriod(purchasePeriod);
        dcaSchedule.purchasePeriod = purchasePeriod;
        emit DcaManager__PurchasePeriodSet(msg.sender, scheduleId, purchasePeriod);
    }

    /**
     * @notice deposit the full stablecoin amount for DCA on the contract, set the period and the amount for purchases
     * @param token: the token address of stablecoin to deposit
     * @param depositAmount: the amount of stablecoin requested from the user; the schedule is credited with what the handler received
     * @param purchaseAmount: the amount of stablecoin to swap periodically for rBTC (validated against the credited balance)
     * @param purchasePeriod: the time (in seconds) between rBTC purchases for each user
     * @param routeIndex: the OperationsAdmin route index for this schedule (idle or lending)
     */
    function createDcaSchedule(
        address token,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 routeIndex
    ) external override nonReentrant {
        _validatePurchasePeriod(purchasePeriod);
        _validateDeposit(depositAmount);
        uint256 received = _handler(token, routeIndex).depositToken(msg.sender, depositAmount);
        _validatePurchaseAmount(token, purchaseAmount, received);

        DcaDetails[] storage schedules = s_dcaSchedules[msg.sender][token];
        uint256 numOfSchedules = schedules.length;
        if (numOfSchedules >= s_maxSchedulesPerToken) {
            revert DcaManager__MaxSchedulesPerTokenReached(token);
        }

        bytes32 scheduleId = keccak256(abi.encodePacked(msg.sender, token, ++s_scheduleNonce));

        DcaDetails memory dcaSchedule = DcaDetails(
            received,
            purchaseAmount,
            purchasePeriod,
            0, // lastPurchaseTimestamp
            scheduleId,
            routeIndex
        );

        schedules.push(dcaSchedule);
        emit DcaManager__DcaScheduleCreated(
            msg.sender, 
            token,
            scheduleId, 
            received, 
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
    function deleteDcaSchedule(address token, uint256 scheduleIndex, bytes32 scheduleId) external override 
        validateScheduleIndex(msg.sender, token, scheduleIndex)
        nonReentrant
    {
        DcaDetails[] storage schedules = s_dcaSchedules[msg.sender][token];
        
        DcaDetails memory dcaSchedule = schedules[scheduleIndex];
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
    function withdrawToken(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 withdrawalAmount)
        external
        override
        nonReentrant
    {
        _withdrawToken(token, scheduleIndex, scheduleId, withdrawalAmount);
    }

    /**
     * @notice buy rBTC for a user
     * @param buyer: the address of the user
     * @param token: the token to buy rBTC with
     * @param scheduleIndex: the index of the schedule to buy rBTC from
     * @param scheduleId: the id of the schedule to buy rBTC from
     */
    function buyRbtc(address buyer, address token, uint256 scheduleIndex, bytes32 scheduleId)
        external
        override
        onlySwapper
    {
        (uint256 purchaseAmount, uint256 routeIndex) =
            _rBtcPurchaseChecksEffects(buyer, token, scheduleIndex, scheduleId);

        IPurchaseRbtc(address(_handler(token, routeIndex))).buyRbtc(
            buyer, scheduleId, purchaseAmount
        );
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
     */
    function batchBuyRbtc(
        address[] calldata buyers,
        address token,
        uint256[] calldata scheduleIndexes,
        bytes32[] calldata scheduleIds,
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
            (uint256 scheudulePurchaseAmount, uint256 scheduleRouteIndex) = _rBtcPurchaseChecksEffects(buyers[i], token, scheduleIndexes[i], scheduleIds[i]);
            if (scheudulePurchaseAmount != purchaseAmounts[i]) revert DcaManager__PurchaseAmountMismatch(buyers[i], token, scheduleIds[i], scheduleIndexes[i], scheudulePurchaseAmount, purchaseAmounts[i]);
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
     * @param tokens Array of token addresses to withdraw rBTC from
     * @param routeIndexes Route indexes whose handlers may hold the user's accumulated rBTC
     */
    function withdrawAllAccumulatedRbtc(address[] calldata tokens, uint256[] calldata routeIndexes) external override nonReentrant {
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < routeIndexes.length; ++j) {
                address tokenHandlerAddress = s_operationsAdmin.getTokenHandler(tokens[i], routeIndexes[j]);
                if (tokenHandlerAddress == address(0)) continue;
                IPurchaseRbtc handler = IPurchaseRbtc(tokenHandlerAddress);
                if (handler.getAccumulatedRbtcBalance(msg.sender) == 0) continue;
                handler.withdrawAccumulatedRbtc(msg.sender);
            }
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
        bytes32 scheduleId,
        uint256 withdrawalAmount
    ) external override nonReentrant {
        uint256 routeIndex = _withdrawToken(token, scheduleIndex, scheduleId, withdrawalAmount);
        _checkTokenYieldsInterest(token, routeIndex);
        _withdrawInterest(ITokenLending(address(_handler(token, routeIndex))), token, routeIndex);
    }

    /**
     * @dev Users can withdraw the stablecoin interests accrued by the deposits they made
     * @param tokens Array of token addresses to withdraw interest from
     * @param routeIndexes Route indexes to withdraw interest from. Idle routes are skipped.
     */
    function withdrawAllAccumulatedInterest(address[] calldata tokens, uint256[] calldata routeIndexes)
        external
        override
        nonReentrant
    {
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < routeIndexes.length; ++j) {
                address tokenHandlerAddress = s_operationsAdmin.getTokenHandler(tokens[i], routeIndexes[j]);
                if (tokenHandlerAddress == address(0)) continue;
                // Skip idle and unregistered routes so a mixed idle+lending call still
                // withdraws interest from the indexes that yield.
                if (!_tokenYieldsInterest(routeIndexes[j])) continue;
                _withdrawInterest(ITokenLending(tokenHandlerAddress), tokens[i], routeIndexes[j]);
            }
        }
    }

    /**
     * @notice update the admin operations contract
     * @param operationsAdminAddress: the address of admin operations
     */
    function setOperationsAdmin(address operationsAdminAddress) external override onlyOwner {
        s_operationsAdmin = OperationsAdmin(operationsAdminAddress);
        emit DcaManager__OperationsAdminUpdated(operationsAdminAddress);
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
        s_minPurchasePeriod = minPurchasePeriod;
        emit DcaManager__MinPurchasePeriodModified(minPurchasePeriod);
    }

    /**
     * @notice modify the maximum number of schedules per token
     * @param maxSchedulesPerToken: the new maximum number of schedules per token
     */
    function modifyMaxSchedulesPerToken(uint256 maxSchedulesPerToken) external override onlyOwner {
        s_maxSchedulesPerToken = maxSchedulesPerToken;
        emit DcaManager__MaxSchedulesPerTokenModified(maxSchedulesPerToken);
    }

    /**
     * @notice modify the default minimum purchase amount for all tokens
     * @param defaultMinPurchaseAmount: the new default minimum purchase amount
     */
    function modifyDefaultMinPurchaseAmount(uint256 defaultMinPurchaseAmount) external override onlyOwner {
        s_defaultMinPurchaseAmount = defaultMinPurchaseAmount;
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
    function _validateScheduleId(bytes32 scheduleId, bytes32 dcaScheduleScheduleId) private pure {
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
            minPurchaseAmount = s_defaultMinPurchaseAmount;
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
        if (purchasePeriod < s_minPurchasePeriod) revert DcaManager__PurchasePeriodMustBeGreaterThanMinimum();
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
        address tokenHandlerAddress = s_operationsAdmin.getTokenHandler(token, routeIndex);
        if (tokenHandlerAddress == address(0)) revert DcaManager__TokenNotAccepted(token, routeIndex);
        return ITokenHandler(tokenHandlerAddress);
    }

    /**
     * @notice checks and effects of the purchase, before interactions take place
     * @param buyer: the address of the buyer
     * @param token: the token
     * @param scheduleIndex: the index of the schedule
     * @param scheduleId: the id of the schedule
     * @return the purchase amount and route index
     */
    function _rBtcPurchaseChecksEffects(address buyer, address token, uint256 scheduleIndex, bytes32 scheduleId)
        private
        validateScheduleIndex(buyer, token, scheduleIndex)
        returns (uint256, uint256)
    {
        DcaDetails storage dcaScheduleStorage = s_dcaSchedules[buyer][token][scheduleIndex];
        DcaDetails memory dcaSchedule = dcaScheduleStorage;

        _validateScheduleId(scheduleId, dcaSchedule.scheduleId);

        // @notice: After the first purchase, the schedule is eligible once the UTC day of last + period has started
        if (dcaSchedule.lastPurchaseTimestamp != 0) {
            uint256 currentDayStart = block.timestamp - (block.timestamp % 1 days);
            uint256 nextDueTimestamp = dcaSchedule.lastPurchaseTimestamp + dcaSchedule.purchasePeriod;
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
        if (dcaSchedule.lastPurchaseTimestamp == 0) {
            dcaSchedule.lastPurchaseTimestamp = block.timestamp;
        } else {
            uint256 periodsElapsed = (block.timestamp - dcaSchedule.lastPurchaseTimestamp) / dcaSchedule.purchasePeriod;
            if (periodsElapsed == 0) periodsElapsed = 1;
            unchecked {
                dcaSchedule.lastPurchaseTimestamp += periodsElapsed * dcaSchedule.purchasePeriod;
            }
        }
        dcaScheduleStorage.lastPurchaseTimestamp = dcaSchedule.lastPurchaseTimestamp;
        emit DcaManager__LastPurchaseTimestampUpdated(token, scheduleId, dcaSchedule.lastPurchaseTimestamp);

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
    function _withdrawToken(address token, uint256 scheduleIndex, bytes32 scheduleId, uint256 withdrawalAmount)
        private
        validateScheduleIndex(msg.sender, token, scheduleIndex)
        returns (uint256 routeIndex)
    {
        DcaDetails storage dcaSchedule = s_dcaSchedules[msg.sender][token][scheduleIndex];
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
        dcaSchedule.tokenBalance = newTokenBalance;
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
        DcaDetails[] storage schedules = s_dcaSchedules[user][token];
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
     */
    function _withdrawInterest(ITokenLending tokenLending, address token, uint256 routeIndex) private {
        tokenLending.withdrawInterest(msg.sender, _lockedPrincipal(msg.sender, token, routeIndex));
    }

    /**
     * @notice whether a route index was registered as lending
     * @param routeIndex: the route index
     */
    function _tokenYieldsInterest(uint256 routeIndex) private view returns (bool) {
        return s_operationsAdmin.isLendingRoute(routeIndex);
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
        returns (DcaDetails memory)
    {
        return s_dcaSchedules[user][token][scheduleIndex];
    }

    /**
     * @notice get all DCA schedules for a specific user
     * @param user: the user to get schedules for
     * @param token: the token to get schedules for
     * @return the DCA schedules
     */
    function getDcaSchedules(address user, address token) external view override returns (DcaDetails[] memory) {
        return s_dcaSchedules[user][token];
    }

    /**
     * @notice get the admin operations address
     * @return the admin operations address
     */
    function getOperationsAdminAddress() external view override returns (address) {
        return address(s_operationsAdmin);
    }

    /**
     * @notice get the minimum purchase period
     * @return the minimum purchase period
     */
    function getMinPurchasePeriod() external view override returns (uint256) {
        return s_minPurchasePeriod;
    }

    /**
     * @notice get the maximum number of schedules per token
     * @return the maximum number of schedules per token
     */
    function getMaxSchedulesPerToken() external view override returns (uint256) {
        return s_maxSchedulesPerToken;
    }

    /**
     * @notice get the total number of DCA schedules ever created, across all users and tokens
     * @dev Never decreases: deleting a schedule does not decrement it. Compare against the number of
     * DcaManager__DcaScheduleCreated events an indexer has ingested to detect missed events.
     * @return the lifetime count of created schedules
     */
    function getSchedulesCreatedCount() external view override returns (uint256) {
        return s_scheduleNonce - 1;
    }

    /**
     * @notice get the default minimum purchase amount for all tokens
     * @return the default minimum purchase amount
     */
    function getDefaultMinPurchaseAmount() external view override returns (uint256) {
        return s_defaultMinPurchaseAmount;
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
        minPurchaseAmount = customMinAmountSet ? customAmount : s_defaultMinPurchaseAmount;
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
