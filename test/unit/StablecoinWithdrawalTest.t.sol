//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";

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
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.expectRevert(IDcaManager.DcaManager__WithdrawalAmountMustBeGreaterThanZero.selector);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, 0);
        vm.stopPrank();
    }

    function testTokenWithdrawalRevertsIfAmountExceedsBalance() external {
        vm.startPrank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__WithdrawalAmountExceedsBalance.selector,
            address(stablecoin),
            USER_TOTAL_AMOUNT,
            AMOUNT_TO_DEPOSIT
        );
        vm.expectRevert(encodedRevert);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, USER_TOTAL_AMOUNT);
        vm.stopPrank();
    }

    function testCannotWithdrawFromInexistentSchedule() external {
        vm.startPrank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX + 1, scheduleId, AMOUNT_TO_DEPOSIT);
        vm.stopPrank();
    }

    function testCannotWithdrawIfScheduleIdAndIndexMismatch() external {
        vm.startPrank(USER);
        bytes32 wrongScheduleId = keccak256(abi.encodePacked(USER, address(stablecoin), block.timestamp, uint256(999)));
        vm.expectRevert(IDcaManager.DcaManager__ScheduleIdAndIndexMismatch.selector);
        dcaManager.withdrawToken(address(stablecoin), 0, wrongScheduleId, AMOUNT_TO_DEPOSIT);
        vm.stopPrank();
    }


} 