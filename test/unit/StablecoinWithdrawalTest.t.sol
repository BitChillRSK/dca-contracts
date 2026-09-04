//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {UNUSED_SCHEDULE_ID} from "../utils/BatchBuyOne.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {scheduleIdAt} from "test/utils/ScheduleAt.sol";

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
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.expectRevert(IDcaManager.DcaManager__WithdrawalAmountMustBeGreaterThanZero.selector);
        dcaManager.withdrawToken(scheduleId, 0);
        vm.stopPrank();
    }

    function testTokenWithdrawalRevertsIfAmountExceedsBalance() external {
        vm.startPrank(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
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
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, USER, wrongScheduleId));
        dcaManager.withdrawToken(wrongScheduleId, AMOUNT_TO_DEPOSIT);
        vm.stopPrank();
    }

    /// @dev Withdrawals pay `msg.sender`, so the schedule's stored owner is what bounds them.
    function testCannotWithdrawFromAnotherUsersSchedule() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        address stranger = makeAddr("notTheOwner");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, stranger, scheduleId));
        dcaManager.withdrawToken(scheduleId, AMOUNT_TO_DEPOSIT);
    }


} 