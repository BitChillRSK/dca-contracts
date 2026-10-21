// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {Vm} from "forge-std/Vm.sol";
import {LayerBankHandler} from "../../src/layerbank/LayerBankHandler.sol";
import {MockLayerBankAToken} from "../mocks/MockLayerBank.sol";
import {MockSwapRouter02} from "../mocks/MockSwapRouter02.sol";
import {toBatch, NO_MIN_RBTC_OUT} from "test/utils/BatchBuyOne.sol";
import "../Constants.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

/**
 * @notice R51: the swapper's per-batch minimum rBTC output, on whichever venue the lane is running.
 * @dev The check lives in the shared `PurchaseRbtc` pipeline, so it must behave identically on MoC redemption
 *      and on a Uniswap swap, and on an idle or a lending route. Rather than predict the output — which the
 *      lending lanes only reach approximately — each test quotes measured input and output from a
 *      successful purchase inside a reverted snapshot.
 */
contract BatchMinRbtcOutTest is DcaDappTest {
    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    function testInputGrowthAfterQuoteCannotWeakenPrice() external {
        if (!isDexSwaps || block.chainid != ANVIL_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        IDcaManager.Batch memory batch = _batch(_measuredOutput());
        uint256 balanceBefore = _schedule().tokenBalance;
        uint64 scheduleId = _scheduleId();
        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, 2 * AMOUNT_TO_SPEND);
        MockSwapRouter02(dexHelperConfig.getActiveNetworkConfig().swapRouter).setOutputFillPercent(0.99 ether);
        vm.expectRevert(bytes("Insufficient output amount"));
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
        assertEq(_schedule().tokenBalance, balanceBefore, "quote failure must preserve principal");
        assertEq(_schedule().cadenceAnchor, 0, "quote failure must preserve eligibility");

        MockSwapRouter02(dexHelperConfig.getActiveNetworkConfig().swapRouter).setOutputFillPercent(1 ether);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
        assertEq(_schedule().tokenBalance, balanceBefore - 2 * AMOUNT_TO_SPEND);
        assertGt(_accumulatedRbtc(), 0, "the changed input must succeed at the original price");
    }

    /// @dev A loss makes a real lending row short. A deposit inside the window restores full funding
    ///      without changing its nominal amount. The old absolute minimum would accept the worse rate.
    function testProtectedWindowDepositRestoresShortRowWithQuotedRate() external {
        _checkProtectedWindowFundingGrowth(false);
    }

    function testProtectedWindowCreationRestoresShortRowWithQuotedRate() external {
        _checkProtectedWindowFundingGrowth(true);
    }

    /// @dev A zero minimum preserves the existing opt-out on every venue.
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
        uint256 collectorCreditBefore =
            IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(FEE_COLLECTOR);
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
        assertEq(feeCollectorRbtcAfter, feeCollectorRbtcBefore, "no rBTC fee was paid out");
        assertEq(
            IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(FEE_COLLECTOR),
            collectorCreditBefore,
            "no fee was credited"
        );
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

    function _checkProtectedWindowFundingGrowth(bool createSchedule) private {
        if (!isDexSwaps || !isLayerbank || block.chainid != ANVIL_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        MockLayerBankAToken(address(LayerBankHandler(address(stablecoinHandler)).i_aToken()))
            .setNormalizedIncome(5e25, true);
        (uint256 quotedOutput, uint256 quotedInput) = _quoteGross();
        assertLt(quotedInput, AMOUNT_TO_SPEND, "the quote must retrieve a short row");
        IDcaManager.Batch memory batch = _batch(quotedOutput);
        uint64 scheduleId = _scheduleId();
        uint256 nominalBefore = _schedule().purchaseAmount;
        vm.prank(SWAPPER);
        dcaManager.activateProtectedPurchaseWindow();
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), type(uint256).max);
        if (createSchedule) {
            dcaManager.createDcaSchedule(
                address(stablecoin), AMOUNT_TO_SPEND, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
            );
        } else {
            dcaManager.depositToken(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
        }
        vm.stopPrank();
        assertEq(_schedule().purchaseAmount, nominalBefore, "funding must not change the nominal amount");
        (, uint256 fullInput) = _quoteGross();
        assertGt(fullInput, quotedInput, "funding must increase actual input");
        assertEq(fullInput, AMOUNT_TO_SPEND, "the funded row must spend its nominal amount");
        uint256 balanceBefore = _schedule().tokenBalance;
        uint256 sharesBefore = stablecoinHandler.getUserShares(USER);
        MockSwapRouter02 router = MockSwapRouter02(dexHelperConfig.getActiveNetworkConfig().swapRouter);
        router.setOutputFillPercent(0.99 ether);
        vm.expectRevert(bytes("Insufficient output amount"));
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
        assertEq(_schedule().tokenBalance, balanceBefore);
        assertEq(_schedule().cadenceAnchor, 0);
        assertEq(stablecoinHandler.getUserShares(USER), sharesBefore, "rejection must restore funding shares");

        router.setOutputFillPercent(1 ether);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
        assertEq(_schedule().tokenBalance, balanceBefore - AMOUNT_TO_SPEND);
        assertGt(_accumulatedRbtc(), 0, "the funded row must buy inside the window");
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
     * @dev Read measured gross output and actual input from a successful zero-minimum purchase,
     *      then restore all state. The quote includes lending redemption effects and precedes fees.
     */
    function _measuredOutput() private returns (uint256 measured) {
        (measured,) = _quoteGross();
    }

    function _quoteGross() private returns (uint256 measured, uint256 quotedInput) {
        uint256 snapshot = vm.snapshot();
        vm.recordLogs();
        _buy(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 batchEvent = keccak256("PurchaseRbtc__SuccessfulRbtcBatchPurchase(address,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(stablecoinHandler) && logs[i].topics[0] == batchEvent) {
                (measured, quotedInput) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        vm.revertTo(snapshot);
        assertGt(measured, 0, "quote must observe a purchase");
        assertGt(quotedInput, 0, "quote must observe actual input");
    }

    function _batch(uint256 minRbtcOut) private returns (IDcaManager.Batch memory) {
        uint64[] memory scheduleIds = new uint64[](1);
        scheduleIds[0] = _scheduleId();
        uint256 quotedInput;
        if (minRbtcOut != 0) (, quotedInput) = _quoteGross();
        return toBatch(scheduleIds, address(stablecoin), s_routeIndex, minRbtcOut, quotedInput);
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
