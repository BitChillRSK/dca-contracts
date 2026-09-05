//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {UNUSED_SCHEDULE_ID} from "../utils/BatchBuyOne.sol";
import {scheduleAt, scheduleIdAt, scheduleCount} from "test/utils/ScheduleAt.sol";

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
        assertEq(scheduleCount(dcaManager, USER, address(stablecoin)), 1);
    }

    function testCannotDepositZeroStablecoin() external {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.expectRevert(IDcaManager.DcaManager__DepositAmountMustBeGreaterThanZero.selector);
        dcaManager.depositToken(address(stablecoin), scheduleId, 0);
        vm.stopPrank();
    }

    function testDepositRevertsIfStablecoinNotApproved() external {
        vm.startPrank(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 balanceBefore = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        vm.expectRevert();
        dcaManager.depositToken(address(stablecoin), scheduleId, AMOUNT_TO_DEPOSIT);
        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance, balanceBefore);
        vm.stopPrank();
    }

    function testDepositRevertsOnWrongScheduleId() external {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        uint64 wrongId = UNUSED_SCHEDULE_ID;
        uint256 balanceBefore = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, address(stablecoin), wrongId));
        dcaManager.depositToken(address(stablecoin), wrongId, AMOUNT_TO_DEPOSIT);
        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance, balanceBefore);
        vm.stopPrank();
    }
} 