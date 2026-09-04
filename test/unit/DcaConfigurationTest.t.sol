//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {UNUSED_SCHEDULE_ID} from "../utils/BatchBuyOne.sol";
import "../Constants.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

contract DcaConfigurationTest is DcaDappTest {
    // Events
    event DcaManager__PurchaseAmountUpdated(
        address indexed user, uint64 indexed scheduleId, uint256 previousAmount, uint256 newAmount
    );
    event DcaManager__PurchasePeriodUpdated(
        address indexed user, uint64 indexed scheduleId, uint256 previousPeriod, uint256 newPeriod
    );
    event DcaManager__MaxSchedulesPerTokenModified(uint256 maxSchedulesPerToken);
    event DcaManager__DefaultMinPurchaseAmountModified(uint256 newDefaultAmount);
    event DcaManager__TokenMinPurchaseAmountSet(address indexed token, uint256 customAmount);

    function setUp() public override {
        super.setUp();
    }

    ///////////////////////////////
    /// DCA configuration tests ///
    ///////////////////////////////
    function testUpdatePurchaseAmount() external {
        uint256 newPurchaseAmount = AMOUNT_TO_SPEND / 2;
        vm.startPrank(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        // The first edit after createDcaSchedule reports the amount that call wrote
        vm.expectEmit(true, true, true, true);
        emit DcaManager__PurchaseAmountUpdated(USER, scheduleId, AMOUNT_TO_SPEND, newPurchaseAmount);
        dcaManager.updatePurchaseAmount(scheduleId, newPurchaseAmount);
        assertEq(newPurchaseAmount, scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount);
        // A second edit reports the amount the first one wrote
        vm.expectEmit(true, true, true, true);
        emit DcaManager__PurchaseAmountUpdated(USER, scheduleId, newPurchaseAmount, AMOUNT_TO_SPEND);
        dcaManager.updatePurchaseAmount(scheduleId, AMOUNT_TO_SPEND);
        assertEq(AMOUNT_TO_SPEND, scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount);
        vm.stopPrank();
    }

    function testUpdatePurchaseAmountRevertsIfScheduleDoesNotExist() external {
        vm.startPrank(USER);
        uint64 wrongScheduleId = UNUSED_SCHEDULE_ID;
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, USER, wrongScheduleId)
        );
        dcaManager.updatePurchaseAmount(wrongScheduleId, AMOUNT_TO_SPEND);
        vm.stopPrank();
    }

    /// @dev The caller is half the storage key, so another account's id simply is not one they hold.
    function testUpdatePurchaseAmountRevertsIfCallerDoesNotOwnTheSchedule() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        address stranger = makeAddr("notTheOwner");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, stranger, scheduleId));
        dcaManager.updatePurchaseAmount(scheduleId, AMOUNT_TO_SPEND);
    }

    function testUpdatePurchasePeriod() external {
        uint256 newPurchasePeriod = MIN_PURCHASE_PERIOD * 7;
        vm.startPrank(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        // The first edit after createDcaSchedule reports the period that call wrote
        vm.expectEmit(true, true, true, true);
        emit DcaManager__PurchasePeriodUpdated(USER, scheduleId, MIN_PURCHASE_PERIOD, newPurchasePeriod);
        dcaManager.updatePurchasePeriod(scheduleId, newPurchasePeriod);
        assertEq(newPurchasePeriod, scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchasePeriod);
        // A second edit reports the period the first one wrote
        vm.expectEmit(true, true, true, true);
        emit DcaManager__PurchasePeriodUpdated(USER, scheduleId, newPurchasePeriod, MIN_PURCHASE_PERIOD);
        dcaManager.updatePurchasePeriod(scheduleId, MIN_PURCHASE_PERIOD);
        assertEq(MIN_PURCHASE_PERIOD, scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchasePeriod);
        vm.stopPrank();
    }

    function testUpdatePurchasePeriodRevertsIfScheduleDoesNotExist() external {
        vm.startPrank(USER);
        uint64 wrongScheduleId = UNUSED_SCHEDULE_ID;
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, USER, wrongScheduleId)
        );
        dcaManager.updatePurchasePeriod(wrongScheduleId, MIN_PURCHASE_PERIOD);
        vm.stopPrank();
    }

    /// @dev The caller is half the storage key, so another account's id simply is not one they hold.
    function testUpdatePurchasePeriodRevertsIfCallerDoesNotOwnTheSchedule() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        address stranger = makeAddr("notTheOwner");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, stranger, scheduleId));
        dcaManager.updatePurchasePeriod(scheduleId, MIN_PURCHASE_PERIOD);
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
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        dcaManager.updatePurchaseAmount(scheduleId, AMOUNT_TO_DEPOSIT);
        assertEq(AMOUNT_TO_DEPOSIT, scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount);
        vm.stopPrank();
    }

    function testPurchaseAmountCannotExceedBalance() external {
        vm.prank(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__PurchaseAmountExceedsBalance.selector,
            address(stablecoin),
            AMOUNT_TO_DEPOSIT + 1,
            AMOUNT_TO_DEPOSIT
        );
        vm.expectRevert(encodedRevert);
        vm.prank(USER);
        dcaManager.updatePurchaseAmount(scheduleId, AMOUNT_TO_DEPOSIT + 1);
    }

    function testCreateScheduleFundedForExactlyOnePurchase() external {
        uint256 onePurchaseAmount = AMOUNT_TO_SPEND;
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), onePurchaseAmount);
        dcaManager.createDcaSchedule(
            address(stablecoin), onePurchaseAmount, onePurchaseAmount, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        uint256 scheduleIndex = 1; // setUp already created schedule 0
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), scheduleIndex);
        assertEq(onePurchaseAmount, scheduleAt(dcaManager, USER, address(stablecoin), scheduleIndex).tokenBalance);
        assertEq(onePurchaseAmount, scheduleAt(dcaManager, USER, address(stablecoin), scheduleIndex).purchaseAmount);
        vm.stopPrank();

        buyRbtcOne(USER, scheduleId);

        vm.prank(USER);
        assertEq(0, scheduleAt(dcaManager, USER, address(stablecoin), scheduleIndex).tokenBalance);
    }

    function testPurchaseAmountMustBeGreaterThanMin() external {
        vm.prank(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__PurchaseAmountMustBeGreaterThanMinimum.selector, address(stablecoin), MIN_PURCHASE_AMOUNT
        );
        vm.expectRevert(encodedRevert);
        vm.prank(USER);
        dcaManager.updatePurchaseAmount(scheduleId, MIN_PURCHASE_AMOUNT - 1);
    }

    function testPurchasePeriodMustBeGreaterThanMin() external {
        vm.prank(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.expectRevert(IDcaManager.DcaManager__PurchasePeriodMustBeGreaterThanMinimum.selector);
        vm.prank(USER);
        dcaManager.updatePurchasePeriod(scheduleId, MIN_PURCHASE_PERIOD - 1);
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
                address(stablecoin), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
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
                address(stablecoin), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
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
            address(stablecoin), AMOUNT_TO_DEPOSIT / 2, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
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
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        
        // Should revert with the custom amount, not the default
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__PurchaseAmountMustBeGreaterThanMinimum.selector, address(stablecoin), customAmount
        );
        vm.expectRevert(encodedRevert);
        dcaManager.updatePurchaseAmount(scheduleId, customAmount - 1);
        vm.stopPrank();
    }
}
