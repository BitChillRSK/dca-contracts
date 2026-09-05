// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {toBatch, batchOf, packBatchRow, NO_MIN_RBTC_OUT_RATE} from "test/utils/BatchBuyOne.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../Constants.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

/**
 * @notice R66: one row's owner cannot cost every other row in the same batch its purchase.
 * @dev Every test here composes the batch the way the swapper does — against the state it can see —
 *      then lets the schedule's own owner change that state before submitting the *unchanged* batch,
 *      which is exactly the one-block front-run the item was opened for. What must hold afterwards is
 *      the same in every case: the touched row is skipped with a reason, it keeps its balance and its
 *      purchase slot, and every other row in the batch still buys.
 */
contract BatchRowFrontRunningTest is DcaDappTest {
    uint256 private constant EDITED_INDEX = 0;
    uint256 private constant BYSTANDER_INDEX = 1;

    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
              ONE OWNER'S EDIT NO LONGER FAILS THE BATCH
    //////////////////////////////////////////////////////////////*/

    /// @dev `setSchedulePaused` front-run into the tick.
    function testPausingARowSkipsOnlyThatRow() external {
        _assertOwnerActionSkipsOnlyItsOwnRow(
            _Action.Pause, IDcaManager.PurchaseRowSkipReason.SchedulePaused
        );
    }

    /// @dev `deleteDcaSchedule` front-run into the tick.
    function testDeletingARowSkipsOnlyThatRow() external {
        _assertOwnerActionSkipsOnlyItsOwnRow(
            _Action.Delete, IDcaManager.PurchaseRowSkipReason.InexistentSchedule
        );
    }

    /// @dev `withdrawToken` down to below one purchase, front-run into the tick.
    function testWithdrawingBelowOnePurchaseSkipsOnlyThatRow() external {
        _assertOwnerActionSkipsOnlyItsOwnRow(
            _Action.Withdraw, IDcaManager.PurchaseRowSkipReason.BalanceInsufficient
        );
    }

    /// @dev `updatePurchasePeriod` pushing the next due date out, front-run into the tick.
    function testPushingThePeriodOutSkipsOnlyThatRow() external {
        _assertOwnerActionSkipsOnlyItsOwnRow(
            _Action.PushPeriod, IDcaManager.PurchaseRowSkipReason.PeriodNotElapsed
        );
    }

    /// @dev `updatePurchaseAmount` in either direction, front-run into the tick: the packed
    ///      `expectedPurchaseAmount` no longer matches, so the row is dropped rather than purchased at a
    ///      size the swapper never quoted.
    function testEditingTheAmountDownSkipsOnlyThatRow() external {
        _assertOwnerActionSkipsOnlyItsOwnRow(
            _Action.AmountDown, IDcaManager.PurchaseRowSkipReason.PurchaseAmountMismatch
        );
    }

    function testEditingTheAmountUpSkipsOnlyThatRow() external {
        _assertOwnerActionSkipsOnlyItsOwnRow(
            _Action.AmountUp, IDcaManager.PurchaseRowSkipReason.PurchaseAmountMismatch
        );
    }

    /*//////////////////////////////////////////////////////////////
                    THE AMOUNT-INCREASE SLIPPAGE GAP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The Background scenario of R66, reproduced: doubling a schedule's purchase amount between the
     *         swapper's quote and its transaction used to let the purchase execute at the larger size against
     *         a minimum sized for the smaller one. The packed expected amount now drops that row instead.
     */
    function testDoublingTheAmountBeforeTheTickDoesNotSpendTheLargerAmount() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        IDcaManager.DcaSchedule memory quoted = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);

        // The swapper composes the batch against the amount it can see.
        IDcaManager.Batch memory batch =
            batchOf(address(stablecoin), scheduleId, quoted.purchaseAmount, s_routeIndex);

        // The owner doubles it before the tick lands.
        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, uint256(quoted.purchaseAmount) * 2);

        uint256 rbtcBefore = _accumulatedRbtc();
        vm.expectEmit(true, true, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__PurchaseRowSkipped(
            address(stablecoin), scheduleId, IDcaManager.PurchaseRowSkipReason.PurchaseAmountMismatch
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);

        IDcaManager.DcaSchedule memory unchangedSchedule =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(unchangedSchedule.tokenBalance, quoted.tokenBalance, "the inflated row was debited anyway");
        assertEq(unchangedSchedule.lastPurchaseTimestamp, quoted.lastPurchaseTimestamp, "it consumed a period");
        assertEq(_accumulatedRbtc(), rbtcBefore, "the inflated row bought rBTC");
    }

    /// @dev The swapper's remedy is simply to requote: a batch naming the schedule's new amount goes through.
    function testRequotingTheNewAmountPurchasesIt() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 newAmount = AMOUNT_TO_SPEND * 2;

        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, newAmount);

        uint256 balanceBefore = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        IDcaManager.Batch memory batch =
            batchOf(address(stablecoin), scheduleId, uint96(newAmount), s_routeIndex);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);

        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance,
            balanceBefore - newAmount,
            "a requoted batch must spend the schedule's new amount"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    A BATCH THAT SKIPS EVERY ROW
    //////////////////////////////////////////////////////////////*/

    /// @dev A non-empty batch that filters down to nothing calls no handler and does not revert.
    function testABatchThatSkipsEveryRowDoesNotRevert() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        IDcaManager.Batch memory batch =
            batchOf(address(stablecoin), scheduleId, uint96(AMOUNT_TO_SPEND), s_routeIndex);

        vm.prank(USER);
        dcaManager.setSchedulePaused(address(stablecoin), scheduleId, true);

        uint256 balanceBefore = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 handlerStablecoinBefore = stablecoin.balanceOf(address(stablecoinHandler));

        vm.expectEmit(true, true, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__PurchaseRowSkipped(
            address(stablecoin), scheduleId, IDcaManager.PurchaseRowSkipReason.SchedulePaused
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);

        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance, balanceBefore);
        assertEq(_accumulatedRbtc(), 0, "an all-skipped batch bought rBTC");
        assertEq(
            stablecoin.balanceOf(address(stablecoinHandler)),
            handlerStablecoinBefore,
            "an all-skipped batch must not reach the handler at all"
        );
    }

    /// @dev The same batch inside `batchBuyRbtcAcrossHandlers`: the emptied handler is passed over and the
    ///      call as a whole still succeeds, rather than the bundle reverting on it.
    function testAnAllSkippedHandlerDoesNotRevertTheBundle() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        IDcaManager.Batch[] memory batches = new IDcaManager.Batch[](1);
        batches[0] = batchOf(address(stablecoin), scheduleId, uint96(AMOUNT_TO_SPEND), s_routeIndex);

        vm.prank(USER);
        dcaManager.setSchedulePaused(address(stablecoin), scheduleId, true);

        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtcAcrossHandlers(batches);

        assertEq(_accumulatedRbtc(), 0, "an all-skipped bundle bought rBTC");
    }

    /// @dev A batch submitted with no rows at all is still malformed swapper input, not a filtered batch.
    function testAGenuinelyEmptyBatchStillReverts() external {
        bytes32[] memory noRows = new bytes32[](0);
        vm.expectRevert(IDcaManager.DcaManager__EmptyBatchPurchaseArrays.selector);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(toBatch(noRows, address(stablecoin), s_routeIndex));
    }

    /*//////////////////////////////////////////////////////////////
                        NOT A SKIP: THE ROUTE
    //////////////////////////////////////////////////////////////*/

    /// @dev A route mismatch is not owner-triggered — no setter moves a schedule's route — so it stays a
    ///      hard revert of the whole batch rather than joining the skip cases.
    function testARouteMismatchStillRevertsTheWholeBatch() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__RouteIndexMismatch.selector,
                address(stablecoin),
                scheduleId,
                s_routeIndex,
                s_routeIndex + 1
            )
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            batchOf(address(stablecoin), scheduleId, uint96(AMOUNT_TO_SPEND), s_routeIndex + 1)
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    enum _Action {
        Pause,
        Delete,
        Withdraw,
        PushPeriod,
        AmountDown,
        AmountUp
    }

    /**
     * @dev The shape every front-running case shares: compose a two-row batch against what the swapper can
     *      see, let the first row's owner take `action`, then submit the unchanged batch. The edited row
     *      must be skipped for `reason` with nothing debited, and the untouched row must still buy.
     */
    function _assertOwnerActionSkipsOnlyItsOwnRow(_Action action, IDcaManager.PurchaseRowSkipReason reason)
        private
    {
        super.createSeveralDcaSchedules();

        (uint64[] memory ids, IDcaManager.DcaSchedule[] memory before) =
            dcaManager.getDcaSchedules(USER, address(stablecoin));

        // The swapper composes both rows against the state it can see.
        bytes32[] memory rows = new bytes32[](2);
        rows[0] = packBatchRow(ids[EDITED_INDEX], before[EDITED_INDEX].purchaseAmount);
        rows[1] = packBatchRow(ids[BYSTANDER_INDEX], before[BYSTANDER_INDEX].purchaseAmount);
        IDcaManager.Batch memory batch = toBatch(rows, address(stablecoin), s_routeIndex);

        uint64 editedId = ids[EDITED_INDEX];
        _takeAction(action, editedId, before[EDITED_INDEX]);

        // What the bystander looked like right before the batch, which the owner's action may have moved
        // (`PushPeriod` buys the edited row first, and nothing else touches the bystander).
        IDcaManager.DcaSchedule memory bystanderBefore =
            dcaManager.getDcaSchedule(address(stablecoin), ids[BYSTANDER_INDEX]);
        IDcaManager.DcaSchedule memory editedBefore = action == _Action.Delete
            ? before[EDITED_INDEX]
            : dcaManager.getDcaSchedule(address(stablecoin), editedId);

        uint256 rbtcBefore = _accumulatedRbtc();
        vm.expectEmit(true, true, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__PurchaseRowSkipped(address(stablecoin), editedId, reason);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);

        // The bystander bought, which is the whole point of the item. Addressed by id, so `delete`'s
        // swap-pop cannot move which schedule this reads.
        IDcaManager.DcaSchedule memory bystanderAfter =
            dcaManager.getDcaSchedule(address(stablecoin), ids[BYSTANDER_INDEX]);
        assertEq(
            bystanderAfter.tokenBalance,
            bystanderBefore.tokenBalance - bystanderBefore.purchaseAmount,
            "the untouched row did not buy"
        );
        assertGt(bystanderAfter.lastPurchaseTimestamp, bystanderBefore.lastPurchaseTimestamp);
        assertGt(_accumulatedRbtc(), rbtcBefore, "no rBTC was bought for the untouched row");

        // The edited row kept everything it had. A deleted one is gone, which is its own assertion.
        if (action == _Action.Delete) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IDcaManager.DcaManager__InexistentSchedule.selector, address(stablecoin), editedId
                )
            );
            dcaManager.getDcaSchedule(address(stablecoin), editedId);
        } else {
            IDcaManager.DcaSchedule memory editedAfter =
                dcaManager.getDcaSchedule(address(stablecoin), editedId);
            assertEq(
                editedAfter.lastPurchaseTimestamp,
                editedBefore.lastPurchaseTimestamp,
                "the skipped row consumed a period"
            );
            assertEq(editedAfter.tokenBalance, editedBefore.tokenBalance, "the skipped row was debited");
        }
    }

    function _takeAction(_Action action, uint64 scheduleId, IDcaManager.DcaSchedule memory schedule) private {
        vm.startPrank(USER);
        if (action == _Action.Pause) {
            dcaManager.setSchedulePaused(address(stablecoin), scheduleId, true);
        } else if (action == _Action.Delete) {
            dcaManager.deleteDcaSchedule(address(stablecoin), scheduleId);
        } else if (action == _Action.Withdraw) {
            // Leave less than one purchase behind, so the row cannot fund itself.
            uint256 leaveBehind = uint256(schedule.purchaseAmount) - 1;
            dcaManager.withdrawToken(
                address(stablecoin), scheduleId, uint256(schedule.tokenBalance) - leaveBehind
            );
        } else if (action == _Action.PushPeriod) {
            // A first purchase is always due, so give the row a purchase to be measured from first.
            vm.stopPrank();
            _buyOneRow(scheduleId, schedule.purchaseAmount);
            vm.startPrank(USER);
            dcaManager.updatePurchasePeriod(address(stablecoin), scheduleId, 52 weeks);
        } else if (action == _Action.AmountDown) {
            // One wei less is already a mismatch, and stays clear of the token minimum, which halving
            // this schedule's share of AMOUNT_TO_SPEND would fall under.
            dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, uint256(schedule.purchaseAmount) - 1);
        } else if (action == _Action.AmountUp) {
            dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, uint256(schedule.purchaseAmount) * 2);
        }
        vm.stopPrank();
    }

    function _buyOneRow(uint64 scheduleId, uint96 expectedPurchaseAmount) private {
        IDcaManager.Batch memory batch =
            batchOf(address(stablecoin), scheduleId, expectedPurchaseAmount, s_routeIndex);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
    }

    function _accumulatedRbtc() private view returns (uint256) {
        return IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
    }
}
