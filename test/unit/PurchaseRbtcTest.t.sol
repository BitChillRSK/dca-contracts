// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {PurchaseRbtc} from "src/PurchaseRbtc.sol";
import {DcaManagerAccessControl} from "src/DcaManagerAccessControl.sol";
import {StablecoinSource} from "src/StablecoinSource.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NO_MIN_RBTC_OUT} from "test/utils/BatchBuyOne.sol";

/**
 * @title PurchaseRbtcTest
 * @notice Base-level coverage for the shared batch purchase algorithm, including exact venue-input
 *         consumption independently of MoC and Uniswap.
 */
contract PurchaseRbtcTest is Test {
    event PurchaseRbtc__RbtcBought(
        address indexed user,
        address indexed tokenSpent,
        uint256 rBtcBought,
        uint64 indexed scheduleId,
        uint256 amountSpent
    );
    event PurchaseRbtc__SuccessfulRbtcBatchPurchase(
        address indexed token, uint256 totalPurchasedRbtc, uint256 totalStablecoinAmountSpent
    );
    event PurchaseFees__FeeTransferred(address indexed token, address indexed collector, uint256 amount);

    uint16 internal constant FLAT_FEE_RATE = 100; // 1%
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant RBTC_OUT = 1 ether;
    /// @dev Above Rootstock's whole native supply (21M rBTC is about 2^84.1 wei).
    uint256 internal constant BOUND_RBTC_OUT = 2 ** 85;

    address internal buyerA = address(0xA11CE);
    address internal buyerB = address(0xB0B);
    address internal feeCollector = address(0xFEE);
    uint64 internal scheduleA = 1;
    uint64 internal scheduleB = 2;

    MockStablecoin internal token;
    PurchaseRbtcHarness internal harness;

    function setUp() public {
        token = new MockStablecoin(address(this));
        IPurchaseFees.FeeSettings memory feeSettings = IPurchaseFees.FeeSettings({
            minFeeRate: FLAT_FEE_RATE,
            maxFeeRate: FLAT_FEE_RATE,
            feePurchaseLowerBound: 1000 ether,
            feePurchaseUpperBound: 100_000 ether
        });
        // dcaManager = this, so tests can call onlyDcaManager entry points directly
        harness = new PurchaseRbtcHarness(address(this), address(token), feeCollector, feeSettings, address(this));
        token.mint(address(harness), 1_000_000 ether);
        harness.setRbtcOut(RBTC_OUT);
        vm.deal(address(harness), type(uint128).max);
    }

    /**
     * @dev The rBTC allocation product runs unchecked. Drive it to the bound the source states: uint96
     *      weights and rBTC at 2^85 (above Rootstock's whole native supply). Every row's credit must match
     *      full-width mulDiv. The retrieval delivers the full request, so each row's `amountSpent` is its
     *      planned gross.
     */
    function test_rbtcAllocationProduct_matchesFullWidthAtItsBound() public {
        harness.setRbtcOut(BOUND_RBTC_OUT);
        (address[] memory buyers, uint64[] memory ids, uint256[] memory amounts) = _uint96BoundBatch(8);
        uint256 requested;
        for (uint256 i; i < amounts.length; ++i) {
            requested += amounts[i];
        }
        token.mint(address(harness), requested);

        vm.recordLogs();
        harness.batchBuyRbtc(buyers, ids, amounts, NO_MIN_RBTC_OUT);
        _assertRowsMatchFullWidth(vm.getRecordedLogs(), buyers, amounts);
    }

    function _uint96BoundBatch(uint256 rows)
        private
        pure
        returns (address[] memory buyers, uint64[] memory ids, uint256[] memory amounts)
    {
        buyers = new address[](rows);
        ids = new uint64[](rows);
        amounts = new uint256[](rows);
        for (uint256 i; i < rows; ++i) {
            buyers[i] = address(uint160(0x1000 + i));
            ids[i] = uint64(i + 1);
            amounts[i] = uint256(type(uint96).max) - i;
        }
    }

    function _assertRowsMatchFullWidth(Vm.Log[] memory logs, address[] memory buyers, uint256[] memory amounts)
        private
    {
        uint256 plannedGross;
        for (uint256 i; i < amounts.length; ++i) {
            plannedGross += amounts[i];
        }
        uint256 row;
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].topics[0] != PurchaseRbtc__RbtcBought.selector) continue;
            _assertRowMatchesFullWidth(
                logs[j], buyers[row], amounts[row] - _fee(amounts[row]), amounts[row], plannedGross
            );
            ++row;
        }
        assertEq(row, buyers.length, "one RbtcBought per row");
    }

    function _assertRowMatchesFullWidth(
        Vm.Log memory log,
        address buyer,
        uint256 net,
        uint256 gross,
        uint256 plannedGross
    ) private {
        (uint256 rbtcBought, uint256 amountSpent) = abi.decode(log.data, (uint256, uint256));
        assertEq(rbtcBought, Math.mulDiv(BOUND_RBTC_OUT, net, plannedGross), "row rBTC");
        assertEq(amountSpent, gross, "row amountSpent");
        assertEq(harness.getAccumulatedRbtcBalance(buyer), rbtcBought, "credited rBTC");
    }

    /// @dev R39 removed `buyRbtc`; a length-1 batch is the one-schedule path. A short retrieval spends
    ///      what it got at the venue; the rBTC fee and buyer credit scale with measured output.
    function test_lengthOneBatch_usesActualRetrievedWhenBelowRequest() public {
        uint256 requested = 100 ether;
        uint256 retrieved = 50 ether;
        harness.setRetrieveOverride(retrieved);

        uint256 userRbtc = _share(RBTC_OUT, requested - _fee(requested), requested);
        uint256 feeRbtc = _share(RBTC_OUT, _fee(requested), requested);

        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__RbtcBought(buyerA, address(token), userRbtc, scheduleA, retrieved);

        harness.batchBuyRbtc(
            _oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(requested), NO_MIN_RBTC_OUT
        );

        assertEq(harness.lastPurchaseAmount(), retrieved);
        assertEq(token.balanceOf(feeCollector), 0);
        assertEq(feeCollector.balance, feeRbtc);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), userRbtc);
    }

    function test_lengthOneBatch_passesGrossToVenueAndPaysRbtcFeeLast() public {
        uint256 requested = 100 ether;
        uint256 feeStable = _fee(requested);
        uint256 userRbtc = _share(RBTC_OUT, requested - feeStable, requested);
        uint256 feeRbtc = _share(RBTC_OUT, feeStable, requested);

        harness.batchBuyRbtc(
            _oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(requested), NO_MIN_RBTC_OUT
        );

        assertEq(harness.purchaseCalls(), 1);
        assertEq(harness.lastPurchaseAmount(), requested);
        assertEq(token.balanceOf(feeCollector), 0);
        assertEq(feeCollector.balance, feeRbtc);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), userRbtc);
    }

    function test_lengthOneBatch_creditsBuyerAndEmitsOnSuccess() public {
        uint256 requested = 100 ether;
        uint256 feeStable = _fee(requested);
        uint256 userRbtc = _share(RBTC_OUT, requested - feeStable, requested);
        uint256 feeRbtc = _share(RBTC_OUT, feeStable, requested);

        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__RbtcBought(buyerA, address(token), userRbtc, scheduleA, requested);
        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__SuccessfulRbtcBatchPurchase(address(token), RBTC_OUT, requested);
        vm.expectEmit(true, true, false, true, address(harness));
        emit PurchaseFees__FeeTransferred(address(0), feeCollector, feeRbtc);

        harness.batchBuyRbtc(
            _oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(requested), NO_MIN_RBTC_OUT
        );

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), userRbtc);
        assertEq(feeCollector.balance, feeRbtc);
    }

    function test_lengthOneBatch_zeroFeeDoesNotPayCollector() public {
        harness.setFeeRateParams(0, 0, 1000 ether, 100_000 ether);
        uint256 requested = 100 ether;
        uint256 collectorBefore = feeCollector.balance;

        vm.recordLogs();
        harness.batchBuyRbtc(
            _oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(requested), NO_MIN_RBTC_OUT
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == PurchaseFees__FeeTransferred.selector) {
                revert("FeeTransferred emitted on a zero-fee purchase");
            }
        }
        assertEq(token.balanceOf(feeCollector), 0);
        assertEq(feeCollector.balance, collectorBefore);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), RBTC_OUT);
    }

    function test_lengthOneBatch_zeroOutputRevertsBatchError() public {
        harness.setRbtcOut(0);

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseRbtc.PurchaseRbtc__RbtcBatchPurchaseFailed.selector, address(token))
        );
        harness.batchBuyRbtc(
            _oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(100 ether), NO_MIN_RBTC_OUT
        );

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
    }

    function test_lengthOneBatch_partialInputConsumptionRevertsAndRollsBack() public {
        uint256 requested = 100 ether;
        uint256 partialAmount = requested - 1 ether;
        harness.setPurchaseInputOverride(partialAmount);

        uint256 handlerBalanceBefore = token.balanceOf(address(harness));
        uint256 collectorBefore = feeCollector.balance;
        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseRbtc.PurchaseRbtc__InputAmountNotFullySpent.selector,
                requested,
                handlerBalanceBefore,
                handlerBalanceBefore - partialAmount
            )
        );
        harness.batchBuyRbtc(
            _oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(requested), NO_MIN_RBTC_OUT
        );

        assertEq(token.balanceOf(address(harness)), handlerBalanceBefore);
        assertEq(token.balanceOf(feeCollector), 0);
        assertEq(feeCollector.balance, collectorBefore);
        assertEq(token.balanceOf(address(0xBEEF)), 0);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
    }

    function test_batchPurchase_shortRetrievalStillPurchasesAndScalesFee() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        uint256 plannedGross = amounts[0] + amounts[1];
        uint256 aggregatedFee = _fee(amounts[0]) + _fee(amounts[1]);
        uint256 retrieved = aggregatedFee;
        harness.setRetrieveOverride(retrieved);

        uint256 net0 = amounts[0] - _fee(amounts[0]);
        uint256 net1 = amounts[1] - _fee(amounts[1]);
        uint256 rbtc0 = _share(RBTC_OUT, net0, plannedGross);
        uint256 rbtc1 = _share(RBTC_OUT, net1, plannedGross);
        uint256 feeRbtc = _share(RBTC_OUT, aggregatedFee, plannedGross);

        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        assertEq(harness.lastPurchaseAmount(), retrieved);
        assertEq(token.balanceOf(feeCollector), 0);
        assertEq(feeCollector.balance, feeRbtc);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), rbtc0);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), rbtc1);
    }

    function test_batchPurchase_allocatesByPlannedWeightsOverGross() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        uint256 plannedGross = amounts[0] + amounts[1];
        uint256 aggregatedFee = _fee(amounts[0]) + _fee(amounts[1]);
        uint256 net0 = amounts[0] - _fee(amounts[0]);
        uint256 net1 = amounts[1] - _fee(amounts[1]);
        uint256 retrieved = 150 ether;
        harness.setRetrieveOverride(retrieved);

        uint256 rbtc0 = _share(RBTC_OUT, net0, plannedGross);
        uint256 rbtc1 = _share(RBTC_OUT, net1, plannedGross);
        uint256 spent0 = _share(retrieved, amounts[0], plannedGross);
        uint256 spent1 = _share(retrieved, amounts[1], plannedGross);
        uint256 feeRbtc = _share(RBTC_OUT, aggregatedFee, plannedGross);

        _expectBatchEvents(buyerA, buyerB, rbtc0, rbtc1, spent0, spent1, retrieved, scheduleA, scheduleB);
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        assertEq(harness.lastPurchaseAmount(), retrieved);
        assertEq(token.balanceOf(feeCollector), 0);
        assertEq(feeCollector.balance, feeRbtc);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), rbtc0);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), rbtc1);
        _assertCreditsAndFeeWithinFloorBound(2, feeRbtc);
    }

    /// @dev Buyer credits plus the collector fee floor to at most the measured output, never above it.
    function _assertCreditsAndFeeWithinFloorBound(uint256 rows, uint256 feeRbtc) private {
        uint256 credited = harness.getAccumulatedRbtcBalance(buyerA) + harness.getAccumulatedRbtcBalance(buyerB);
        assertLe(credited + feeRbtc, RBTC_OUT, "credits plus fee exceed the measured rBTC");
        assertGe(credited + feeRbtc, RBTC_OUT - rows, "residue larger than one wei per buyer term");
    }

    /// @dev The accepted residue, pinned: floors that do not divide out leave measured rBTC credited to
    ///      nobody (buyers or collector). Under one wei per term, no owner sweep, last row is not a remainder.
    function test_batchPurchase_flooredSharesLeaveResidueUncredited() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        uint256 q = RBTC_OUT + 1;
        harness.setRbtcOut(q);
        uint256 plannedGross = amounts[0] + amounts[1];
        uint256 aggregatedFee = _fee(amounts[0]) + _fee(amounts[1]);
        uint256 net0 = amounts[0] - _fee(amounts[0]);
        uint256 net1 = amounts[1] - _fee(amounts[1]);
        uint256 rbtc0 = _share(q, net0, plannedGross);
        uint256 rbtc1 = _share(q, net1, plannedGross);
        uint256 feeRbtc = _share(q, aggregatedFee, plannedGross);

        assertLt(rbtc0 + rbtc1 + feeRbtc, q, "fixture must actually truncate, or the residue is untested");

        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), rbtc0, "row 0 takes its floor");
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), rbtc1, "the last row takes its floor, not a remainder");
        assertEq(feeCollector.balance, feeRbtc);
        uint256 credited = harness.getAccumulatedRbtcBalance(buyerA) + harness.getAccumulatedRbtcBalance(buyerB);
        assertLe(credited + feeRbtc, q, "credits plus fee exceed the measured rBTC");
        assertGe(credited + feeRbtc, q - 2, "residue larger than one wei per buyer term");
    }

    /// @dev Both reported figures floor on every row, so both can sum below the batch total. Pinned
    ///      alongside the batch event, which carries the true totals for anyone who needs them.
    function test_batchPurchase_bothSidesFloorOnEveryRow() public {
        address[] memory buyers = new address[](2);
        buyers[0] = buyerA;
        buyers[1] = buyerB;
        uint64[] memory scheduleIds = new uint64[](2);
        scheduleIds[0] = scheduleA;
        scheduleIds[1] = scheduleB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 ether;
        amounts[1] = 200 ether;

        uint256 plannedGross = amounts[0] + amounts[1];
        uint256 aggregatedFee = _fee(amounts[0]) + _fee(amounts[1]);
        uint256 net0 = amounts[0] - _fee(amounts[0]);
        uint256 net1 = amounts[1] - _fee(amounts[1]);
        uint256 retrieved = 100 ether + 1;
        harness.setRetrieveOverride(retrieved);

        uint256 spent0 = _share(retrieved, amounts[0], plannedGross);
        uint256 spent1 = _share(retrieved, amounts[1], plannedGross);
        assertLt(spent0 + spent1, retrieved, "fixture must truncate the reported spend");

        uint256 rbtc0 = _share(RBTC_OUT, net0, plannedGross);
        uint256 rbtc1 = _share(RBTC_OUT, net1, plannedGross);
        uint256 feeRbtc = _share(RBTC_OUT, aggregatedFee, plannedGross);
        _expectBatchEvents(buyerA, buyerB, rbtc0, rbtc1, spent0, spent1, retrieved, scheduleA, scheduleB);
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        _assertCreditsAndFeeWithinFloorBound(2, feeRbtc);
    }

    function test_batchPurchase_repeatedBuyersAccumulateAndEmitInOrder() public {
        address[] memory buyers = new address[](2);
        buyers[0] = buyerA;
        buyers[1] = buyerA;
        uint64[] memory scheduleIds = new uint64[](2);
        scheduleIds[0] = scheduleA;
        scheduleIds[1] = scheduleB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 ether;
        amounts[1] = 200 ether;

        uint256 plannedGross = amounts[0] + amounts[1];
        uint256 net0 = amounts[0] - _fee(amounts[0]);
        uint256 net1 = amounts[1] - _fee(amounts[1]);
        uint256 actualSpent = plannedGross;

        uint256 rbtc0 = _share(RBTC_OUT, net0, plannedGross);
        uint256 rbtc1 = _share(RBTC_OUT, net1, plannedGross);
        uint256 spent0 = _share(actualSpent, amounts[0], plannedGross);
        uint256 spent1 = _share(actualSpent, amounts[1], plannedGross);

        _expectBatchEvents(buyerA, buyerA, rbtc0, rbtc1, spent0, spent1, actualSpent, scheduleA, scheduleB);
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), rbtc0 + rbtc1);
    }

    /// @dev Floor of `total * weight / gross`. Independent of the contract rather than `total - share0`.
    function _share(uint256 total, uint256 weight, uint256 gross) private pure returns (uint256) {
        return total * weight / gross;
    }

    function _expectBatchEvents(
        address user0,
        address user1,
        uint256 rbtc0,
        uint256 rbtc1,
        uint256 spent0,
        uint256 spent1,
        uint256 totalSpent,
        uint64 id0,
        uint64 id1
    ) private {
        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__RbtcBought(user0, address(token), rbtc0, id0, spent0);
        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__RbtcBought(user1, address(token), rbtc1, id1, spent1);
        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__SuccessfulRbtcBatchPurchase(address(token), RBTC_OUT, totalSpent);
    }

    function test_batchPurchase_zeroOutputRevertsBatchError() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        harness.setRbtcOut(0);

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseRbtc.PurchaseRbtc__RbtcBatchPurchaseFailed.selector, address(token))
        );
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    R51: THE CALLER'S PER-BATCH MINIMUM
    //////////////////////////////////////////////////////////////*/

    /// @dev `0` is the pre-R51 contract: the venue's own floor stays the only bound.
    function test_minRbtcOut_zeroIsInert() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        uint256 plannedGross = amounts[0] + amounts[1];
        uint256 aggregatedFee = _fee(amounts[0]) + _fee(amounts[1]);
        uint256 net0 = amounts[0] - _fee(amounts[0]);
        uint256 net1 = amounts[1] - _fee(amounts[1]);
        uint256 rbtc0 = _share(RBTC_OUT, net0, plannedGross);
        uint256 rbtc1 = _share(RBTC_OUT, net1, plannedGross);
        uint256 feeRbtc = _share(RBTC_OUT, aggregatedFee, plannedGross);

        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        assertEq(harness.purchaseCalls(), 1);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), rbtc0);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), rbtc1);
        _assertCreditsAndFeeWithinFloorBound(2, feeRbtc);
    }

    function test_minRbtcOut_equalToMeasuredOutputSucceeds() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        uint256 plannedGross = amounts[0] + amounts[1];
        uint256 aggregatedFee = _fee(amounts[0]) + _fee(amounts[1]);
        uint256 net0 = amounts[0] - _fee(amounts[0]);
        uint256 net1 = amounts[1] - _fee(amounts[1]);
        uint256 feeRbtc = _share(RBTC_OUT, aggregatedFee, plannedGross);

        harness.batchBuyRbtc(buyers, scheduleIds, amounts, RBTC_OUT);

        uint256 rbtc0 = _share(RBTC_OUT, net0, plannedGross);
        uint256 rbtc1 = _share(RBTC_OUT, net1, plannedGross);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), rbtc0);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), rbtc1);
        _assertCreditsAndFeeWithinFloorBound(2, feeRbtc);
    }

    function test_minRbtcOut_oneWeiAboveMeasuredOutputReverts() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum.selector, RBTC_OUT, RBTC_OUT + 1)
        );
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, RBTC_OUT + 1);
    }

    /// @dev A violated minimum must undo the fee transfer, both credits, and every event of the batch.
    function test_minRbtcOut_violationRollsBackFeeAndCredits() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();

        (bool ok,) = address(harness)
            .call(abi.encodeCall(IPurchaseRbtc.batchBuyRbtc, (buyers, scheduleIds, amounts, RBTC_OUT + 1)));

        // `vm.recordLogs` keeps the logs of reverted frames, so the proof that nothing was emitted is
        // that nothing they report happened: no credit and no fee survive the call.
        assertFalse(ok, "a batch below the caller minimum must revert");
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), 0);
        assertEq(feeCollector.balance, 0, "the fee payment rolls back with the batch");
        assertEq(token.balanceOf(feeCollector), 0, "no stablecoin fee is taken");
    }

    /// @dev The bound is on the rBTC the handler measured, not on the gross stablecoin the swapper asked for:
    ///      the same batch clears a minimum set from the measured output and fails one set a wei higher, even
    ///      though the stablecoin actually retrieved was well below what the rows planned to spend.
    function test_minRbtcOut_comparesMeasuredOutputNotPlannedStablecoin() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        harness.setRetrieveOverride(150 ether); // the rows planned 300 ether of gross spend

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum.selector, RBTC_OUT, RBTC_OUT + 1)
        );
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, RBTC_OUT + 1);

        harness.batchBuyRbtc(buyers, scheduleIds, amounts, RBTC_OUT);
        assertEq(harness.lastPurchaseAmount(), 150 ether);
    }

    /// @dev The zero-output check runs first, so a failed purchase reports the venue error rather than a
    ///      minimum the caller could read as "the swap merely underperformed".
    function test_minRbtcOut_zeroOutputStillReportsTheVenueFailure() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        harness.setRbtcOut(0);

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseRbtc.PurchaseRbtc__RbtcBatchPurchaseFailed.selector, address(token))
        );
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, 1);
    }

    function testFuzz_minRbtcOut_passesExactlyWhenAtOrBelowMeasuredOutput(uint256 measured, uint256 minRbtcOut) public {
        measured = bound(measured, 1, 100 ether);
        minRbtcOut = bound(minRbtcOut, 0, 200 ether);
        harness.setRbtcOut(measured);
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();

        if (minRbtcOut > measured) {
            vm.expectRevert(
                abi.encodeWithSelector(IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum.selector, measured, minRbtcOut)
            );
        }
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, minRbtcOut);
    }

    function test_transferFee_rejectingCollectorRevertsTheBatch() public {
        FeeCollectorRejects rejecting = new FeeCollectorRejects();
        harness.setFeeCollector(address(rejecting));
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();

        vm.expectRevert(IPurchaseFees.PurchaseFees__FeePaymentFailed.selector);
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), 0);
        assertEq(token.balanceOf(address(0xBEEF)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                     ACCUMULATED-RBTC STORAGE SENTINEL
    //////////////////////////////////////////////////////////////*/

    /// @dev Full withdraw pays the complete claim, getter stays 0, and raw storage keeps sentinel 1.
    function test_fullWithdraw_leavesSentinelAndPaysCompleteClaim() public {
        uint256 requested = 100 ether;
        uint256 userRbtc = _share(RBTC_OUT, requested - _fee(requested), requested);
        uint256 feeRbtc = _share(RBTC_OUT, _fee(requested), requested);

        harness.batchBuyRbtc(
            _oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(requested), NO_MIN_RBTC_OUT
        );

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), userRbtc);
        assertEq(_rawAccumulatedRbtc(buyerA), userRbtc + 1);
        assertEq(feeCollector.balance, feeRbtc);

        uint256 balanceBefore = buyerA.balance;
        harness.withdrawAccumulatedRbtc(buyerA);

        assertEq(buyerA.balance - balanceBefore, userRbtc, "withdrawal left claimable dust");
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0, "getter exposed the sentinel");
        assertEq(_rawAccumulatedRbtc(buyerA), 1, "full withdraw cleared storage");
    }

    /// @dev After a full withdraw, the next credit lands on the sentinel and stays fully withdrawable.
    function test_recreditAfterFullWithdraw_creditsAndPaysAgain() public {
        uint256 requested = 100 ether;
        uint256 userRbtc = _share(RBTC_OUT, requested - _fee(requested), requested);

        harness.batchBuyRbtc(
            _oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(requested), NO_MIN_RBTC_OUT
        );
        harness.withdrawAccumulatedRbtc(buyerA);

        harness.batchBuyRbtc(
            _oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(requested), NO_MIN_RBTC_OUT
        );
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), userRbtc);
        assertEq(_rawAccumulatedRbtc(buyerA), userRbtc + 1);

        uint256 balanceBefore = buyerA.balance;
        harness.withdrawAccumulatedRbtc(buyerA);
        assertEq(buyerA.balance - balanceBefore, userRbtc);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
        assertEq(_rawAccumulatedRbtc(buyerA), 1);
    }

    /// @dev A never-credited user and a post-withdraw sentinel both refuse a direct withdraw.
    function test_withdraw_revertsWhenNeverCreditedOrOnlySentinel() public {
        vm.expectRevert(IPurchaseRbtc.PurchaseRbtc__NoAccumulatedRbtcToWithdraw.selector);
        harness.withdrawAccumulatedRbtc(buyerA);

        harness.batchBuyRbtc(
            _oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(100 ether), NO_MIN_RBTC_OUT
        );
        harness.withdrawAccumulatedRbtc(buyerA);

        vm.expectRevert(IPurchaseRbtc.PurchaseRbtc__NoAccumulatedRbtcToWithdraw.selector);
        harness.withdrawAccumulatedRbtc(buyerA);
    }

    /// @dev A zero floor allocation must not plant a sentinel on a never-credited buyer.
    function test_zeroCredit_doesNotPlantSentinelOnNeverCreditedBuyer() public {
        harness.setRbtcOut(2);
        address[] memory buyers = new address[](2);
        buyers[0] = buyerA;
        buyers[1] = buyerB;
        uint64[] memory scheduleIds = new uint64[](2);
        scheduleIds[0] = scheduleA;
        scheduleIds[1] = scheduleB;
        uint256[] memory amounts = new uint256[](2);
        // Light row floors to 0 over planned gross; heavy row takes floor(2 * heavyNet / G).
        amounts[0] = 1 ether;
        amounts[1] = 100_000 ether;
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
        assertEq(_rawAccumulatedRbtc(buyerA), 0, "zero credit marked a never-credited user live");
        uint256 plannedGross = amounts[0] + amounts[1];
        uint256 expectedB = _share(2, amounts[1] - _fee(amounts[1]), plannedGross);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), expectedB);
        if (expectedB != 0) {
            assertEq(_rawAccumulatedRbtc(buyerB), expectedB + 1);
        }
    }

    /// @dev Test probe into private `s_usersAccumulatedRbtc` (slot 4 on this harness layout).
    ///      Re-check with `forge inspect PurchaseRbtcHarness storage-layout` if PurchaseFees packing moves.
    function _rawAccumulatedRbtc(address user) private view returns (uint256) {
        return uint256(vm.load(address(harness), keccak256(abi.encode(user, uint256(4)))));
    }

    function _fee(uint256 amount) private pure returns (uint256) {
        return amount * FLAT_FEE_RATE / BPS_DENOMINATOR;
    }

    function _oneBuyerBatchBuyers() private view returns (address[] memory buyers) {
        buyers = new address[](1);
        buyers[0] = buyerA;
    }

    function _oneBuyerBatchIds() private view returns (uint64[] memory scheduleIds) {
        scheduleIds = new uint64[](1);
        scheduleIds[0] = scheduleA;
    }

    function _oneBuyerBatchAmounts(uint256 amount) private pure returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = amount;
    }

    function _twoBuyerBatch()
        private
        view
        returns (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts)
    {
        buyers = new address[](2);
        buyers[0] = buyerA;
        buyers[1] = buyerB;
        scheduleIds = new uint64[](2);
        scheduleIds[0] = scheduleA;
        scheduleIds[1] = scheduleB;
        amounts = new uint256[](2);
        amounts[0] = 100 ether;
        amounts[1] = 200 ether;
    }
}

