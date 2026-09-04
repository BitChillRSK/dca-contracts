// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";

/**
 * @title TokenKeyedDcaManager
 * @notice Design E: `mapping(uint64 scheduleId => mapping(address token => Schedule))`, so the
 *         stablecoin moves into the key and the schedule fits two slots again.
 * @dev Test-only. Never deployed, never imported by `src/`. Same checks, effects and events as the
 *      shipped manager; only the key and the packing differ.
 *
 *      The point of keying on the token rather than the owner is that a batch already carries one
 *      `token` for all its rows, so the second key costs the purchase path no calldata at all: a row
 *      stays a single `uint64` and the manager reads the owner from storage exactly as the shipped
 *      design does. The token check also becomes structural — a row naming a schedule of another
 *      stablecoin lands on an empty struct rather than being caught by a comparison.
 *
 *      What it costs sits on the user's side: the stablecoin is no longer derivable from the id alone,
 *      so every schedule mutator takes it back as an argument, and ownership stays an explicit check
 *      rather than becoming structural.
 */
contract TokenKeyedDcaManager is ReentrancyGuard {
    using SafeCast for uint256;

    /// @notice Two slots: the stablecoin is the key, so only the owner has to be carried.
    struct Schedule {
        uint128 tokenBalance;
        uint48 lastPurchaseTimestamp;
        bool paused;
        uint32 purchasePeriod;
        uint32 routeIndex;
        address user;
        uint96 purchaseAmount;
    }

    /// @notice A row is one id; the batch's `token` completes the key for every row at once.
    struct Batch {
        uint64[] scheduleIds;
        uint256[] purchaseAmounts;
        address token;
        uint256 routeIndex;
        uint256 minRbtcOut;
    }

    OperationsAdmin private immutable i_operationsAdmin;

    mapping(uint64 scheduleId => mapping(address token => Schedule)) private s_dcaSchedules;
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
    error Prototype__NotScheduleOwner();
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

        s_dcaSchedules[scheduleId][token] = Schedule({
            tokenBalance: deposit,
            lastPurchaseTimestamp: 0,
            paused: false,
            purchasePeriod: period,
            routeIndex: route,
            user: msg.sender,
            purchaseAmount: purchase
        });
        scheduleIds.push(scheduleId);

        emit DcaManager__DcaScheduleCreated(
            msg.sender, token, scheduleId, depositAmount, purchaseAmount, purchasePeriod, routeIndex
        );
    }

    /// @dev The token completes the key, so the caller supplies it; ownership is still a check.
    function deleteDcaSchedule(address token, uint64 scheduleId) external nonReentrant {
        Schedule memory dcaSchedule = s_dcaSchedules[scheduleId][token];
        if (dcaSchedule.user == address(0)) revert Prototype__InexistentSchedule();
        if (dcaSchedule.user != msg.sender) revert Prototype__NotScheduleOwner();

        _removeScheduleId(msg.sender, token, scheduleId);
        delete s_dcaSchedules[scheduleId][token];

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
        if (numOfPurchases != batch.purchaseAmounts.length) revert Prototype__ArraysLengthMismatch();
        address[] memory buyers = new address[](numOfPurchases);
        for (uint256 i; i < numOfPurchases; ++i) {
            (address buyer, uint256 schedulePurchaseAmount, uint256 scheduleRouteIndex) =
                _rBtcPurchaseChecksEffects(batch.scheduleIds[i], batch.token);
            if (schedulePurchaseAmount != batch.purchaseAmounts[i]) revert Prototype__PurchaseAmountMismatch();
            if (scheduleRouteIndex != batch.routeIndex) revert Prototype__RouteIndexMismatch();
            buyers[i] = buyer;
        }
        IPurchaseRbtc(address(_handler(batch.token, batch.routeIndex))).batchBuyRbtc(
            buyers, batch.scheduleIds, batch.purchaseAmounts, batch.minRbtcOut
        );
    }

    function getSchedule(uint64 scheduleId, address token) external view returns (Schedule memory) {
        return s_dcaSchedules[scheduleId][token];
    }

    function getScheduleIds(address user, address token) external view returns (uint64[] memory) {
        return s_scheduleIds[user][token];
    }

    function getSchedulesCreatedCount() external view returns (uint256) {
        return s_protocolSettings.scheduleNonce;
    }

    /**
     * @dev Existence and the token check are one comparison: a row naming a schedule of another
     *      stablecoin lands on an empty struct, whose `user` is `address(0)`.
     */
    function _rBtcPurchaseChecksEffects(uint64 scheduleId, address token)
        private
        returns (address, uint256, uint256)
    {
        Schedule storage dcaScheduleStorage = s_dcaSchedules[scheduleId][token];
        Schedule memory dcaSchedule = dcaScheduleStorage;

        address buyer = dcaSchedule.user;
        if (buyer == address(0)) revert Prototype__InexistentSchedule();
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

        return (buyer, dcaSchedule.purchaseAmount, dcaSchedule.routeIndex);
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
