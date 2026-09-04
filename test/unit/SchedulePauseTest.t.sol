//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {batchBuyOne, UNUSED_SCHEDULE_ID, toBatch} from "../utils/BatchBuyOne.sol";
import "./TestsHelper.t.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

/**
 * @notice R19: a user can stop and resume purchases on one of their own schedules.
 * @dev The pause must only ever cost the user purchases. Everything that puts money in, edits the
 *      schedule, or takes money out has to keep working, or a pause becomes a way to strand funds.
 */
contract SchedulePauseTest is DcaDappTest {
    event DcaManager__SchedulePauseSet(address indexed user, uint64 indexed scheduleId, bool paused);

    /// @dev A live lending share round-trip loses a few wei to rounding, and how many depends on the
    ///      forked block. These tests assert that the exit paid while paused, not the share math.
    uint256 private constant WITHDRAWAL_ROUNDING_TOLERANCE = 1e12; // 0.0001%, Foundry's 1e18 scale

    function setUp() public override {
        super.setUp();
    }

    function _scheduleId(uint256 scheduleIndex) private view returns (uint64) {
        return scheduleIdAt(dcaManager, USER, address(stablecoin), scheduleIndex);
    }

    function _isPaused(uint256 scheduleIndex) private view returns (bool) {
        return scheduleAt(dcaManager, USER, address(stablecoin), scheduleIndex).paused;
    }

    function _setPaused(uint256 scheduleIndex, bool paused) private {
        uint64 scheduleId = _scheduleId(scheduleIndex);
        vm.prank(USER);
        dcaManager.setSchedulePaused(scheduleId, paused);
    }

    function _schedulePausedRevert(uint256 scheduleIndex) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            IDcaManager.DcaManager__SchedulePaused.selector,
            USER,
            address(stablecoin),
            _scheduleId(scheduleIndex),
            scheduleIndex
        );
    }

    /*//////////////////////////////////////////////////////////////
                              PAUSE STATE
    //////////////////////////////////////////////////////////////*/

    function testSchedulesStartActive() external {
        assertFalse(_isPaused(SCHEDULE_INDEX), "a new schedule was born paused");
    }

    function testOwnerPausesAndResumesTheirSchedule() external {
        uint64 scheduleId = _scheduleId(SCHEDULE_INDEX);

        vm.expectEmit(true, true, false, true);
        emit DcaManager__SchedulePauseSet(USER, scheduleId, true);
        _setPaused(SCHEDULE_INDEX, true);
        assertTrue(_isPaused(SCHEDULE_INDEX));

        vm.expectEmit(true, true, false, true);
        emit DcaManager__SchedulePauseSet(USER, scheduleId, false);
        _setPaused(SCHEDULE_INDEX, false);
        assertFalse(_isPaused(SCHEDULE_INDEX));
    }

    /// @dev Every emitted event is a real transition, so an indexer can replay them without
    ///      deduplicating repeats.
    function testRepeatingTheCurrentStateEmitsNothing() external {
        vm.recordLogs();
        _setPaused(SCHEDULE_INDEX, false);
        assertEq(vm.getRecordedLogs().length, 0, "a no-op resume emitted a transition");
        assertFalse(_isPaused(SCHEDULE_INDEX));

        _setPaused(SCHEDULE_INDEX, true);

        vm.recordLogs();
        _setPaused(SCHEDULE_INDEX, true);
        assertEq(vm.getRecordedLogs().length, 0, "a no-op pause emitted a transition");
        assertTrue(_isPaused(SCHEDULE_INDEX));
    }

    /// @dev An id addresses a schedule directly, so the owner stored on it is what refuses a stranger.
    function testAnotherUserCannotPauseThisSchedule() external {
        uint64 scheduleId = _scheduleId(SCHEDULE_INDEX);

        address stranger = makeAddr("r19Stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, stranger, scheduleId));
        dcaManager.setSchedulePaused(scheduleId, true);

        assertFalse(_isPaused(SCHEDULE_INDEX), "a stranger paused someone else's schedule");
    }

    function testPausingAnInexistentScheduleReverts() external {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, USER, UNUSED_SCHEDULE_ID));
        dcaManager.setSchedulePaused(UNUSED_SCHEDULE_ID, true);

        assertFalse(_isPaused(SCHEDULE_INDEX));
    }

    /// @dev `deleteDcaSchedule` swap-pops, so the pause flag has to travel with the schedule struct
    ///      rather than stay attached to the index it used to sit at.
    function testPauseFollowsTheScheduleThroughSwapPop() external {
        super.createSeveralDcaSchedules();

        uint256 lastIndex = dcaManager.getDcaSchedules(USER, address(stablecoin)).length - 1;
        uint64 movedScheduleId = _scheduleId(lastIndex);
        _setPaused(lastIndex, true);

        uint64 deletedScheduleId = _scheduleId(SCHEDULE_INDEX);
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(deletedScheduleId);

        IDcaManager.DcaSchedule memory moved = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(moved.scheduleId, movedScheduleId, "swap-pop did not move the last schedule here");
        assertTrue(moved.paused, "the pause did not travel with the schedule");
    }

    /*//////////////////////////////////////////////////////////////
                            PURCHASES BLOCKED
    //////////////////////////////////////////////////////////////*/

    function testPausedScheduleRejectsPurchase() external {
        _setPaused(SCHEDULE_INDEX, true);

        IDcaManager.DcaSchedule memory before = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 rbtcBefore = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);

        vm.expectRevert(_schedulePausedRevert(SCHEDULE_INDEX));
        super.buyRbtcOne(USER, before.scheduleId);

        IDcaManager.DcaSchedule memory unchangedSchedule =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(unchangedSchedule.tokenBalance, before.tokenBalance, "a paused schedule was debited");
        assertEq(
            unchangedSchedule.lastPurchaseTimestamp,
            before.lastPurchaseTimestamp,
            "a paused schedule consumed a period"
        );
        assertEq(
            IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER),
            rbtcBefore,
            "a paused schedule bought rBTC"
        );
    }

    /// @dev One paused row fails the whole batch: no other row may keep its debit or timestamp.
    function testOnePausedRowRevertsTheWholeBatch() external {
        super.createSeveralDcaSchedules();

        uint256 pausedIndex = NUM_OF_SCHEDULES - 1;
        _setPaused(pausedIndex, true);

        IDcaManager.DcaSchedule[] memory before = dcaManager.getDcaSchedules(USER, address(stablecoin));
        uint256 rbtcBefore = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);

        address[] memory buyers = new address[](NUM_OF_SCHEDULES);
        uint256[] memory scheduleIndexes = new uint256[](NUM_OF_SCHEDULES);
        uint64[] memory scheduleIds = new uint64[](NUM_OF_SCHEDULES);
        uint256[] memory purchaseAmounts = new uint256[](NUM_OF_SCHEDULES);
        for (uint256 i; i < NUM_OF_SCHEDULES; ++i) {
            buyers[i] = USER;
            scheduleIndexes[i] = i;
            scheduleIds[i] = before[i].scheduleId;
            purchaseAmounts[i] = before[i].purchaseAmount;
        }

        bytes memory pausedRevert = _schedulePausedRevert(pausedIndex);
        vm.prank(SWAPPER);
        vm.expectRevert(pausedRevert);
        dcaManager.batchBuyRbtc(
            toBatch(scheduleIds, buyers, address(stablecoin), s_routeIndex)
        );

        IDcaManager.DcaSchedule[] memory afterSchedules = dcaManager.getDcaSchedules(USER, address(stablecoin));
        for (uint256 i; i < NUM_OF_SCHEDULES; ++i) {
            assertEq(afterSchedules[i].tokenBalance, before[i].tokenBalance, "a batch row kept its debit");
            assertEq(
                afterSchedules[i].lastPurchaseTimestamp,
                before[i].lastPurchaseTimestamp,
                "a batch row kept its timestamp"
            );
        }
        assertEq(
            IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER),
            rbtcBefore,
            "a reverted batch still bought rBTC"
        );
    }

    function testResumingRestoresPurchases() external {
        _setPaused(SCHEDULE_INDEX, true);
        _setPaused(SCHEDULE_INDEX, false);

        super.makeSinglePurchase();
    }

    /*//////////////////////////////////////////////////////////////
                       EVERYTHING ELSE STAYS OPEN
    //////////////////////////////////////////////////////////////*/

    function testPausedScheduleStillAcceptsDeposits() external {
        _setPaused(SCHEDULE_INDEX, true);

        (uint256 balanceAfter, uint256 balanceBefore) = super.depositStablecoin();
        assertEq(balanceAfter - balanceBefore, AMOUNT_TO_DEPOSIT, "a paused schedule refused a deposit");
        assertTrue(_isPaused(SCHEDULE_INDEX), "the deposit resumed the schedule");
    }

    function testPausedScheduleStillAllowsEdits() external {
        _setPaused(SCHEDULE_INDEX, true);

        uint64 scheduleId = _scheduleId(SCHEDULE_INDEX);
        uint256 newPurchaseAmount = AMOUNT_TO_SPEND / 2;
        uint256 newPurchasePeriod = MIN_PURCHASE_PERIOD * 2;

        vm.startPrank(USER);
        dcaManager.updatePurchaseAmount(scheduleId, newPurchaseAmount);
        dcaManager.updatePurchasePeriod(scheduleId, newPurchasePeriod);
        vm.stopPrank();

        IDcaManager.DcaSchedule memory schedule = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(schedule.purchaseAmount, newPurchaseAmount);
        assertEq(schedule.purchasePeriod, newPurchasePeriod);
        assertTrue(schedule.paused, "an edit resumed the schedule");
    }

    function testPausedScheduleStillWithdrawsStablecoin() external {
        _setPaused(SCHEDULE_INDEX, true);

        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);
        super.withdrawStablecoin();
        assertApproxEqRel(
            stablecoin.balanceOf(USER) - userStablecoinBefore,
            AMOUNT_TO_DEPOSIT,
            WITHDRAWAL_ROUNDING_TOLERANCE,
            "the exit did not pay the user on a paused schedule"
        );
    }

    function testPausedScheduleStillPaysAccumulatedRbtc() external {
        super.makeSinglePurchase();
        _setPaused(SCHEDULE_INDEX, true);

        uint256 rbtcAccumulated = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        assertGt(rbtcAccumulated, 0, "nothing was bought to withdraw");

        uint256 userRbtcBefore = USER.balance;
        vm.prank(USER);
        dcaManager.withdrawRbtcFromTokenHandler(address(stablecoin), s_routeIndex);
        assertEq(USER.balance - userRbtcBefore, rbtcAccumulated);
    }

    function testPausedScheduleStillPaysInterest() external onlyLendingLane {
        updateExchangeRate(10 days);
        _setPaused(SCHEDULE_INDEX, true);

        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;

        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);
        assertGt(stablecoin.balanceOf(USER), userStablecoinBefore, "no interest was paid on a paused schedule");
    }

    function testPausedScheduleStillWithdrawsTokenAndInterest() external onlyLendingLane {
        updateExchangeRate(10 days);
        _setPaused(SCHEDULE_INDEX, true);

        uint64 scheduleId = _scheduleId(SCHEDULE_INDEX);
        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);

        vm.prank(USER);
        dcaManager.withdrawTokenAndInterest(scheduleId, AMOUNT_TO_DEPOSIT);

        // Principal plus interest, so strictly more than the principal alone left the handler.
        assertGt(
            stablecoin.balanceOf(USER) - userStablecoinBefore,
            AMOUNT_TO_DEPOSIT,
            "the combined exit did not pay principal and interest on a paused schedule"
        );
        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance, 0);
    }

    function testPausedScheduleStillPaysAllAccumulatedRbtc() external {
        super.makeSinglePurchase();
        _setPaused(SCHEDULE_INDEX, true);

        uint256 rbtcAccumulated = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        assertGt(rbtcAccumulated, 0, "nothing was bought to withdraw");

        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;

        uint256 userRbtcBefore = USER.balance;
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes);
        assertEq(USER.balance - userRbtcBefore, rbtcAccumulated, "the sweep did not pay rBTC on a paused schedule");
    }

    function testPausedScheduleStillAllowsDeletion() external {
        _setPaused(SCHEDULE_INDEX, true);

        uint64 scheduleId = _scheduleId(SCHEDULE_INDEX);
        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);

        vm.prank(USER);
        dcaManager.deleteDcaSchedule(scheduleId);

        assertEq(dcaManager.getDcaSchedules(USER, address(stablecoin)).length, 0);
        assertGt(stablecoin.balanceOf(USER), userStablecoinBefore, "the refund never reached the user");
    }

    /// @dev One paused schedule must not stop the user's other schedules from buying.
    function testPausingOneScheduleLeavesTheOthersBuying() external {
        super.createSeveralDcaSchedules();

        uint256 pausedIndex = NUM_OF_SCHEDULES - 1;
        _setPaused(pausedIndex, true);

        uint256 activeIndex = SCHEDULE_INDEX;
        IDcaManager.DcaSchedule memory active = scheduleAt(dcaManager, USER, address(stablecoin), activeIndex);

        super.buyRbtcOne(USER, active.scheduleId);

        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), activeIndex).tokenBalance,
            active.tokenBalance - active.purchaseAmount,
            "an active sibling schedule did not buy"
        );
    }
}
