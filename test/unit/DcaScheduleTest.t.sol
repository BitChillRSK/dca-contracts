//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {UNUSED_SCHEDULE_ID} from "../utils/BatchBuyOne.sol";
import "../Constants.sol";
import {DummyTokenHandler} from "./TestsHelper.t.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

contract DcaScheduleTest is DcaDappTest {
    // Events
    event DcaManager__DcaScheduleDeleted(
        address indexed user, address indexed token, uint64 indexed scheduleId, uint256 refundedAmount
    );
    event DcaManager__PurchaseAmountUpdated(
        address indexed user, uint64 indexed scheduleId, uint256 previousAmount, uint256 newAmount
    );
    event DcaManager__PurchasePeriodUpdated(
        address indexed user, uint64 indexed scheduleId, uint256 previousPeriod, uint256 newPeriod
    );

    /// @dev the refund is what the handler actually paid, and a lending protocol's share conversion rounds
    /// up, so the amount can exceed the schedule's recorded balance by dust
    uint256 constant REFUND_ROUNDING_TOLERANCE = 1e6;

    function setUp() public override {
        super.setUp();
    }

    /**
     * @notice Deletes a schedule and checks its event. The identity fields must match exactly; the refunded
     * amount is what the handler paid, compared with a rounding tolerance.
     */
    function _deleteAndAssertEvent(uint64 scheduleId, uint256 expectedRefund) private {
        vm.recordLogs();
        dcaManager.deleteDcaSchedule(scheduleId);

        bytes32 sig = keccak256("DcaManager__DcaScheduleDeleted(address,address,uint64,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            assertEq(logs[i].topics.length, 4, "DcaScheduleDeleted must index user, token, and scheduleId");
            assertEq(address(uint160(uint256(logs[i].topics[1]))), USER);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(stablecoin));
            assertEq(uint64(uint256(logs[i].topics[3])), scheduleId);
            uint256 refundedAmount = abi.decode(logs[i].data, (uint256));
            assertApproxEqAbs(refundedAmount, expectedRefund, REFUND_ROUNDING_TOLERANCE);
            found = true;
        }
        assertTrue(found, "no DcaManager__DcaScheduleDeleted log recorded");
    }

    /////////////////////////////////
    /// DcaSchedule tests  //////////
    /////////////////////////////////

    function testCreateDcaSchedule() external {
        vm.startPrank(USER);
        uint256 scheduleIndex = dcaManager.getDcaSchedules(USER, address(stablecoin)).length;
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        // scheduleId derives from a monotonic nonce and cannot be precomputed; it is checked
        // against storage after the call instead of being predicted here.
        vm.expectEmit(true, true, false, true);
        emit DcaManager__DcaScheduleCreated(
            USER, address(stablecoin), 0, AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.recordLogs();
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        _assertCreatedEventIdMatchesStorage();
        uint256 scheduleBalanceAfterDeposit = scheduleAt(dcaManager, USER, address(stablecoin), scheduleIndex).tokenBalance;
        assertEq(AMOUNT_TO_DEPOSIT, scheduleBalanceAfterDeposit);
        assertEq(AMOUNT_TO_SPEND, scheduleAt(dcaManager, USER, address(stablecoin), scheduleIndex).purchaseAmount);
        assertEq(MIN_PURCHASE_PERIOD, scheduleAt(dcaManager, USER, address(stablecoin), scheduleIndex).purchasePeriod);
        vm.stopPrank();
    }

    function testCannotCreateAZeroTokenScheduleEvenIfAHandlerWasAssigned() external {
        uint256 zeroTokenRoute = 10;
        DummyTokenHandler zeroTokenHandler = new DummyTokenHandler();

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(zeroTokenRoute, false);
        operationsAdmin.assignTokenHandler(address(0), zeroTokenRoute, address(zeroTokenHandler));
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__TokenNotAccepted.selector, address(0), zeroTokenRoute)
        );
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(0), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, zeroTokenRoute
        );

        assertEq(dcaManager.getDcaSchedules(USER, address(0)).length, 0);
    }

    function testDcaScheduleIdsDontCollide() external {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        // Both schedules are created in the same block: ids must still differ.
        console.log("First timestamp", block.timestamp);
        vm.expectEmit(true, true, false, true);
        emit DcaManager__DcaScheduleCreated(
            USER, address(stablecoin), 0, AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.recordLogs();
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        _assertCreatedEventIdMatchesStorage();
        uint64 scheduleId = _lastScheduleId();
        console.log("Second timestamp", block.timestamp);
        vm.expectEmit(true, true, false, true);
        emit DcaManager__DcaScheduleCreated(
            USER, address(stablecoin), 0, AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.recordLogs();
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        _assertCreatedEventIdMatchesStorage();
        uint64 scheduleId2 = _lastScheduleId();
        assertTrue(scheduleId != scheduleId2);
        // and neither collides with the schedule created in setUp
        assertTrue(scheduleId != scheduleIdAt(dcaManager, USER, address(stablecoin), 0));
        assertTrue(scheduleId2 != scheduleIdAt(dcaManager, USER, address(stablecoin), 0));
        vm.stopPrank();
    }

    function testSchedulesCreatedCountTracksCreatesAndIgnoresDeletes() external {
        // setUp() already created one schedule
        uint256 countAfterSetUp = dcaManager.getSchedulesCreatedCount();
        assertEq(countAfterSetUp, 1);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        assertEq(dcaManager.getSchedulesCreatedCount(), countAfterSetUp + 1);

        // deleting must not decrement: the count is a lifetime total for indexer cross-checks
        dcaManager.deleteDcaSchedule(_lastScheduleId());
        assertEq(dcaManager.getSchedulesCreatedCount(), countAfterSetUp + 1);
        assertEq(dcaManager.getDcaSchedules(USER, address(stablecoin)).length, 1);
        vm.stopPrank();
    }

    function testIntentSpecificScheduleEdits() external {
        uint256 newPurchaseAmount = AMOUNT_TO_SPEND / 2;
        uint256 newPurchasePeriod = MIN_PURCHASE_PERIOD * 10;
        uint256 extraStablecoinToDeposit = AMOUNT_TO_DEPOSIT / 3;
        vm.startPrank(USER);
        uint256 userBalanceBeforeDeposit = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        stablecoin.approve(address(stablecoinHandler), extraStablecoinToDeposit);
        uint64 scheduleId =
            scheduleAt(dcaManager, USER, address(stablecoin), dcaManager.getDcaSchedules(USER, address(stablecoin)).length - 1).scheduleId;
        uint256 newBalance = userBalanceBeforeDeposit + extraStablecoinToDeposit;
        vm.expectEmit(true, true, true, true);
        emit DcaManager__TokenBalanceUpdated(address(stablecoin), scheduleId, newBalance);
        dcaManager.depositToken(scheduleId, extraStablecoinToDeposit);
        vm.expectEmit(true, true, true, true);
        emit DcaManager__PurchaseAmountUpdated(USER, scheduleId, AMOUNT_TO_SPEND, newPurchaseAmount);
        dcaManager.updatePurchaseAmount(scheduleId, newPurchaseAmount);
        vm.expectEmit(true, true, true, true);
        emit DcaManager__PurchasePeriodUpdated(USER, scheduleId, MIN_PURCHASE_PERIOD, newPurchasePeriod);
        dcaManager.updatePurchasePeriod(scheduleId, newPurchasePeriod);
        uint256 userBalanceAfterDeposit = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        assertEq(extraStablecoinToDeposit, userBalanceAfterDeposit - userBalanceBeforeDeposit);
        assertEq(newPurchaseAmount, scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount);
        assertEq(newPurchasePeriod, scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchasePeriod);
        vm.stopPrank();
    }

    function testDeleteDcaSchedule() external {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT * 5);
        // Create two schedules in different blocks
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT * 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        uint64 scheduleId = _lastScheduleId();
        vm.warp(block.timestamp + 1 minutes);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT * 3, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        uint64 scheduleId2 = _lastScheduleId();
        console.log("scheduleId is", vm.toString(scheduleId));
        console.log("scheduleId2 is", vm.toString(scheduleId2));
        // Delete one
        _deleteAndAssertEvent(scheduleId, AMOUNT_TO_DEPOSIT * 2);
        // Check that there are two (the one created in setUp() and the second one created in this test)
        assertEq(dcaManager.getDcaSchedules(USER, address(stablecoin)).length, 2);
        // Check that the deleted one was the first one created in this test and its place was taken by the second one
        assertEq(scheduleIdAt(dcaManager, USER, address(stablecoin), 1), scheduleId2);
        vm.stopPrank();
    }

    function testDeleteTwoDcaSchedules() public {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT * 5);
        // Create two schedules in different blocks
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT * 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        uint64 scheduleId = _lastScheduleId();
        vm.warp(block.timestamp + 1 minutes);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT * 3, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        uint64 scheduleId2 = _lastScheduleId();
        console.log("scheduleId is", vm.toString(scheduleId));
        console.log(vm.toString(scheduleIdAt(dcaManager, USER, address(stablecoin), 1)));
        console.log("scheduleId 2 is", vm.toString(scheduleId2));
        console.log(vm.toString(scheduleIdAt(dcaManager, USER, address(stablecoin), 2)));
        // Delete one
        _deleteAndAssertEvent(scheduleId, AMOUNT_TO_DEPOSIT * 2);
        // Delete the second one passing the same index, since the first one was already deleted
        _deleteAndAssertEvent(scheduleId2, AMOUNT_TO_DEPOSIT * 3);
        // Check only the schedule created in setUp() remains
        assertEq(dcaManager.getDcaSchedules(USER, address(stablecoin)).length, 1);
        vm.stopPrank();
    }

    /**
     * @notice This was just a test to compare options in terms of gas consumption
     */
    function testDeleteSeveraldcaSchedules() external {
        super.createSeveralDcaSchedules();
        vm.startPrank(USER);
        for (int256 i = int256(NUM_OF_SCHEDULES) - 1; i >= 0; --i) {
            uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), uint256(i));
            dcaManager.deleteDcaSchedule(scheduleId);
        }
        vm.stopPrank();
    }

    /// @dev Id-based deletion is independent of a schedule's current position in the enumeration list.
    function testCanDeleteTwoSchedulesByIdInTheSameBlock() external {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT * 5);
        // Create two schedules in different blocks
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT * 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        uint64 scheduleId = _lastScheduleId();
        vm.warp(block.timestamp + 1 minutes);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT * 3, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        uint64 scheduleId2 = _lastScheduleId();
        console.log("scheduleId is", vm.toString(scheduleId));
        console.log(vm.toString(scheduleIdAt(dcaManager, USER, address(stablecoin), 1)));
        console.log("scheduleId 2 is", vm.toString(scheduleId2));
        console.log(vm.toString(scheduleIdAt(dcaManager, USER, address(stablecoin), 2)));
        // Delete one
        _deleteAndAssertEvent(scheduleId, AMOUNT_TO_DEPOSIT * 2);
        // The first delete moves this id in the enumeration list, but its identity does not change.
        _deleteAndAssertEvent(scheduleId2, AMOUNT_TO_DEPOSIT * 3);
        assertEq(dcaManager.getDcaSchedules(USER, address(stablecoin)).length, 1);
        vm.stopPrank();
    }

    function testCreateSeveralDcaSchedules() external {
        super.createSeveralDcaSchedules();
    }

    function testCannotUpdateInexistentSchedule() external {
        vm.startPrank(USER);
        uint64 fakeScheduleId = UNUSED_SCHEDULE_ID;
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, USER, fakeScheduleId));
        dcaManager.depositToken(fakeScheduleId, AMOUNT_TO_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, USER, fakeScheduleId));
        dcaManager.updatePurchaseAmount(fakeScheduleId, AMOUNT_TO_SPEND);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, USER, fakeScheduleId));
        dcaManager.updatePurchasePeriod(fakeScheduleId, MIN_PURCHASE_PERIOD);
        vm.stopPrank();
    }

    function testCannotConsultInexistentSchedule() external {
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, USER, UNUSED_SCHEDULE_ID)
        );
        dcaManager.getDcaSchedule(USER, UNUSED_SCHEDULE_ID);
    }

    /// @dev An id is retired by deletion, never reissued: the counter only ever moves forward.
    function testCannotDeleteAScheduleTwice() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(scheduleId);

        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, USER, scheduleId));
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(scheduleId);
    }

    function testCannotDeleteAScheduleThatDoesNotExist() external {
        uint64 wrongScheduleId = UNUSED_SCHEDULE_ID;
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, USER, wrongScheduleId));
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(wrongScheduleId);
    }

    /// @dev The caller is half the storage key, so another account's id is not one they hold.
    function testCannotDeleteAnotherUsersSchedule() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        address stranger = makeAddr("notTheOwner");
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, stranger, scheduleId));
        vm.prank(stranger);
        dcaManager.deleteDcaSchedule(scheduleId);
    }

}
