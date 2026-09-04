//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenLending} from "../../src/interfaces/ITokenLending.sol";
import "../Constants.sol";
import {scheduleAt} from "test/utils/ScheduleAt.sol";

/**
 * @notice R54: `topUpFromInterest` credits accrued lending interest to one schedule's spendable
 *         balance without moving a single token.
 * @dev The interest already sits in the handler's lending position, so the call is a storage write
 *      plus a view. Two things therefore have to hold everywhere below: no state-changing external
 *      call happens, and the route's summed principal never rises above the position's value.
 */
contract TopUpFromInterestTest is DcaDappTest {
    /// @dev 5% linear APR in every lending mock, so 200 days on the setUp deposit accrues ~2.7% of
    ///      it — comfortably more than the slack the boundary tests need, on all three lanes.
    uint256 private constant ACCRUAL_TIME = 200 days;
    /// @dev Long enough that the accrued interest exceeds a whole minimum purchase amount, which is
    ///      what a depleted schedule needs before it can resume.
    uint256 private constant LONG_ACCRUAL_TIME = 400 days;
    /// @dev Share round-trips lose a wei or two; the point of these assertions is the ledger.
    uint256 private constant DUST = 2;

    event DcaManager__ScheduleToppedUpFromInterest(
        address indexed user, address indexed token, uint64 indexed scheduleId, uint256 interest
    );

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _schedule(uint256 scheduleIndex) private view returns (IDcaManager.DcaSchedule memory) {
        return scheduleAt(dcaManager, USER, address(stablecoin), scheduleIndex);
    }

    /// @dev `view`, and that is load-bearing: the compiler rejects this the moment
    ///      `getInterestAccrued` stops being one, which is what keeps generated clients reading it
    ///      for free instead of routing it through a write binding.
    function _accruedInterest() private view returns (uint256) {
        return dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
    }

    /// @dev Every schedule read is hoisted out of the arguments: a view call made after `vm.prank`
    ///      or `vm.expectRevert` consumes the cheatcode instead of the call under test.
    function _topUp(uint256 scheduleIndex, uint256 amount) private {
        uint64 scheduleId = _schedule(scheduleIndex).scheduleId;
        vm.prank(USER);
        dcaManager.topUpFromInterest(scheduleId, amount);
    }

    /**
     * @dev A top-up must buy at least one more whole purchase, so a schedule whose balance is an
     *      exact multiple of its purchase amount needs a whole purchase amount credited. Withdrawing
     *      `slack` leaves the balance that far below the next boundary, which is the realistic shape
     *      (a user rarely holds an exact multiple).
     * @dev The slack is sized from what the route actually paid, not from a constant: the mock lanes
     *      accrue 5% APR over `ACCRUAL_TIME` while a fork lane accrues whatever the live protocol
     *      paid, and the boundary has to be reachable on both.
     */
    function _accrueAndOpenSlack(uint256 scheduleIndex) private returns (uint256 slack) {
        updateExchangeRate(ACCRUAL_TIME);
        uint256 accruedInterest = _accruedInterest();
        assertGt(accruedInterest, 0, "the lane accrued no interest at all");

        IDcaManager.DcaSchedule memory schedule = _schedule(scheduleIndex);
        assertEq(schedule.tokenBalance % schedule.purchaseAmount, 0, "the balance is no longer a whole multiple");
        slack = accruedInterest / 4;
        if (slack > schedule.purchaseAmount / 10) slack = schedule.purchaseAmount / 10;
        assertGt(slack, 0, "the accrued interest is too small to open any slack");

        vm.prank(USER);
        dcaManager.withdrawToken(schedule.scheduleId, slack);
    }

    /// @dev Open the same slack on a second schedule, after interest has already accrued.
    function _openSlackOn(uint256 scheduleIndex, uint256 slack) private {
        IDcaManager.DcaSchedule memory schedule = _schedule(scheduleIndex);
        assertEq(schedule.tokenBalance % schedule.purchaseAmount, 0, "the balance is no longer a whole multiple");
        vm.prank(USER);
        dcaManager.withdrawToken(schedule.scheduleId, slack);
    }

    /// @dev The credit that takes a schedule past its next whole purchase.
    function _neededToFundAnotherPurchase(uint256 scheduleIndex) private view returns (uint256) {
        IDcaManager.DcaSchedule memory schedule = _schedule(scheduleIndex);
        return schedule.purchaseAmount - (schedule.tokenBalance % schedule.purchaseAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                 CREDIT
    //////////////////////////////////////////////////////////////*/

    /// @notice The whole accrued figure lands on the schedule, and the route is left yielding ~0.
    function testTopUpCreditsAccruedInterestToTheSchedule() external onlyLendingLane {
        uint256 slack = _accrueAndOpenSlack(SCHEDULE_INDEX);

        uint256 accruedInterest = _accruedInterest();
        assertGt(accruedInterest, slack, "the lane accrued too little to cross a purchase boundary");
        uint256 balanceBefore = _schedule(SCHEDULE_INDEX).tokenBalance;
        uint64 scheduleId = _schedule(SCHEDULE_INDEX).scheduleId;

        vm.expectEmit(true, true, true, true);
        emit DcaManager__ScheduleToppedUpFromInterest(USER, address(stablecoin), scheduleId, accruedInterest);
        vm.expectEmit(true, true, false, true);
        emit DcaManager__TokenBalanceUpdated(address(stablecoin), scheduleId, balanceBefore + accruedInterest);
        _topUp(SCHEDULE_INDEX, accruedInterest);

        assertEq(
            _schedule(SCHEDULE_INDEX).tokenBalance,
            balanceBefore + accruedInterest,
            "the schedule was not credited the exact accrued figure"
        );
        assertLe(_accruedInterest(), DUST, "interest is still reported after crediting all of it");
    }

    /**
     * @notice Nothing is redeemed, minted, or transferred: the credit only relabels what the
     *         position already holds.
     * @dev Asserted on the lending position and the stablecoin rather than on the transaction's log
     *      count. Reading the accrued figure is no longer a `view` — on a market that accrues lazily
     *      it pokes that accrual, which can log — but a redemption or a transfer cannot happen
     *      without moving shares or stablecoin, and neither moves here.
     */
    function testTopUpMovesNoCashAndLeavesTheSharesAlone() external onlyLendingLane {
        _accrueAndOpenSlack(SCHEDULE_INDEX);

        uint256 accruedInterest = _accruedInterest();
        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);
        uint256 handlerStablecoinBefore = stablecoin.balanceOf(address(stablecoinHandler));
        uint256 userSharesBefore = ITokenLending(address(stablecoinHandler)).getUserShares(USER);

        vm.recordLogs();
        _topUp(SCHEDULE_INDEX, accruedInterest);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // A mint, burn, redeem, or transfer of the underlying would log from the stablecoin itself.
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(stablecoin), "the stablecoin moved during a top-up");
        }
        assertEq(
            ITokenLending(address(stablecoinHandler)).getUserShares(USER),
            userSharesBefore,
            "the top-up minted or burnt lending shares"
        );
        assertEq(stablecoin.balanceOf(USER), userStablecoinBefore, "stablecoin reached the user");
        assertEq(
            stablecoin.balanceOf(address(stablecoinHandler)), handlerStablecoinBefore, "stablecoin reached the handler"
        );
    }

    /// @notice Interest is pooled per route, but the credit lands on the named schedule alone.
    function testTopUpLeavesTheOtherSchedulesOnTheRouteUntouched() external onlyLendingLane {
        super.createSeveralDcaSchedules();
        uint256 slack = _accrueAndOpenSlack(SCHEDULE_INDEX);

        uint256 accruedInterest = _accruedInterest();
        assertGt(accruedInterest, slack, "the lane accrued too little to cross a purchase boundary");

        uint256[] memory balancesBefore = new uint256[](NUM_OF_SCHEDULES);
        for (uint256 i; i < NUM_OF_SCHEDULES; ++i) {
            balancesBefore[i] = _schedule(i).tokenBalance;
        }

        _topUp(SCHEDULE_INDEX, accruedInterest);

        assertEq(_schedule(SCHEDULE_INDEX).tokenBalance, balancesBefore[SCHEDULE_INDEX] + accruedInterest);
        for (uint256 i = SCHEDULE_INDEX + 1; i < NUM_OF_SCHEDULES; ++i) {
            assertEq(_schedule(i).tokenBalance, balancesBefore[i], "another schedule on the route moved");
        }
    }

    /// @notice The `amount` parameter exists so one pot of interest can feed several schedules.
    function testTopUpCanBeSplitAcrossTwoSchedules() external onlyLendingLane {
        super.createSeveralDcaSchedules();
        uint256 firstSlack = _accrueAndOpenSlack(SCHEDULE_INDEX);
        _openSlackOn(SCHEDULE_INDEX + 1, firstSlack);

        uint256 accruedInterest = _accruedInterest();
        uint256 firstCredit = accruedInterest / 2;
        assertGt(firstCredit, firstSlack, "the lane accrued too little to split");

        uint256 firstBalanceBefore = _schedule(SCHEDULE_INDEX).tokenBalance;
        _topUp(SCHEDULE_INDEX, firstCredit);
        assertEq(_schedule(SCHEDULE_INDEX).tokenBalance, firstBalanceBefore + firstCredit);

        // Crediting the first schedule raised the route's locked principal, so the interest still
        // available is what is left of the pot.
        uint256 remainingInterest = _accruedInterest();
        assertApproxEqAbs(remainingInterest, accruedInterest - firstCredit, DUST, "the pot did not shrink by the credit");

        uint256 secondSlack = _neededToFundAnotherPurchase(SCHEDULE_INDEX + 1);
        assertGt(remainingInterest, secondSlack, "not enough left to cross the second schedule's boundary");
        uint256 secondBalanceBefore = _schedule(SCHEDULE_INDEX + 1).tokenBalance;
        _topUp(SCHEDULE_INDEX + 1, remainingInterest);

        assertEq(_schedule(SCHEDULE_INDEX + 1).tokenBalance, secondBalanceBefore + remainingInterest);
        assertLe(_accruedInterest(), DUST, "interest is still reported after both credits");
    }

    /**
     * @notice The quote is a real `eth_call`: readable with no signer and no state change.
     * @dev The helper above already fails to compile if `getInterestAccrued` loses `view`, but that
     *      only binds Solidity callers. This binds the wire: a `staticcall` reverts on any state
     *      write, so a getter that pokes the market would fail here.
     */
    function testInterestQuoteIsReadableByStaticCall() external onlyLendingLane {
        _accrueAndOpenSlack(SCHEDULE_INDEX);

        (bool success, bytes memory returnData) = address(dcaManager).staticcall(
            abi.encodeCall(IDcaManager.getInterestAccrued, (USER, address(stablecoin), s_routeIndex))
        );

        assertTrue(success, "the accrued-interest quote is no longer readable without a transaction");
        assertEq(abi.decode(returnData, (uint256)), _accruedInterest(), "the staticcall read a different figure");
    }

    /**
     * @notice The quote never exceeds the ceiling the credit is bounded by.
     * @dev The two are read at different rates on a market that accrues lazily — the quote at the
     *      market's plain read, the ceiling at the rate a write path would get — and only one
     *      ordering of the two is safe. This is the lane-agnostic half; the Tropykus handler suite
     *      pins the case where they actually differ.
     */
    function testQuotedInterestNeverExceedsTheCeiling() external onlyLendingLane {
        _accrueAndOpenSlack(SCHEDULE_INDEX);

        uint256 quoted = _accruedInterest();
        uint256 balanceBefore = _schedule(SCHEDULE_INDEX).tokenBalance;

        _topUp(SCHEDULE_INDEX, quoted);
        assertEq(
            _schedule(SCHEDULE_INDEX).tokenBalance,
            balanceBefore + quoted,
            "the quoted figure was above the ceiling the credit is bounded by"
        );
    }

    /*//////////////////////////////////////////////////////////////
                            SPENDING THE CREDIT
    //////////////////////////////////////////////////////////////*/

    /// @notice A purchase can spend the credited balance, and a depleted schedule resumes on it.
    function testDepletedScheduleResumesOnACreditAndBuys() external onlyLendingLane {
        // A second schedule keeps principal (and so interest) on the route while the first is emptied.
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();

        updateExchangeRate(LONG_ACCRUAL_TIME);
        uint256 accruedInterest = _accruedInterest();
        assertGt(accruedInterest, 0, "the lane accrued no interest at all");

        // An empty schedule funds no purchase at all, so the credit that revives it is a whole
        // purchase amount. Size that against what this lane actually paid rather than the shipped
        // 25-token floor, which a fork lane's real yield does not reach inside a test.
        uint256 purchaseAmount = accruedInterest / 2;
        vm.prank(OWNER);
        dcaManager.setTokenMinPurchaseAmount(address(stablecoin), purchaseAmount);

        uint64 scheduleId = _schedule(SCHEDULE_INDEX).scheduleId;
        vm.startPrank(USER);
        dcaManager.updatePurchaseAmount(scheduleId, purchaseAmount);
        dcaManager.withdrawToken(scheduleId, type(uint256).max);
        vm.stopPrank();
        assertEq(_schedule(SCHEDULE_INDEX).tokenBalance, 0, "the schedule was not depleted");

        // Re-read: exiting the position may have cost a redemption fee, which the top-up must not
        // outrun.
        uint256 credit = _accruedInterest();
        assertGe(credit, purchaseAmount, "not enough interest left to revive the schedule");

        _topUp(SCHEDULE_INDEX, credit);
        assertEq(_schedule(SCHEDULE_INDEX).tokenBalance, credit, "the depleted schedule was not credited");

        uint256 rbtcBefore = dcaManager.getAccumulatedRbtcBalance(USER, address(stablecoin), s_routeIndex);
        super.buyRbtcOne(USER, SCHEDULE_INDEX, scheduleId, purchaseAmount);

        assertEq(
            _schedule(SCHEDULE_INDEX).tokenBalance,
            credit - purchaseAmount,
            "the purchase did not spend the credited balance"
        );
        assertGt(
            dcaManager.getAccumulatedRbtcBalance(USER, address(stablecoin), s_routeIndex),
            rbtcBefore,
            "the revived schedule bought no rBTC"
        );
    }

    /*//////////////////////////////////////////////////////////////
                             EXIT BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    /// @notice After a full credit the route's principal equals the position's value; the sentinel
    ///         withdrawal is where a 1-wei shortfall would surface.
    function testFullWithdrawalAfterAFullTopUpStillExits() external onlyLendingLane {
        _accrueAndOpenSlack(SCHEDULE_INDEX);
        _topUp(SCHEDULE_INDEX, _accruedInterest());

        uint256 credited = _schedule(SCHEDULE_INDEX).tokenBalance;
        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);

        uint64 scheduleId = _schedule(SCHEDULE_INDEX).scheduleId;
        vm.prank(USER);
        dcaManager.withdrawToken(scheduleId, type(uint256).max);

        assertEq(_schedule(SCHEDULE_INDEX).tokenBalance, 0, "the sentinel left principal behind");
        assertApproxEqAbs(
            stablecoin.balanceOf(USER) - userStablecoinBefore, credited, DUST, "the exit paid less than the ledger"
        );
    }

    /// @notice Deletion still refunds after a full credit.
    function testDeleteScheduleAfterAFullTopUpStillPaysOut() external onlyLendingLane {
        _accrueAndOpenSlack(SCHEDULE_INDEX);
        _topUp(SCHEDULE_INDEX, _accruedInterest());

        uint256 credited = _schedule(SCHEDULE_INDEX).tokenBalance;
        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);

        uint64 scheduleId = _schedule(SCHEDULE_INDEX).scheduleId;
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(scheduleId);

        assertApproxEqAbs(
            stablecoin.balanceOf(USER) - userStablecoinBefore, credited, DUST, "deletion paid less than the ledger"
        );
    }

    /// @notice Withdrawing interest that has already been credited is a no-op, not a revert.
    function testWithdrawAllInterestAfterAFullTopUpIsANoOp() external onlyLendingLane {
        _accrueAndOpenSlack(SCHEDULE_INDEX);
        _topUp(SCHEDULE_INDEX, _accruedInterest());

        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;

        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);

        assertApproxEqAbs(
            stablecoin.balanceOf(USER), userStablecoinBefore, DUST, "a credited position still paid interest out"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Nothing has accrued yet, so there is nothing to credit.
    function testTopUpRevertsWithoutAccruedInterest() external onlyLendingLane {
        assertEq(_accruedInterest(), 0, "the lane accrued interest before any time passed");
        uint64 scheduleId = _schedule(SCHEDULE_INDEX).scheduleId;

        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__NoInterestToTopUpWith.selector, address(stablecoin), s_routeIndex
            )
        );
        dcaManager.topUpFromInterest(scheduleId, AMOUNT_TO_SPEND);
    }

    /// @notice A caller cannot credit more than they have earned on the route.
    function testTopUpRevertsWhenTheAmountExceedsTheAccruedInterest() external onlyLendingLane {
        _accrueAndOpenSlack(SCHEDULE_INDEX);
        uint256 accruedInterest = _accruedInterest();
        uint64 scheduleId = _schedule(SCHEDULE_INDEX).scheduleId;

        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__TopUpExceedsAccruedInterest.selector,
                address(stablecoin),
                s_routeIndex,
                accruedInterest + 1,
                accruedInterest
            )
        );
        dcaManager.topUpFromInterest(scheduleId, accruedInterest + 1);
    }

    /// @notice A credit that buys no further purchase is refused, so interest cannot be moved as dust.
    function testTopUpRevertsWhenItFundsNoFurtherPurchase() external onlyLendingLane {
        _accrueAndOpenSlack(SCHEDULE_INDEX);

        uint256 needed = _neededToFundAnotherPurchase(SCHEDULE_INDEX);
        assertLt(needed, _accruedInterest(), "the accrued interest cannot reach the boundary at all");
        uint64 scheduleId = _schedule(SCHEDULE_INDEX).scheduleId;

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__TopUpDoesNotFundAnotherPurchase.selector,
                address(stablecoin),
                scheduleId,
                needed - 1
            )
        );
        dcaManager.topUpFromInterest(scheduleId, needed - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__TopUpDoesNotFundAnotherPurchase.selector, address(stablecoin), scheduleId, 0
            )
        );
        dcaManager.topUpFromInterest(scheduleId, 0);
        vm.stopPrank();

        // The boundary itself is reachable: one wei more is accepted.
        _topUp(SCHEDULE_INDEX, needed);
        assertEq(_schedule(SCHEDULE_INDEX).tokenBalance % _schedule(SCHEDULE_INDEX).purchaseAmount, 0);
    }

    /// @notice An idle route earns nothing, so it has nothing to credit.
    function testTopUpRevertsOnAnIdleRoute() external {
        if (isLendingLane) {
            console2.log("Skipping test: idle-only");
            return;
        }

        uint64 scheduleId = _schedule(SCHEDULE_INDEX).scheduleId;

        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__TokenDoesNotYieldInterest.selector, address(stablecoin))
        );
        dcaManager.topUpFromInterest(scheduleId, AMOUNT_TO_SPEND);
    }

    /// @notice The id is checked against storage, as on every other schedule mutator.
    function testTopUpRevertsOnAnIdThatBelongsToNoSchedule() external onlyLendingLane {
        _accrueAndOpenSlack(SCHEDULE_INDEX);

        uint64 wrongScheduleId = _schedule(SCHEDULE_INDEX).scheduleId + 1;
        uint256 accruedInterest = _accruedInterest();

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, wrongScheduleId));
        dcaManager.topUpFromInterest(wrongScheduleId, accruedInterest);
    }

    /// @notice A deleted id is retired: it never comes back and never opens the schedule that replaced it.
    function testTopUpRevertsOnADeletedSchedule() external onlyLendingLane {
        updateExchangeRate(ACCRUAL_TIME);
        uint64 scheduleId = _schedule(SCHEDULE_INDEX).scheduleId;

        vm.prank(USER);
        dcaManager.deleteDcaSchedule(scheduleId);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, scheduleId));
        dcaManager.topUpFromInterest(scheduleId, 1);
    }

    /// @notice The schedule stores its owner, so the entry point only reaches the caller's own.
    function testTopUpCannotReachAnotherUsersSchedule() external onlyLendingLane {
        _accrueAndOpenSlack(SCHEDULE_INDEX);

        uint256 balanceBefore = _schedule(SCHEDULE_INDEX).tokenBalance;
        uint64 scheduleId = _schedule(SCHEDULE_INDEX).scheduleId;
        address attacker = makeAddr("attacker");
        uint256 accruedInterest = _accruedInterest();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__NotScheduleOwner.selector, scheduleId));
        dcaManager.topUpFromInterest(scheduleId, accruedInterest);

        assertEq(_schedule(SCHEDULE_INDEX).tokenBalance, balanceBefore, "another account moved the schedule");
    }

    /**
     * @notice A deposit pause is an intake valve, so it does not block a top-up.
     * @dev The pause exists to stop users putting new funds into a route. Interest already sitting
     *      in that route's position is not new funds, and crediting it moves nothing in, so the same
     *      call that rejects a deposit lets the top-up through.
     */
    function testTopUpSucceedsWhileDepositsArePaused() external onlyLendingLane {
        _accrueAndOpenSlack(SCHEDULE_INDEX);
        uint256 accruedInterest = _accruedInterest();
        uint256 balanceBefore = _schedule(SCHEDULE_INDEX).tokenBalance;
        uint64 scheduleId = _schedule(SCHEDULE_INDEX).scheduleId;

        vm.prank(OWNER);
        operationsAdmin.setDepositsPaused(address(stablecoin), s_routeIndex, true);

        _topUp(SCHEDULE_INDEX, accruedInterest);
        assertEq(
            _schedule(SCHEDULE_INDEX).tokenBalance,
            balanceBefore + accruedInterest,
            "the pause blocked a credit that moves no funds in"
        );

        // The pause still does its job on the path it was written for.
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__DepositsPaused.selector, address(stablecoin), s_routeIndex)
        );
        dcaManager.depositToken(scheduleId, AMOUNT_TO_DEPOSIT);
        vm.stopPrank();
    }
}
