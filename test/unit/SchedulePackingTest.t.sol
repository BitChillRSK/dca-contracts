// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IFeeHandler} from "../../src/interfaces/IFeeHandler.sol";
import {IdleDocHandlerMoc} from "../../src/idle/IdleDocHandlerMoc.sol";
import {MockMocProxy} from "../mocks/MockMocProxy.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./TestsHelper.t.sol";
import {scheduleAt, scheduleIdAt, scheduleCount} from "test/utils/ScheduleAt.sol";

/**
 * @notice R18 + R50 + R64: each stored schedule occupies two slots with checked widths, and the
 *         protocol scalars plus the id nonce share one slot of their own.
 * @dev External arguments stay `uint256`, except `scheduleId`, which is the `uint64` creation nonce.
 *      Overflow reverts with OZ `SafeCast` data before cash or schedule state changes. A schedule is
 *      keyed by `(token, scheduleId)`, so neither key is duplicated in the value. Slot 0 holds every
 *      field a purchase touches, keeping a purchase to one `SSTORE`; slot 1 holds the owner and the
 *      purchase amount. Deleting a schedule swap-pops its owner's id list and never moves another
 *      schedule's value.
 */
contract SchedulePackingTest is DcaDappTest {
    uint256 private constant SCHEDULES_MAPPING_SLOT = 2;
    uint256 private constant PROTOCOL_SETTINGS_SLOT = 4;

    function setUp() public override {
        super.setUp();
    }

    function _safeCastOverflow(uint8 bits, uint256 value) private pure returns (bytes memory) {
        return abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, bits, value);
    }

    /// @dev `s_dcaSchedules[token][scheduleId]`: the stablecoin picks the inner mapping, the id the value.
    function _scheduleBase(address token, uint64 scheduleId) private pure returns (uint256) {
        bytes32 inner = keccak256(abi.encode(token, SCHEDULES_MAPPING_SLOT));
        return uint256(keccak256(abi.encode(scheduleId, inner)));
    }

    function _load(uint256 slot) private view returns (uint256) {
        return uint256(vm.load(address(dcaManager), bytes32(slot)));
    }

    function _assertPackedAgainstGetter(uint256 scheduleIndex) private {
        IDcaManager.DcaSchedule memory schedule =
            scheduleAt(dcaManager, USER, address(stablecoin), scheduleIndex);
        uint256 base =
            _scheduleBase(address(stablecoin), scheduleIdAt(dcaManager, USER, address(stablecoin), scheduleIndex));

        // Slot 0 is every field a purchase reads or writes, so the whole update is one SSTORE.
        uint256 slot0 = uint256(uint128(schedule.tokenBalance))
            | (uint256(uint48(schedule.lastPurchaseTimestamp)) << 128) | (uint256(schedule.paused ? 1 : 0) << 176)
            | (uint256(uint32(schedule.purchasePeriod)) << 184) | (uint256(uint32(schedule.routeIndex)) << 216);
        // Slot 1 pairs the owner with the purchase amount, which is `uint96` so that the pair fits.
        uint256 slot1 = uint256(uint160(schedule.user)) | (uint256(uint96(schedule.purchaseAmount)) << 160);

        assertEq(_load(base), slot0, "slot 0 is not tokenBalance|timestamp|paused|period|route");
        assertEq(_load(base + 1), slot1, "slot 1 is not user|purchaseAmount");
        // Neither half of the key is repeated in storage, so nothing follows.
        assertEq(_load(base + 2), 0, "a third slot was written");
    }

    /*//////////////////////////////////////////////////////////////
                              LAYOUT
    //////////////////////////////////////////////////////////////*/

    function testOneScheduleOccupiesExactlyTwoSlots() external {
        assertEq(scheduleCount(dcaManager, USER, address(stablecoin)), 1);
        _assertPackedAgainstGetter(SCHEDULE_INDEX);

        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(
            _load(_scheduleBase(address(stablecoin), scheduleId) + 2), 0, "a third slot was written for one schedule"
        );
    }

    /// @dev The stablecoin is half the key, so the same id under another one is untouched storage.
    ///      This is what makes a batch row of the wrong stablecoin address nothing at all.
    function testAnIdUnderAnotherStablecoinIsEmptyStorage() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 otherTokenBase = _scheduleBase(makeAddr("packingStablecoin"), scheduleId);

        assertEq(_load(otherTokenBase), 0, "another stablecoin's key is not empty");
        assertEq(_load(otherTokenBase + 1), 0, "another stablecoin's key is not empty");
    }

    function testProtocolScalarsAndNonceShareOneSlot() external {
        uint256 packed = _load(PROTOCOL_SETTINGS_SLOT);
        uint256 expected = dcaManager.getMinPurchasePeriod() | (dcaManager.getMaxSchedulesPerToken() << 32)
            | (dcaManager.getDefaultMinPurchaseAmount() << 48) | (dcaManager.getSchedulesCreatedCount() << 176);

        assertEq(packed, expected, "protocol scalars and the nonce are not one packed slot");
        // The token-specific minimums keep their own mapping root, one slot further down.
        assertEq(_load(PROTOCOL_SETTINGS_SLOT + 1), 0, "the scalars spilled into the mapping slot");
    }

    function testMaxWidthsPackIntoTwoSlots() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);

        vm.startPrank(USER);
        dcaManager.updatePurchasePeriod(address(stablecoin), scheduleId, type(uint32).max);
        vm.stopPrank();

        vm.warp(type(uint48).max);
        super.buyRbtcOne(scheduleId);

        vm.prank(USER);
        dcaManager.setSchedulePaused(address(stablecoin), scheduleId, true);

        IDcaManager.DcaSchedule memory schedule =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(schedule.purchasePeriod, type(uint32).max);
        assertEq(schedule.lastPurchaseTimestamp, type(uint48).max);
        assertTrue(schedule.paused);
        _assertPackedAgainstGetter(SCHEDULE_INDEX);
    }

    /*//////////////////////////////////////////////////////////////
                         WIDTH BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    /// @dev The balance keeps `uint128`; only the periodic amount narrowed, so the widest schedule a
    ///      user can create is a `uint128` balance spending `uint96` at a time.
    function testCreateAcceptsMaxWidthAmounts() external {
        if (block.chainid != ANVIL_CHAIN_ID) return; // live DOC has no public mint for this size

        uint256 maxDeposit = type(uint128).max;
        uint256 maxPurchase = type(uint96).max;
        stablecoin.mint(USER, maxDeposit);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), maxDeposit);
        dcaManager.createDcaSchedule(
            address(stablecoin), maxDeposit, maxPurchase, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();

        IDcaManager.DcaSchedule memory schedule = scheduleAt(dcaManager, USER, address(stablecoin), 1);
        assertEq(schedule.tokenBalance, maxDeposit);
        assertEq(schedule.purchaseAmount, maxPurchase);
        _assertPackedAgainstGetter(1);
    }

    function testCreateRevertsUint128MaxPlusOneDepositBeforeTokensMove() external {
        uint256 overflowing = uint256(type(uint128).max) + 1;
        uint256 userBefore = stablecoin.balanceOf(USER);
        uint256 handlerBefore = stablecoin.balanceOf(address(stablecoinHandler));
        uint256 schedulesBefore = scheduleCount(dcaManager, USER, address(stablecoin));

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), overflowing);
        vm.expectRevert(_safeCastOverflow(128, overflowing));
        dcaManager.createDcaSchedule(
            address(stablecoin), overflowing, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();

        assertEq(stablecoin.balanceOf(USER), userBefore, "an overflowing create pulled tokens");
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerBefore);
        assertEq(scheduleCount(dcaManager, USER, address(stablecoin)), schedulesBefore);
    }

    function testCreateRevertsUint96MaxPlusOnePurchaseAmountBeforeTokensMove() external {
        uint256 overflowing = uint256(type(uint96).max) + 1;
        uint256 userBefore = stablecoin.balanceOf(USER);
        uint256 handlerBefore = stablecoin.balanceOf(address(stablecoinHandler));

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        vm.expectRevert(_safeCastOverflow(96, overflowing));
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, overflowing, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();

        assertEq(stablecoin.balanceOf(USER), userBefore);
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerBefore);
    }

    function testCreateAcceptsUint32MaxPeriod() external {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, type(uint32).max, s_routeIndex
        );
        vm.stopPrank();

        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), 1).purchasePeriod, type(uint32).max
        );
    }

    function testCreateRevertsUint32MaxPlusOnePeriod() external {
        uint256 overflowing = uint256(type(uint32).max) + 1;
        uint256 userBefore = stablecoin.balanceOf(USER);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        vm.expectRevert(_safeCastOverflow(32, overflowing));
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, overflowing, s_routeIndex
        );
        vm.stopPrank();

        assertEq(stablecoin.balanceOf(USER), userBefore);
    }

    function testCreateAtUint32MaxRoute() external {
        uint256 maxRoute = type(uint32).max;
        MockMocProxy extraMoc = new MockMocProxy(address(stablecoin));
        IdleDocHandlerMoc extraHandler = new IdleDocHandlerMoc(
            address(dcaManager),
            address(stablecoin),
            FEE_COLLECTOR,
            address(extraMoc),
            IFeeHandler(address(stablecoinHandler)).getFeeSettings(),
            OWNER
        );

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(maxRoute, false);
        operationsAdmin.assignTokenHandler(address(stablecoin), maxRoute, address(extraHandler));
        vm.stopPrank();

        vm.startPrank(USER);
        stablecoin.approve(address(extraHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, maxRoute
        );
        vm.stopPrank();

        IDcaManager.DcaSchedule memory schedule = scheduleAt(dcaManager, USER, address(stablecoin), 1);
        assertEq(schedule.routeIndex, maxRoute);
        _assertPackedAgainstGetter(1);
    }

    function testCreateRevertsUint32MaxPlusOneRouteBeforeTokensMove() external {
        uint256 overflowing = uint256(type(uint32).max) + 1;
        uint256 userBefore = stablecoin.balanceOf(USER);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        vm.expectRevert(_safeCastOverflow(32, overflowing));
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, overflowing
        );
        vm.stopPrank();

        assertEq(stablecoin.balanceOf(USER), userBefore);
    }

    function testDepositRevertsWhenSumExceedsUint128BeforeTokensMove() external {
        uint256 overflowingAdd = uint256(type(uint128).max) - AMOUNT_TO_DEPOSIT + 1;
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 scheduleBefore = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 userBefore = stablecoin.balanceOf(USER);
        uint256 handlerBefore = stablecoin.balanceOf(address(stablecoinHandler));

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), overflowingAdd);
        vm.expectRevert(_safeCastOverflow(128, uint256(type(uint128).max) + 1));
        dcaManager.depositToken(address(stablecoin), scheduleId, overflowingAdd);
        vm.stopPrank();

        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance,
            scheduleBefore,
            "an overflowing deposit credited the schedule"
        );
        assertEq(stablecoin.balanceOf(USER), userBefore, "an overflowing deposit pulled tokens");
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerBefore);
    }

    function testDepositRevertsUint128MaxPlusOneBeforeTokensMove() external {
        uint256 overflowing = uint256(type(uint128).max) + 1;
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 scheduleBefore = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 userBefore = stablecoin.balanceOf(USER);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), overflowing);
        vm.expectRevert(_safeCastOverflow(128, overflowing));
        dcaManager.depositToken(address(stablecoin), scheduleId, overflowing);
        vm.stopPrank();

        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance, scheduleBefore);
        assertEq(stablecoin.balanceOf(USER), userBefore);
    }

    function testUpdatePurchaseAmountAcceptsUint96MaxWhenBalanceAllows() external {
        if (block.chainid != ANVIL_CHAIN_ID) return; // live DOC has no public mint for this size

        uint256 maxAmount = type(uint96).max;
        uint256 extra = maxAmount - AMOUNT_TO_DEPOSIT;
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        stablecoin.mint(USER, extra);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), extra);
        dcaManager.depositToken(address(stablecoin), scheduleId, extra);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, maxAmount);
        vm.stopPrank();

        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount, maxAmount
        );
    }

    function testUpdatePurchaseAmountRevertsUint96MaxPlusOne() external {
        uint256 overflowing = uint256(type(uint96).max) + 1;
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 amountBefore = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount;

        vm.prank(USER);
        vm.expectRevert(_safeCastOverflow(96, overflowing));
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, overflowing);

        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount, amountBefore
        );
    }

    function testUpdatePurchasePeriodAcceptsUint32Max() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);

        vm.prank(USER);
        dcaManager.updatePurchasePeriod(address(stablecoin), scheduleId, type(uint32).max);

        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchasePeriod, type(uint32).max
        );
    }

    function testUpdatePurchasePeriodRevertsUint32MaxPlusOne() external {
        uint256 overflowing = uint256(type(uint32).max) + 1;
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 periodBefore = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchasePeriod;

        vm.prank(USER);
        vm.expectRevert(_safeCastOverflow(32, overflowing));
        dcaManager.updatePurchasePeriod(address(stablecoin), scheduleId, overflowing);

        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchasePeriod, periodBefore
        );
    }

    function testFirstPurchaseAcceptsUint48MaxTimestamp() external {
        vm.warp(type(uint48).max);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        super.buyRbtcOne(scheduleId);

        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp,
            type(uint48).max
        );
    }

    function testFirstPurchaseRevertsUint48MaxPlusOneTimestamp() external {
        vm.warp(uint256(type(uint48).max) + 1);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 timestampBefore =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp;
        uint256 balanceBefore = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;

        vm.expectRevert(_safeCastOverflow(48, uint256(type(uint48).max) + 1));
        super.buyRbtcOne(scheduleId);

        IDcaManager.DcaSchedule memory schedule =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(schedule.lastPurchaseTimestamp, timestampBefore, "a timestamp overflow consumed a period");
        assertEq(schedule.tokenBalance, balanceBefore, "a timestamp overflow debited the schedule");
    }

    function testSubsequentPurchaseRevertsWhenTimestampWouldOverflowUint48() external {
        vm.warp(type(uint48).max);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        super.buyRbtcOne(scheduleId);

        vm.warp(uint256(type(uint48).max) + MIN_PURCHASE_PERIOD);
        uint256 overflowingTimestamp = uint256(type(uint48).max) + MIN_PURCHASE_PERIOD;
        uint256 balanceBefore = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;

        vm.expectRevert(_safeCastOverflow(48, overflowingTimestamp));
        super.buyRbtcOne(scheduleId);

        IDcaManager.DcaSchedule memory schedule =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(schedule.lastPurchaseTimestamp, type(uint48).max);
        assertEq(schedule.tokenBalance, balanceBefore);
    }

    /*//////////////////////////////////////////////////////////////
                        NONCE AS PUBLIC ID
    //////////////////////////////////////////////////////////////*/

    function testFirstScheduleIdIsOneAndIdsCountUp() external {
        // The harness created one schedule in setUp; it is the first id ever handed out.
        assertEq(scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX), 1);
        assertEq(dcaManager.getSchedulesCreatedCount(), 1);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();

        assertEq(scheduleIdAt(dcaManager, USER, address(stablecoin), 1), 2);
        assertEq(dcaManager.getSchedulesCreatedCount(), 2, "the created count is not the last assigned id");
    }

    function testStaleIdIsRejectedAfterSwapPop() external {
        super.createSeveralDcaSchedules();

        uint256 lastIndex = NUM_OF_SCHEDULES - 1;
        uint64 deletedId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint64 survivorId = scheduleIdAt(dcaManager, USER, address(stablecoin), lastIndex);

        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), deletedId);

        // The survivor now sits at index 0 carrying its own nonce; the deleted id must not open it.
        assertEq(scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX), survivorId);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, address(stablecoin), deletedId));
        dcaManager.updatePurchaseAmount(address(stablecoin), deletedId, MIN_PURCHASE_AMOUNT);

        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), survivorId, MIN_PURCHASE_AMOUNT);
        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount, MIN_PURCHASE_AMOUNT);
    }

    function testCreateRevertsWhenTheNonceIsExhaustedBeforeTokensMove() external {
        // Park the counter one create short of the cap, keeping the scalars beside it intact.
        uint256 packed = _load(PROTOCOL_SETTINGS_SLOT);
        uint256 nonceMask = uint256(type(uint64).max) << 176;
        vm.store(
            address(dcaManager),
            bytes32(PROTOCOL_SETTINGS_SLOT),
            bytes32((packed & ~nonceMask) | (uint256(type(uint64).max) << 176))
        );
        assertEq(dcaManager.getMinPurchasePeriod(), MIN_PURCHASE_PERIOD, "vm.store clobbered a neighbouring scalar");

        uint256 userBefore = stablecoin.balanceOf(USER);
        uint256 handlerBefore = stablecoin.balanceOf(address(stablecoinHandler));
        uint256 schedulesBefore = scheduleCount(dcaManager, USER, address(stablecoin));

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        vm.expectRevert(_safeCastOverflow(64, uint256(type(uint64).max) + 1));
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();

        assertEq(stablecoin.balanceOf(USER), userBefore, "an exhausted nonce still pulled tokens");
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerBefore);
        assertEq(scheduleCount(dcaManager, USER, address(stablecoin)), schedulesBefore);
    }

    /*//////////////////////////////////////////////////////////////
                         SWAP-POP FIDELITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Deleting a schedule swap-pops its owner's id list and leaves every schedule where it is.
    ///      The survivor that changes position keeps every packed field, including its own id: nothing
    ///      about it is derived from where it sits in the list.
    function testSwapPopLeavesTheSurvivingScheduleIntact() external {
        super.createSeveralDcaSchedules();

        uint256 lastIndex = NUM_OF_SCHEDULES - 1;
        IDcaManager.DcaSchedule memory last = scheduleAt(dcaManager, USER, address(stablecoin), lastIndex);
        uint64 lastId = scheduleIdAt(dcaManager, USER, address(stablecoin), lastIndex);
        uint256 distinctAmount = last.purchaseAmount / 2;
        if (distinctAmount < MIN_PURCHASE_AMOUNT) distinctAmount = MIN_PURCHASE_AMOUNT;

        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), lastId, distinctAmount);

        super.buyRbtcOne(lastId);

        vm.prank(USER);
        dcaManager.setSchedulePaused(address(stablecoin), lastId, true);

        IDcaManager.DcaSchedule memory expected = scheduleAt(dcaManager, USER, address(stablecoin), lastIndex);
        uint64 deletedId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);

        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), deletedId);

        // The survivor moved into the freed position in the list, and is otherwise untouched.
        IDcaManager.DcaSchedule memory moved = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(
            scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX),
            lastId,
            "swap-pop changed the survivor's id"
        );
        assertEq(moved.tokenBalance, expected.tokenBalance, "swap-pop dropped tokenBalance");
        assertEq(moved.purchaseAmount, expected.purchaseAmount, "swap-pop dropped purchaseAmount");
        assertEq(moved.purchasePeriod, expected.purchasePeriod, "swap-pop dropped purchasePeriod");
        assertEq(moved.lastPurchaseTimestamp, expected.lastPurchaseTimestamp, "swap-pop dropped timestamp");
        assertEq(moved.routeIndex, expected.routeIndex, "swap-pop dropped routeIndex");
        assertEq(moved.user, expected.user, "swap-pop dropped the owner");
        assertTrue(moved.paused, "swap-pop dropped paused");
        _assertPackedAgainstGetter(SCHEDULE_INDEX);

        // Reading it by id gives the same schedule: the list position was never part of its address.
        IDcaManager.DcaSchedule memory byId = dcaManager.getDcaSchedule(address(stablecoin), lastId);
        assertEq(byId.tokenBalance, expected.tokenBalance);
        assertEq(byId.purchaseAmount, expected.purchaseAmount);
    }

    /// @dev The deleted schedule's slots are cleared, not left as orphaned state under its key.
    function testDeleteClearsEveryScheduleSlot() external {
        super.createSeveralDcaSchedules();

        uint64 deletedId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 base = _scheduleBase(address(stablecoin), deletedId);
        assertTrue(_load(base) != 0, "the schedule was empty before the delete");

        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), deletedId);

        assertEq(_load(base), 0, "slot 0 survived the delete");
        assertEq(_load(base + 1), 0, "slot 1 survived the delete");
    }
}
