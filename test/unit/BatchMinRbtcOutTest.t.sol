// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {batchOf, NO_MIN_RBTC_OUT_RATE} from "test/utils/BatchBuyOne.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../Constants.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

/**
 * @notice R51 / R66: the swapper's per-batch minimum rBTC output rate, on whichever venue the lane is running.
 * @dev The check lives in the shared `PurchaseRbtc` pipeline, so it must behave identically on MoC redemption
 *      and on a Uniswap swap, and on an idle or a lending route. `minRbtcOutRate` is rBTC wei per raw
 *      stablecoin wei (1e18-scaled), applied to the stablecoin actually spent on this tick — never to a
 *      pre-computed or planned amount. Rather than predict the output — which the lending lanes only reach
 *      approximately — each test reads the measured amount out of the revert the contract itself reports,
 *      which also proves the failure leaves no trace to clean up, then derives the rate that reproduces it.
 */
contract BatchMinRbtcOutTest is DcaDappTest {
    /// @dev A rate no real purchase can clear, but small enough that `rate * netSpend / 1e18` does not
    ///      itself overflow `uint256` — unlike `type(uint256).max`, which is a fine sentinel for an
    ///      absolute minimum but panics as a rate once multiplied by any nonzero spend.
    uint256 private constant UNREACHABLE_RATE = type(uint128).max;

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

        _buy(NO_MIN_RBTC_OUT_RATE);

        assertGt(_accumulatedRbtc(), rbtcBefore, "a zero minimum must not stop the purchase");
        assertEq(_schedule().tokenBalance, balanceBefore - AMOUNT_TO_SPEND);
        assertGt(_schedule().lastPurchaseTimestamp, 0);
    }

    /// @dev A rate that reproduces exactly the measured output, rounded down so the required minimum
    ///      (rounded up in the contract) still clears, is not a failure.
    function testMinimumEqualToMeasuredOutputSucceeds() external {
        uint256 measured = _measuredOutput();
        uint256 rate = _rateFor(measured);
        uint256 rbtcBefore = _accumulatedRbtc();

        _buy(rate);

        assertGe(_accumulatedRbtc() - rbtcBefore, measured, "the batch credited at least the minimum it cleared");
    }

    /// @dev A rate that demands strictly more than the batch actually buys fails. On Dex the router enforces
    ///      `max(amountOutLowerBound, requiredMinimum)` before the measured check; on MoC only the post-check fires.
    function testMinimumAboveMeasuredOutputReverts() external {
        uint256 measured = _measuredOutput();
        uint256 rate = _rateAbove(measured);

        IDcaManager.Batch memory batch = _batch(rate);
        uint256 requiredMinimum = _requiredMinimum(rate);
        vm.prank(SWAPPER);
        _expectMinimumViolationRevert(measured, requiredMinimum);
        dcaManager.batchBuyRbtc(batch);
    }

    /// @dev A violated minimum unwinds the whole batch: the schedule keeps its balance and its purchase slot,
    ///      the handler keeps no rBTC and no fee, and the funds never left the route.
    function testViolatedMinimumRollsBackTheWholeBatch() external {
        IDcaManager.DcaSchedule memory before = _schedule();
        uint256 rbtcBefore = _accumulatedRbtc();
        uint256 feeCollectorBefore = stablecoin.balanceOf(FEE_COLLECTOR);
        uint256 handlerCashBefore = _handlerRbtcCash();
        uint256 handlerStablecoinBefore = stablecoin.balanceOf(address(stablecoinHandler));

        IDcaManager.Batch memory batch = _batch(UNREACHABLE_RATE);
        vm.prank(SWAPPER);
        (bool ok,) = address(dcaManager).call(abi.encodeCall(IDcaManager.batchBuyRbtc, (batch)));
        assertFalse(ok, "an unreachable minimum must revert the batch");

        IDcaManager.DcaSchedule memory afterCall = _schedule();
        assertEq(afterCall.tokenBalance, before.tokenBalance, "the schedule keeps its deposit");
        assertEq(
            afterCall.lastPurchaseTimestamp,
            before.lastPurchaseTimestamp,
            "the schedule keeps its purchase slot, so the swapper can retry this period"
        );
        assertEq(_accumulatedRbtc(), rbtcBefore, "no buyer was credited");
        assertEq(stablecoin.balanceOf(FEE_COLLECTOR), feeCollectorBefore, "no fee was kept");
        assertEq(_handlerRbtcCash(), handlerCashBefore, "the handler bought and kept no rBTC");
        assertEq(
            stablecoin.balanceOf(address(stablecoinHandler)),
            handlerStablecoinBefore,
            "nothing was redeemed out of the route"
        );

        // The retry the bot would send next clears the same period.
        _buy(NO_MIN_RBTC_OUT_RATE);
        assertEq(_schedule().tokenBalance, before.tokenBalance - AMOUNT_TO_SPEND);
    }

    /// @dev The one-handler entry point is the bot's retry path, and it enforces the same field.
    function testOneHandlerRetryEnforcesTheSameMinimum() external {
        uint256 measured = _measuredOutput();
        uint256 rate = _rateAbove(measured);

        IDcaManager.Batch[] memory batches = new IDcaManager.Batch[](1);
        batches[0] = _batch(rate);
        uint256 requiredMinimum = _requiredMinimum(rate);
        vm.prank(SWAPPER);
        _expectMinimumViolationRevert(measured, requiredMinimum);
        dcaManager.batchBuyRbtcAcrossHandlers(batches);

        // The same batch, retried one-handler with a reachable minimum, goes through.
        _buy(_rateFor(measured));
        assertGe(_accumulatedRbtc(), measured);
    }

    /// @dev The bound is computed against the stablecoin this tick actually measures itself spending, not
    ///      the batch's planned gross purchase amount: a rate sized so that the *gross* amount would just
    ///      clear it is stricter than the swapper intended once applied to the smaller, fee-adjusted net
    ///      spend the contract actually uses, and can push a batch that "should" have passed into failing.
    function testMinimumIsAppliedToNetSpendNotPlannedGross() external {
        uint256 measured = _measuredOutput();
        // The rate that makes the gross purchase amount exactly clear `measured` 1:1 is stricter once
        // applied to net spend, since net < gross: requiredMinimum ends up below `measured` here, the
        // opposite failure mode from an unreachable rate, which is exactly the point — the two are not
        // interchangeable, so an off-by-one on which figure to use is observable in either direction.
        uint256 grossRate = Math.mulDiv(measured, 1 ether, AMOUNT_TO_SPEND, Math.Rounding.Ceil);
        uint256 requiredMinimum = _requiredMinimum(grossRate);
        assertLt(
            requiredMinimum,
            measured,
            "a gross-denominated rate applied to the smaller net spend must demand less than the gross figure implied"
        );

        uint256 rbtcBefore = _accumulatedRbtc();
        _buy(grossRate);
        assertGe(
            _accumulatedRbtc() - rbtcBefore,
            requiredMinimum,
            "the actual net-spend requirement is what the purchase must clear, not the gross-derived figure"
        );
    }

    function _expectMinimumViolationRevert(uint256 measured, uint256 requiredMinimum) private {
        if (isDexSwaps) {
            // The router rejects `max(amountOutLowerBound, requiredMinimum)` before the measured check can run.
            // The mock and the live SwapRouter02 word that rejection differently, so match on neither:
            // any revert is the assertion, and the venue-specific string is not the behaviour under test.
            vm.expectRevert();
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum.selector, measured, requiredMinimum
                )
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev What this batch actually buys. On MoC, an unreachable rate reverts with the measured output in
     *      `PurchaseRbtc__BelowSwapperMinimum` and rolls the whole batch back. On Dex, the router would
     *      reject an unreachable minimum before that check, so take a snapshot, buy with `0`, read the
     *      credited delta, and revert the world.
     */
    function _measuredOutput() private returns (uint256 measured) {
        if (isDexSwaps) {
            uint256 snapshot = vm.snapshot();
            uint256 rbtcBefore = _accumulatedRbtc();
            _buy(NO_MIN_RBTC_OUT_RATE);
            measured = _accumulatedRbtc() - rbtcBefore;
            assertGt(measured, 0, "the batch must buy something for the minimum to be meaningful");
            vm.revertTo(snapshot);
            return measured;
        }

        IDcaManager.Batch memory batch = _batch(UNREACHABLE_RATE);
        vm.prank(SWAPPER);
        (bool ok, bytes memory returnData) = address(dcaManager).call(
            abi.encodeCall(IDcaManager.batchBuyRbtc, (batch))
        );

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

    /// @dev The rate that requires exactly `targetRbtc` against this schedule's net spend, rounded down so
    ///      the contract's own round-up of `rate * netSpend / 1e18` does not overshoot `targetRbtc`.
    function _rateFor(uint256 targetRbtc) private view returns (uint256) {
        uint256 netSpend = AMOUNT_TO_SPEND - feeCalculator.calculateFee(AMOUNT_TO_SPEND);
        return Math.mulDiv(targetRbtc, 1 ether, netSpend, Math.Rounding.Floor);
    }

    /// @dev The smallest rate whose `requiredMinimum` is guaranteed to exceed `measured`, i.e. the batch
    ///      must fail. Rounds the rate itself up: a floor-rounded rate for `measured + 1` can round back
    ///      down to the same rate that reproduces `measured` exactly whenever `netSpend` does not evenly
    ///      divide it, which would demand exactly `measured` again instead of one wei more.
    function _rateAbove(uint256 measured) private view returns (uint256) {
        uint256 netSpend = AMOUNT_TO_SPEND - feeCalculator.calculateFee(AMOUNT_TO_SPEND);
        return Math.mulDiv(measured + 1, 1 ether, netSpend, Math.Rounding.Ceil);
    }

    /// @dev Reproduces the contract's own `requiredMinimum = rate * netSpend / 1e18`, rounded up.
    function _requiredMinimum(uint256 rate) private view returns (uint256) {
        uint256 netSpend = AMOUNT_TO_SPEND - feeCalculator.calculateFee(AMOUNT_TO_SPEND);
        return Math.mulDiv(rate, netSpend, 1 ether, Math.Rounding.Ceil);
    }

    function _batch(uint256 minRbtcOutRate) private view returns (IDcaManager.Batch memory) {
        return batchOf(address(stablecoin), _scheduleId(), uint96(AMOUNT_TO_SPEND), s_routeIndex, minRbtcOutRate);
    }

    function _buy(uint256 minRbtcOutRate) private {
        IDcaManager.Batch memory batch = _batch(minRbtcOutRate);
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
        return isDexSwaps ? wrBtcToken.balanceOf(address(stablecoinHandler)) : address(stablecoinHandler).balance;
    }
}