contract PurchaseRbtcHarness is PurchaseRbtc {
    uint256 public lastPurchaseAmount;
    uint256 public purchaseCalls;
    uint256 public rbtcOut;
    uint256 internal retrieveOverride;
    uint256 internal purchaseInputOverride;
    bool internal useRetrieveOverride;
    bool internal usePurchaseInputOverride;
    bool internal revertOnPurchase;

    constructor(
        address dcaManager,
        address stablecoin,
        address feeCollector,
        FeeSettings memory feeSettings,
        address initialOwner
    )
        PurchaseRbtc(FeeConfig({feeCollector: feeCollector, feeSettings: feeSettings}), initialOwner)
        DcaManagerAccessControl(dcaManager)
        StablecoinSource(stablecoin)
    {}

    function setRbtcOut(uint256 amount) external {
        rbtcOut = amount;
    }

    function setRetrieveOverride(uint256 amount) external {
        retrieveOverride = amount;
        useRetrieveOverride = true;
    }

    function setPurchaseInputOverride(uint256 amount) external {
        purchaseInputOverride = amount;
        usePurchaseInputOverride = true;
    }

    function setRevertOnPurchase(bool shouldRevert) external {
        revertOnPurchase = shouldRevert;
    }

    function _purchaseRbtc(
        uint256 stablecoinAmount,
        uint256 /* minRbtcOut */
    )
        internal
        override
        returns (uint256)
    {
        if (revertOnPurchase) revert("route-called");
        purchaseCalls++;
        lastPurchaseAmount = stablecoinAmount;
        uint256 inputToConsume = usePurchaseInputOverride ? purchaseInputOverride : stablecoinAmount;
        require(i_stablecoin.transfer(address(0xBEEF), inputToConsume));
        return rbtcOut;
    }

    function _batchRetrieveStablecoin(address[] calldata, uint256[] calldata purchaseAmounts)
        internal
        view
        override
        returns (uint256)
    {
        if (useRetrieveOverride) return retrieveOverride;
        uint256 total;
        for (uint256 i; i < purchaseAmounts.length; ++i) {
            total += purchaseAmounts[i];
        }
        return total;
    }
}

contract FeeCollectorRejects {
    receive() external payable {
        revert("no");
    }
}
