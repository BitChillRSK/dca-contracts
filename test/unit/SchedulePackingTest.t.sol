// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IFeeHandler} from "../../src/interfaces/IFeeHandler.sol";
import {IdleDocHandlerMoc} from "../../src/idle/IdleDocHandlerMoc.sol";
import {MockMocProxy} from "../mocks/MockMocProxy.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./TestsHelper.t.sol";

/**
 * @notice R18: each `DcaSchedule` occupies three slots with checked widths.
 * @dev External arguments stay `uint256`. Overflow reverts with OZ `SafeCast` data before cash
 *      or schedule state changes. Swap-pop must copy every packed field, not just `scheduleId`.
 */
contract SchedulePackingTest is DcaDappTest {
    uint256 private constant SCHEDULES_MAPPING_SLOT = 2;

    function setUp() public override {
        super.setUp();
    }

    function _safeCastOverflow(uint8 bits, uint256 value) private pure returns (bytes memory) {
        return abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, bits, value);
    }

    function _elementBase(address user, address token, uint256 scheduleIndex) private pure returns (uint256) {
        bytes32 inner = keccak256(abi.encode(user, SCHEDULES_MAPPING_SLOT));
        bytes32 arraySlot = keccak256(abi.encode(token, inner));
        return uint256(keccak256(abi.encode(arraySlot))) + scheduleIndex * 3;
    }

    function _load(uint256 slot) private view returns (uint256) {
        return uint256(vm.load(address(dcaManager), bytes32(slot)));
    }

    function _assertPackedAgainstGetter(uint256 scheduleIndex) private {
        IDcaManager.DcaSchedule memory schedule =
            dcaManager.getDcaSchedule(USER, address(stablecoin), scheduleIndex);
        uint256 base = _elementBase(USER, address(stablecoin), scheduleIndex);

        uint256 slot0 = uint256(uint128(schedule.tokenBalance)) | (uint256(uint128(schedule.purchaseAmount)) << 128);
        uint256 slot1 = uint256(uint32(schedule.purchasePeriod)) | (uint256(uint48(schedule.lastPurchaseTimestamp)) << 32)
            | (uint256(uint32(schedule.routeIndex)) << 80) | (uint256(schedule.paused ? 1 : 0) << 112);

        assertEq(_load(base), slot0, "slot 0 is not tokenBalance|purchaseAmount");
        assertEq(_load(base + 1), slot1, "slot 1 is not period|timestamp|route|paused");
        assertEq(bytes32(_load(base + 2)), schedule.scheduleId, "slot 2 is not scheduleId");
    }

    /*//////////////////////////////////////////////////////////////
                              LAYOUT
    //////////////////////////////////////////////////////////////*/

    function testOneScheduleOccupiesExactlyThreeSlots() external {
        assertEq(dcaManager.getDcaSchedules(USER, address(stablecoin)).length, 1);
        _assertPackedAgainstGetter(SCHEDULE_INDEX);

        uint256 base = _elementBase(USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(_load(base + 3), 0, "a fourth slot was written for a single schedule");
    }

    function testMaxWidthsPackIntoThreeSlots() external {
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;

        vm.startPrank(USER);
        dcaManager.updatePurchasePeriod(address(stablecoin), SCHEDULE_INDEX, scheduleId, type(uint32).max);
        vm.stopPrank();

        vm.warp(type(uint48).max);
        super.buyRbtcOne(USER, SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND);

        vm.prank(USER);
        dcaManager.setSchedulePaused(address(stablecoin), SCHEDULE_INDEX, scheduleId, true);

        IDcaManager.DcaSchedule memory schedule =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(schedule.purchasePeriod, type(uint32).max);
        assertEq(schedule.lastPurchaseTimestamp, type(uint48).max);
        assertTrue(schedule.paused);
        _assertPackedAgainstGetter(SCHEDULE_INDEX);
    }

    /*//////////////////////////////////////////////////////////////
                         WIDTH BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    function testCreateAcceptsUint128MaxAmounts() external {
        if (block.chainid != ANVIL_CHAIN_ID) return; // live DOC has no public mint for this size

        uint256 maxAmount = type(uint128).max;
        stablecoin.mint(USER, maxAmount);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), maxAmount);
        dcaManager.createDcaSchedule(
            address(stablecoin), maxAmount, maxAmount, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();

        IDcaManager.DcaSchedule memory schedule = dcaManager.getDcaSchedule(USER, address(stablecoin), 1);
        assertEq(schedule.tokenBalance, maxAmount);
        assertEq(schedule.purchaseAmount, maxAmount);
        _assertPackedAgainstGetter(1);
    }

    function testCreateRevertsUint128MaxPlusOneDepositBeforeTokensMove() external {
        uint256 overflowing = uint256(type(uint128).max) + 1;
        uint256 userBefore = stablecoin.balanceOf(USER);
        uint256 handlerBefore = stablecoin.balanceOf(address(stablecoinHandler));
        uint256 schedulesBefore = dcaManager.getDcaSchedules(USER, address(stablecoin)).length;

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), overflowing);
        vm.expectRevert(_safeCastOverflow(128, overflowing));
        dcaManager.createDcaSchedule(
            address(stablecoin), overflowing, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();

        assertEq(stablecoin.balanceOf(USER), userBefore, "an overflowing create pulled tokens");
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerBefore);
        assertEq(dcaManager.getDcaSchedules(USER, address(stablecoin)).length, schedulesBefore);
    }

    function testCreateRevertsUint128MaxPlusOnePurchaseAmountBeforeTokensMove() external {
        uint256 overflowing = uint256(type(uint128).max) + 1;
        uint256 userBefore = stablecoin.balanceOf(USER);
        uint256 handlerBefore = stablecoin.balanceOf(address(stablecoinHandler));

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        vm.expectRevert(_safeCastOverflow(128, overflowing));
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
            dcaManager.getDcaSchedule(USER, address(stablecoin), 1).purchasePeriod, type(uint32).max
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

        IDcaManager.DcaSchedule memory schedule = dcaManager.getDcaSchedule(USER, address(stablecoin), 1);
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
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        uint256 scheduleBefore = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 userBefore = stablecoin.balanceOf(USER);
        uint256 handlerBefore = stablecoin.balanceOf(address(stablecoinHandler));

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), overflowingAdd);
        vm.expectRevert(_safeCastOverflow(128, uint256(type(uint128).max) + 1));
        dcaManager.depositToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, overflowingAdd);
        vm.stopPrank();

        assertEq(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance,
            scheduleBefore,
            "an overflowing deposit credited the schedule"
        );
        assertEq(stablecoin.balanceOf(USER), userBefore, "an overflowing deposit pulled tokens");
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerBefore);
    }

    function testDepositRevertsUint128MaxPlusOneBeforeTokensMove() external {
        uint256 overflowing = uint256(type(uint128).max) + 1;
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        uint256 scheduleBefore = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 userBefore = stablecoin.balanceOf(USER);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), overflowing);
        vm.expectRevert(_safeCastOverflow(128, overflowing));
        dcaManager.depositToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, overflowing);
        vm.stopPrank();

        assertEq(dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance, scheduleBefore);
        assertEq(stablecoin.balanceOf(USER), userBefore);
    }

    function testUpdatePurchaseAmountAcceptsUint128MaxWhenBalanceAllows() external {
        if (block.chainid != ANVIL_CHAIN_ID) return; // live DOC has no public mint for this size

        uint256 maxAmount = type(uint128).max;
        uint256 extra = maxAmount - AMOUNT_TO_DEPOSIT;
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        stablecoin.mint(USER, extra);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), extra);
        dcaManager.depositToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, extra);
        dcaManager.updatePurchaseAmount(address(stablecoin), SCHEDULE_INDEX, scheduleId, maxAmount);
        vm.stopPrank();

        assertEq(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount, maxAmount
        );
    }

    function testUpdatePurchaseAmountRevertsUint128MaxPlusOne() external {
        uint256 overflowing = uint256(type(uint128).max) + 1;
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        uint256 amountBefore = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount;

        vm.prank(USER);
        vm.expectRevert(_safeCastOverflow(128, overflowing));
        dcaManager.updatePurchaseAmount(address(stablecoin), SCHEDULE_INDEX, scheduleId, overflowing);

        assertEq(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount, amountBefore
        );
    }

    function testUpdatePurchasePeriodAcceptsUint32Max() external {
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;

        vm.prank(USER);
        dcaManager.updatePurchasePeriod(address(stablecoin), SCHEDULE_INDEX, scheduleId, type(uint32).max);

        assertEq(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).purchasePeriod, type(uint32).max
        );
    }

    function testUpdatePurchasePeriodRevertsUint32MaxPlusOne() external {
        uint256 overflowing = uint256(type(uint32).max) + 1;
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        uint256 periodBefore = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).purchasePeriod;

        vm.prank(USER);
        vm.expectRevert(_safeCastOverflow(32, overflowing));
        dcaManager.updatePurchasePeriod(address(stablecoin), SCHEDULE_INDEX, scheduleId, overflowing);

        assertEq(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).purchasePeriod, periodBefore
        );
    }

    function testFirstPurchaseAcceptsUint48MaxTimestamp() external {
        vm.warp(type(uint48).max);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        super.buyRbtcOne(USER, SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND);

        assertEq(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp,
            type(uint48).max
        );
    }

    function testFirstPurchaseRevertsUint48MaxPlusOneTimestamp() external {
        vm.warp(uint256(type(uint48).max) + 1);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        uint256 timestampBefore =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp;
        uint256 balanceBefore = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;

        vm.expectRevert(_safeCastOverflow(48, uint256(type(uint48).max) + 1));
        super.buyRbtcOne(USER, SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND);

        IDcaManager.DcaSchedule memory schedule =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(schedule.lastPurchaseTimestamp, timestampBefore, "a timestamp overflow consumed a period");
        assertEq(schedule.tokenBalance, balanceBefore, "a timestamp overflow debited the schedule");
    }

    function testSubsequentPurchaseRevertsWhenTimestampWouldOverflowUint48() external {
        vm.warp(type(uint48).max);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        super.buyRbtcOne(USER, SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND);

        vm.warp(uint256(type(uint48).max) + MIN_PURCHASE_PERIOD);
        uint256 overflowingTimestamp = uint256(type(uint48).max) + MIN_PURCHASE_PERIOD;
        uint256 balanceBefore = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;

        vm.expectRevert(_safeCastOverflow(48, overflowingTimestamp));
        super.buyRbtcOne(USER, SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND);

        IDcaManager.DcaSchedule memory schedule =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(schedule.lastPurchaseTimestamp, type(uint48).max);
        assertEq(schedule.tokenBalance, balanceBefore);
    }

    /*//////////////////////////////////////////////////////////////
                         SWAP-POP FIDELITY
    //////////////////////////////////////////////////////////////*/

    function testSwapPopCopiesEveryPackedField() external {
        super.createSeveralDcaSchedules();

        uint256 lastIndex = NUM_OF_SCHEDULES - 1;
        IDcaManager.DcaSchedule memory last = dcaManager.getDcaSchedule(USER, address(stablecoin), lastIndex);
        uint256 distinctAmount = last.purchaseAmount / 2;
        if (distinctAmount < MIN_PURCHASE_AMOUNT) distinctAmount = MIN_PURCHASE_AMOUNT;

        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), lastIndex, last.scheduleId, distinctAmount);

        super.buyRbtcOne(USER, lastIndex, last.scheduleId, distinctAmount);

        vm.prank(USER);
        dcaManager.setSchedulePaused(address(stablecoin), lastIndex, last.scheduleId, true);

        IDcaManager.DcaSchedule memory expected = dcaManager.getDcaSchedule(USER, address(stablecoin), lastIndex);
        bytes32 deletedId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;

        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), SCHEDULE_INDEX, deletedId);

        IDcaManager.DcaSchedule memory moved = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(moved.tokenBalance, expected.tokenBalance, "swap-pop dropped tokenBalance");
        assertEq(moved.purchaseAmount, expected.purchaseAmount, "swap-pop dropped purchaseAmount");
        assertEq(moved.purchasePeriod, expected.purchasePeriod, "swap-pop dropped purchasePeriod");
        assertEq(moved.lastPurchaseTimestamp, expected.lastPurchaseTimestamp, "swap-pop dropped timestamp");
        assertEq(moved.routeIndex, expected.routeIndex, "swap-pop dropped routeIndex");
        assertTrue(moved.paused, "swap-pop dropped paused");
        assertEq(moved.scheduleId, expected.scheduleId, "swap-pop dropped scheduleId");
        _assertPackedAgainstGetter(SCHEDULE_INDEX);
    }
}
