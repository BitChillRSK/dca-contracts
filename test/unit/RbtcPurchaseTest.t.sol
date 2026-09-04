//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
// import {RbtcBaseTest} from "./RbtcBaseTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {IDcaManagerAccessControl} from "../../src/interfaces/IDcaManagerAccessControl.sol";
import {batchBuyOne, handlerBatchBuyOne, UNUSED_SCHEDULE_ID, toBatch} from "../utils/BatchBuyOne.sol";
import "../Constants.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

contract RbtcPurchaseTest is DcaDappTest {

    struct BatchPurchase {
        address[] buyers;
        uint256[] scheduleIndexes;
        uint64[] scheduleIds;
        uint256[] purchaseAmounts;
    }

    function setUp() public override {
        super.setUp();
    }

    //////////////////////
    /// Purchase tests ///
    //////////////////////
    function testSinglePurchase() external {
        super.makeSinglePurchase();
    }

    function testCannotBuyIfInexistentSchedule() external {
        uint64 wrongScheduleId = UNUSED_SCHEDULE_ID;
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, USER, wrongScheduleId));
        buyRbtcOne(USER, wrongScheduleId);
    }

    /// @dev A row is one id, so the batch's token is what ties it to a handler. A schedule holding
    ///      another stablecoin must not be debited by the handler this batch names.
    function testCannotBuyIfScheduleHoldsAnotherToken() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        address otherToken = makeAddr("someOtherStablecoin");
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__ScheduleTokenMismatch.selector, USER, scheduleId, otherToken, address(stablecoin)
            )
        );
        vm.prank(SWAPPER);
        batchBuyOne(dcaManager, USER, otherToken, scheduleId, s_routeIndex);
    }

    function testCannotBuyIfPeriodNotElapsed() external {
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        dcaManager.updatePurchaseAmount(scheduleId, AMOUNT_TO_SPEND);
        dcaManager.updatePurchasePeriod(scheduleId, MIN_PURCHASE_PERIOD);
        vm.stopPrank();
        buyRbtcOne(USER, scheduleId); // first purchase
        IDcaManager.DcaSchedule memory schedule = dcaManager.getDcaSchedules(USER, address(stablecoin))[SCHEDULE_INDEX];
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed.selector,
            _secondsUntilDueUtcDayStart(schedule.lastPurchaseTimestamp, schedule.purchasePeriod)
        );
        vm.expectRevert(encodedRevert);
        buyRbtcOne(USER, scheduleId); // second purchase
    }

    function testBuyAllowedAtUtcDayStartOfDueDay() external {
        uint256 firstBuy = _nextUtcTimestamp(20 hours);
        vm.warp(firstBuy);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        buyRbtcOne(USER, scheduleId);

        uint256 dueDayStart = _utcDayStart(firstBuy) + 1 days; // still 20 hours before last + period
        vm.warp(dueDayStart);
        buyRbtcOne(USER, scheduleId);

        IDcaManager.DcaSchedule memory schedule = dcaManager.getDcaSchedules(USER, address(stablecoin))[SCHEDULE_INDEX];
        assertEq(schedule.lastPurchaseTimestamp, firstBuy + MIN_PURCHASE_PERIOD);
    }

    function testCannotBuyOneSecondBeforeDueUtcDay() external {
        uint256 firstBuy = _nextUtcTimestamp(20 hours);
        vm.warp(firstBuy);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        buyRbtcOne(USER, scheduleId);

        uint256 dueDayStart = _utcDayStart(firstBuy) + 1 days;
        vm.warp(dueDayStart - 1);
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed.selector,
            uint256(1)
        );
        vm.expectRevert(encodedRevert);
        buyRbtcOne(USER, scheduleId);
    }

    function testUtcDayEarlyBuyConsumesOnePeriodAndBlocksSameDaySecondBuy() external {
        uint256 firstBuy = _nextUtcTimestamp(20 hours);
        vm.warp(firstBuy);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        buyRbtcOne(USER, scheduleId);

        uint256 dueDayStart = _utcDayStart(firstBuy) + 1 days;
        vm.warp(dueDayStart); // 00:00 UTC of the due day, before last + period wall-clock
        buyRbtcOne(USER, scheduleId);

        IDcaManager.DcaSchedule memory schedule = dcaManager.getDcaSchedules(USER, address(stablecoin))[SCHEDULE_INDEX];
        assertEq(schedule.lastPurchaseTimestamp, firstBuy + MIN_PURCHASE_PERIOD);

        vm.warp(dueDayStart + 9 hours); // still the due UTC day
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__CannotBuyIfPurchasePeriodHasNotElapsed.selector,
            _secondsUntilDueUtcDayStart(schedule.lastPurchaseTimestamp, schedule.purchasePeriod)
        );
        vm.expectRevert(encodedRevert);
        buyRbtcOne(USER, scheduleId);
    }

    function testWeeklyBuyAllowedOnDueUtcDay() external {
        uint256 weeklyPeriod = 7 days;
        uint256 firstBuy = _nextUtcTimestamp(20 hours);
        vm.warp(firstBuy);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.prank(USER);
        dcaManager.updatePurchasePeriod(scheduleId, weeklyPeriod);
        buyRbtcOne(USER, scheduleId);

        uint256 dueDayStart = _utcDayStart(firstBuy) + weeklyPeriod;
        vm.warp(dueDayStart); // due UTC day 00:00, 20 hours before last + period
        buyRbtcOne(USER, scheduleId);

        IDcaManager.DcaSchedule memory schedule = dcaManager.getDcaSchedules(USER, address(stablecoin))[SCHEDULE_INDEX];
        assertEq(schedule.lastPurchaseTimestamp, firstBuy + weeklyPeriod);
    }

    function testSeveralPurchasesOneSchedule() external {
        uint256 numOfPurchases = 5;

        uint256 fee = feeCalculator.calculateFee(AMOUNT_TO_SPEND);
        uint256 netPurchaseAmount = AMOUNT_TO_SPEND - fee;

        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.prank(USER);
        dcaManager.updatePurchasePeriod(scheduleId, MIN_PURCHASE_PERIOD);
        for (uint256 i; i < numOfPurchases; ++i) {
            buyRbtcOne(USER, scheduleId);
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
        buyRbtcOne(USER, scheduleId);

        // Imagine after the first purchase, the schedule runs out of stablecoin and is resumed later
        vm.warp(vm.getBlockTimestamp() + timeUntilResume);

        buyRbtcOne(USER, scheduleId);

        IDcaManager.DcaSchedule memory schedule = dcaManager.getDcaSchedules(USER, address(stablecoin))[SCHEDULE_INDEX];
        assertLe(schedule.lastPurchaseTimestamp, block.timestamp);
        assertGt(schedule.lastPurchaseTimestamp, block.timestamp - MIN_PURCHASE_PERIOD);
        uint256 firstPurchaseTimestamp = s_firstPurchaseTimestampForResumeTest;
        uint256 periodsElapsed = (block.timestamp - firstPurchaseTimestamp) / MIN_PURCHASE_PERIOD;
        assertEq(schedule.lastPurchaseTimestamp, firstPurchaseTimestamp + periodsElapsed * MIN_PURCHASE_PERIOD);
    }

    /**
     * @notice the DcaManager balance guard fires once a schedule has nothing left to spend.
     * @dev The batch path debits each buyer's shares rounded **up** (`_batchRetrieveStablecoin`) and
     *      reverts on a shortfall, where the removed single path clamped to the shares held. On a
     *      live lending fork with a static exchange rate that round-up costs ~1 wei of shares per
     *      purchase, so draining the very last purchase through the batch can revert on shares
     *      before the schedule balance reaches zero. Withdraw the tail instead of spending it, so
     *      this test asserts the DcaManager guard it is named for on every lane.
     */
    function testRevertPurchasetIfStablecoinRunsOut() external {
        uint256 numOfPurchases = AMOUNT_TO_DEPOSIT / AMOUNT_TO_SPEND;
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        for (uint256 i; i < numOfPurchases - 1; ++i) {
            buyRbtcOne(USER, scheduleId);
            vm.warp(vm.getBlockTimestamp() + MIN_PURCHASE_PERIOD);
        }

        // Empty the schedule without spending the tail, so its balance is exactly zero
        uint256 remaining = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        vm.prank(USER);
        dcaManager.withdrawToken(scheduleId, remaining);
        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance, 0);

        // Attempt to purchase once more
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__ScheduleBalanceNotEnoughForPurchase.selector, USER, scheduleId, address(stablecoin), 0
        );
        vm.expectRevert(encodedRevert);
        buyRbtcOne(USER, scheduleId);
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
        batchBuyOne(dcaManager, USER, address(stablecoin), scheduleId, s_routeIndex);
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
        address[] memory emptyBuyerArray;
        uint64[] memory emptyScheduleIdArray;
        vm.expectRevert(IDcaManager.DcaManager__EmptyBatchPurchaseArrays.selector);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            toBatch(emptyScheduleIdArray, emptyBuyerArray, address(stablecoin), s_routeIndex)
        );
    }

    /// @dev R64 dropped the per-row amount from `Batch`: the manager spends what the schedule holds,
    ///      so a swapper working from a stale snapshot buys the user's current amount rather than
    ///      failing the whole batch for everyone in it.
    function testBatchPurchaseSpendsTheScheduleAmountAfterAnEdit() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 editedAmount = AMOUNT_TO_SPEND / 2;

        vm.prank(USER);
        dcaManager.updatePurchaseAmount(scheduleId, editedAmount);

        uint256 balanceBefore = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;

        vm.prank(SWAPPER);
        batchBuyOne(dcaManager, USER, address(stablecoin), scheduleId, s_routeIndex);

        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance,
            balanceBefore - editedAmount,
            "the batch did not spend the schedule's own amount"
        );
    }

    function testBatchPurchaseFailsIfRouteIndexMismatch() external {
        address[] memory users = new address[](1);
        users[0] = USER;
        uint256[] memory scheduleIndexes = new uint256[](1);
        scheduleIndexes[0] = SCHEDULE_INDEX;
        uint64[] memory scheduleIds = new uint64[](1);
        scheduleIds[0] = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        uint256[] memory purchaseAmounts = new uint256[](1);
        purchaseAmounts[0] = AMOUNT_TO_SPEND;
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__RouteIndexMismatch.selector,
                USER,
                address(stablecoin),
                scheduleIds[0],
                s_routeIndex,
                s_routeIndex + 1
            )
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(toBatch(scheduleIds, users, address(stablecoin), s_routeIndex + 1));
    }

    function testBatchPurchaseFailsIfArraysHaveDifferentLenghts() external {
        address[] memory dummyBuyerArray = new address[](2);
        uint64[] memory dummyScheduleIdArray = new uint64[](3);
        vm.expectRevert(IDcaManager.DcaManager__ArraysLengthMismatch.selector);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            toBatch(dummyScheduleIdArray, dummyBuyerArray, address(stablecoin), s_routeIndex)
        );
    }

    function testPurchaseFailsIfTheIdBelongsToNoSchedule() external {
        uint64 scheduleId = UNUSED_SCHEDULE_ID;

        vm.startPrank(USER);
        uint256 stablecoinBalanceBeforePurchase = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 rbtcBalanceBeforePurchase = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, USER, scheduleId));
        buyRbtcOne(USER, scheduleId);

        vm.startPrank(USER);
        uint256 stablecoinBalanceAfterPurchase = scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 rbtcBalanceAfterPurchase = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        vm.stopPrank();

        // Check that there are no changes in balances
        assertEq(stablecoinBalanceBeforePurchase - stablecoinBalanceAfterPurchase, 0);
        assertEq(rbtcBalanceAfterPurchase - rbtcBalanceBeforePurchase, 0);
    }

    function testBatchPurchaseFailsIfAnIdBelongsToNoSchedule() external {
        super.createSeveralDcaSchedules();

        uint64 scheduleId = UNUSED_SCHEDULE_ID;

        uint256 prevStablecoinHandlerBalance = address(stablecoinHandler).balance;
        vm.prank(USER);
        uint256 userAccumulatedRbtcPrev = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        address[] memory users = new address[](NUM_OF_SCHEDULES);
        uint256[] memory scheduleIndexes = new uint256[](NUM_OF_SCHEDULES);
        uint256[] memory purchaseAmounts = new uint256[](NUM_OF_SCHEDULES);
        uint256[] memory purchasePeriods = new uint256[](NUM_OF_SCHEDULES);
        uint64[] memory scheduleIds = new uint64[](NUM_OF_SCHEDULES);

        uint256 totalNetPurchaseAmount;

        // Create the arrays for the batch purchase (in production, this is done in the back end)
        for (uint8 i; i < NUM_OF_SCHEDULES; ++i) {
            uint256 scheduleIndex = i;
            vm.startPrank(USER);
            uint256 schedulePurchaseAmount = scheduleAt(dcaManager, USER, address(stablecoin), scheduleIndex).purchaseAmount;
            vm.stopPrank();
            uint256 fee = feeCalculator.calculateFee(schedulePurchaseAmount);
            totalNetPurchaseAmount += schedulePurchaseAmount - fee;

            users[i] = USER; // Same user for has 5 schedules due for a purchase in this scenario
            scheduleIndexes[i] = i;
            vm.startPrank(OWNER);
            purchaseAmounts[i] = dcaManager.getDcaSchedules(users[0], address(stablecoin))[i].purchaseAmount;
            purchasePeriods[i] = dcaManager.getDcaSchedules(users[0], address(stablecoin))[i].purchasePeriod;
            scheduleIds[i] = scheduleId;
            vm.stopPrank();
        }
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, USER, scheduleId));
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            toBatch(scheduleIds, users, address(stablecoin), s_routeIndex)
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
            // Build batch arrays in auxiliary struct
            BatchPurchase memory batchPurchase = BatchPurchase({
                buyers: new address[](totalSchedules),
                scheduleIndexes: new uint256[](totalSchedules),
                scheduleIds: new uint64[](totalSchedules),
                purchaseAmounts: new uint256[](totalSchedules)
            });

            uint256 idx;
            // Fill arrays for USER
            for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
                batchPurchase.buyers[idx] = USER;
                batchPurchase.scheduleIndexes[idx] = i;
                batchPurchase.purchaseAmounts[idx] = AMOUNT_TO_SPEND;
                batchPurchase.scheduleIds[idx] = scheduleIdAt(dcaManager, USER, address(stablecoin), i);
                ++idx;
            }
            // Fill arrays for SECOND_USER
            for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
                batchPurchase.buyers[idx] = SECOND_USER;
                batchPurchase.scheduleIndexes[idx] = i;
                batchPurchase.purchaseAmounts[idx] = AMOUNT_TO_SPEND;
                batchPurchase.scheduleIds[idx] = scheduleIdAt(dcaManager, SECOND_USER, address(stablecoin), i);
                ++idx;
            }

            // Execute batch purchase as SWAPPER
            vm.prank(SWAPPER);
            dcaManager.batchBuyRbtc(
                toBatch(batchPurchase.scheduleIds, batchPurchase.buyers, address(stablecoin), s_routeIndex)
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
                buyRbtcOne(USER, scheduleId);
            }

            // Execute individual purchases for SECOND_USER's schedules
            for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
                uint64 scheduleId = scheduleIdAt(dcaManager, SECOND_USER, address(stablecoin), i);
                buyRbtcOne(SECOND_USER, scheduleId);
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
            // Build batch arrays in auxiliary struct
            BatchPurchase memory batchPurchase = BatchPurchase({
                buyers: new address[](totalSchedules),
                scheduleIndexes: new uint256[](totalSchedules),
                scheduleIds: new uint64[](totalSchedules),
                purchaseAmounts: new uint256[](totalSchedules)
            });

            uint256 idx;
            // Fill arrays for USER
            for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
                batchPurchase.buyers[idx] = USER;
                batchPurchase.scheduleIndexes[idx] = i;
                batchPurchase.purchaseAmounts[idx] = AMOUNT_TO_SPEND;
                batchPurchase.scheduleIds[idx] = scheduleIdAt(dcaManager, USER, address(stablecoin), i);
                ++idx;
            }
            // Fill arrays for SECOND_USER
            for (uint256 i; i < SCHEDULES_PER_USER; ++i) {
                batchPurchase.buyers[idx] = SECOND_USER;
                batchPurchase.scheduleIndexes[idx] = i;
                batchPurchase.purchaseAmounts[idx] = AMOUNT_TO_SPEND;
                batchPurchase.scheduleIds[idx] = scheduleIdAt(dcaManager, SECOND_USER, address(stablecoin), i);
                ++idx;
            }

            // Execute batch purchase as SWAPPER
            vm.prank(SWAPPER);
            dcaManager.batchBuyRbtc(
                toBatch(batchPurchase.scheduleIds, batchPurchase.buyers, address(stablecoin), s_routeIndex)
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

    function _secondsUntilDueUtcDayStart(uint256 lastPurchaseTimestamp, uint256 purchasePeriod)
        private
        view
        returns (uint256)
    {
        uint256 nextDueTimestamp = lastPurchaseTimestamp + purchasePeriod;
        uint256 nextPurchaseDayStart = _utcDayStart(nextDueTimestamp);
        return nextPurchaseDayStart - block.timestamp;
    }
}
