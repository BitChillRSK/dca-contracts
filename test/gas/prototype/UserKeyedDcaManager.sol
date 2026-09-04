// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";

/**
 * @title UserKeyedDcaManager
 * @notice Design D: `mapping(uint64 scheduleId => mapping(address user => Schedule))`, so the owner
 *         moves back into the key and the schedule fits two slots again.
 * @dev Test-only. Never deployed, never imported by `src/`. Same checks, effects and events as the
 *      shipped manager; only the key and the packing differ.
 *
 *      What the second key buys, beyond the slot: ownership becomes structural again. A caller reaching
 *      `s_dcaSchedules[scheduleId][msg.sender]` cannot address a schedule that is not theirs — the
 *      lookup lands on an empty struct — so the explicit owner check the flat key needed disappears,
 *      and with it the class of bug where one entry point forgets it. On the purchase path the same
 *      thing collapses existence and the token check into one comparison: an empty struct has
 *      `token == address(0)`, which fails the batch's token check anyway.
 *
 *      What it costs: the buyer can no longer be read from storage, so `Batch` carries a `buyers`
 *      array again and a row is a `uint64` plus an address rather than a `uint64`. That is calldata on
 *      every row of every tick, against one fewer cold `SLOAD` on every row of every tick. Which way
 *      that nets is the question this prototype exists to answer.
 */
