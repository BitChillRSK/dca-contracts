// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {PurchaseRbtc} from "src/PurchaseRbtc.sol";
import {FeeHandler} from "src/FeeHandler.sol";
import {DcaManagerAccessControl} from "src/DcaManagerAccessControl.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NO_MIN_RBTC_OUT} from "test/utils/BatchBuyOne.sol";

/**
 * @title PurchaseRbtcTest
 * @notice Base-level coverage for the shared batch purchase algorithm, independent of
 *         MoC/Uniswap cash measurement.
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
    event FeeHandler__FeeTransferred(address indexed token, address indexed collector, uint256 amount);

    uint16 internal constant FLAT_FEE_RATE = 100; // 1%
    uint256 internal constant FEE_DIVISOR = 10_000;
    uint256 internal constant RBTC_OUT = 1 ether;

    address internal buyerA = address(0xA11CE);
    address internal buyerB = address(0xB0B);
    address internal feeCollector = address(0xFEE);
    uint64 internal scheduleA = 1;
    uint64 internal scheduleB = 2;

    MockStablecoin internal token;
    PurchaseRbtcHarness internal harness;

    function setUp() public {
        token = new MockStablecoin(address(this));
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: FLAT_FEE_RATE,
            maxFeeRate: FLAT_FEE_RATE,
            feePurchaseLowerBound: 1000 ether,
            feePurchaseUpperBound: 100_000 ether
        });
        // dcaManager = this, so tests can call onlyDcaManager entry points directly
        harness = new PurchaseRbtcHarness(address(this), address(token), feeCollector, feeSettings, address(this));
        token.mint(address(harness), 1_000_000 ether);
        harness.setRbtcOut(RBTC_OUT);
    }

    /// @dev R39 removed `buyRbtc`; a length-1 batch is the one-schedule path. The batch charges the fee
    ///      on the planned amount, so a short retrieval eats into the net spend rather than the fee.
    function test_lengthOneBatch_usesActualRetrievedWhenBelowRequest() public {
        uint256 requested = 100 ether;
        uint256 retrieved = 50 ether;
        harness.setRetrieveOverride(retrieved);

        uint256 fee = _fee(requested);
        uint256 spent = retrieved - fee;

        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__RbtcBought(buyerA, address(token), RBTC_OUT, scheduleA, spent);

        harness.batchBuyRbtc(_oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(requested), NO_MIN_RBTC_OUT);

        assertEq(harness.lastPurchaseAmount(), spent);
        assertEq(token.balanceOf(feeCollector), fee);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), RBTC_OUT);
    }

    function test_lengthOneBatch_transfersFeeBeforeRouteAndPassesNet() public {
        uint256 requested = 100 ether;
        uint256 fee = _fee(requested);
        uint256 net = requested - fee;

        harness.batchBuyRbtc(_oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(requested), NO_MIN_RBTC_OUT);

        assertEq(harness.purchaseCalls(), 1);
        assertEq(harness.lastPurchaseAmount(), net);
        assertEq(harness.feeCollectorBalanceOnPurchase(), fee);
        assertEq(token.balanceOf(feeCollector), fee);
    }

    function test_lengthOneBatch_creditsBuyerAndEmitsOnSuccess() public {
        uint256 requested = 100 ether;
        uint256 fee = _fee(requested);
        uint256 net = requested - fee;

        vm.expectEmit(true, true, false, true, address(harness));
        emit FeeHandler__FeeTransferred(address(token), feeCollector, fee);
        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__RbtcBought(buyerA, address(token), RBTC_OUT, scheduleA, net);
        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__SuccessfulRbtcBatchPurchase(address(token), RBTC_OUT, net);

        harness.batchBuyRbtc(_oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(requested), NO_MIN_RBTC_OUT);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), RBTC_OUT);
    }

    function test_lengthOneBatch_zeroFeeDoesNotEmitFeeTransferred() public {
        harness.setFeeRateParams(0, 0, 1000 ether, 100_000 ether);
        uint256 requested = 100 ether;

        vm.recordLogs();
        harness.batchBuyRbtc(_oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(requested), NO_MIN_RBTC_OUT);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = FeeHandler__FeeTransferred.selector;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != sig, "FeeTransferred emitted on a zero-fee purchase");
        }
        assertEq(token.balanceOf(feeCollector), 0);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), RBTC_OUT);
    }

    function test_lengthOneBatch_zeroOutputRevertsBatchError() public {
        harness.setRbtcOut(0);

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseRbtc.PurchaseRbtc__RbtcBatchPurchaseFailed.selector, address(token))
        );
        harness.batchBuyRbtc(_oneBuyerBatchBuyers(), _oneBuyerBatchIds(), _oneBuyerBatchAmounts(100 ether), NO_MIN_RBTC_OUT);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
    }

    function test_batchPurchase_revertsWhenRetrievedAtFee() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        uint256 aggregatedFee = _fee(amounts[0]) + _fee(amounts[1]);
        harness.setRetrieveOverride(aggregatedFee);
        harness.setRevertOnPurchase(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseRbtc.PurchaseRbtc__StablecoinRetrievedBelowFee.selector, aggregatedFee, aggregatedFee
            )
        );
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
        assertEq(token.balanceOf(feeCollector), 0);
    }

    function test_batchPurchase_revertsWhenRetrievedBelowFee() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        uint256 aggregatedFee = _fee(amounts[0]) + _fee(amounts[1]);
        uint256 retrieved = aggregatedFee - 1;
        harness.setRetrieveOverride(retrieved);
        harness.setRevertOnPurchase(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseRbtc.PurchaseRbtc__StablecoinRetrievedBelowFee.selector, retrieved, aggregatedFee
            )
        );
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), 0);
        assertEq(token.balanceOf(feeCollector), 0);
    }

    function test_batchPurchase_allocatesByPlannedNetsUsingActualCash() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        uint256 aggregatedFee = _fee(amounts[0]) + _fee(amounts[1]);
        uint256 net0 = amounts[0] - _fee(amounts[0]);
        uint256 net1 = amounts[1] - _fee(amounts[1]);
        uint256 totalNetPlanned = net0 + net1;
        uint256 retrieved = 150 ether;
        uint256 actualSpent = retrieved - aggregatedFee;
        harness.setRetrieveOverride(retrieved);

        _expectBatchEvents(
            buyerA, buyerB, net0, net1, totalNetPlanned, actualSpent, scheduleA, scheduleB
        );
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        assertEq(harness.lastPurchaseAmount(), actualSpent);
        assertEq(harness.feeCollectorBalanceOnPurchase(), aggregatedFee);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), RBTC_OUT * net0 / totalNetPlanned);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), RBTC_OUT * net1 / totalNetPlanned);
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

        uint256 net0 = amounts[0] - _fee(amounts[0]);
        uint256 net1 = amounts[1] - _fee(amounts[1]);
        uint256 totalNetPlanned = net0 + net1;
        uint256 actualSpent = amounts[0] + amounts[1] - _fee(amounts[0]) - _fee(amounts[1]);

        _expectBatchEvents(buyerA, buyerA, net0, net1, totalNetPlanned, actualSpent, scheduleA, scheduleB);
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        assertEq(
            harness.getAccumulatedRbtcBalance(buyerA),
            RBTC_OUT * net0 / totalNetPlanned + RBTC_OUT * net1 / totalNetPlanned
        );
    }

    function _expectBatchEvents(
        address user0,
        address user1,
        uint256 net0,
        uint256 net1,
        uint256 totalNetPlanned,
        uint256 actualSpent,
        uint64 id0,
        uint64 id1
    ) private {
        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__RbtcBought(
            user0, address(token), RBTC_OUT * net0 / totalNetPlanned, id0, actualSpent * net0 / totalNetPlanned
        );
        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__RbtcBought(
            user1, address(token), RBTC_OUT * net1 / totalNetPlanned, id1, actualSpent * net1 / totalNetPlanned
        );
        vm.expectEmit(true, true, true, true, address(harness));
        emit PurchaseRbtc__SuccessfulRbtcBatchPurchase(address(token), RBTC_OUT, actualSpent);
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

        uint256 net0 = amounts[0] - _fee(amounts[0]);
        uint256 net1 = amounts[1] - _fee(amounts[1]);

        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);

        assertEq(harness.purchaseCalls(), 1);
        // The same truncated pro-rata shares R51 must not disturb; they sum a wei short of the measured total.
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), RBTC_OUT * net0 / (net0 + net1));
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), RBTC_OUT * net1 / (net0 + net1));
    }

    function test_minRbtcOut_equalToMeasuredOutputSucceeds() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();

        harness.batchBuyRbtc(buyers, scheduleIds, amounts, RBTC_OUT);

        uint256 net0 = amounts[0] - _fee(amounts[0]);
        uint256 net1 = amounts[1] - _fee(amounts[1]);
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), RBTC_OUT * net0 / (net0 + net1));
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), RBTC_OUT * net1 / (net0 + net1));
    }

    function test_minRbtcOut_oneWeiAboveMeasuredOutputReverts() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();

        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum.selector, RBTC_OUT, RBTC_OUT + 1
            )
        );
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, RBTC_OUT + 1);
    }

    /// @dev A violated minimum must undo the fee transfer, both credits, and every event of the batch.
    function test_minRbtcOut_violationRollsBackFeeAndCredits() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();

        (bool ok,) = address(harness).call(
            abi.encodeCall(IPurchaseRbtc.batchBuyRbtc, (buyers, scheduleIds, amounts, RBTC_OUT + 1))
        );

        // `vm.recordLogs` keeps the logs of reverted frames, so the proof that nothing was emitted is
        // that nothing they report happened: no credit and no fee survive the call.
        assertFalse(ok, "a batch below the caller minimum must revert");
        assertEq(harness.getAccumulatedRbtcBalance(buyerA), 0);
        assertEq(harness.getAccumulatedRbtcBalance(buyerB), 0);
        assertEq(token.balanceOf(feeCollector), 0, "the fee transfer rolls back with the batch");
    }

    /// @dev The bound is on the rBTC the handler measured, not on the gross stablecoin the swapper asked for:
    ///      the same batch clears a minimum set from the measured output and fails one set a wei higher, even
    ///      though the stablecoin actually retrieved was well below what the rows planned to spend.
    function test_minRbtcOut_comparesMeasuredOutputNotPlannedStablecoin() public {
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();
        harness.setRetrieveOverride(150 ether); // the rows planned 300 ether of gross spend

        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum.selector, RBTC_OUT, RBTC_OUT + 1
            )
        );
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, RBTC_OUT + 1);

        harness.batchBuyRbtc(buyers, scheduleIds, amounts, RBTC_OUT);
        assertEq(harness.lastPurchaseAmount(), 150 ether - _fee(amounts[0]) - _fee(amounts[1]));
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

    function testFuzz_minRbtcOut_passesExactlyWhenAtOrBelowMeasuredOutput(uint256 measured, uint256 minRbtcOut)
        public
    {
        measured = bound(measured, 1, 100 ether);
        minRbtcOut = bound(minRbtcOut, 0, 200 ether);
        harness.setRbtcOut(measured);
        (address[] memory buyers, uint64[] memory scheduleIds, uint256[] memory amounts) = _twoBuyerBatch();

        if (minRbtcOut > measured) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum.selector, measured, minRbtcOut
                )
            );
        }
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, minRbtcOut);
    }

    function _fee(uint256 amount) private pure returns (uint256) {
        return amount * FLAT_FEE_RATE / FEE_DIVISOR;
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
    IERC20 internal immutable i_token;
    uint256 public lastPurchaseAmount;
    uint256 public feeCollectorBalanceOnPurchase;
    uint256 public purchaseCalls;
    uint256 public rbtcOut;
    uint256 internal retrieveOverride;
    bool internal useRetrieveOverride;
    bool internal revertOnPurchase;

    constructor(
        address dcaManagerAddress,
        address tokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        address initialOwner
    ) FeeHandler(feeCollector, feeSettings, initialOwner) DcaManagerAccessControl(dcaManagerAddress) {
        i_token = IERC20(tokenAddress);
    }

    function setRbtcOut(uint256 amount) external {
        rbtcOut = amount;
    }

    function setRetrieveOverride(uint256 amount) external {
        retrieveOverride = amount;
        useRetrieveOverride = true;
    }

    function setRevertOnPurchase(bool shouldRevert) external {
        revertOnPurchase = shouldRevert;
    }

    function _purchaseToken() internal view override returns (IERC20) {
        return i_token;
    }

    function _purchaseRbtc(uint256 stablecoinAmount, uint256 /* minRbtcOut */) internal override returns (uint256) {
        if (revertOnPurchase) revert("route-called");
        purchaseCalls++;
        lastPurchaseAmount = stablecoinAmount;
        feeCollectorBalanceOnPurchase = i_token.balanceOf(s_feeCollector);
        return rbtcOut;
    }

    function _retrieveStablecoin(address, uint256 amount) internal view override returns (uint256) {
        return useRetrieveOverride ? retrieveOverride : amount;
    }

    function _batchRetrieveStablecoin(address[] memory, uint256[] memory, uint256 totalStablecoinToRetrieve)
        internal
        view
        override
        returns (uint256)
    {
        return useRetrieveOverride ? retrieveOverride : totalStablecoinToRetrieve;
    }
}
