//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {UNUSED_SCHEDULE_ID} from "../utils/BatchBuyOne.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {scheduleAt} from "test/utils/ScheduleAt.sol";

contract StablecoinWithdrawalTest is DcaDappTest {
    function setUp() public override {
        super.setUp();
    }

    ////////////////////////////////////
    /// Stablecoin Withdrawal tests ///
    ////////////////////////////////////
    function testStablecoinWithdrawal() external {
        super.withdrawStablecoin();
    }

    function testCannotWithdrawZeroStablecoin() external {
        vm.startPrank(USER);
        uint64 scheduleId = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.expectRevert(IDcaManager.DcaManager__WithdrawalAmountMustBeGreaterThanZero.selector);
        dcaManager.withdrawToken(scheduleId, 0);
        vm.stopPrank();
    }

    function testTokenWithdrawalRevertsIfAmountExceedsBalance() external {
        vm.startPrank(USER);
        uint64 scheduleId = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__WithdrawalAmountExceedsBalance.selector,
            address(stablecoin),
            USER_TOTAL_AMOUNT,
            AMOUNT_TO_DEPOSIT
        );
        vm.expectRevert(encodedRevert);
        dcaManager.withdrawToken(scheduleId, USER_TOTAL_AMOUNT);
        vm.stopPrank();
    }

    function testCannotWithdrawFromInexistentSchedule() external {
        vm.startPrank(USER);
        uint64 wrongScheduleId = UNUSED_SCHEDULE_ID;
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, wrongScheduleId));
        dcaManager.withdrawToken(wrongScheduleId, AMOUNT_TO_DEPOSIT);
        vm.stopPrank();
    }

    /// @dev Withdrawals pay `msg.sender`, so the schedule's stored owner is what bounds them.
    function testCannotWithdrawFromAnotherUsersSchedule() external {
        uint64 scheduleId = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.prank(makeAddr("notTheOwner"));
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__NotScheduleOwner.selector, scheduleId));
        dcaManager.withdrawToken(scheduleId, AMOUNT_TO_DEPOSIT);
    }


} 