//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import "../../script/Constants.sol";

contract DcaConfigurationTest is DcaDappTest {
    // Events
    event DcaManager__PurchaseAmountSet(address indexed user, bytes32 indexed scheduleId, uint256 indexed purchaseAmount);
    event DcaManager__PurchasePeriodSet(address indexed user, bytes32 indexed scheduleId, uint256 indexed purchasePeriod);
    event DcaManager__MaxSchedulesPerTokenModified(uint256 indexed maxSchedulesPerToken);
    event DcaManager__DefaultMinPurchaseAmountModified(uint256 indexed newDefaultAmount);
    event DcaManager__TokenMinPurchaseAmountSet(address indexed token, uint256 indexed customAmount);

    function setUp() public override {
        super.setUp();
    }

    ///////////////////////////////
    /// DCA configuration tests ///
    ///////////////////////////////
    function testSetPurchaseAmount() external {
        vm.startPrank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.expectEmit(true, true, true, true);
        emit DcaManager__PurchaseAmountSet(USER, scheduleId, AMOUNT_TO_SPEND);
        dcaManager.setPurchaseAmount(address(stablecoin), SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND);
        assertEq(AMOUNT_TO_SPEND, dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount);
        vm.stopPrank();
    }

    function testSetPurchaseAmountRevertsIfScheduleIdAndIndexMismatch() external {
        vm.startPrank(USER);
        bytes32 wrongScheduleId = keccak256(abi.encodePacked(USER, address(stablecoin), block.timestamp, uint256(999)));
        vm.expectRevert(IDcaManager.DcaManager__ScheduleIdAndIndexMismatch.selector);
        dcaManager.setPurchaseAmount(address(stablecoin), SCHEDULE_INDEX, wrongScheduleId, AMOUNT_TO_SPEND);
        vm.stopPrank();
    }

    function testSetPurchaseAmountRevertsIfInexistentSchedule() external {
        vm.startPrank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.setPurchaseAmount(address(stablecoin), SCHEDULE_INDEX + 1, scheduleId, AMOUNT_TO_SPEND);
        vm.stopPrank();
    }

    function testSetPurchasePeriod() external {
        vm.startPrank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.expectEmit(true, true, true, true);
        emit DcaManager__PurchasePeriodSet(USER, scheduleId, MIN_PURCHASE_PERIOD);
        dcaManager.setPurchasePeriod(address(stablecoin), SCHEDULE_INDEX, scheduleId, MIN_PURCHASE_PERIOD);
        assertEq(MIN_PURCHASE_PERIOD, dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).purchasePeriod);
        vm.stopPrank();
    }

    function testSetPurchasePeriodRevertsIfScheduleIdAndIndexMismatch() external {
        vm.startPrank(USER);
        bytes32 wrongScheduleId = keccak256(abi.encodePacked(USER, address(stablecoin), block.timestamp, uint256(999)));
        vm.expectRevert(IDcaManager.DcaManager__ScheduleIdAndIndexMismatch.selector);
        dcaManager.setPurchasePeriod(address(stablecoin), SCHEDULE_INDEX, wrongScheduleId, MIN_PURCHASE_PERIOD);
        vm.stopPrank();
    }

    function testSetPurchasePeriodRevertsIfInexistentSchedule() external {
        vm.startPrank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        dcaManager.setPurchasePeriod(address(stablecoin), SCHEDULE_INDEX + 1, scheduleId, MIN_PURCHASE_PERIOD);
        vm.stopPrank();
    }

    function testModifyMaxSchedulesPerToken() external {
        vm.expectEmit(true, true, true, true);
        emit DcaManager__MaxSchedulesPerTokenModified(MAX_SCHEDULES_PER_TOKEN);
        vm.startPrank(OWNER);
        dcaManager.modifyMaxSchedulesPerToken(MAX_SCHEDULES_PER_TOKEN);
        assertEq(MAX_SCHEDULES_PER_TOKEN, dcaManager.getMaxSchedulesPerToken());
    }

    function testPurchaseAmountEqualToBalanceSucceeds() external {
        vm.startPrank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        dcaManager.setPurchaseAmount(address(stablecoin), SCHEDULE_INDEX, scheduleId, AMOUNT_TO_DEPOSIT);
        assertEq(AMOUNT_TO_DEPOSIT, dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount);
        vm.stopPrank();
    }

    function testPurchaseAmountCannotExceedBalance() external {
        vm.prank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__PurchaseAmountExceedsBalance.selector,
            address(stablecoin),
            AMOUNT_TO_DEPOSIT + 1,
            AMOUNT_TO_DEPOSIT
        );
        vm.expectRevert(encodedRevert);
        vm.prank(USER);
        dcaManager.setPurchaseAmount(address(stablecoin), SCHEDULE_INDEX, scheduleId, AMOUNT_TO_DEPOSIT + 1);
    }

    function testCreateScheduleFundedForExactlyOnePurchase() external {
        uint256 onePurchaseAmount = AMOUNT_TO_SPEND;
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), onePurchaseAmount);
        dcaManager.createDcaSchedule(
            address(stablecoin), onePurchaseAmount, onePurchaseAmount, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        uint256 scheduleIndex = 1; // setUp already created schedule 0
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), scheduleIndex).scheduleId;
        assertEq(onePurchaseAmount, dcaManager.getDcaSchedule(USER, address(stablecoin), scheduleIndex).tokenBalance);
        assertEq(onePurchaseAmount, dcaManager.getDcaSchedule(USER, address(stablecoin), scheduleIndex).purchaseAmount);
        vm.stopPrank();

        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(stablecoin), scheduleIndex, scheduleId);

        vm.prank(USER);
        assertEq(0, dcaManager.getDcaSchedule(USER, address(stablecoin), scheduleIndex).tokenBalance);
    }

    function testPurchaseAmountMustBeGreaterThanMin() external {
        vm.prank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__PurchaseAmountMustBeGreaterThanMinimum.selector, address(stablecoin), MIN_PURCHASE_AMOUNT
        );
        vm.expectRevert(encodedRevert);
        vm.prank(USER);
        dcaManager.setPurchaseAmount(address(stablecoin), SCHEDULE_INDEX, scheduleId, MIN_PURCHASE_AMOUNT - 1);
    }

    function testPurchasePeriodMustBeGreaterThanMin() external {
        vm.prank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.expectRevert(IDcaManager.DcaManager__PurchasePeriodMustBeGreaterThanMinimum.selector);
        vm.prank(USER);
        dcaManager.setPurchasePeriod(address(stablecoin), SCHEDULE_INDEX, scheduleId, MIN_PURCHASE_PERIOD - 1);
    }

    function testMaxSchedulesPerTokenCannotBeExceeded() external {
        uint256 maxSchedulesPerToken = dcaManager.getMaxSchedulesPerToken();
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__MaxSchedulesPerTokenReached.selector, address(stablecoin)
        );
        for (uint256 i; i < maxSchedulesPerToken; ++i) {
            vm.startPrank(USER);
            stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
            if (i == maxSchedulesPerToken - 1) {
                vm.expectRevert(encodedRevert);
            }
            dcaManager.createDcaSchedule(
                address(stablecoin), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
            );
            vm.stopPrank();
        }
    }

    function testCreateRevertsAfterOwnerLowersMaxBelowCurrentCount() external {
        uint256 maxSchedulesPerToken = dcaManager.getMaxSchedulesPerToken();
        // setUp already created one schedule; fill up to the current max
        for (uint256 i = 1; i < maxSchedulesPerToken; ++i) {
            vm.startPrank(USER);
            stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
            dcaManager.createDcaSchedule(
                address(stablecoin), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
            );
            vm.stopPrank();
        }
        vm.prank(USER);
        assertEq(maxSchedulesPerToken, dcaManager.getDcaSchedules(USER, address(stablecoin)).length);

        uint256 loweredMax = maxSchedulesPerToken - 1;
        vm.prank(OWNER);
        dcaManager.modifyMaxSchedulesPerToken(loweredMax);

        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__MaxSchedulesPerTokenReached.selector, address(stablecoin)
        );
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        vm.expectRevert(encodedRevert);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        vm.stopPrank();
    }

    ///////////////////////////////
    /// Min Purchase Amount tests ///
    ///////////////////////////////

    function testModifyDefaultMinPurchaseAmount() external {
        uint256 newDefaultAmount = 50 ether;
        vm.expectEmit(true, true, true, true);
        emit DcaManager__DefaultMinPurchaseAmountModified(newDefaultAmount);
        vm.startPrank(OWNER);
        dcaManager.modifyDefaultMinPurchaseAmount(newDefaultAmount);
        assertEq(newDefaultAmount, dcaManager.getDefaultMinPurchaseAmount());
        vm.stopPrank();
    }

    function testSetTokenMinPurchaseAmount() external {
        uint256 customAmount = 75 ether;
        vm.expectEmit(true, true, true, true);
        emit DcaManager__TokenMinPurchaseAmountSet(address(stablecoin), customAmount);
        vm.startPrank(OWNER);
        dcaManager.setTokenMinPurchaseAmount(address(stablecoin), customAmount);
        (uint256 returnedAmount, bool isCustom) = dcaManager.getTokenMinPurchaseAmount(address(stablecoin));
        assertEq(customAmount, returnedAmount);
        assertTrue(isCustom);
        vm.stopPrank();
    }

    function testEffectiveMinPurchaseAmountUsesDefaultWhenNoCustomSet() external {
        uint256 defaultAmount = dcaManager.getDefaultMinPurchaseAmount();
        (uint256 returnedAmount, bool isCustom) = dcaManager.getTokenMinPurchaseAmount(address(stablecoin));
        assertEq(defaultAmount, returnedAmount);
        assertFalse(isCustom);
        
        // Verify that a token without custom amount returns the default
        address newToken = makeAddr("newToken");
        (uint256 newTokenAmount, bool newTokenIsCustom) = dcaManager.getTokenMinPurchaseAmount(newToken);
        assertEq(defaultAmount, newTokenAmount);
        assertFalse(newTokenIsCustom);
    }

    function testEffectiveMinPurchaseAmountUsesCustomWhenSet() external {
        uint256 customAmount = 100 ether;
        vm.startPrank(OWNER);
        dcaManager.setTokenMinPurchaseAmount(address(stablecoin), customAmount);
        vm.stopPrank();
        
        (uint256 returnedAmount, bool isCustom) = dcaManager.getTokenMinPurchaseAmount(address(stablecoin));
        assertEq(customAmount, returnedAmount);
        assertTrue(isCustom);
    }

    function testMinPurchaseAmountValidationUsesEffectiveAmount() external {
        uint256 customAmount = 30 ether;
        vm.startPrank(OWNER);
        dcaManager.setTokenMinPurchaseAmount(address(stablecoin), customAmount);
        vm.stopPrank();
        
        vm.startPrank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        
        // Should revert with the custom amount, not the default
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__PurchaseAmountMustBeGreaterThanMinimum.selector, address(stablecoin), customAmount
        );
        vm.expectRevert(encodedRevert);
        dcaManager.setPurchaseAmount(address(stablecoin), SCHEDULE_INDEX, scheduleId, customAmount - 1);
        vm.stopPrank();
    }
}
