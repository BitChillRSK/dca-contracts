//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {UNUSED_SCHEDULE_ID} from "../utils/BatchBuyOne.sol";
import "../Constants.sol";
import {scheduleAt, scheduleIdAt, scheduleCount} from "test/utils/ScheduleAt.sol";

contract DcaConfigurationTest is DcaDappTest {
    // Events
    event DcaManager__PurchaseAmountUpdated(
        address indexed user, uint64 indexed scheduleId, uint256 previousAmount, uint256 newAmount
    );
    event DcaManager__PurchasePeriodUpdated(
        address indexed user, uint64 indexed scheduleId, uint256 previousPeriod, uint256 newPeriod
    );
    event DcaManager__MaxSchedulesPerTokenModified(uint256 maxSchedulesPerToken);
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
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, newPurchaseAmount);
        assertEq(newPurchaseAmount, scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount);
        // A second edit reports the amount the first one wrote
        vm.expectEmit(true, true, true, true);
        emit DcaManager__PurchaseAmountUpdated(USER, scheduleId, newPurchaseAmount, AMOUNT_TO_SPEND);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
        assertEq(AMOUNT_TO_SPEND, scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchaseAmount);
        vm.stopPrank();
    }

    function testUpdatePurchaseAmountRevertsIfScheduleDoesNotExist() external {
        vm.startPrank(USER);
        uint64 wrongScheduleId = UNUSED_SCHEDULE_ID;
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__InexistentSchedule.selector, address(stablecoin), wrongScheduleId
            )
        );
        dcaManager.updatePurchaseAmount(address(stablecoin), wrongScheduleId, AMOUNT_TO_SPEND);
        vm.stopPrank();
    }

    /// @dev The schedule stores its owner, so another account's id is refused as one they do not own.
    function testUpdatePurchaseAmountRevertsIfCallerDoesNotOwnTheSchedule() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        address stranger = makeAddr("notTheOwner");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__NotScheduleOwner.selector, address(stablecoin), scheduleId, USER
            )
        );
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
    }

    function testUpdatePurchasePeriod() external {
        uint256 newPurchasePeriod = MIN_PURCHASE_PERIOD * 7;
        vm.startPrank(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        // The first edit after createDcaSchedule reports the period that call wrote
        vm.expectEmit(true, true, true, true);
        emit DcaManager__PurchasePeriodUpdated(USER, scheduleId, MIN_PURCHASE_PERIOD, newPurchasePeriod);
        dcaManager.updatePurchasePeriod(address(stablecoin), scheduleId, newPurchasePeriod);
        assertEq(newPurchasePeriod, scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchasePeriod);
        // A second edit reports the period the first one wrote
        vm.expectEmit(true, true, true, true);
        emit DcaManager__PurchasePeriodUpdated(USER, scheduleId, newPurchasePeriod, MIN_PURCHASE_PERIOD);
        dcaManager.updatePurchasePeriod(address(stablecoin), scheduleId, MIN_PURCHASE_PERIOD);
        assertEq(MIN_PURCHASE_PERIOD, scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).purchasePeriod);
        vm.stopPrank();
    }

    function testUpdatePurchasePeriodRevertsIfScheduleDoesNotExist() external {
        vm.startPrank(USER);
        uint64 wrongScheduleId = UNUSED_SCHEDULE_ID;
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__InexistentSchedule.selector, address(stablecoin), wrongScheduleId
            )
        );
        dcaManager.updatePurchasePeriod(address(stablecoin), wrongScheduleId, MIN_PURCHASE_PERIOD);
        vm.stopPrank();
    }

    /// @dev The schedule stores its owner, so another account's id is refused as one they do not own.
    function testUpdatePurchasePeriodRevertsIfCallerDoesNotOwnTheSchedule() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        address stranger = makeAddr("notTheOwner");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__NotScheduleOwner.selector, address(stablecoin), scheduleId, USER
            )
        );
        dcaManager.updatePurchasePeriod(address(stablecoin), scheduleId, MIN_PURCHASE_PERIOD);
    }

    function testModifyMaxSchedulesPerToken() external {
        vm.expectEmit(true, true, true, true);
        emit DcaManager__MaxSchedulesPerTokenModified(MAX_SCHEDULES_PER_TOKEN);
        vm.startPrank(OWNER);
        dcaManager.setMaxSchedulesPerToken(MAX_SCHEDULES_PER_TOKEN);
        assertEq(MAX_SCHEDULES_PER_TOKEN, dcaManager.getMaxSchedulesPerToken());
    }

    function testPurchaseAmountEqualToBalanceSucceeds() external {
        vm.startPrank(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, AMOUNT_TO_DEPOSIT);
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
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, AMOUNT_TO_DEPOSIT + 1);
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

        buyRbtcOne(scheduleId);

        vm.prank(USER);
        assertEq(0, scheduleAt(dcaManager, USER, address(stablecoin), scheduleIndex).tokenBalance);
    }

    function testPurchaseAmountMustBeAtLeastMin() external {
        uint256 minPurchaseAmount = dcaManager.getTokenMinPurchaseAmount(address(stablecoin));
        vm.prank(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__PurchaseAmountMustBeAtLeastMinimum.selector, address(stablecoin), minPurchaseAmount
        );
        vm.expectRevert(encodedRevert);
        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, minPurchaseAmount - 1);
    }

    function testPurchasePeriodMustBeAtLeastMin() external {
        vm.prank(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.expectRevert(IDcaManager.DcaManager__PurchasePeriodMustBeAtLeastMinimum.selector);
        vm.prank(USER);
        dcaManager.updatePurchasePeriod(address(stablecoin), scheduleId, MIN_PURCHASE_PERIOD - 1);
    }

    function testCreateRevertsBelowMinPurchaseAmountBeforeTokensMove() external {
        uint256 minPurchaseAmount = dcaManager.getTokenMinPurchaseAmount(address(stablecoin));
        uint256 userBefore = stablecoin.balanceOf(USER);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        vm.expectCall(address(stablecoinHandler), abi.encodeWithSelector(ITokenHandler.depositToken.selector), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__PurchaseAmountMustBeAtLeastMinimum.selector,
                address(stablecoin),
                minPurchaseAmount
            )
        );
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, minPurchaseAmount - 1, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();

        assertEq(stablecoin.balanceOf(USER), userBefore, "a rejected create pulled tokens");
    }

    function testMaxSchedulesPerTokenCannotBeExceeded() external {
        uint256 maxSchedulesPerToken = dcaManager.getMaxSchedulesPerToken();
        bytes memory encodedRevert =
            abi.encodeWithSelector(IDcaManager.DcaManager__MaxSchedulesPerTokenReached.selector, address(stablecoin));
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
        assertEq(maxSchedulesPerToken, scheduleCount(dcaManager, USER, address(stablecoin)));

        uint256 loweredMax = maxSchedulesPerToken - 1;
        vm.prank(OWNER);
        dcaManager.setMaxSchedulesPerToken(loweredMax);

        bytes memory encodedRevert =
            abi.encodeWithSelector(IDcaManager.DcaManager__MaxSchedulesPerTokenReached.selector, address(stablecoin));
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

    function testSetTokenMinPurchaseAmount() external {
        uint256 customAmount = 75 ether;
        vm.expectEmit(true, true, true, true);
        emit DcaManager__TokenMinPurchaseAmountSet(address(stablecoin), customAmount);
        vm.startPrank(OWNER);
        dcaManager.setTokenMinPurchaseAmount(address(stablecoin), customAmount);
        assertEq(dcaManager.getTokenMinPurchaseAmount(address(stablecoin)), customAmount);
        vm.stopPrank();
    }

    function testSetTokenMinPurchaseAmountRevertsOnZero() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__TokenMinPurchaseAmountMustBeGreaterThanZero.selector, address(stablecoin)
            )
        );
        vm.prank(OWNER);
        dcaManager.setTokenMinPurchaseAmount(address(stablecoin), 0);
    }

    function testUnsetTokenMinPurchaseAmountRevertsOnValidation() external {
        address newToken = makeAddr("newToken");
        assertEq(dcaManager.getTokenMinPurchaseAmount(newToken), 0);

        // Clear the harness stablecoin's min so the validation path fails closed without needing a
        // second handler assignment (each handler address is one-shot).
        uint256 tokenMinSlot = uint256(keccak256(abi.encode(address(stablecoin), uint256(5))));
        vm.store(address(dcaManager), bytes32(tokenMinSlot), bytes32(0));
        assertEq(dcaManager.getTokenMinPurchaseAmount(address(stablecoin)), 0);

        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__TokenMinPurchaseAmountNotSet.selector, address(stablecoin))
        );
        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
    }

    function testMinPurchaseAmountValidationUsesConfiguredAmount() external {
        uint256 customAmount = 30 ether;
        vm.startPrank(OWNER);
        dcaManager.setTokenMinPurchaseAmount(address(stablecoin), customAmount);
        vm.stopPrank();

        vm.startPrank(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);

        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__PurchaseAmountMustBeAtLeastMinimum.selector, address(stablecoin), customAmount
        );
        vm.expectRevert(encodedRevert);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, customAmount - 1);
        vm.stopPrank();
    }
}
