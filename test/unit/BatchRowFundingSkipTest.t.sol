// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {toBatch, packBatchRow} from "test/utils/BatchBuyOne.sol";
import "../Constants.sol";
import {scheduleIdAt} from "test/utils/ScheduleAt.sol";

/**
 * @notice R66: a buyer whose own funds fall short cannot fail anybody else's row.
 * @dev A schedule's principal and the shares backing it are two different books. The principal is
 *      credited with what the deposit asked for, while the shares behind it are minted rounded down and
 *      debited rounded up, so a schedule spending its exact remaining balance can want one share more
 *      than its owner holds. Accrued interest hides that by orders of magnitude — a second of it is
 *      worth far more than the rounding — but it is the owner who decides when to take that cushion
 *      away, and the shares are pooled per buyer rather than per schedule, so one schedule's
 *      withdrawal moves what another one's purchase can spend.
 *
 *      R43 kept the shortfall as a batch revert, on the grounds that the swapper filters the tail
 *      before batching. R66's threat model breaks that argument: the owner reaches this state *after*
 *      the swapper's snapshot, using their own public entry points on their own schedules, and every
 *      check `DcaManager` can make still passes — the schedule balance, the purchase amount and the
 *      due date are all exactly what was quoted. So the batch reverted and every other buyer in the
 *      tick lost their purchase to one buyer's rounding dust. These tests reproduce that and pin the
 *      answer: the row that cannot fund itself is skipped, and the rest of the batch buys.
 *
 *      Lending lanes only: the idle handler holds stablecoin one-to-one, with no rate and no rounding.
 */
