// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";

/**
 * @title NestedIndexedDcaManager
 * @notice Design B of the R64 measurement: the schedule keying `DcaManager` had before R64 —
 *         `s_dcaSchedules[user][token][index]`, with a batch row carrying buyer, index, id and amount.
 * @dev Test-only. Never deployed, never imported by `src/`. This is the design the benchmark measures
 *      against, so it is a faithful copy of the paths under test rather than a sketch: the same
 *      two-slot struct, the same checks in the same order, the same two events per row, the same
 *      handler call. The paths R64 does not measure (deposits, withdrawals, interest, owner setters)
 *      are absent rather than approximated; adding them could only mislead a reader into treating
 *      this as a fork of `DcaManager`.
 *
 *      Keeping it after the change is what lets the branch show its own before-and-after under one
 *      harness. Its create and delete are asserted against `DcaManager`'s pre-R64 figures, so a
 *      prototype that drifts from the design it claims to reproduce fails the run.
 */
contract NestedIndexedDcaManager is ReentrancyGuard {
    using SafeCast for uint256;

    /// @notice The pre-R64 schedule: two slots, with the owner and stablecoin held in the mapping key.
    struct NestedSchedule {
        uint128 tokenBalance;
        uint48 lastPurchaseTimestamp;
        bool paused;
        uint128 purchaseAmount;
        uint32 purchasePeriod;
        uint32 routeIndex;
        uint64 scheduleId;
    }

    /// @notice The pre-R64 batch: four parallel arrays, one row each.
    struct Batch {
        address[] buyers;
        address token;
        uint256[] scheduleIndexes;
        uint64[] scheduleIds;
        uint256[] purchaseAmounts;
        uint256 routeIndex;
        uint256 minRbtcOut;
    }

    OperationsAdmin private immutable i_operationsAdmin;

    mapping(address user => mapping(address tokenDeposited => NestedSchedule[])) private s_dcaSchedules;
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

    error Prototype__InexistentScheduleIndex();
    error Prototype__ScheduleIdAndIndexMismatch();
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

    modifier validateScheduleIndex(address user, address token, uint256 scheduleIndex) {
        if (scheduleIndex >= s_dcaSchedules[user][token].length) revert Prototype__InexistentScheduleIndex();
        _;
    }

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
        uint128 purchase = purchaseAmount.toUint128();
        uint32 period = purchasePeriod.toUint32();
        uint32 route = routeIndex.toUint32();

        IDcaManager.ProtocolSettings memory settings = s_protocolSettings;
        uint64 scheduleId = (uint256(settings.scheduleNonce) + 1).toUint64();

        _validatePurchasePeriod(purchasePeriod);
        _validateDeposit(depositAmount);
        _handlerForDeposit(token, route).depositToken(msg.sender, depositAmount);
        _validatePurchaseAmount(token, purchaseAmount, depositAmount);

        NestedSchedule[] storage schedules = s_dcaSchedules[msg.sender][token];
        if (schedules.length >= settings.maxSchedulesPerToken) revert Prototype__MaxSchedulesReached();

        s_protocolSettings.scheduleNonce = scheduleId;

        schedules.push(
            NestedSchedule({
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
            msg.sender, token, scheduleId, depositAmount, purchaseAmount, purchasePeriod, routeIndex
        );
    }

    function deleteDcaSchedule(address token, uint256 scheduleIndex, uint64 scheduleId)
        external
        nonReentrant
        validateScheduleIndex(msg.sender, token, scheduleIndex)
    {
        NestedSchedule[] storage schedules = s_dcaSchedules[msg.sender][token];
        NestedSchedule memory dcaSchedule = schedules[scheduleIndex];
        if (scheduleId != dcaSchedule.scheduleId) revert Prototype__ScheduleIdAndIndexMismatch();

        uint256 tokenBalance = dcaSchedule.tokenBalance;
        uint256 routeIndex = dcaSchedule.routeIndex;

        uint256 lastIndex = schedules.length - 1;
        if (scheduleIndex != lastIndex) schedules[scheduleIndex] = schedules[lastIndex];
        schedules.pop();

        uint256 amountWithdrawn;
        if (tokenBalance > 0) amountWithdrawn = _handler(token, routeIndex).withdrawToken(msg.sender, tokenBalance);

        emit DcaManager__DcaScheduleDeleted(msg.sender, token, scheduleId, amountWithdrawn);
    }

    function batchBuyRbtc(Batch calldata batch) external onlySwapper {
        uint256 numOfPurchases = batch.buyers.length;
        if (numOfPurchases == 0) revert Prototype__EmptyBatch();
        if (
            numOfPurchases != batch.scheduleIndexes.length || numOfPurchases != batch.scheduleIds.length
                || numOfPurchases != batch.purchaseAmounts.length
        ) revert Prototype__ArraysLengthMismatch();
        for (uint256 i; i < numOfPurchases; ++i) {
            (uint256 schedulePurchaseAmount, uint256 scheduleRouteIndex) = _rBtcPurchaseChecksEffects(
                batch.buyers[i], batch.token, batch.scheduleIndexes[i], batch.scheduleIds[i]
            );
            if (schedulePurchaseAmount != batch.purchaseAmounts[i]) revert Prototype__PurchaseAmountMismatch();
            if (scheduleRouteIndex != batch.routeIndex) revert Prototype__RouteIndexMismatch();
        }
        IPurchaseRbtc(address(_handler(batch.token, batch.routeIndex))).batchBuyRbtc(
            batch.buyers, batch.scheduleIds, batch.purchaseAmounts, batch.minRbtcOut
        );
    }

    /// @dev The counterpart of `DcaManager.getSchedulesCreatedCount`, so a benchmark can warm the
    ///      packed-settings slot on all three designs alike before it measures a create.
    function getSchedulesCreatedCount() external view returns (uint256) {
        return s_protocolSettings.scheduleNonce;
    }

    function getDcaSchedules(address user, address token) external view returns (NestedSchedule[] memory) {
        return s_dcaSchedules[user][token];
    }

    /// @dev `DcaManager` resolves a deposit's handler through the governance deposit-pause check;
    ///      reproduced so a create measured here pays the same registry reads.
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

    function _rBtcPurchaseChecksEffects(address buyer, address token, uint256 scheduleIndex, uint64 scheduleId)
        private
        validateScheduleIndex(buyer, token, scheduleIndex)
        returns (uint256, uint256)
    {
        NestedSchedule storage dcaScheduleStorage = s_dcaSchedules[buyer][token][scheduleIndex];
        NestedSchedule memory dcaSchedule = dcaScheduleStorage;

        if (scheduleId != dcaSchedule.scheduleId) revert Prototype__ScheduleIdAndIndexMismatch();
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

    /// @dev The create-path validations `DcaManager` runs, reproduced so the cold-path comparison is
    ///      between two keying designs and not between a real contract and a thinner one.
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
