//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import "../../script/Constants.sol";

contract DcaScheduleTest is DcaDappTest {
    // Events
    event DcaManager__DcaScheduleDeleted(address user, address token, bytes32 scheduleId, uint256 refundedAmount);
    
    function setUp() public override {
        super.setUp();
    }

    /////////////////////////////////
    /// DcaSchedule tests  //////////
    /////////////////////////////////

    function testCreateDcaSchedule() external {
        vm.startPrank(USER);
        uint256 scheduleIndex = dcaManager.getMyDcaSchedules(address(stablecoin)).length;
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        // scheduleId derives from a monotonic nonce and cannot be precomputed; it is checked
        // against storage after the call instead of being predicted here.
        vm.expectEmit(true, true, false, true);
        emit DcaManager__DcaScheduleCreated(
            USER, address(stablecoin), bytes32(0), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        vm.recordLogs();
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        _assertCreatedEventIdMatchesStorage();
        uint256 scheduleBalanceAfterDeposit = dcaManager.getMyScheduleTokenBalance(address(stablecoin), scheduleIndex);
        assertEq(AMOUNT_TO_DEPOSIT, scheduleBalanceAfterDeposit);
        assertEq(AMOUNT_TO_SPEND, dcaManager.getMySchedulePurchaseAmount(address(stablecoin), scheduleIndex));
        assertEq(MIN_PURCHASE_PERIOD, dcaManager.getMySchedulePurchasePeriod(address(stablecoin), scheduleIndex));
        vm.stopPrank();
    }

    function testDcaScheduleIdsDontCollide() external {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        // Both schedules are created in the same block: ids must still differ.
        console.log("First timestamp", block.timestamp);
        vm.expectEmit(true, true, false, true);
        emit DcaManager__DcaScheduleCreated(
            USER, address(stablecoin), bytes32(0), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        vm.recordLogs();
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        _assertCreatedEventIdMatchesStorage();
        bytes32 scheduleId = _lastScheduleId();
        console.log("Second timestamp", block.timestamp);
        vm.expectEmit(true, true, false, true);
        emit DcaManager__DcaScheduleCreated(
            USER, address(stablecoin), bytes32(0), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        vm.recordLogs();
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        _assertCreatedEventIdMatchesStorage();
        bytes32 scheduleId2 = _lastScheduleId();
        assertTrue(scheduleId != scheduleId2);
        // and neither collides with the schedule created in setUp
        assertTrue(scheduleId != dcaManager.getMyScheduleId(address(stablecoin), 0));
        assertTrue(scheduleId2 != dcaManager.getMyScheduleId(address(stablecoin), 0));
        vm.stopPrank();
    }

    function testSchedulesCreatedCountTracksCreatesAndIgnoresDeletes() external {
        // setUp() already created one schedule
        uint256 countAfterSetUp = dcaManager.getSchedulesCreatedCount();
        assertEq(countAfterSetUp, 1);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        assertEq(dcaManager.getSchedulesCreatedCount(), countAfterSetUp + 1);

        // deleting must not decrement: the count is a lifetime total for indexer cross-checks
        dcaManager.deleteDcaSchedule(address(stablecoin), 1, _lastScheduleId());
        assertEq(dcaManager.getSchedulesCreatedCount(), countAfterSetUp + 1);
        assertEq(dcaManager.getMyDcaSchedules(address(stablecoin)).length, 1);
        vm.stopPrank();
    }

    function testUpdateDcaSchedule() external {
        uint256 newPurchaseAmount = AMOUNT_TO_SPEND / 2;
        uint256 newPurchasePeriod = MIN_PURCHASE_PERIOD * 10;
        uint256 extraStablecoinToDeposit = AMOUNT_TO_DEPOSIT / 3;
        vm.startPrank(USER);
        uint256 userBalanceBeforeDeposit = dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX);
        stablecoin.approve(address(stablecoinHandler), extraStablecoinToDeposit);
        bytes32 scheduleId =
            dcaManager.getMyScheduleId(address(stablecoin), dcaManager.getMyDcaSchedules(address(stablecoin)).length - 1);
        vm.expectEmit(true, true, true, true);
        emit DcaManager__DcaScheduleUpdated(
            USER, address(stablecoin), scheduleId, AMOUNT_TO_DEPOSIT + extraStablecoinToDeposit, newPurchaseAmount, newPurchasePeriod
        );
        dcaManager.updateDcaSchedule(
            address(stablecoin), SCHEDULE_INDEX, scheduleId, extraStablecoinToDeposit, newPurchaseAmount, newPurchasePeriod
        );
        uint256 userBalanceAfterDeposit = dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX);
        assertEq(extraStablecoinToDeposit, userBalanceAfterDeposit - userBalanceBeforeDeposit);
        assertEq(newPurchaseAmount, dcaManager.getMySchedulePurchaseAmount(address(stablecoin), SCHEDULE_INDEX));
        assertEq(newPurchasePeriod, dcaManager.getMySchedulePurchasePeriod(address(stablecoin), SCHEDULE_INDEX));
        vm.stopPrank();
    }

    function testUpdateDcaScheduleDoesNotCreditIfDepositReverts() external {
        vm.startPrank(USER);
        bytes32 scheduleId = dcaManager.getMyScheduleId(address(stablecoin), SCHEDULE_INDEX);
        uint256 balanceBefore = dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX);
        vm.expectRevert();
        dcaManager.updateDcaSchedule(
            address(stablecoin), SCHEDULE_INDEX, scheduleId, AMOUNT_TO_DEPOSIT, 0, 0
        );
        assertEq(dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX), balanceBefore);
        vm.stopPrank();
    }

    function testDeleteDcaSchedule() external {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT * 5);
        // Create two schedules in different blocks
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT * 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        bytes32 scheduleId = _lastScheduleId();
        vm.warp(block.timestamp + 1 minutes);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT * 3, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        bytes32 scheduleId2 = _lastScheduleId();
        console.log("scheduleId is", vm.toString(scheduleId));
        console.log("scheduleId2 is", vm.toString(scheduleId2));
        // Delete one
        vm.expectEmit(true, true, true, true);
        emit DcaManager__DcaScheduleDeleted(USER, address(stablecoin), scheduleId, AMOUNT_TO_DEPOSIT * 2);
        dcaManager.deleteDcaSchedule(address(stablecoin), 1, scheduleId);
        // Check that there are two (the one created in setUp() and the second one created in this test)
        assertEq(dcaManager.getMyDcaSchedules(address(stablecoin)).length, 2);
        // Check that the deleted one was the first one created in this test and its place was taken by the second one
        assertEq(dcaManager.getMyDcaSchedules(address(stablecoin))[1].scheduleId, scheduleId2);
        vm.stopPrank();
    }

    function testDeleteTwoDcaSchedules() public {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT * 5);
        // Create two schedules in different blocks
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT * 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        bytes32 scheduleId = _lastScheduleId();
        vm.warp(block.timestamp + 1 minutes);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT * 3, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        bytes32 scheduleId2 = _lastScheduleId();
        console.log("scheduleId is", vm.toString(scheduleId));
        console.log(vm.toString(dcaManager.getMyDcaSchedules(address(stablecoin))[1].scheduleId));
        console.log("scheduleId 2 is", vm.toString(scheduleId2));
        console.log(vm.toString(dcaManager.getMyDcaSchedules(address(stablecoin))[2].scheduleId));
        // Delete one
        vm.expectEmit(true, true, true, true);
        emit DcaManager__DcaScheduleDeleted(USER, address(stablecoin), scheduleId, AMOUNT_TO_DEPOSIT * 2);
        dcaManager.deleteDcaSchedule(address(stablecoin), 1, scheduleId);
        // Delete the second one passing the same index, since the first one was already deleted
        vm.expectEmit(true, true, true, true);
        emit DcaManager__DcaScheduleDeleted(USER, address(stablecoin), scheduleId2, AMOUNT_TO_DEPOSIT * 3);
        dcaManager.deleteDcaSchedule(address(stablecoin), 1, scheduleId2);
        // Check only the schedule created in setUp() remains
        assertEq(dcaManager.getMyDcaSchedules(address(stablecoin)).length, 1);
        vm.stopPrank();
    }

    /**
     * @notice This was just a test to compare options in terms of gas consumption
     */
    function testDeleteSeveraldcaSchedules() external {
        super.createSeveralDcaSchedules();
        vm.startPrank(USER);
        for (int256 i = int256(NUM_OF_SCHEDULES) - 1; i >= 0; --i) {
            bytes32 scheduleId = dcaManager.getMyScheduleId(address(stablecoin), uint256(i));
            dcaManager.deleteDcaSchedule(address(stablecoin), uint256(i), scheduleId);
        }
        vm.stopPrank();
    }

    /**
     * @notice this test shows that a transaction that aims to delete the last schedule in the array after another schedule has been deleted in a previous transaction
     * reverts if both transactions have been included in the same block // this has to be prevented in the front end
     */
    function testCannotDeleteLastDcaScheduleInTheSameBlock() external {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT * 5);
        // Create two schedules in different blocks
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT * 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        bytes32 scheduleId = _lastScheduleId();
        vm.warp(block.timestamp + 1 minutes);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT * 3, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        bytes32 scheduleId2 = _lastScheduleId();
        console.log("scheduleId is", vm.toString(scheduleId));
        console.log(vm.toString(dcaManager.getMyDcaSchedules(address(stablecoin))[1].scheduleId));
        console.log("scheduleId 2 is", vm.toString(scheduleId2));
        console.log(vm.toString(dcaManager.getMyDcaSchedules(address(stablecoin))[2].scheduleId));
        // Delete one
        vm.expectEmit(true, true, true, true);
        emit DcaManager__DcaScheduleDeleted(USER, address(stablecoin), scheduleId, AMOUNT_TO_DEPOSIT * 2);
        dcaManager.deleteDcaSchedule(address(stablecoin), 1, scheduleId);
        // Deleting the second one fails, because when the first one was deleted, the second one was moved to its index
        vm.expectEmit(true, true, true, true);
        emit DcaManager__DcaScheduleDeleted(USER, address(stablecoin), scheduleId2, AMOUNT_TO_DEPOSIT * 3);
        dcaManager.deleteDcaSchedule(address(stablecoin), 1, scheduleId2);
        vm.stopPrank();
    }

    function testCreateSeveralDcaSchedules() external {
        super.createSeveralDcaSchedules();
    }

    function testCannotUpdateInexistentSchedule() external {
        vm.startPrank(USER);
        bytes32 fakeScheduleId = keccak256("fake");
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.depositToken(address(stablecoin), SCHEDULE_INDEX + 1, fakeScheduleId, AMOUNT_TO_DEPOSIT);
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.setPurchaseAmount(address(stablecoin), SCHEDULE_INDEX + 1, fakeScheduleId, AMOUNT_TO_SPEND);
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.setPurchasePeriod(address(stablecoin), SCHEDULE_INDEX + 1, fakeScheduleId, MIN_PURCHASE_PERIOD);
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.updateDcaSchedule(address(stablecoin), 1, fakeScheduleId, 1, 1, 1);
        vm.stopPrank();
    }

    function testCannotConsultInexistentSchedule() external {
        vm.startPrank(USER);
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX + 1);
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.getMySchedulePurchaseAmount(address(stablecoin), SCHEDULE_INDEX + 1);
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.getMySchedulePurchasePeriod(address(stablecoin), SCHEDULE_INDEX + 1);
        vm.stopPrank();
    }

    function testCannotDeleteInexistentScheduleIndex() external {
        bytes32 scheduleId = dcaManager.getScheduleId(USER, address(stablecoin), 0);
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), 999, scheduleId);
    }

    function testCannotDeleteScheduleWithIdAndIndexMismatch() external {
        bytes32 wrongScheduleId = keccak256(
            abi.encodePacked(USER, address(stablecoin), block.timestamp + 1, dcaManager.getDcaSchedules(USER, address(stablecoin)).length)
        );
        vm.expectRevert(IDcaManager.DcaManager__ScheduleIdAndIndexMismatch.selector);
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), 0, wrongScheduleId);
    }

}
