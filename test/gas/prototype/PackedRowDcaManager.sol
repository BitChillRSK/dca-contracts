// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";

/**
 * @title PackedRowDcaManager
 * @notice Design H: design G's key, with the batch row packed into one word instead of two arrays.
 * @dev Test-only. Never deployed, never imported by `src/`. Storage, checks, effects and events are
 *      byte-for-byte design G's; only the batch encoding differs.
 *
 *      G has to name the buyer per row, because the owner is half the key. Encoded as a second array
 *      that costs a full 32-byte word per row on top of the id's. But an id is 8 bytes and an address
 *      is 20, so the pair fits in one word with four to spare: `row = (id << 160) | buyer`. The row
 *      count halves, and G's calldata drops to E's.
 *
 *      What it costs is legibility on the path that matters most. A swapper composes rows by shifting
 *      rather than by naming fields, a reviewer decodes them by hand, and a wrong shift is a valid word
 *      addressing a different schedule. Priced here so that trade is made on a number rather than on a
 *      hunch.
 */
contract PackedRowDcaManager is ReentrancyGuard {
    using SafeCast for uint256;

    /**
     * @notice Two slots, and no identity in either: id, owner and stablecoin are all the key.
     * @dev Slot 0 is every field a purchase reads or writes, so a purchase writes one slot. Slot 1
     *      holds `purchaseAmount` alone, at full `uint128` width, because there is no address left in
     *      the struct to share a slot with it.
     *
     *      With no address field there is no `address(0)` sentinel either. `purchasePeriod` is the
     *      existence flag: it is validated at or above one day on every path that writes it, so a live
     *      schedule can never carry zero and a missing one always does.
     */
    struct Schedule {
        uint128 tokenBalance;
        uint48 lastPurchaseTimestamp;
        bool paused;
        uint32 purchasePeriod;
        uint32 routeIndex;
        uint128 purchaseAmount;
    }

    /// @notice A row is `(scheduleId << 160) | buyer` in one word; the batch's `token` completes the key.
    struct Batch {
        bytes32[] rows;
        address token;
        uint256 routeIndex;
        uint256 minRbtcOut;
    }

    OperationsAdmin private immutable i_operationsAdmin;

    mapping(uint64 scheduleId => mapping(address user => mapping(address token => Schedule))) private s_dcaSchedules;
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
    error Prototype__RouteIndexMismatch();
    error Prototype__MaxSchedulesReached();
    error Prototype__EmptyBatch();
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
        uint128 purchase = purchaseAmount.toUint128();
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

        s_dcaSchedules[scheduleId][msg.sender][token] = Schedule({
            tokenBalance: deposit,
            lastPurchaseTimestamp: 0,
            paused: false,
            purchasePeriod: period,
            routeIndex: route,
            purchaseAmount: purchase
        });
        scheduleIds.push(scheduleId);

        emit DcaManager__DcaScheduleCreated(
            msg.sender, token, scheduleId, depositAmount, purchaseAmount, purchasePeriod, routeIndex
        );
    }

    /// @dev The token completes the key, so the caller supplies it. There is no ownership check:
    ///      `msg.sender` is the other half of the key, so an id the caller does not hold reads empty.
    function deleteDcaSchedule(address token, uint64 scheduleId) external nonReentrant {
        Schedule memory dcaSchedule = s_dcaSchedules[scheduleId][msg.sender][token];
        if (dcaSchedule.purchasePeriod == 0) revert Prototype__InexistentSchedule();

        _removeScheduleId(msg.sender, token, scheduleId);
        delete s_dcaSchedules[scheduleId][msg.sender][token];

        uint256 amountWithdrawn;
        if (dcaSchedule.tokenBalance > 0) {
            amountWithdrawn =
                _handler(token, dcaSchedule.routeIndex).withdrawToken(msg.sender, dcaSchedule.tokenBalance);
        }

        emit DcaManager__DcaScheduleDeleted(msg.sender, token, scheduleId, amountWithdrawn);
    }

    function batchBuyRbtc(Batch calldata batch) external onlySwapper {
        uint256 numOfPurchases = batch.rows.length;
        if (numOfPurchases == 0) revert Prototype__EmptyBatch();
        address[] memory buyers = new address[](numOfPurchases);
        uint64[] memory scheduleIds = new uint64[](numOfPurchases);
        uint256[] memory purchaseAmounts = new uint256[](numOfPurchases);
        for (uint256 i; i < numOfPurchases; ++i) {
            uint256 row = uint256(batch.rows[i]);
            uint64 scheduleId = uint64(row >> 160);
            address buyer = address(uint160(row));
            (uint256 schedulePurchaseAmount, uint256 scheduleRouteIndex) =
                _rBtcPurchaseChecksEffects(scheduleId, buyer, batch.token);
            if (scheduleRouteIndex != batch.routeIndex) revert Prototype__RouteIndexMismatch();
            buyers[i] = buyer;
            scheduleIds[i] = scheduleId;
            purchaseAmounts[i] = schedulePurchaseAmount;
        }
        IPurchaseRbtc(address(_handler(batch.token, batch.routeIndex))).batchBuyRbtc(
            buyers, scheduleIds, purchaseAmounts, batch.minRbtcOut
        );
    }

    function getSchedule(uint64 scheduleId, address user, address token) external view returns (Schedule memory) {
        return s_dcaSchedules[scheduleId][user][token];
    }

    function getScheduleIds(address user, address token) external view returns (uint64[] memory) {
        return s_scheduleIds[user][token];
    }

    function getSchedulesCreatedCount() external view returns (uint256) {
        return s_protocolSettings.scheduleNonce;
    }

    /**
     * @dev Existence, ownership and the token check are all the lookup: a row naming another account's
     *      schedule, or a schedule of another stablecoin, lands on an empty struct.
     */
    function _rBtcPurchaseChecksEffects(uint64 scheduleId, address buyer, address token)
        private
        returns (uint256, uint256)
    {
        Schedule storage dcaScheduleStorage = s_dcaSchedules[scheduleId][buyer][token];
        Schedule memory dcaSchedule = dcaScheduleStorage;

        uint256 purchasePeriod = dcaSchedule.purchasePeriod;
        if (purchasePeriod == 0) revert Prototype__InexistentSchedule();
        if (dcaSchedule.paused) revert Prototype__SchedulePaused();

        uint256 lastPurchaseTimestamp = dcaSchedule.lastPurchaseTimestamp;

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
