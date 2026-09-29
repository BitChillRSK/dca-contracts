// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {toBatch, NO_MIN_RBTC_OUT} from "test/utils/BatchBuyOne.sol";
import "../Constants.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

/**
 * @notice R51: the swapper's per-batch minimum rBTC output, on whichever venue the lane is running.
 * @dev The check lives in the shared `PurchaseRbtc` pipeline, so it must behave identically on MoC redemption
 *      and on a Uniswap swap, and on an idle or a lending route. Rather than predict the output — which the
 *      lending lanes only reach approximately — each test reads the measured amount out of the revert the
 *      contract itself reports, which also proves the failure leaves no trace to clean up.
 */
contract BatchMinRbtcOutTest is DcaDappTest {
    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev `0` is the pre-R51 contract on every venue: the batch buys and credits exactly as before.
    function testZeroMinimumBuysAsBefore() external {
        uint256 rbtcBefore = _accumulatedRbtc();
        uint256 balanceBefore = _schedule().tokenBalance;

        _buy(NO_MIN_RBTC_OUT);

        assertGt(_accumulatedRbtc(), rbtcBefore, "a zero minimum must not stop the purchase");
        assertEq(_schedule().tokenBalance, balanceBefore - AMOUNT_TO_SPEND);
        assertGt(_schedule().cadenceAnchor, 0);
    }

    /// @dev Equality succeeds: a minimum set to exactly what the batch buys is not a failure.
    function testMinimumEqualToMeasuredOutputSucceeds() external {
        uint256 measured = _measuredOutput();
        uint256 rbtcBefore = _accumulatedRbtc();

        _buy(measured);

        assertGt(_accumulatedRbtc() - rbtcBefore, 0, "the batch must credit the buyer");
        assertLe(_accumulatedRbtc() - rbtcBefore, measured, "credits cannot exceed gross measured output");
    }

    /// @dev One wei above what the batch buys fails. On Dex the router enforces `max(amountOutLowerBound, minRbtcOut)`
    ///      before the measured check; on MoC only the post-check fires.
    function testMinimumOneWeiAboveMeasuredOutputReverts() external {
        uint256 measured = _measuredOutput();

        IDcaManager.Batch memory batch = _batch(measured + 1);
        vm.prank(SWAPPER);
        _expectMinimumViolationRevert(measured, measured + 1);
        dcaManager.batchBuyRbtc(batch);
    }

    /// @dev A violated minimum unwinds the whole batch: the schedule keeps its balance and its purchase slot,
    ///      the handler keeps no rBTC and no fee, and the funds never left the route.
    function testViolatedMinimumRollsBackTheWholeBatch() external {
        IDcaManager.DcaSchedule memory before = _schedule();
        uint256 rbtcBefore = _accumulatedRbtc();
        uint256 feeCollectorStableBefore = stablecoin.balanceOf(FEE_COLLECTOR);
        uint256 feeCollectorRbtcBefore = isDexSwaps ? wrbtc.balanceOf(FEE_COLLECTOR) : FEE_COLLECTOR.balance;
        uint256 handlerCashBefore = _handlerRbtcCash();
        uint256 handlerStablecoinBefore = stablecoin.balanceOf(address(stablecoinHandler));

        IDcaManager.Batch memory batch = _batch(type(uint256).max);
        vm.prank(SWAPPER);
        (bool ok,) = address(dcaManager).call(abi.encodeCall(IDcaManager.batchBuyRbtc, (batch)));
        assertFalse(ok, "an unreachable minimum must revert the batch");

        IDcaManager.DcaSchedule memory afterCall = _schedule();
        assertEq(afterCall.tokenBalance, before.tokenBalance, "the schedule keeps its deposit");
        assertEq(
            afterCall.cadenceAnchor,
            before.cadenceAnchor,
            "the schedule keeps its purchase slot, so the swapper can retry this period"
        );
        assertEq(_accumulatedRbtc(), rbtcBefore, "no buyer was credited");
        assertEq(stablecoin.balanceOf(FEE_COLLECTOR), feeCollectorStableBefore, "no stablecoin fee was kept");
        uint256 feeCollectorRbtcAfter = isDexSwaps ? wrbtc.balanceOf(FEE_COLLECTOR) : FEE_COLLECTOR.balance;
        assertEq(feeCollectorRbtcAfter, feeCollectorRbtcBefore, "no rBTC fee was kept");
        assertEq(_handlerRbtcCash(), handlerCashBefore, "the handler bought and kept no rBTC");
        assertEq(
            stablecoin.balanceOf(address(stablecoinHandler)),
            handlerStablecoinBefore,
            "nothing was redeemed out of the route"
        );

        // The retry the bot would send next clears the same period.
        _buy(NO_MIN_RBTC_OUT);
        assertEq(_schedule().tokenBalance, before.tokenBalance - AMOUNT_TO_SPEND);
    }

    /// @dev The one-handler entry point is the bot's retry path, and it enforces the same field.
    function testOneHandlerRetryEnforcesTheSameMinimum() external {
        uint256 measured = _measuredOutput();

        IDcaManager.Batch[] memory batches = new IDcaManager.Batch[](1);
        batches[0] = _batch(measured + 1);
        vm.prank(SWAPPER);
        _expectMinimumViolationRevert(measured, measured + 1);
        dcaManager.batchBuyRbtcAcrossHandlers(batches);

        // The same batch, retried one-handler with a reachable minimum, goes through.
        _buy(measured);
        assertGt(_accumulatedRbtc(), 0);
        assertLe(_accumulatedRbtc(), measured);
    }

    /// @dev The bound is on measured venue output, not buyer credit. A min set to the buyer's
    ///      credit (below Q after the rBTC fee) still succeeds; one wei above Q fails.
    function testMinimumIsGrossVenueOutputNotBuyerCredit() external {
        uint256 measured = _measuredOutput();

        uint256 snapshot = vm.snapshot();
        uint256 rbtcBefore = _accumulatedRbtc();
        _buy(NO_MIN_RBTC_OUT);
        uint256 credit = _accumulatedRbtc() - rbtcBefore;
        assertLt(credit, measured, "the rBTC fee must leave buyer credit strictly below gross Q");
        vm.revertTo(snapshot);

        snapshot = vm.snapshot();
        _buy(credit);
        assertGt(_accumulatedRbtc() - rbtcBefore, 0, "a min equal to buyer credit must still clear gross Q");
        vm.revertTo(snapshot);

        IDcaManager.Batch memory batch = _batch(measured + 1);
        vm.prank(SWAPPER);
        _expectMinimumViolationRevert(measured, measured + 1);
        dcaManager.batchBuyRbtc(batch);
    }

    function _expectMinimumViolationRevert(uint256 measured, uint256 minRbtcOut) private {
        if (isDexSwaps) {
            // The router rejects `max(amountOutLowerBound, minRbtcOut)` before the measured check can run.
            // The mock and the live SwapRouter02 word that rejection differently, so match on neither:
            // any revert is the assertion, and the venue-specific string is not the behaviour under test.
            vm.expectRevert();
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum.selector, measured, minRbtcOut)
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Gross venue output Q. On MoC, an unreachable `minRbtcOut` reverts with Q in
     *      `PurchaseRbtc__BelowSwapperMinimum` and rolls the whole batch back. On Dex, the router would
     *      reject `type(uint256).max` before that check, so take a snapshot, buy with `0`, sum handler
     *      WRBTC (credits + dust) and collector WRBTC (fee), and revert the world.
     */
    function _measuredOutput() private returns (uint256 measured) {
        if (isDexSwaps) {
            uint256 snapshot = vm.snapshot();
            uint256 handlerBefore = wrbtc.balanceOf(address(stablecoinHandler));
            uint256 collectorBefore = wrbtc.balanceOf(FEE_COLLECTOR);
            _buy(NO_MIN_RBTC_OUT);
            measured = (wrbtc.balanceOf(address(stablecoinHandler)) - handlerBefore)
                + (wrbtc.balanceOf(FEE_COLLECTOR) - collectorBefore);
            assertGt(measured, 0, "the batch must buy something for the minimum to be meaningful");
            vm.revertTo(snapshot);
            return measured;
        }

        IDcaManager.Batch memory batch = _batch(type(uint256).max);
        vm.prank(SWAPPER);
        (bool ok, bytes memory returnData) = address(dcaManager).call(abi.encodeCall(IDcaManager.batchBuyRbtc, (batch)));

        assertFalse(ok, "an unreachable minimum must revert");
        assertEq(
            bytes4(returnData),
            IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum.selector,
            "the probe must fail on the caller minimum, not on something else"
        );

        bytes memory args = new bytes(returnData.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = returnData[i + 4];
        }
        (measured,) = abi.decode(args, (uint256, uint256));
        assertGt(measured, 0, "the batch must buy something for the minimum to be meaningful");
    }

    function _batch(uint256 minRbtcOut) private view returns (IDcaManager.Batch memory) {
        uint64[] memory scheduleIds = new uint64[](1);
        scheduleIds[0] = _scheduleId();
        return toBatch(scheduleIds, address(stablecoin), s_routeIndex, minRbtcOut);
    }

    function _buy(uint256 minRbtcOut) private {
        IDcaManager.Batch memory batch = _batch(minRbtcOut);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
    }

    function _schedule() private view returns (IDcaManager.DcaSchedule memory) {
        return scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
    }

    function _scheduleId() private view returns (uint64) {
        return scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
    }

    function _accumulatedRbtc() private view returns (uint256) {
        return IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
    }

    /// @dev MoC pays native rBTC into the handler; the Uniswap route holds WRBTC until withdrawal.
    function _handlerRbtcCash() private view returns (uint256) {
        return isDexSwaps ? wrbtc.balanceOf(address(stablecoinHandler)) : address(stablecoinHandler).balance;
    }
}
