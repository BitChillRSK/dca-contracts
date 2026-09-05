//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
// import {RbtcBaseTest} from "./RbtcBaseTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {IDcaManagerAccessControl} from "../../src/interfaces/IDcaManagerAccessControl.sol";
import {batchOf, handlerBatchBuyOne, UNUSED_SCHEDULE_ID, toBatch, packBatchRow} from "../utils/BatchBuyOne.sol";
import "../Constants.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

contract RbtcPurchaseTest is DcaDappTest {

    function setUp() public override {
        super.setUp();
    }

    //////////////////////
    /// Purchase tests ///
    //////////////////////
    function testSinglePurchase() external {
        super.makeSinglePurchase();
    }

    /// @dev R66: a batch row naming no live schedule is skipped, not reverted. A length-1 batch that
    ///      skips its only row buys nothing and calls no handler, but does not revert.
    function testCannotBuyIfInexistentSchedule() external {
        uint64 wrongScheduleId = UNUSED_SCHEDULE_ID;
        vm.expectEmit(true, true, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__PurchaseRowSkipped(
            address(stablecoin), wrongScheduleId, IDcaManager.PurchaseRowSkipReason.InexistentSchedule
        );
        buyRbtcOne(wrongScheduleId);
    }

    /// @dev A row is one id, and the batch's token is the other half of the key that addresses it.
    ///      A schedule holding another stablecoin is therefore not reachable from this batch at all:
    ///      the pair addresses empty storage and is skipped the same as a deleted schedule (R66).
    function testCannotBuyIfScheduleHoldsAnotherToken() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        address otherToken = makeAddr("someOtherStablecoin");
        vm.expectEmit(true, true, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__PurchaseRowSkipped(
            otherToken, scheduleId, IDcaManager.PurchaseRowSkipReason.InexistentSchedule
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batchOf(otherToken, scheduleId, 0, s_routeIndex));
    }

    /// @dev R66: a row not yet due is skipped, not reverted.
    function testCannotBuyIfPeriodNotElapsed() external {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
        dcaManager.updatePurchasePeriod(address(stablecoin), scheduleId, MIN_PURCHASE_PERIOD);
        vm.stopPrank();
        buyRbtcOne(scheduleId); // first purchase
        IDcaManager.DcaSchedule memory schedule = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.expectEmit(true, true, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__PurchaseRowSkipped(
            address(stablecoin), scheduleId, IDcaManager.PurchaseRowSkipReason.PeriodNotElapsed
        );
        buyRbtcOne(scheduleId); // second purchase, skipped
        IDcaManager.DcaSchedule memory unchanged = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(unchanged.lastPurchaseTimestamp, schedule.lastPurchaseTimestamp, "the skipped row is not purchased");
    }

    function testBuyAllowedAtUtcDayStartOfDueDay() external {
        uint256 firstBuy = _nextUtcTimestamp(20 hours);
        vm.warp(firstBuy);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        buyRbtcOne(scheduleId);

        uint256 dueDayStart = _utcDayStart(firstBuy) + 1 days; // still 20 hours before last + period
        vm.warp(dueDayStart);
        buyRbtcOne(scheduleId);

        IDcaManager.DcaSchedule memory schedule = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(schedule.lastPurchaseTimestamp, firstBuy + MIN_PURCHASE_PERIOD);
    }

    function testCannotBuyOneSecondBeforeDueUtcDay() external {
        uint256 firstBuy = _nextUtcTimestamp(20 hours);
        vm.warp(firstBuy);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        buyRbtcOne(scheduleId);
        uint256 lastPurchaseTimestamp =
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp;

        uint256 dueDayStart = _utcDayStart(firstBuy) + 1 days;
        vm.warp(dueDayStart - 1);
        vm.expectEmit(true, true, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__PurchaseRowSkipped(
            address(stablecoin), scheduleId, IDcaManager.PurchaseRowSkipReason.PeriodNotElapsed
        );
        buyRbtcOne(scheduleId);
        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp,
            lastPurchaseTimestamp,
            "the skipped row is not purchased"
        );
    }

    function testUtcDayEarlyBuyConsumesOnePeriodAndBlocksSameDaySecondBuy() external {
        uint256 firstBuy = _nextUtcTimestamp(20 hours);
        vm.warp(firstBuy);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        buyRbtcOne(scheduleId);

        uint256 dueDayStart = _utcDayStart(firstBuy) + 1 days;
        vm.warp(dueDayStart); // 00:00 UTC of the due day, before last + period wall-clock
        buyRbtcOne(scheduleId);

        IDcaManager.DcaSchedule memory schedule = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(schedule.lastPurchaseTimestamp, firstBuy + MIN_PURCHASE_PERIOD);

        vm.warp(dueDayStart + 9 hours); // still the due UTC day
        vm.expectEmit(true, true, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__PurchaseRowSkipped(
            address(stablecoin), scheduleId, IDcaManager.PurchaseRowSkipReason.PeriodNotElapsed
        );
        buyRbtcOne(scheduleId);
        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).lastPurchaseTimestamp,
            schedule.lastPurchaseTimestamp,
            "the skipped row is not purchased"
        );
    }

    function testWeeklyBuyAllowedOnDueUtcDay() external {
        uint256 weeklyPeriod = 7 days;
        uint256 firstBuy = _nextUtcTimestamp(20 hours);
        vm.warp(firstBuy);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.prank(USER);
        dcaManager.updatePurchasePeriod(address(stablecoin), scheduleId, weeklyPeriod);
        buyRbtcOne(scheduleId);

        uint256 dueDayStart = _utcDayStart(firstBuy) + weeklyPeriod;
        vm.warp(dueDayStart); // due UTC day 00:00, 20 hours before last + period
        buyRbtcOne(scheduleId);

        IDcaManager.DcaSchedule memory schedule = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(schedule.lastPurchaseTimestamp, firstBuy + weeklyPeriod);
    }

    function testSeveralPurchasesOneSchedule() external {
        uint256 numOfPurchases = 5;

        uint256 fee = feeCalculator.calculateFee(AMOUNT_TO_SPEND);
        uint256 netPurchaseAmount = AMOUNT_TO_SPEND - fee;

        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.prank(USER);
        dcaManager.updatePurchasePeriod(address(stablecoin), scheduleId, MIN_PURCHASE_PERIOD);
        for (uint256 i; i < numOfPurchases; ++i) {
            buyRbtcOne(scheduleId);
            vm.warp(vm.getBlockTimestamp() + MIN_PURCHASE_PERIOD);
        }
        vm.prank(USER);
        // assertEq(stablecoinHandler.getAccumulatedRbtcBalance(), (netPurchaseAmount / s_btcPrice) * numOfPurchases);

        // if (keccak256(abi.encodePacked(swapType)) == keccak256(abi.encodePacked("mocSwaps"))) {
        //     assertEq(
        //         IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER),
        //         (netPurchaseAmount / s_btcPrice) * numOfPurchases
        //     );
        // } else if (keccak256(abi.encodePacked(swapType)) == keccak256(abi.encodePacked("dexSwaps"))) {
        assertApproxEqRel( // The mock contract that simulates swapping on Uniswap allows for some slippage
            IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER),
            (netPurchaseAmount / s_btcPrice) * numOfPurchases,
            _maxPurchaseSlippage() // Allow a maximum difference of 0.5% (on fork tests we saw this was necessary for both MoC and Uniswap purchases)
        );
        // }
    }

    // This test would be relevant if a schedule runs out of stablecoin and later the user deposits more
    // Solidity gives no ordering guarantee between "read a local assigned from block.timestamp" and
    // "a later vm.warp changes block.timestamp" beyond what the compiler's optimizer happens to do —
    // vm.warp is a cheatcode, not part of the language the immutable-within-a-transaction assumption
    // is written against. The Yul optimizer under via_ir can rematerialize a TIMESTAMP read instead of
    // keeping the assigned local, so a value snapshotted before a warp must be pinned somewhere a
    // cheatcode-driven rematerialization cannot reach it: storage survives that, a stack local does
    // not. See docs/relaunch/R55-solx-and-ir-evaluation.md and R60-src-only-via-ir.md.
    uint256 private s_firstPurchaseTimestampForResumeTest;

    function testLastPurchaseTimestampConsistencyWhenScheduleResumed(uint256 timeUntilResume) public {
        if (timeUntilResume < MIN_PURCHASE_PERIOD) return; // Avoid known revert
        if (timeUntilResume > 100 * 52 weeks) return; // Avoid overflows
        s_firstPurchaseTimestampForResumeTest = block.timestamp;
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        buyRbtcOne(scheduleId);

        // Imagine after the first purchase, the schedule runs out of stablecoin and is resumed later
        vm.warp(vm.getBlockTimestamp() + timeUntilResume);

        buyRbtcOne(scheduleId);

        IDcaManager.DcaSchedule memory schedule = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        assertLe(schedule.lastPurchaseTimestamp, block.timestamp);
        assertGt(schedule.lastPurchaseTimestamp, block.timestamp - MIN_PURCHASE_PERIOD);
        uint256 firstPurchaseTimestamp = s_firstPurchaseTimestampForResumeTest;
        uint256 periodsElapsed = (block.timestamp - firstPurchaseTimestamp) / MIN_PURCHASE_PERIOD;
        assertEq(schedule.lastPurchaseTimestamp, firstPurchaseTimestamp + periodsElapsed * MIN_PURCHASE_PERIOD);
    }

    /**
     * @notice A schedule with nothing left to spend is skipped rather than failing the batch (R66).
     * @dev The batch path debits each buyer's shares rounded **up** (`_batchRetrieveStablecoin`) and
     *      reverts on a shortfall, where the removed single path clamped to the shares held. On a
     *      live lending fork with a static exchange rate that round-up costs ~1 wei of shares per
     *      purchase, so draining the very last purchase through the batch can revert on shares
     *      before the schedule balance reaches zero. Withdraw the tail instead of spending it, so
     *      this test asserts the DcaManager guard it is named for on every lane.
     */
    function testSkipsPurchaseIfStablecoinRunsOut() external {
        uint256 numOfPurchases = AMOUNT_TO_DEPOSIT / AMOUNT_TO_SPEND;
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        for (uint256 i; i < numOfPurchases - 1; ++i) {
            buyRbtcOne(scheduleId);
            vm.warp(vm.getBlockTimestamp() + MIN_PURCHASE_PERIOD);
        }

        // Empty the schedule without spending the tail, so its balance is exactly zero
        uint256 remaining = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, remaining);
        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance, 0);

        // Attempt to purchase once more: skipped, not reverted
        vm.expectEmit(true, true, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__PurchaseRowSkipped(
            address(stablecoin), scheduleId, IDcaManager.PurchaseRowSkipReason.BalanceInsufficient
        );
        buyRbtcOne(scheduleId);
        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance, 0);
    }

    function testSeveralPurchasesWithSeveralSchedules() external {
        super.createSeveralDcaSchedules();
        super.makeSeveralPurchasesWithSeveralSchedules();
    }

    function testOnlySwapperCanCallDcaManagerToPurchase() external {
        vm.startPrank(USER);
        uint256 stablecoinBalanceBeforePurchase = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 rbtcBalanceBeforePurchase = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        bytes memory encodedRevert = abi.encodeWithSelector(IDcaManager.DcaManager__UnauthorizedSwapper.selector, USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.expectRevert(encodedRevert);
        dcaManager.batchBuyRbtc(batchOf(address(stablecoin), scheduleId, uint96(AMOUNT_TO_SPEND), s_routeIndex));
        uint256 stablecoinBalanceAfterPurchase = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 RbtcBalanceAfterPurchase = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        vm.stopPrank();
        // Check that balances didn't change
        assertEq(stablecoinBalanceBeforePurchase, stablecoinBalanceAfterPurchase);
        assertEq(RbtcBalanceAfterPurchase, rbtcBalanceBeforePurchase);
    }

    function testOnlyDcaManagerCanPurchase() external {
        vm.startPrank(USER);
        uint256 stablecoinBalanceBeforePurchase = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 rbtcBalanceBeforePurchase = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.expectRevert(IDcaManagerAccessControl.DcaManagerAccessControl__OnlyDcaManagerCanCall.selector);
        handlerBatchBuyOne(IPurchaseRbtc(address(stablecoinHandler)), USER, scheduleId, MIN_PURCHASE_AMOUNT);
        uint256 stablecoinBalanceAfterPurchase = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 RbtcBalanceAfterPurchase = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        vm.stopPrank();
        // Check that balances didn't change
        assertEq(stablecoinBalanceBeforePurchase, stablecoinBalanceAfterPurchase);
        assertEq(RbtcBalanceAfterPurchase, rbtcBalanceBeforePurchase);
    }

    function testBatchPurchasesOneUser() external {
        super.createSeveralDcaSchedules();
        super.makeBatchPurchasesOneUser();
    }

    function testBatchPurchaseFailsIfArraysEmpty() external {
        bytes32[] memory emptyRows;
        vm.expectRevert(IDcaManager.DcaManager__EmptyBatchPurchaseArrays.selector);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            toBatch(emptyRows, address(stablecoin), s_routeIndex)
        );
    }

    /// @dev R64 dropped the per-row amount from `Batch`: the manager spends what the schedule holds,
    ///      so a swapper working from a stale snapshot buys the user's current amount rather than
    ///      failing the whole batch for everyone in it.
    function testBatchPurchaseSpendsTheScheduleAmountAfterAnEdit() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 editedAmount = AMOUNT_TO_SPEND / 2;

        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, editedAmount);

        uint256 balanceBefore = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;

        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batchOf(address(stablecoin), scheduleId, uint96(editedAmount), s_routeIndex));

        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance,
            balanceBefore - editedAmount,
            "the batch did not spend the schedule's own amount"
        );
    }

    function testBatchPurchaseFailsIfRouteIndexMismatch() external {
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
        dcaManager.batchBuyRbtc(batchOf(address(stablecoin), scheduleId, uint96(AMOUNT_TO_SPEND), s_routeIndex + 1));
    }

    /// @dev A batch carries a single array, so there are no two lengths left to disagree. What the
    ///      manager still refuses is a batch that names no rows at all.
    function testBatchPurchaseFailsIfTheBatchIsEmpty() external {
        bytes32[] memory emptyRows;
        vm.expectRevert(IDcaManager.DcaManager__EmptyBatchPurchaseArrays.selector);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(toBatch(emptyRows, address(stablecoin), s_routeIndex));
    }

    /// @dev R66: an id that belongs to no schedule is skipped, not reverted.
    function testPurchaseSkipsIfTheIdBelongsToNoSchedule() external {
        uint64 scheduleId = UNUSED_SCHEDULE_ID;

        vm.startPrank(USER);
        uint256 stablecoinBalanceBeforePurchase = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 rbtcBalanceBeforePurchase = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        vm.stopPrank();

        vm.expectEmit(true, true, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__PurchaseRowSkipped(
            address(stablecoin), scheduleId, IDcaManager.PurchaseRowSkipReason.InexistentSchedule
        );
        buyRbtcOne(scheduleId);

        vm.startPrank(USER);
        uint256 stablecoinBalanceAfterPurchase = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 rbtcBalanceAfterPurchase = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        vm.stopPrank();

        // Check that there are no changes in balances
        assertEq(stablecoinBalanceBeforePurchase - stablecoinBalanceAfterPurchase, 0);
        assertEq(rbtcBalanceAfterPurchase - rbtcBalanceBeforePurchase, 0);
    }

    /// @dev R66: every row in this batch names the same nonexistent id, so every row is skipped and
    ///      the call itself does not revert.
    function testBatchPurchaseSkipsIfAnIdBelongsToNoSchedule() external {
        super.createSeveralDcaSchedules();

        uint64 scheduleId = UNUSED_SCHEDULE_ID;

        uint256 prevStablecoinHandlerBalance = address(stablecoinHandler).balance;
        vm.prank(USER);
        uint256 userAccumulatedRbtcPrev = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        // Every row names the same id, and it belongs to no schedule
        bytes32[] memory rows = new bytes32[](NUM_OF_SCHEDULES);
        for (uint8 i; i < NUM_OF_SCHEDULES; ++i) {
            rows[i] = packBatchRow(scheduleId, 0);
        }
        vm.expectEmit(true, true, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__PurchaseRowSkipped(
            address(stablecoin), scheduleId, IDcaManager.PurchaseRowSkipReason.InexistentSchedule
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            toBatch(rows, address(stablecoin), s_routeIndex)
        );

        uint256 postStablecoinHandlerBalance = address(stablecoinHandler).balance;

        // The balance of the token handler contract gets incremented in exactly the purchased amount of rBTC
        assertEq(postStablecoinHandlerBalance - prevStablecoinHandlerBalance, 0);

        vm.prank(USER);
        uint256 userAccumulatedRbtcPost = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        // The user's balance is also equal (since we're batching the purchases of 5 schedules but only one user)
        assertEq(userAccumulatedRbtcPost - userAccumulatedRbtcPrev, 0);
    }

    function testOnlyUserCanWithdrawRbtc() external {
        vm.expectRevert();
        vm.prank(makeAddr("notUser"));
        IPurchaseRbtc(address(stablecoinHandler)).withdrawAccumulatedRbtc(USER);
    }

    // New test: exhaust handler balance across multiple users and schedules without revert
    // @notice: this test won't pass for Tropykus on forked chains because updating
    // the exchange rate requires to roll to a future block, which makes the MoC oracle
    // throw an "Oracle have no Bitcoin Price" error.
    function testDepleteHandlerBalanceDoesNotRevert() external onlyLendingLane {
        // Prepare a second user
        address SECOND_USER = makeAddr("SECOND_USER");

        // Fund SECOND_USER with rBTC for gas
        vm.deal(SECOND_USER, 10 ether);

        // Give SECOND_USER enough stablecoin
        uint256 secondUserInitialStable = USER_TOTAL_AMOUNT;
        if (block.chainid == ANVIL_CHAIN_ID) {
            // Local tests – mint directly
            stablecoin.mint(SECOND_USER, secondUserInitialStable);
        } else {
            // On forked chains we transfer from USER (who already owns tokens)
            vm.startPrank(USER);
            stablecoin.transfer(SECOND_USER, secondUserInitialStable);
            vm.stopPrank();
        }

        // Define how many schedules each user will have
        uint256 SCHEDULES_PER_USER = 3;

        // USER already has 1 schedule from setUp → create 2 more so both users end up with 3 each
        _createAdditionalSchedules(USER, SCHEDULES_PER_USER - 1);
        // Create 3 schedules for SECOND_USER
        _createAdditionalSchedules(SECOND_USER, SCHEDULES_PER_USER);

        // Total number of schedules in batch operations
        uint256 totalSchedules = SCHEDULES_PER_USER * 2;

        // Each schedule can execute AMOUNT_TO_DEPOSIT / AMOUNT_TO_SPEND purchases before running out of balance
        uint256 purchasesPerSchedule = AMOUNT_TO_DEPOSIT / AMOUNT_TO_SPEND;

        // Store initial interest accrued (should be 0 initially)
        uint256 initialInterestUser = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        uint256 initialInterestSecondUser = dcaManager.getInterestAccrued(SECOND_USER, address(stablecoin), s_routeIndex);
        
        // Both users should have 0 interest initially
        assertEq(initialInterestUser, 0, "USER should have 0 interest initially");
        assertEq(initialInterestSecondUser, 0, "SECOND_USER should have 0 interest initially");

        // Perform the required number of purchase rounds
        for (uint256 round; round < purchasesPerSchedule; ++round) {
            // Build the batch's only array: one packed row per schedule, all sharing AMOUNT_TO_SPEND
            bytes32[] memory rows = new bytes32[](totalSchedules);

            uint256 idx;
            for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
                rows[idx] = packBatchRow(scheduleIdAt(dcaManager, USER, address(stablecoin), i), uint96(AMOUNT_TO_SPEND));
                ++idx;
            }
            for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
                rows[idx] =
                    packBatchRow(scheduleIdAt(dcaManager, SECOND_USER, address(stablecoin), i), uint96(AMOUNT_TO_SPEND));
                ++idx;
            }

            // Execute batch purchase as SWAPPER
            vm.prank(SWAPPER);
            dcaManager.batchBuyRbtc(
                toBatch(rows, address(stablecoin), s_routeIndex)
            );

            // Advance time and update exchange rate so future purchases are allowed and interest accrues
            updateExchangeRate(MIN_PURCHASE_PERIOD);
        }

        // After time has passed and multiple purchase rounds, check that interest has accrued
        uint256 finalInterestUser = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        uint256 finalInterestSecondUser = dcaManager.getInterestAccrued(SECOND_USER, address(stablecoin), s_routeIndex);

        // Both users should have accrued some interest during the test
        assertGt(finalInterestUser, initialInterestUser, "USER should have accrued interest during the test");
        assertGt(finalInterestSecondUser, initialInterestSecondUser, "SECOND_USER should have accrued interest during the test");

        // The interest should be positive (greater than 0) since time has passed
        assertGt(finalInterestUser, 0, "USER should have positive interest after time passage");
        assertGt(finalInterestSecondUser, 0, "SECOND_USER should have positive interest after time passage");

        // After depletion all schedule balances should be zero
        for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
            assertEq(scheduleAt(dcaManager, USER, address(stablecoin), i).tokenBalance, 0);
            assertEq(scheduleAt(dcaManager, SECOND_USER, address(stablecoin), i).tokenBalance, 0);
        }

        // Handler must hold no stablecoin after final purchase
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), 0);

        // Withdrawing interest should not revert
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);

        // Withdrawing interest should not revert
        vm.prank(SECOND_USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);
    }

    /// @dev Similar to testDepleteHandlerBalanceDoesNotRevert but drives one length-1 batch per schedule
    ///      instead of a single batch covering every schedule.
    function testDepleteHandlerBalanceDoesNotRevertOneScheduleAtATime() external onlyLendingLane {
        // Prepare a second user
        address SECOND_USER = makeAddr("SECOND_USER");

        // Fund SECOND_USER with rBTC for gas
        vm.deal(SECOND_USER, 10 ether);

        // Give SECOND_USER enough stablecoin
        uint256 secondUserInitialStable = USER_TOTAL_AMOUNT;
        if (block.chainid == ANVIL_CHAIN_ID) {
            // Local tests – mint directly
            stablecoin.mint(SECOND_USER, secondUserInitialStable);
        } else {
            // On forked chains we transfer from USER (who already owns tokens)
            vm.startPrank(USER);
            stablecoin.transfer(SECOND_USER, secondUserInitialStable);
            vm.stopPrank();
        }

        // Define how many schedules each user will have
        uint256 SCHEDULES_PER_USER = 3;

        // USER already has 1 schedule from setUp → create 2 more so both users end up with 3 each
        _createAdditionalSchedules(USER, SCHEDULES_PER_USER - 1);
        // Create 3 schedules for SECOND_USER
        _createAdditionalSchedules(SECOND_USER, SCHEDULES_PER_USER);

        // Each schedule can execute AMOUNT_TO_DEPOSIT / AMOUNT_TO_SPEND purchases before running out of balance
        uint256 purchasesPerSchedule = AMOUNT_TO_DEPOSIT / AMOUNT_TO_SPEND;

        // Store initial interest accrued (should be 0 initially)
        uint256 initialInterestUser = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        uint256 initialInterestSecondUser = dcaManager.getInterestAccrued(SECOND_USER, address(stablecoin), s_routeIndex);
        
        // Both users should have 0 interest initially
        assertEq(initialInterestUser, 0, "USER should have 0 interest initially");
        assertEq(initialInterestSecondUser, 0, "SECOND_USER should have 0 interest initially");

        // Perform the required number of purchase rounds
        for (uint256 round; round < purchasesPerSchedule; ++round) {
            // Execute individual purchases for USER's schedules
            for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
                uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), i);
                buyRbtcOne(scheduleId);
            }

            // Execute individual purchases for SECOND_USER's schedules
            for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
                uint64 scheduleId = scheduleIdAt(dcaManager, SECOND_USER, address(stablecoin), i);
                buyRbtcOne(scheduleId);
            }

            // Advance time and update exchange rate so future purchases are allowed and interest accrues
            updateExchangeRate(MIN_PURCHASE_PERIOD);
        }

        // After time has passed and multiple purchase rounds, check that interest has accrued
        uint256 finalInterestUser = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        uint256 finalInterestSecondUser = dcaManager.getInterestAccrued(SECOND_USER, address(stablecoin), s_routeIndex);
        
        // Both users should have accrued some interest during the test
        assertGt(finalInterestUser, initialInterestUser, "USER should have accrued interest during the test");
        assertGt(finalInterestSecondUser, initialInterestSecondUser, "SECOND_USER should have accrued interest during the test");
        
        // The interest should be positive (greater than 0) since time has passed
        assertGt(finalInterestUser, 0, "USER should have positive interest after time passage");
        assertGt(finalInterestSecondUser, 0, "SECOND_USER should have positive interest after time passage");

        // After depletion all schedule balances should be zero
        for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
            assertEq(scheduleAt(dcaManager, USER, address(stablecoin), i).tokenBalance, 0);
            assertEq(scheduleAt(dcaManager, SECOND_USER, address(stablecoin), i).tokenBalance, 0);
        }

        // Handler must hold no stablecoin after final purchase
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), 0);

        // Withdrawing interest should not revert
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);

        // Withdrawing interest should not revert
        vm.prank(SECOND_USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);
    }

    // New test: exhaust handler balance across multiple users and schedules with interest withdrawals in between batch purchases without revert
    // @notice: this test won't pass for Tropykus on forked chains because updating
    // the exchange rate requires to roll to a future block, which makes the MoC oracle
    // throw an "Oracle have no Bitcoin Price" error.
    function testDepleteHandlerBalanceWithInterestWithdrawalsDoesNotRevert() external onlyLendingLane {
        // Prepare a second user
        address SECOND_USER = makeAddr("SECOND_USER");

        // Fund SECOND_USER with rBTC for gas
        vm.deal(SECOND_USER, 10 ether);

        // Give SECOND_USER enough stablecoin
        uint256 secondUserInitialStable = USER_TOTAL_AMOUNT;
        if (block.chainid == ANVIL_CHAIN_ID) {
            // Local tests – mint directly
            stablecoin.mint(SECOND_USER, secondUserInitialStable);
        } else {
            // On forked chains we transfer from USER (who already owns tokens)
            vm.startPrank(USER);
            stablecoin.transfer(SECOND_USER, secondUserInitialStable);
            vm.stopPrank();
        }

        // Define how many schedules each user will have
        uint256 SCHEDULES_PER_USER = 3;

        // USER already has 1 schedule from setUp → create 2 more so both users end up with 3 each
        _createAdditionalSchedules(USER, SCHEDULES_PER_USER - 1);
        // Create 3 schedules for SECOND_USER
        _createAdditionalSchedules(SECOND_USER, SCHEDULES_PER_USER);

        // Total number of schedules in batch operations
        uint256 totalSchedules = SCHEDULES_PER_USER * 2;

        // Each schedule can execute AMOUNT_TO_DEPOSIT / AMOUNT_TO_SPEND purchases before running out of balance
        uint256 purchasesPerSchedule = AMOUNT_TO_DEPOSIT / AMOUNT_TO_SPEND;

        // Store initial interest accrued (should be 0 initially)
        uint256 initialInterestUser = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        uint256 initialInterestSecondUser = dcaManager.getInterestAccrued(SECOND_USER, address(stablecoin), s_routeIndex);
        
        // Both users should have 0 interest initially
        assertEq(initialInterestUser, 0, "USER should have 0 interest initially");
        assertEq(initialInterestSecondUser, 0, "SECOND_USER should have 0 interest initially");

        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;

        // Perform the required number of purchase rounds
        for (uint256 round; round < purchasesPerSchedule; ++round) {
            // Build the batch's only array: one packed row per schedule, all sharing AMOUNT_TO_SPEND
            bytes32[] memory rows = new bytes32[](totalSchedules);

            uint256 idx;
            for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
                rows[idx] = packBatchRow(scheduleIdAt(dcaManager, USER, address(stablecoin), i), uint96(AMOUNT_TO_SPEND));
                ++idx;
            }
            for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
                rows[idx] =
                    packBatchRow(scheduleIdAt(dcaManager, SECOND_USER, address(stablecoin), i), uint96(AMOUNT_TO_SPEND));
                ++idx;
            }

            // Execute batch purchase as SWAPPER
            vm.prank(SWAPPER);
            dcaManager.batchBuyRbtc(
                toBatch(rows, address(stablecoin), s_routeIndex)
            );

            // Withdrawing interest should not revert
            vm.prank(USER);
            dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);
            // Withdrawing interest should not revert
            vm.prank(SECOND_USER);
            dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);

            // Advance time and update exchange rate so future purchases are allowed and interest accrues
            updateExchangeRate(MIN_PURCHASE_PERIOD);
        }

        // After time has passed and multiple purchase rounds, check that interest has accrued
        uint256 finalInterestUser = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        uint256 finalInterestSecondUser = dcaManager.getInterestAccrued(SECOND_USER, address(stablecoin), s_routeIndex);
        
        // Both users should have accrued some interest during the test
        assertEq(finalInterestUser, 0, "USER should have already withdrawn all interest");
        assertEq(finalInterestSecondUser, 0, "SECOND_USER should have already withdrawn all interest");
        
        // After depletion all schedule balances should be zero
        for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
            assertEq(scheduleAt(dcaManager, USER, address(stablecoin), i).tokenBalance, 0);
            assertEq(scheduleAt(dcaManager, SECOND_USER, address(stablecoin), i).tokenBalance, 0);
        }

        // Handler must hold no stablecoin after final purchase except for some dust due to precision loss
        assertLt(stablecoin.balanceOf(address(stablecoinHandler)), 100); // Allow 100 wei of dust due to precision loss
    }

    /// @dev helper to create additional schedules for a user
    function _createAdditionalSchedules(address user, uint256 num) internal {
        if (num == 0) return;
        vm.startPrank(user);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT * num);
        for (uint256 i; i < num; ++i) {
            dcaManager.createDcaSchedule(
                address(stablecoin),
                AMOUNT_TO_DEPOSIT,
                AMOUNT_TO_SPEND,
                MIN_PURCHASE_PERIOD,
                s_routeIndex
            );
        }
        vm.stopPrank();
    }

    function _utcDayStart(uint256 timestamp) private pure returns (uint256) {
        return timestamp - (timestamp % 1 days);
    }

    function _nextUtcTimestamp(uint256 hourOfDay) private view returns (uint256) {
        uint256 candidate = _utcDayStart(block.timestamp) + hourOfDay;
        if (candidate < block.timestamp) {
            candidate += 1 days;
        }
        return candidate;
    }

}
