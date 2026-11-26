//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ILendingHandler} from "../../src/interfaces/ILendingHandler.sol";
import {UNUSED_SCHEDULE_ID} from "../utils/BatchBuyOne.sol";
import "./TestsHelper.t.sol";
import {scheduleAt, scheduleIdAt, scheduleCount} from "test/utils/ScheduleAt.sol";

/**
 * @notice R64: no entry point can reach a schedule that is not the caller's.
 * @dev A schedule is keyed by `(token, scheduleId)`, so ownership is a **checked field** rather than
 *      the mapping key: `_callersSchedule` compares the stored `user` against `msg.sender`. That check
 *      exists once, and every user-facing mutator that takes a `scheduleId` reaches a schedule through
 *      it. `withdrawLendingShares` takes no id: it walks the caller's own id list and reads each
 *      schedule directly (AGENTS.md invariant 8). "Checked in the one place they all go through" is a
 *      claim about every entry point at once, and a checked owner is exactly the kind of thing that can
 *      be forgotten on a path added later. So this walks the whole mutator surface rather than a
 *      sample of it, including the share exit, and fails if an entry point reaches another user's
 *      schedule.
 *
 *      Two refusals, deliberately distinguished: a schedule that exists and belongs to somebody else
 *      reverts `DcaManager__NotScheduleOwner` and names the owner, while a pair that addresses no
 *      schedule at all reverts `DcaManager__InexistentSchedule`. Under the previous key those were the
 *      same case; keeping them apart is what makes a wrong-stablecoin call diagnosable.
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

    /// @dev What a stranger gets: the schedule is there, and its stored owner is not them.
    function _notOwner(uint64 scheduleId) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            IDcaManager.DcaManager__NotScheduleOwner.selector, address(stablecoin), scheduleId, USER
        );
    }

    /// @dev What anybody gets for an id no schedule of this stablecoin holds.
    function _inexistent(uint64 scheduleId) private view returns (bytes memory) {
        return
            abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, address(stablecoin), scheduleId);
    }

    /*//////////////////////////////////////////////////////////////
                        A SCHEDULE SOMEBODY OWNS
    //////////////////////////////////////////////////////////////*/

    function testAStrangerCannotDepositIntoAnotherUsersSchedule() external {
        uint64 scheduleId = _scheduleId();
        vm.startPrank(s_stranger);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.depositToken(address(stablecoin), scheduleId, AMOUNT_TO_DEPOSIT);
        vm.stopPrank();
    }

    function testAStrangerCannotWithdrawFromAnotherUsersSchedule() external {
        uint64 scheduleId = _scheduleId();
        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.withdrawToken(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
    }

    function testAStrangerCannotWithdrawTokenAndInterestFromAnotherUsersSchedule() external {
        uint64 scheduleId = _scheduleId();
        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.withdrawTokenAndInterest(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
    }

    function testAStrangerCannotEditAnotherUsersSchedule() external {
        uint64 scheduleId = _scheduleId();

        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.setPurchaseAmount(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);

        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.setPurchasePeriod(address(stablecoin), scheduleId, MIN_PURCHASE_PERIOD);

        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.setSchedulePaused(address(stablecoin), scheduleId, true);
    }

    function testAStrangerCannotDeleteAnotherUsersSchedule() external {
        uint64 scheduleId = _scheduleId();
        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.deleteDcaSchedule(address(stablecoin), scheduleId, type(uint256).max);
    }

    function testAStrangerCannotTopUpAnotherUsersScheduleFromInterest() external {
        uint64 scheduleId = _scheduleId();
        vm.prank(s_stranger);
        vm.expectRevert(_notOwner(scheduleId));
        dcaManager.topUpFromInterest(address(stablecoin), scheduleId, 1);
    }

    /// @dev The schedule has to come through all of that untouched, not merely have refused each call.
    function testARefusedStrangerLeavesTheScheduleExactlyAsItWas() external {
        IDcaManager.DcaSchedule memory before = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint64 idBefore = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);

        this.testAStrangerCannotDepositIntoAnotherUsersSchedule();
        this.testAStrangerCannotEditAnotherUsersSchedule();
        this.testAStrangerCannotDeleteAnotherUsersSchedule();

        IDcaManager.DcaSchedule memory unchanged = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(
            scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX), idBefore, "a stranger moved the id"
        );
        assertEq(unchanged.tokenBalance, before.tokenBalance, "a stranger moved the balance");
        assertEq(unchanged.purchaseAmount, before.purchaseAmount);
        assertEq(unchanged.purchasePeriod, before.purchasePeriod);
        assertEq(unchanged.paused, before.paused);
        assertEq(scheduleCount(dcaManager, s_stranger, address(stablecoin)), 0, "a stranger gained a schedule");
    }

    /// @dev The share exit takes no id and reads the caller's own list, so a stranger's exit clears
    ///      only the stranger's schedule and moves only the stranger's shares.
    function testAStrangersShareExitLeavesAnotherUsersPositionUntouched() external {
        if (!isLendingLane) return;
        ILendingHandler lendingHandler = ILendingHandler(address(stablecoinHandler));
        uint64 usersId = _scheduleId();
        uint256 usersBalance = dcaManager.getDcaSchedule(address(stablecoin), usersId).tokenBalance;
        uint256 usersShares = lendingHandler.getUserShares(USER);
        assertGt(usersBalance, 0);
        assertGt(usersShares, 0);

        vm.prank(s_stranger);
        vm.expectRevert(abi.encodeWithSelector(ILendingHandler.LendingHandler__NoSharesToWithdraw.selector, s_stranger));
        dcaManager.withdrawLendingShares(address(stablecoin), s_routeIndex);

        vm.startPrank(s_stranger);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        dcaManager.withdrawLendingShares(address(stablecoin), s_routeIndex);
        vm.stopPrank();

        assertEq(scheduleAt(dcaManager, s_stranger, address(stablecoin), 0).tokenBalance, 0);
        assertEq(lendingHandler.getUserShares(s_stranger), 0);
        assertEq(
            dcaManager.getDcaSchedule(address(stablecoin), usersId).tokenBalance,
            usersBalance,
            "a stranger's exit cleared another user's balance"
        );
        assertEq(lendingHandler.getUserShares(USER), usersShares, "a stranger's exit moved another user's shares");
    }

    /*//////////////////////////////////////////////////////////////
                        A SCHEDULE NOBODY OWNS
    //////////////////////////////////////////////////////////////*/

    function testEveryMutatorRejectsAnIdThatBelongsToNoSchedule() external {
        uint64 ghost = UNUSED_SCHEDULE_ID;

        vm.startPrank(USER);
        vm.expectRevert(_inexistent(ghost));
        dcaManager.depositToken(address(stablecoin), ghost, AMOUNT_TO_DEPOSIT);

        vm.expectRevert(_inexistent(ghost));
        dcaManager.withdrawToken(address(stablecoin), ghost, AMOUNT_TO_SPEND);

        vm.expectRevert(_inexistent(ghost));
        dcaManager.withdrawTokenAndInterest(address(stablecoin), ghost, AMOUNT_TO_SPEND);

        vm.expectRevert(_inexistent(ghost));
        dcaManager.setPurchaseAmount(address(stablecoin), ghost, AMOUNT_TO_SPEND);

        vm.expectRevert(_inexistent(ghost));
        dcaManager.setPurchasePeriod(address(stablecoin), ghost, MIN_PURCHASE_PERIOD);

        vm.expectRevert(_inexistent(ghost));
        dcaManager.setSchedulePaused(address(stablecoin), ghost, true);

        vm.expectRevert(_inexistent(ghost));
        dcaManager.deleteDcaSchedule(address(stablecoin), ghost, type(uint256).max);

        vm.expectRevert(_inexistent(ghost));
        dcaManager.topUpFromInterest(address(stablecoin), ghost, 1);
        vm.stopPrank();
    }

    /// @dev Zero is not a schedule: ids start at 1, so an uninitialised argument must not open one.
    function testIdZeroBelongsToNoSchedule() external {
        vm.prank(USER);
        vm.expectRevert(_inexistent(0));
        dcaManager.withdrawToken(address(stablecoin), 0, AMOUNT_TO_SPEND);
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

        (uint64[] memory strangerSchedulesIds, IDcaManager.DcaSchedule[] memory strangerSchedules) =
            dcaManager.getDcaSchedules(s_stranger, address(stablecoin));
        assertEq(strangerSchedules.length, 1);
        assertTrue(strangerSchedulesIds[0] != usersId, "two live schedules share an id");
        // The first user's schedule still names them as its owner. Reading is public, so what an id
        // cannot survive is being paired with another stablecoin: that pair addresses nothing.
        assertEq(dcaManager.getDcaSchedule(address(stablecoin), usersId).user, USER);
        address anotherStablecoin = makeAddr("anotherStablecoin");
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, anotherStablecoin, usersId)
        );
        dcaManager.getDcaSchedule(anotherStablecoin, usersId);
    }
}