contract UserKeyedDcaManager is ReentrancyGuard {
    using SafeCast for uint256;

    /// @notice Two slots: the owner is the key, so only the stablecoin has to be carried.
    struct Schedule {
        uint128 tokenBalance;
        uint48 lastPurchaseTimestamp;
        bool paused;
        uint32 purchasePeriod;
        uint32 routeIndex;
        address token;
        uint96 purchaseAmount;
    }

    /// @notice A row is an id and its buyer; the pair is the key.
    struct Batch {
        uint64[] scheduleIds;
        address[] buyers;
        uint256[] purchaseAmounts;
        address token;
        uint256 routeIndex;
        uint256 minRbtcOut;
    }

    OperationsAdmin private immutable i_operationsAdmin;

    mapping(uint64 scheduleId => mapping(address user => Schedule)) private s_dcaSchedules;
    mapping(address user => mapping(address token => uint64[] scheduleIds)) private s_scheduleIds;
    IDcaManager.ProtocolSettings private s_protocolSettings;
    mapping(address token => uint256) private s_tokenMinPurchaseAmounts;

    event DcaManager__TokenBalanceUpdated(address indexed token, uint64 indexed scheduleId, uint256 amount);
    event DcaManager__LastPurchaseTimestampUpdated(
        address indexed token, uint64 indexed scheduleId, uint256 lastPurchaseTimestamp
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
    event DcaManager__DcaScheduleDeleted(
        address indexed user, address indexed token, uint64 indexed scheduleId, uint256 refundedAmount
    );

    error Prototype__InexistentSchedule();
    error Prototype__SchedulePaused();
    error Prototype__PeriodHasNotElapsed();
    error Prototype__BalanceNotEnough();
    error Prototype__PurchaseAmountMismatch();
    error Prototype__RouteIndexMismatch();
    error Prototype__MaxSchedulesReached();
    error Prototype__EmptyBatch();
    error Prototype__ArraysLengthMismatch();
    error Prototype__PurchasePeriodBelowMinimum();
    error Prototype__DepositAmountIsZero();
    error Prototype__PurchaseAmountBelowMinimum();
    error Prototype__PurchaseAmountExceedsBalance();
    error Prototype__DepositsPaused();
    error Prototype__TokenNotAccepted();
    error Prototype__UnauthorizedSwapper();

    modifier onlySwapper() {
        if (!i_operationsAdmin.isSwapper(msg.sender)) revert Prototype__UnauthorizedSwapper();
        _;
    }

    constructor(
        address operationsAdminAddress,
        uint256 minPurchasePeriod,
        uint256 maxSchedulesPerToken,
        uint256 defaultMinPurchaseAmount
    ) {
        i_operationsAdmin = OperationsAdmin(operationsAdminAddress);
        s_protocolSettings = IDcaManager.ProtocolSettings({
            minPurchasePeriod: minPurchasePeriod.toUint32(),
            maxSchedulesPerToken: maxSchedulesPerToken.toUint16(),
            defaultMinPurchaseAmount: defaultMinPurchaseAmount.toUint128(),
            scheduleNonce: 0
        });
    }

    function createDcaSchedule(
        address token,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod,
        uint256 routeIndex
    ) external nonReentrant {
        uint128 deposit = depositAmount.toUint128();
        uint96 purchase = purchaseAmount.toUint96();
        uint32 period = purchasePeriod.toUint32();
        uint32 route = routeIndex.toUint32();

        IDcaManager.ProtocolSettings memory settings = s_protocolSettings;
        uint64 scheduleId = (uint256(settings.scheduleNonce) + 1).toUint64();

        _validatePurchasePeriod(purchasePeriod);
        _validateDeposit(depositAmount);
        _handlerForDeposit(token, route).depositToken(msg.sender, depositAmount);
        _validatePurchaseAmount(token, purchaseAmount, depositAmount);

        uint64[] storage scheduleIds = s_scheduleIds[msg.sender][token];
        if (scheduleIds.length >= settings.maxSchedulesPerToken) revert Prototype__MaxSchedulesReached();

        s_protocolSettings.scheduleNonce = scheduleId;

        s_dcaSchedules[scheduleId][msg.sender] = Schedule({
            tokenBalance: deposit,
            lastPurchaseTimestamp: 0,
            paused: false,
            purchasePeriod: period,
            routeIndex: route,
            token: token,
            purchaseAmount: purchase
        });
        scheduleIds.push(scheduleId);

        emit DcaManager__DcaScheduleCreated(
            msg.sender, token, scheduleId, depositAmount, purchaseAmount, purchasePeriod, routeIndex
        );
    }

    /// @dev No owner check: `msg.sender` is half the key, so a stranger's lookup is an empty struct.
    function deleteDcaSchedule(uint64 scheduleId) external nonReentrant {
        Schedule memory dcaSchedule = s_dcaSchedules[scheduleId][msg.sender];
        address token = dcaSchedule.token;
        if (token == address(0)) revert Prototype__InexistentSchedule();

        _removeScheduleId(msg.sender, token, scheduleId);
        delete s_dcaSchedules[scheduleId][msg.sender];

        uint256 amountWithdrawn;
        if (dcaSchedule.tokenBalance > 0) {
            amountWithdrawn =
                _handler(token, dcaSchedule.routeIndex).withdrawToken(msg.sender, dcaSchedule.tokenBalance);
        }

        emit DcaManager__DcaScheduleDeleted(msg.sender, token, scheduleId, amountWithdrawn);
    }

    function batchBuyRbtc(Batch calldata batch) external onlySwapper {
        uint256 numOfPurchases = batch.scheduleIds.length;
        if (numOfPurchases == 0) revert Prototype__EmptyBatch();
        if (numOfPurchases != batch.purchaseAmounts.length || numOfPurchases != batch.buyers.length) {
            revert Prototype__ArraysLengthMismatch();
        }
        for (uint256 i; i < numOfPurchases; ++i) {
            (uint256 schedulePurchaseAmount, uint256 scheduleRouteIndex) =
                _rBtcPurchaseChecksEffects(batch.scheduleIds[i], batch.buyers[i], batch.token);
            if (schedulePurchaseAmount != batch.purchaseAmounts[i]) revert Prototype__PurchaseAmountMismatch();
            if (scheduleRouteIndex != batch.routeIndex) revert Prototype__RouteIndexMismatch();
        }
        IPurchaseRbtc(address(_handler(batch.token, batch.routeIndex))).batchBuyRbtc(
            batch.buyers, batch.scheduleIds, batch.purchaseAmounts, batch.minRbtcOut
        );
    }

    function getSchedule(uint64 scheduleId, address user) external view returns (Schedule memory) {
        return s_dcaSchedules[scheduleId][user];
    }

    function getScheduleIds(address user, address token) external view returns (uint64[] memory) {
        return s_scheduleIds[user][token];
    }

    function getSchedulesCreatedCount() external view returns (uint256) {
        return s_protocolSettings.scheduleNonce;
    }

    /**
     * @dev Existence and the token check are one comparison: a schedule that does not belong to this
     *      buyer reads as an empty struct, whose `token` is `address(0)` and so is never the batch's.
     */
    function _rBtcPurchaseChecksEffects(uint64 scheduleId, address buyer, address token)
        private
        returns (uint256, uint256)
    {
        Schedule storage dcaScheduleStorage = s_dcaSchedules[scheduleId][buyer];
        Schedule memory dcaSchedule = dcaScheduleStorage;

        if (dcaSchedule.token != token) revert Prototype__InexistentSchedule();
        if (dcaSchedule.paused) revert Prototype__SchedulePaused();

        uint256 lastPurchaseTimestamp = dcaSchedule.lastPurchaseTimestamp;
        uint256 purchasePeriod = dcaSchedule.purchasePeriod;

        if (lastPurchaseTimestamp != 0) {
            uint256 currentDayStart = block.timestamp - (block.timestamp % 1 days);
            uint256 nextDueTimestamp = lastPurchaseTimestamp + purchasePeriod;
            uint256 nextPurchaseDayStart = nextDueTimestamp - (nextDueTimestamp % 1 days);
            if (currentDayStart < nextPurchaseDayStart) revert Prototype__PeriodHasNotElapsed();
        }

        if (dcaSchedule.purchaseAmount > dcaSchedule.tokenBalance) revert Prototype__BalanceNotEnough();
        dcaSchedule.tokenBalance -= dcaSchedule.purchaseAmount;
        dcaScheduleStorage.tokenBalance = dcaSchedule.tokenBalance;
        emit DcaManager__TokenBalanceUpdated(token, scheduleId, dcaSchedule.tokenBalance);

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

    function _removeScheduleId(address user, address token, uint64 scheduleId) private {
        uint64[] storage scheduleIds = s_scheduleIds[user][token];
        uint256 numOfSchedules = scheduleIds.length;
        for (uint256 i; i < numOfSchedules; ++i) {
            if (scheduleIds[i] == scheduleId) {
                uint256 lastIndex = numOfSchedules - 1;
                if (i != lastIndex) scheduleIds[i] = scheduleIds[lastIndex];
                scheduleIds.pop();
                return;
            }
        }
        revert Prototype__InexistentSchedule();
    }

    function _handlerForDeposit(address token, uint256 routeIndex) private view returns (ITokenHandler) {
        ITokenHandler tokenHandler = _handler(token, routeIndex);
        if (i_operationsAdmin.areDepositsPaused(token, routeIndex)) revert Prototype__DepositsPaused();
        return tokenHandler;
    }

    function _handler(address token, uint256 routeIndex) private view returns (ITokenHandler) {
        address tokenHandlerAddress = i_operationsAdmin.getTokenHandler(token, routeIndex);
        if (tokenHandlerAddress == address(0)) revert Prototype__TokenNotAccepted();
        return ITokenHandler(tokenHandlerAddress);
    }

    function _validatePurchasePeriod(uint256 purchasePeriod) private view {
        if (purchasePeriod < s_protocolSettings.minPurchasePeriod) revert Prototype__PurchasePeriodBelowMinimum();
    }

    function _validateDeposit(uint256 depositAmount) private pure {
        if (depositAmount == 0) revert Prototype__DepositAmountIsZero();
    }

    function _validatePurchaseAmount(address token, uint256 purchaseAmount, uint256 tokenBalance) private view {
        uint256 minPurchaseAmount = s_tokenMinPurchaseAmounts[token];
        if (minPurchaseAmount == 0) minPurchaseAmount = s_protocolSettings.defaultMinPurchaseAmount;
        if (purchaseAmount < minPurchaseAmount) revert Prototype__PurchaseAmountBelowMinimum();
        if (purchaseAmount > tokenBalance) revert Prototype__PurchaseAmountExceedsBalance();
    }
}
