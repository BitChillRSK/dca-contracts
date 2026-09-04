//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {UNUSED_SCHEDULE_ID} from "../utils/BatchBuyOne.sol";
import "./TestsHelper.t.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

/**
 * @notice R64: no entry point can reach a schedule that is not the caller's.
 * @dev A schedule is keyed by `(scheduleId, user)`, so ownership is the mapping key rather than a
 *      checked field: `s_dcaSchedules[scheduleId][msg.sender]` lands on an empty struct when the id
 *      belongs to somebody else, and an empty struct is refused as an id the caller does not hold.
 *      There is no owner check to write and none to forget, which is the point — but "the key makes it
 *      impossible" is a claim about every entry point at once, so this walks the whole mutator surface
 *      rather than a sample of it. A stranger's id and an id nobody holds are the same case here, and
 *      the tests assert they produce the same refusal.
 */
contract ScheduleOwnershipTest is DcaDappTest {
    address private s_stranger;

    function setUp() public override {
        super.setUp();
        s_stranger = makeAddr("scheduleStranger");
        deal(address(stablecoin), s_stranger, AMOUNT_TO_DEPOSIT);
    }

    function _scheduleId() private view returns (uint64) {
        return scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
    }

    /// @dev What a stranger gets: the pair `(scheduleId, stranger)` is not a schedule.
    function _notOwner(uint64 scheduleId) private view returns (bytes memory) {
        return abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, s_stranger, scheduleId);
    }

    function _inexistent(address caller, uint64 scheduleId) private pure returns (bytes memory) {
        return abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, caller, scheduleId);
    }

    /*//////////////////////////////////////////////////////////////
                        A SCHEDULE SOMEBODY OWNS
    //////////////////////////////////////////////////////////////*/

    function testAStrangerCannotDepositIntoAnotherUsersSchedule() external {
        uint64 scheduleId = _scheduleId();
        vm.startPrank(s_stranger);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.depositToken(scheduleId, AMOUNT_TO_DEPOSIT);
        vm.stopPrank();
    }

    function testAStrangerCannotWithdrawFromAnotherUsersSchedule() external {
        uint64 scheduleId = _scheduleId();
        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.withdrawToken(scheduleId, AMOUNT_TO_SPEND);
    }

    function testAStrangerCannotWithdrawTokenAndInterestFromAnotherUsersSchedule() external {
        uint64 scheduleId = _scheduleId();
        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.withdrawTokenAndInterest(scheduleId, AMOUNT_TO_SPEND);
    }

    function testAStrangerCannotEditAnotherUsersSchedule() external {
        uint64 scheduleId = _scheduleId();

        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.updatePurchaseAmount(scheduleId, AMOUNT_TO_SPEND);

        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.updatePurchasePeriod(scheduleId, MIN_PURCHASE_PERIOD);

        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.setSchedulePaused(scheduleId, true);
    }

    function testAStrangerCannotDeleteAnotherUsersSchedule() external {
        uint64 scheduleId = _scheduleId();
        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.deleteDcaSchedule(scheduleId);
    }

    function testAStrangerCannotTopUpAnotherUsersScheduleFromInterest() external {
        uint64 scheduleId = _scheduleId();
        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.topUpFromInterest(scheduleId, 1);
    }

    /// @dev The schedule has to come through all of that untouched, not merely have refused each call.
    function testARefusedStrangerLeavesTheScheduleExactlyAsItWas() external {
        IDcaManager.DcaSchedule memory before = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);

        this.testAStrangerCannotDepositIntoAnotherUsersSchedule();
        this.testAStrangerCannotEditAnotherUsersSchedule();
        this.testAStrangerCannotDeleteAnotherUsersSchedule();

        IDcaManager.DcaSchedule memory unchanged = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(unchanged.scheduleId, before.scheduleId);
        assertEq(unchanged.tokenBalance, before.tokenBalance, "a stranger moved the balance");
        assertEq(unchanged.purchaseAmount, before.purchaseAmount);
        assertEq(unchanged.purchasePeriod, before.purchasePeriod);
        assertEq(unchanged.paused, before.paused);
        assertEq(dcaManager.getDcaSchedules(s_stranger, address(stablecoin)).length, 0, "a stranger gained a schedule");
    }

    /*//////////////////////////////////////////////////////////////
                        A SCHEDULE NOBODY OWNS
    //////////////////////////////////////////////////////////////*/

    function testEveryMutatorRejectsAnIdThatBelongsToNoSchedule() external {
        uint64 ghost = UNUSED_SCHEDULE_ID;

        vm.startPrank(USER);
        vm.expectRevert(_inexistent(USER, ghost));
        dcaManager.depositToken(ghost, AMOUNT_TO_DEPOSIT);

        vm.expectRevert(_inexistent(USER, ghost));
        dcaManager.withdrawToken(ghost, AMOUNT_TO_SPEND);

        vm.expectRevert(_inexistent(USER, ghost));
        dcaManager.withdrawTokenAndInterest(ghost, AMOUNT_TO_SPEND);

        vm.expectRevert(_inexistent(USER, ghost));
        dcaManager.updatePurchaseAmount(ghost, AMOUNT_TO_SPEND);

        vm.expectRevert(_inexistent(USER, ghost));
        dcaManager.updatePurchasePeriod(ghost, MIN_PURCHASE_PERIOD);

        vm.expectRevert(_inexistent(USER, ghost));
        dcaManager.setSchedulePaused(ghost, true);

        vm.expectRevert(_inexistent(USER, ghost));
        dcaManager.deleteDcaSchedule(ghost);

        vm.expectRevert(_inexistent(USER, ghost));
        dcaManager.topUpFromInterest(ghost, 1);
        vm.stopPrank();
    }

    /// @dev Zero is not a schedule: ids start at 1, so an uninitialised argument must not open one.
    function testIdZeroBelongsToNoSchedule() external {
        vm.prank(USER);
        vm.expectRevert(_inexistent(USER, 0));
        dcaManager.withdrawToken(0, AMOUNT_TO_SPEND);
    }

    /*//////////////////////////////////////////////////////////////
                          OWNERSHIP IS PER USER
    //////////////////////////////////////////////////////////////*/

    /// @dev Two users' schedules share one id space now, so the ids must not collide and each user's
    ///      list must contain only their own.
    function testTwoUsersHoldDistinctIdsInOneIdSpace() external {
        uint64 usersId = _scheduleId();

        vm.startPrank(s_stranger);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();

        IDcaManager.DcaSchedule[] memory strangerSchedules =
            dcaManager.getDcaSchedules(s_stranger, address(stablecoin));
        assertEq(strangerSchedules.length, 1);
        assertTrue(strangerSchedules[0].scheduleId != usersId, "two live schedules share an id");
        // The first user's schedule is still theirs, and is not reachable under the stranger's key.
        assertEq(dcaManager.getDcaSchedule(USER, usersId).scheduleId, usersId);
        vm.expectRevert(_inexistent(s_stranger, usersId));
        dcaManager.getDcaSchedule(s_stranger, usersId);
    }
}
