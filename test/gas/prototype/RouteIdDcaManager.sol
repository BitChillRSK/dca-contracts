// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {RouteIdRegistry} from "./RouteIdRegistry.sol";

/**
 * @title RouteIdDcaManager
 * @notice Design F: `mapping(uint64 scheduleId => Schedule)`, where the schedule carries a four-byte
 *         `routeId` instead of a twenty-byte token address, so a flat key still fits two slots.
 * @dev Test-only. Never deployed, never imported by `src/`. Same checks, effects and events as the
 *      shipped manager; only the key, the packing and the route reference differ.
 *
 *      The token address is what made design C cost a third slot, not the flat key. `(token, routeIndex)`
 *      is already an add-only, assign-once pair in `OperationsAdmin`, so naming it with a `uint32` loses
 *      no information and weakens no guarantee. Replace the address with that name and the schedule is
 *      two slots again, an id addresses a schedule on its own, and a batch row is one `uint64`.
 *
 *      The user-facing API is unchanged: `createDcaSchedule` still takes `(token, routeIndex)` and
 *      resolves the id once, on the cold path. Compact in storage, legible at the surface.
 */
contract RouteIdDcaManager is ReentrancyGuard {
    using SafeCast for uint256;

    /**
     * @notice Two slots, grouped by how a purchase touches them.
     * @dev Slot 0 is read on every purchase and written by none of them. Slot 1 holds every field a
     *      purchase reads or writes, so a purchase is two cold `SLOAD`s and one `SSTORE`. Neither the
     *      id nor the token is repeated: the id is the key, and the token is reachable through
     *      `routeId`. A live schedule always has a non-zero `user`, which is the existence sentinel.
     */
    struct Schedule {
        address user;
        uint96 purchaseAmount;
        uint128 tokenBalance;
        uint48 lastPurchaseTimestamp;
        uint32 purchasePeriod;
        uint32 routeId;
        bool paused;
    }

    /// @notice A row is one `uint64`. Everything else a batch needs it carries once.
    struct Batch {
        uint64[] scheduleIds;
        uint32 routeId;
        uint256 minRbtcOut;
    }

    RouteIdRegistry private immutable i_registry;

    mapping(uint64 scheduleId => Schedule) private s_dcaSchedules;
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
    error Prototype__RouteIdMismatch();
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
        if (!i_registry.isSwapper(msg.sender)) revert Prototype__UnauthorizedSwapper();
        _;
    }

    constructor(
        address registryAddress,
        uint256 minPurchasePeriod,
        uint256 maxSchedulesPerToken,
        uint256 defaultMinPurchaseAmount
    ) {
        i_registry = RouteIdRegistry(registryAddress);
        s_protocolSettings = IDcaManager.ProtocolSettings({
            minPurchasePeriod: minPurchasePeriod.toUint32(),
            maxSchedulesPerToken: maxSchedulesPerToken.toUint16(),
            defaultMinPurchaseAmount: defaultMinPurchaseAmount.toUint128(),
            scheduleNonce: 0
        });
    }

    /// @dev The pair is resolved to its compact id once, here, on the path the user already pays for.
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

        uint32 routeId = i_registry.getRouteId(token, routeIndex);
        if (routeId == 0) revert Prototype__TokenNotAccepted();

        IDcaManager.ProtocolSettings memory settings = s_protocolSettings;
        uint64 scheduleId = (uint256(settings.scheduleNonce) + 1).toUint64();

        _validatePurchasePeriod(purchasePeriod);
        _validateDeposit(depositAmount);
        _handlerForDeposit(routeId).depositToken(msg.sender, depositAmount);
        _validatePurchaseAmount(token, purchaseAmount, depositAmount);

        uint64[] storage scheduleIds = s_scheduleIds[msg.sender][token];
        if (scheduleIds.length >= settings.maxSchedulesPerToken) revert Prototype__MaxSchedulesReached();

        s_protocolSettings.scheduleNonce = scheduleId;

        s_dcaSchedules[scheduleId] = Schedule({
            user: msg.sender,
            purchaseAmount: purchase,
            tokenBalance: deposit,
            lastPurchaseTimestamp: 0,
            purchasePeriod: period,
            routeId: routeId,
            paused: false
        });
        scheduleIds.push(scheduleId);

        emit DcaManager__DcaScheduleCreated(
            msg.sender, token, scheduleId, depositAmount, purchaseAmount, purchasePeriod, routeIndex
        );
    }

    /// @dev The id addresses the schedule on its own; the token is reached through the route it names.
    function deleteDcaSchedule(uint64 scheduleId) external nonReentrant {
        Schedule memory dcaSchedule = s_dcaSchedules[scheduleId];
        if (dcaSchedule.user == address(0)) revert Prototype__InexistentSchedule();
        if (dcaSchedule.user != msg.sender) revert Prototype__NotScheduleOwner();

        (address token,) = i_registry.getRoute(dcaSchedule.routeId);
        _removeScheduleId(msg.sender, token, scheduleId);
        delete s_dcaSchedules[scheduleId];

        uint256 amountWithdrawn;
        if (dcaSchedule.tokenBalance > 0) {
            amountWithdrawn = _handler(dcaSchedule.routeId).withdrawToken(msg.sender, dcaSchedule.tokenBalance);
        }

        emit DcaManager__DcaScheduleDeleted(msg.sender, token, scheduleId, amountWithdrawn);
    }

    function batchBuyRbtc(Batch calldata batch) external onlySwapper {
        uint256 numOfPurchases = batch.scheduleIds.length;
        if (numOfPurchases == 0) revert Prototype__EmptyBatch();
        (address handler, address token) = i_registry.getHandlerAndToken(batch.routeId);
        if (handler == address(0)) revert Prototype__TokenNotAccepted();
        address[] memory buyers = new address[](numOfPurchases);
        uint256[] memory purchaseAmounts = new uint256[](numOfPurchases);
        for (uint256 i; i < numOfPurchases; ++i) {
            (address buyer, uint256 schedulePurchaseAmount) =
                _rBtcPurchaseChecksEffects(batch.scheduleIds[i], batch.routeId, token);
            buyers[i] = buyer;
            purchaseAmounts[i] = schedulePurchaseAmount;
        }
        IPurchaseRbtc(handler).batchBuyRbtc(buyers, batch.scheduleIds, purchaseAmounts, batch.minRbtcOut);
    }

    function getSchedule(uint64 scheduleId) external view returns (Schedule memory) {
        return s_dcaSchedules[scheduleId];
    }

    function getScheduleIds(address user, address token) external view returns (uint64[] memory) {
        return s_scheduleIds[user][token];
    }

    function getSchedulesCreatedCount() external view returns (uint256) {
        return s_protocolSettings.scheduleNonce;
    }

    /**
     * @dev The route comparison replaces both the token check and the route check the shipped manager
     *      makes: one `uint32` equality proves the row belongs to the handler this batch is paying,
     *      because a `routeId` names the pair rather than either half of it.
     */
    function _rBtcPurchaseChecksEffects(uint64 scheduleId, uint32 batchRouteId, address token)
        private
        returns (address, uint256)
    {
        Schedule storage dcaScheduleStorage = s_dcaSchedules[scheduleId];
        Schedule memory dcaSchedule = dcaScheduleStorage;

        address buyer = dcaSchedule.user;
        if (buyer == address(0)) revert Prototype__InexistentSchedule();
        if (dcaSchedule.routeId != batchRouteId) revert Prototype__RouteIdMismatch();
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

        return (buyer, dcaSchedule.purchaseAmount);
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

    function _handlerForDeposit(uint32 routeId) private view returns (ITokenHandler) {
        ITokenHandler tokenHandler = _handler(routeId);
        if (i_registry.areDepositsPaused(routeId)) revert Prototype__DepositsPaused();
        return tokenHandler;
    }

    function _handler(uint32 routeId) private view returns (ITokenHandler) {
        address tokenHandlerAddress = i_registry.getHandler(routeId);
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
