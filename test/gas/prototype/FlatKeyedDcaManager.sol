// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";

/**
 * @title FlatKeyedDcaManager
 * @notice Design C of the R64 measurement: schedules keyed by id alone, so a batch row is one `uint64`.
 * @dev Test-only. Never deployed, never imported by `src/`. Same checks, same effects and the same two
 *      events per row as `DcaManager`; only the addressing changes. Two consequences follow from the
 *      key, and both are measured rather than argued:
 *
 *      1. The owner and the token move into the struct, since a flat key no longer carries them. The
 *         packing below is the cheapest one that still writes a single slot per purchase: slot 0 holds
 *         everything a purchase touches, so `tokenBalance` and `lastPurchaseTimestamp` stay on one
 *         `SSTORE` as they do today. Paying for that costs `purchaseAmount` 32 bits of width — `uint96`
 *         caps a single purchase at ~7.9e10 tokens at 18 decimals. Keeping `uint128` would push the
 *         purchase's two writes onto separate slots, which loses more than the calldata saves; a fourth
 *         slot loses outright. Three slots is the floor either way, against today's exact two.
 *      2. Enumeration needs its own structure. `getDcaSchedules` and the max-schedules bound both need
 *         a per-(user, token) list, so create and delete each write two structures instead of one.
 *         Those are the cold-path regressions the hot-path saving has to pay for.
 */
contract FlatKeyedDcaManager is ReentrancyGuard {
    using SafeCast for uint256;

    /// @notice One schedule, addressed by id alone.
    /// @dev Three slots. Slot 0 is every field a purchase reads or writes; slot 1 and 2 carry the
    ///      identity the nested key used to give away for free.
    struct FlatSchedule {
        uint128 tokenBalance;
        uint48 lastPurchaseTimestamp;
        bool paused;
        uint32 purchasePeriod;
        uint32 routeIndex;
        address user;
        uint96 purchaseAmount;
        address token;
    }

    /// @notice One handler's purchase batch: one id per row, and no index, buyer or amount beside it.
    struct Batch {
        uint64[] scheduleIds;
        address token;
        uint256 routeIndex;
        uint256 minRbtcOut;
    }

    OperationsAdmin private immutable i_operationsAdmin;

    mapping(uint64 scheduleId => FlatSchedule) private s_dcaSchedules;
    /// @dev The parallel structure a flat key forces: what `getDcaSchedules` and the per-token bound read.
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
    error Prototype__RouteIndexMismatch();
    error Prototype__TokenMismatch();
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

        s_dcaSchedules[scheduleId] = FlatSchedule({
            tokenBalance: deposit,
            lastPurchaseTimestamp: 0,
            paused: false,
            purchasePeriod: period,
            routeIndex: route,
            user: msg.sender,
            purchaseAmount: purchase,
            token: token
        });
        scheduleIds.push(scheduleId);

        emit DcaManager__DcaScheduleCreated(
            msg.sender, token, scheduleId, depositAmount, purchaseAmount, purchasePeriod, routeIndex
        );
    }

    /**
     * @dev Deletes both structures: the schedule itself and the id's position in its owner's list.
     *      Finding that position is a linear scan, bounded by the max-schedules-per-token setting.
     */
    function deleteDcaSchedule(uint64 scheduleId) external nonReentrant {
        FlatSchedule memory dcaSchedule = s_dcaSchedules[scheduleId];
        if (dcaSchedule.user == address(0)) revert Prototype__InexistentSchedule();
        if (dcaSchedule.user != msg.sender) revert Prototype__NotScheduleOwner();

        uint64[] storage scheduleIds = s_scheduleIds[msg.sender][dcaSchedule.token];
        uint256 numOfSchedules = scheduleIds.length;
        uint256 lastIndex = numOfSchedules - 1;
        for (uint256 i; i < numOfSchedules; ++i) {
            if (scheduleIds[i] == scheduleId) {
                if (i != lastIndex) scheduleIds[i] = scheduleIds[lastIndex];
                break;
            }
        }
        scheduleIds.pop();
        delete s_dcaSchedules[scheduleId];

        uint256 amountWithdrawn;
        if (dcaSchedule.tokenBalance > 0) {
            amountWithdrawn =
                _handler(dcaSchedule.token, dcaSchedule.routeIndex).withdrawToken(msg.sender, dcaSchedule.tokenBalance);
        }

        emit DcaManager__DcaScheduleDeleted(msg.sender, dcaSchedule.token, scheduleId, amountWithdrawn);
    }

    /**
     * @dev The buyer list the handler takes is built from storage, since the batch no longer carries it.
     */
    function batchBuyRbtc(Batch calldata batch) external onlySwapper {
        uint256 numOfPurchases = batch.scheduleIds.length;
        if (numOfPurchases == 0) revert Prototype__EmptyBatch();

        address[] memory buyers = new address[](numOfPurchases);
        uint256[] memory purchaseAmounts = new uint256[](numOfPurchases);
        for (uint256 i; i < numOfPurchases; ++i) {
            (address buyer, uint256 purchaseAmount) =
                _rBtcPurchaseChecksEffects(batch.scheduleIds[i], batch.token, batch.routeIndex);
            buyers[i] = buyer;
            purchaseAmounts[i] = purchaseAmount;
        }
        IPurchaseRbtc(address(_handler(batch.token, batch.routeIndex))).batchBuyRbtc(
            buyers, batch.scheduleIds, purchaseAmounts, batch.minRbtcOut
        );
    }

    /// @dev One `SLOAD` per id for the list, then three per schedule; the nested design reads a
    ///      contiguous array instead. A `view` a front end reaches by `eth_call`, so this costs a node
    ///      rather than a user — measured for completeness, not as an argument.
    function getDcaSchedules(address user, address token) external view returns (FlatSchedule[] memory) {
        uint64[] storage scheduleIds = s_scheduleIds[user][token];
        uint256 numOfSchedules = scheduleIds.length;
        FlatSchedule[] memory schedules = new FlatSchedule[](numOfSchedules);
        for (uint256 i; i < numOfSchedules; ++i) {
            schedules[i] = s_dcaSchedules[scheduleIds[i]];
        }
        return schedules;
    }

    function getSchedule(uint64 scheduleId) external view returns (FlatSchedule memory) {
        return s_dcaSchedules[scheduleId];
    }

    /// @dev The last id handed out, so a caller that just created a schedule knows its key.
    function getSchedulesCreatedCount() external view returns (uint256) {
        return s_protocolSettings.scheduleNonce;
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

    /**
     * @dev The id is the whole row, so the pair the nested design carries in its key has to be read and
     *      checked here: a row naming another token or route would otherwise be debited by a handler
     *      that never holds its funds.
     */
    function _rBtcPurchaseChecksEffects(uint64 scheduleId, address token, uint256 routeIndex)
        private
        returns (address, uint256)
    {
        FlatSchedule storage dcaScheduleStorage = s_dcaSchedules[scheduleId];
        FlatSchedule memory dcaSchedule = dcaScheduleStorage;

        if (dcaSchedule.user == address(0)) revert Prototype__InexistentSchedule();
        if (dcaSchedule.token != token) revert Prototype__TokenMismatch();
        if (dcaSchedule.routeIndex != routeIndex) revert Prototype__RouteIndexMismatch();
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

        return (dcaSchedule.user, dcaSchedule.purchaseAmount);
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
