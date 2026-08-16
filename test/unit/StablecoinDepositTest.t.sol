//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";

contract StablecoinDepositTest is DcaDappTest {
    function setUp() public override {
        super.setUp();
    }

    /////////////////////////////////
    /// Stablecoin deposit tests ///
    /////////////////////////////////
    function testStablecoinDeposit() external {
        (uint256 userBalanceAfterDeposit, uint256 userBalanceBeforeDeposit) = super.depositStablecoin();
        assertEq(AMOUNT_TO_DEPOSIT, userBalanceAfterDeposit - userBalanceBeforeDeposit);
        assertEq(dcaManager.getDcaSchedules(USER, address(stablecoin)).length, 1);
    }

    function testCannotDepositZeroStablecoin() external {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        bytes32 scheduleId = dcaManager.getMyScheduleId(address(stablecoin), SCHEDULE_INDEX);
        vm.expectRevert(IDcaManager.DcaManager__DepositAmountMustBeGreaterThanZero.selector);
        dcaManager.depositToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, 0);
        vm.stopPrank();
    }

    function testDepositRevertsIfStablecoinNotApproved() external {
        vm.startPrank(USER);
        bytes32 scheduleId = dcaManager.getMyScheduleId(address(stablecoin), SCHEDULE_INDEX);
        uint256 balanceBefore = dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX);
        vm.expectRevert();
        dcaManager.depositToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, AMOUNT_TO_DEPOSIT);
        assertEq(dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX), balanceBefore);
        vm.stopPrank();
    }

    function testDepositRevertsOnWrongScheduleId() external {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        bytes32 wrongId = keccak256("not-a-schedule");
        uint256 balanceBefore = dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX);
        vm.expectRevert(IDcaManager.DcaManager__ScheduleIdAndIndexMismatch.selector);
        dcaManager.depositToken(address(stablecoin), SCHEDULE_INDEX, wrongId, AMOUNT_TO_DEPOSIT);
        assertEq(dcaManager.getMyScheduleTokenBalance(address(stablecoin), SCHEDULE_INDEX), balanceBefore);
        vm.stopPrank();
    }
} 