contract BatchRowFundingSkipTest is DcaDappTest {
    /// @dev The owner of the rows that go unfundable. Not `USER`, whose row is the bystander here.
    address internal STARVER = makeAddr("share-book-starver");

    /// @dev Withdrawn and put straight back per starving call. Deliberately not a round multiple of any
    ///      exchange rate, so the withdrawal's rounded-up debit and the deposit's rounded-down mint do
    ///      not cancel.
    uint256 internal constant ROUND_TRIP_AMOUNT = 1e12 + 7;

    /// @dev More round trips than any lane needs; the test asserts it got there well inside the budget.
    uint256 internal constant MAX_STARVING_CALLS = 120;

    uint64 internal s_bystanderId;
    uint64 internal s_firstTailId;
    uint64 internal s_secondTailId;

    function setUp() public override {
        super.setUp();
        if (!_lanesApply()) return;

        // A live protocol's exchange rate is never a round number, and a schedule that has been around
        // for a while is the only one that can be batched at all: the swapper indexes from finalized
        // blocks, so a schedule created in the tick's own block is never in the batch it front-runs.
        vm.warp(block.timestamp + 197 days + 13 hours + 7 minutes);

        s_bystanderId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);

        // Two schedules of one owner, each holding exactly one purchase. Nothing here is exotic: it is
        // what any schedule looks like on its last tick, and this owner simply has two of them due
        // together.
        stablecoin.mint(STARVER, USER_TOTAL_AMOUNT);
        vm.startPrank(STARVER);
        stablecoin.approve(address(stablecoinHandler), type(uint256).max);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_SPEND, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        s_firstTailId = scheduleIdAt(dcaManager, STARVER, address(stablecoin), 0);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_SPEND, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        s_secondTailId = scheduleIdAt(dcaManager, STARVER, address(stablecoin), 1);
        vm.stopPrank();

        // Let the position earn for a while before the tick. This is what makes the sweep below the
        // trigger rather than a formality: accrued interest is worth orders of magnitude more than the
        // rounding, so while it is there every row funds comfortably.
        vm.warp(block.timestamp + 30 days);
    }

    /*//////////////////////////////////////////////////////////////
                        THE FRONT-RUN ITSELF
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The batch the swapper composed works; the owner then starves their own funding in the
     *         tick's block, using only their own entry points on their own schedules and leaving the
     *         batch untouched in every way `DcaManager` can see; the same batch must still buy for the
     *         bystander.
     * @dev Before this item that reverted the whole batch with `TokenLending__InsufficientShares`, a
     *      couple of shares short — worth a fraction of one raw unit of stablecoin. The setup is cheap:
     *      an interest sweep plus a handful of round trips (none on LayerBank, four on Sovryn and
     *      Tropykus at the time of writing), all of which a contract owning the schedules can do in one
     *      transaction ahead of the tick.
     */
    function testStarvingOwnFundingCannotCostAnotherRowItsPurchase() external {
        _skipUnlessLending();
        IDcaManager.Batch memory batch = _threeRowBatch();

        // Establish that this exact batch works before the owner touches anything.
        uint256 snapshot = vm.snapshot();
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
        assertGt(_accumulatedRbtc(USER), 0, "the batch did not work before the owner acted");
        assertEq(
            dcaManager.getDcaSchedule(address(stablecoin), s_secondTailId).tokenBalance,
            0,
            "both tail rows should fund while the interest cushion is there"
        );
        vm.revertTo(snapshot);

        uint256 calls = _starveOwnFunding(batch);
        assertLt(calls, MAX_STARVING_CALLS, "could not starve the buyer's own funding within the budget");

        IDcaManager.DcaSchedule memory bystanderBefore =
            dcaManager.getDcaSchedule(address(stablecoin), s_bystanderId);
        IDcaManager.DcaSchedule memory secondTailBefore =
            dcaManager.getDcaSchedule(address(stablecoin), s_secondTailId);

        // Everything the manager checks still passes on the rows that are about to go short: they are
        // live, due, unpaused, their balances still cover their purchases, and their amounts are the
        // ones the swapper quoted.
        assertEq(
            secondTailBefore.tokenBalance, secondTailBefore.purchaseAmount, "the tail row stopped being a tail"
        );

        vm.expectEmit(true, true, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__PurchaseRowSkipped(
            address(stablecoin), s_secondTailId, IDcaManager.PurchaseRowSkipReason.FundingInsufficient
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);

        // The bystander bought, which is the whole point of the item.
        IDcaManager.DcaSchedule memory bystanderAfter =
            dcaManager.getDcaSchedule(address(stablecoin), s_bystanderId);
        assertEq(
            bystanderAfter.tokenBalance,
            bystanderBefore.tokenBalance - bystanderBefore.purchaseAmount,
            "the bystander row did not buy"
        );
        assertGt(_accumulatedRbtc(USER), 0, "no rBTC was bought for the bystander");

        // The row that could not fund itself kept its balance and its purchase slot.
        IDcaManager.DcaSchedule memory secondTailAfter =
            dcaManager.getDcaSchedule(address(stablecoin), s_secondTailId);
        assertEq(secondTailAfter.tokenBalance, secondTailBefore.tokenBalance, "the skipped row was debited");
        assertEq(
            secondTailAfter.lastPurchaseTimestamp,
            secondTailBefore.lastPurchaseTimestamp,
            "the skipped row consumed a period"
        );

        // The owner's first row funded out of the same pooled book, in the order it was submitted, and
        // no row was ever debited for part of a purchase.
        assertEq(
            dcaManager.getDcaSchedule(address(stablecoin), s_firstTailId).tokenBalance,
            0,
            "the first row of a repeated buyer did not buy"
        );
    }

    /// @dev The skipped row is not merely un-debited: it pays no fee and is credited no rBTC, because it
    ///      is dropped before the fee and the allocation weights are calculated.
    function testAnUnfundedRowPaysNoFeeAndIsCreditedNothingExtra() external {
        _skipUnlessLending();
        IDcaManager.Batch memory batch = _threeRowBatch();
        assertLt(_starveOwnFunding(batch), MAX_STARVING_CALLS, "could not starve the buyer's own funding");

        uint256 feeCollectorBefore = stablecoin.balanceOf(FEE_COLLECTOR);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);

        // Two rows funded out of the three submitted, so the aggregated fee is the fee on two.
        uint256 feePaid = stablecoin.balanceOf(FEE_COLLECTOR) - feeCollectorBefore;
        assertEq(feePaid, 2 * feeCalculator.calculateFee(AMOUNT_TO_SPEND), "the skipped row was charged a fee");
    }

    /*//////////////////////////////////////////////////////////////
                          BATCH COMPOSITION
    //////////////////////////////////////////////////////////////*/

    /// @dev Rows are all checked before any of them is committed, so the same schedule twice would buy
    ///      twice. Strictly increasing ids make that unrepresentable for one comparison per row.
    function testADuplicateRowRevertsTheBatch() external {
        _skipUnlessLending();
        bytes32[] memory rows = new bytes32[](2);
        rows[0] = packBatchRow(s_bystanderId, uint96(AMOUNT_TO_SPEND));
        rows[1] = packBatchRow(s_bystanderId, uint96(AMOUNT_TO_SPEND));

        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__BatchRowsNotSorted.selector, s_bystanderId)
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(toBatch(rows, address(stablecoin), s_routeIndex));
    }

    /// @dev Descending ids are the same composition error, reported on the row that broke the order.
    function testDescendingRowsRevertTheBatch() external {
        _skipUnlessLending();
        bytes32[] memory rows = new bytes32[](2);
        rows[0] = packBatchRow(s_firstTailId, uint96(AMOUNT_TO_SPEND));
        rows[1] = packBatchRow(s_bystanderId, uint96(AMOUNT_TO_SPEND));

        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__BatchRowsNotSorted.selector, s_bystanderId)
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(toBatch(rows, address(stablecoin), s_routeIndex));
    }

    /// @dev The order is over decoded ids, so a skipped row still has to hold its place in it — the
    ///      swapper cannot drop the sort for rows it expects to be filtered out anyway.
    function testASkippedRowStillHasToBeInOrder() external {
        _skipUnlessLending();
        vm.prank(USER);
        dcaManager.setSchedulePaused(address(stablecoin), s_bystanderId, true);

        bytes32[] memory rows = new bytes32[](2);
        rows[0] = packBatchRow(s_firstTailId, uint96(AMOUNT_TO_SPEND));
        rows[1] = packBatchRow(s_bystanderId, uint96(AMOUNT_TO_SPEND));

        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__BatchRowsNotSorted.selector, s_bystanderId)
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(toBatch(rows, address(stablecoin), s_routeIndex));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev A lending route is what has a share book to run short of; the idle handler holds its
    ///      stablecoin one-to-one, with no rate and no rounding. Anvil because this funds a second buyer
    ///      by minting, which a fork of the real stablecoin cannot do — the shortfall itself is not
    ///      mock-specific, and `make fork-sovryn` still runs the flipped `BatchTailScheduleTest` pins.
    function _lanesApply() private view returns (bool) {
        return address(dcaManager) != address(0) && isLendingLane && block.chainid == ANVIL_CHAIN_ID;
    }

    function _skipUnlessLending() private {
        if (!_lanesApply()) vm.skip(true);
    }

    /**
     * @dev The front-run, using nothing but the owner's own public entry points, on their own
     *      schedules, and leaving every field the manager checks exactly as the swapper quoted it.
     *
     *      Sweeping the interest removes the cushion accrual keeps between the share book and the
     *      principal ledger. What is left of it is a rounding remainder — under one raw unit of
     *      stablecoin, which is still worth up to `1 / sharePrice` whole shares — so the sweep alone
     *      usually is not enough. Each withdrawal-and-redeposit round trip after it burns exactly one
     *      more share (the withdrawal's debit rounds up, the deposit's mint rounds down) while putting
     *      the principal back, so the ledger the manager sees never moves. A contract owning the
     *      schedule can do the whole thing in one transaction.
     * @return calls How many round trips it took, so the caller can assert it got there.
     */
    function _starveOwnFunding(IDcaManager.Batch memory batch) private returns (uint256 calls) {
        vm.prank(STARVER);
        dcaManager.withdrawAllAccumulatedInterest(_oneToken(), _oneRoute());

        while (calls < MAX_STARVING_CALLS && _batchStillFundsEveryRow(batch)) {
            vm.startPrank(STARVER);
            dcaManager.withdrawToken(address(stablecoin), s_secondTailId, ROUND_TRIP_AMOUNT);
            dcaManager.depositToken(address(stablecoin), s_secondTailId, ROUND_TRIP_AMOUNT);
            vm.stopPrank();
            ++calls;
        }
    }

    /// @dev Whether every row would still fund, decided by running the batch on a snapshot and rolling
    ///      it back. Reading it off a real execution is the only honest test: it is exactly the question
    ///      the handler answers, and it needs no copy of the handler's share arithmetic here.
    function _batchStillFundsEveryRow(IDcaManager.Batch memory batch) private returns (bool funded) {
        uint256 snapshot = vm.snapshot();
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batch);
        funded = dcaManager.getDcaSchedule(address(stablecoin), s_secondTailId).tokenBalance == 0;
        vm.revertTo(snapshot);
    }

    /// @dev The batch the swapper composes, in ascending id order: the bystander's row first, then the
    ///      two rows of the owner who is about to run out of backing.
    function _threeRowBatch() private view returns (IDcaManager.Batch memory) {
        bytes32[] memory rows = new bytes32[](3);
        rows[0] = packBatchRow(s_bystanderId, uint96(AMOUNT_TO_SPEND));
        rows[1] = packBatchRow(s_firstTailId, uint96(AMOUNT_TO_SPEND));
        rows[2] = packBatchRow(s_secondTailId, uint96(AMOUNT_TO_SPEND));
        return toBatch(rows, address(stablecoin), s_routeIndex);
    }

    function _oneToken() private view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(stablecoin);
    }

    function _oneRoute() private view returns (uint256[] memory routes) {
        routes = new uint256[](1);
        routes[0] = s_routeIndex;
    }

    function _accumulatedRbtc(address user) private view returns (uint256) {
        return IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(user);
    }
}
