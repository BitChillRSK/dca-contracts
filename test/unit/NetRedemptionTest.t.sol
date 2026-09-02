//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {Vm} from "forge-std/Test.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {MockIsusdToken} from "../mocks/MockIsusdToken.sol";
import {toBatch} from "../utils/BatchBuyOne.sol";
import "../../script/Constants.sol";

/**
 * @title NetRedemptionTest
 * @notice R1 / R20. Sovryn's burn() returns the GROSS amount and pays the NET one once the SIP-0094
 * Perimeter Fee is enabled, so every path that trusted the return value asked for DOC the handler did not
 * hold and reverted. These tests run the mock with that fee switched on and assert BitChill moves, credits,
 * and deducts the amount it actually received — and that with the fee off nothing is haircut.
 * @dev Sovryn + MoC + local mocks only: the exit fee is a mock switch, and the rBTC solvency check reads the
 * handler's native balance.
 */
contract NetRedemptionTest is DcaDappTest {
    uint256 constant EXIT_FEE_BPS = 10; // the 0.10% Sovryn approved
    /// @dev not SIP-0094: a lending protocol withholding almost the whole redemption (rug / insolvency)
    uint256 constant RUG_EXIT_FEE_BPS = 9950;
    uint256 constant BPS_DIVISOR = 10_000;
    uint256 constant WITHDRAWAL_AMOUNT = AMOUNT_TO_DEPOSIT / 2;
    uint256 constant ROUNDING_TOLERANCE = 1e6; // the share conversion rounds up, so payouts can exceed the request by dust

    function setUp() public override {
        super.setUp();
    }

    /**
     * @notice these assertions only mean something against the Sovryn mock on a local chain
     */
    modifier onlySovrynMocMocks() {
        if (s_routeIndex != SOVRYN_INDEX || !isMocSwaps || block.chainid != ANVIL_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            EXIT FEE ENABLED
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The single-purchase break: the handler received net DOC and used to spend the gross return.
     */
    function test_sovryn_singleScheduleBatchSpendsTheNetRedeemedAmount() public onlySovrynMocMocks {
        _enableExitFee();

        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        uint256 rbtcBefore = _accumulatedRbtc();

        buyRbtcOne(USER, SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND);

        uint256 rbtcBought = _accumulatedRbtc() - rbtcBefore;
        uint256 netRedeemed = _afterExitFee(AMOUNT_TO_SPEND);
        uint256 expected = (netRedeemed - feeCalculator.calculateFee(netRedeemed)) / s_btcPrice;

        assertApproxEqRel(rbtcBought, expected, _maxPurchaseSlippage());
        // the exit fee is a haircut on the purchase, not a free lunch: strictly less rBTC than a fee-free redeem
        assertLt(rbtcBought, (AMOUNT_TO_SPEND - feeCalculator.calculateFee(AMOUNT_TO_SPEND)) / s_btcPrice);
    }

    /**
     * @notice A batch must never distribute more rBTC than the purchase actually produced. The per-user
     * weights are shares of the planned net total, so they still sum to one when the redeem pays less.
     */
    function test_sovryn_batchBuyRbtcCreditsNoMoreRbtcThanReceived() public onlySovrynMocMocks {
        createSeveralDcaSchedules();
        _enableExitFee();

        (
            address[] memory users,
            uint256[] memory scheduleIndexes,
            uint64[] memory scheduleIds,
            uint256[] memory purchaseAmounts
        ) = _batchArrays();

        uint256 handlerRbtcBefore = address(stablecoinHandler).balance;
        uint256 creditedBefore = _accumulatedRbtc();

        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            toBatch(users, address(stablecoin), scheduleIndexes, scheduleIds, purchaseAmounts, s_routeIndex)
        );

        uint256 received = address(stablecoinHandler).balance - handlerRbtcBefore;
        uint256 credited = _accumulatedRbtc() - creditedBefore;

        assertGt(credited, 0);
        assertLe(credited, received, "credited more rBTC than the handler received");
    }

    /**
     * @notice The user is paid the net amount, but the schedule is debited the amount requested. The exit fee
     * consumes principal: the iTokens for the full request were burned and the difference went to Sovryn's
     * vault. Crediting it back would invent principal the handler does not hold, and that dust would later
     * revert in `burn`. Purchases already work this way — the schedule pays the full purchaseAmount.
     */
    function test_sovryn_withdrawTokenDebitsTheRequestedAmount() public onlySovrynMocMocks {
        _enableExitFee();

        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        uint256 scheduleBalanceBefore = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 userDocBefore = stablecoin.balanceOf(USER);

        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, WITHDRAWAL_AMOUNT);

        uint256 paid = stablecoin.balanceOf(USER) - userDocBefore;
        uint256 deducted =
            scheduleBalanceBefore - dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;

        assertLt(paid, WITHDRAWAL_AMOUNT, "the exit fee should have produced a shortfall");
        assertApproxEqAbs(paid, _afterExitFee(WITHDRAWAL_AMOUNT), ROUNDING_TOLERANCE);
        assertEq(deducted, WITHDRAWAL_AMOUNT, "the schedule must be debited what was requested");
    }

    /**
     * @notice What is left on the schedule is exactly what was not requested — the fee does not linger as
     * phantom principal — and that remainder is still withdrawable.
     */
    function test_sovryn_remainderIsWhatWasNotRequestedAndStaysWithdrawable() public onlySovrynMocMocks {
        _enableExitFee();

        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, WITHDRAWAL_AMOUNT);

        uint256 remaining = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        assertEq(remaining, AMOUNT_TO_DEPOSIT - WITHDRAWAL_AMOUNT, "the fee must not be credited back");

        uint256 userDocBefore = stablecoin.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, remaining);
        assertGt(stablecoin.balanceOf(USER) - userDocBefore, 0, "remainder was not claimable");
        assertEq(dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance, 0);
    }

    /**
     * @notice The schedule is gone by the time the handler pays, so the event must at least stop overstating.
     */
    function test_sovryn_deleteDcaScheduleReportsTheAmountActuallyPaid() public onlySovrynMocMocks {
        _enableExitFee();

        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        uint256 userDocBefore = stablecoin.balanceOf(USER);

        vm.recordLogs();
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), SCHEDULE_INDEX, scheduleId);

        uint256 paid = stablecoin.balanceOf(USER) - userDocBefore;
        assertLt(paid, AMOUNT_TO_DEPOSIT, "the exit fee should have produced a shortfall");
        assertEq(_deletedEventAmount(), paid, "the event overstates what the user was paid");
    }

    /**
     * @notice Interest redeems onto the handler then transfers; the event must report the net the user received.
     */
    function test_sovryn_withdrawInterestPaysAndReportsNet() public onlySovrynMocMocks {
        vm.warp(block.timestamp + 365 days); // the mock's exchange rate grows 5% a year
        _enableExitFee();

        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;

        uint256 userDocBefore = stablecoin.balanceOf(USER);

        vm.recordLogs();
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);

        uint256 paid = stablecoin.balanceOf(USER) - userDocBefore;
        assertGt(paid, 0, "no interest was paid");
        assertEq(_interestWithdrawnEventAmount(), paid, "the event overstates the interest paid");
    }

    /**
     * @notice Per-user events must add up to the batch event. After a short redemption the batch reports the
     * smaller actual spend, so reporting each buyer's *planned* net amount would make the per-user totals
     * exceed the cash that moved. The planned amounts are allocation weights, not amounts spent.
     */
    function test_sovryn_batchBuyRbtcEventsReportActualSpending() public onlySovrynMocMocks {
        createSeveralDcaSchedules();
        _enableExitFee();

        (
            address[] memory users,
            uint256[] memory scheduleIndexes,
            uint64[] memory scheduleIds,
            uint256[] memory purchaseAmounts
        ) = _batchArrays();

        uint256 plannedNetTotal;
        for (uint256 i; i < purchaseAmounts.length; ++i) {
            plannedNetTotal += purchaseAmounts[i] - feeCalculator.calculateFee(purchaseAmounts[i]);
        }

        vm.recordLogs();
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            toBatch(users, address(stablecoin), scheduleIndexes, scheduleIds, purchaseAmounts, s_routeIndex)
        );

        (uint256 perUserSpentTotal, uint256 batchSpent) = _batchSpendFromLogs();

        assertLt(batchSpent, plannedNetTotal, "the exit fee should have shortened the spend");
        assertLe(perUserSpentTotal, batchSpent, "per-user events report more spending than the batch did");
        // and they are not silently zeroed either: rounding may drop a wei per buyer, nothing more
        assertApproxEqAbs(perUserSpentTotal, batchSpent, NUM_OF_SCHEDULES);
    }

    /**
     * @notice The guard for a redemption that cannot even cover BitChill's own fee.
     * @dev This is deliberately not a SIP-0094 scenario. The Perimeter Fee is 10 bps against a BitChill fee
     * of ~100-200 bps, so a batch always redeems roughly a hundred times what it owes in fees and
     * `PurchaseRbtc__StablecoinRetrievedBelowFee` is unreachable in production. It fires only if a lending
     * protocol withholds almost the entire redemption — a rug or an insolvent pool — which is what the
     * ~99% fee below simulates. The point is that BitChill reverts cleanly instead of underflowing.
     */
    function test_sovryn_batchBuyRbtcRevertsWhenRedeemCannotCoverTheFee() public onlySovrynMocMocks {
        createSeveralDcaSchedules();

        // Purchases here are AMOUNT_TO_SPEND / NUM_OF_SCHEDULES = 40 DOC, below FEE_PURCHASE_LOWER_BOUND, so
        // they pay the max rate (200 bps locally): 4 DOC of fees on a 200 DOC batch. Withholding 99.5%
        // leaves 1 DOC redeemed, which is below the fee but still above zero — a zero payout would revert
        // earlier with TokenLending__ZeroStablecoinReceived, which is a different failure.
        MockIsusdToken(address(shareToken)).setExitFeeBps(RUG_EXIT_FEE_BPS);

        (
            address[] memory users,
            uint256[] memory scheduleIndexes,
            uint64[] memory scheduleIds,
            uint256[] memory purchaseAmounts
        ) = _batchArrays();

        uint256 aggregatedFee;
        uint256 totalPurchase;
        for (uint256 i; i < purchaseAmounts.length; ++i) {
            aggregatedFee += feeCalculator.calculateFee(purchaseAmounts[i]);
            totalPurchase += purchaseAmounts[i];
        }
        uint256 expectedRedeemed = totalPurchase * (BPS_DIVISOR - RUG_EXIT_FEE_BPS) / BPS_DIVISOR;
        // the two conditions the guard exists for, spelled out
        assertGt(expectedRedeemed, 0, "a zero payout is a different error");
        assertLe(expectedRedeemed, aggregatedFee, "the redeem must fall short of the fee for this to fire");

        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseRbtc.PurchaseRbtc__StablecoinRetrievedBelowFee.selector, expectedRedeemed, aggregatedFee
            )
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            toBatch(users, address(stablecoin), scheduleIndexes, scheduleIds, purchaseAmounts, s_routeIndex)
        );
    }

    /*//////////////////////////////////////////////////////////////
                           EXIT FEE DISABLED
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pre-activation, and Sovryn's fail-open path, both pay 100%. No haircut may appear where there
     * is no fee.
     */
    function test_sovryn_withoutExitFeeWithdrawalStaysOneToOne() public onlySovrynMocMocks {
        assertEq(MockIsusdToken(address(shareToken)).getExitFeeBps(), 0);

        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        uint256 scheduleBalanceBefore = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;
        uint256 userDocBefore = stablecoin.balanceOf(USER);

        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, WITHDRAWAL_AMOUNT);

        uint256 paid = stablecoin.balanceOf(USER) - userDocBefore;
        uint256 deducted =
            scheduleBalanceBefore - dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;

        assertGe(paid, WITHDRAWAL_AMOUNT, "a fee-free redemption must not pay less than requested");
        assertApproxEqAbs(paid, WITHDRAWAL_AMOUNT, ROUNDING_TOLERANCE);
        assertEq(deducted, WITHDRAWAL_AMOUNT, "nothing should be credited back when the full amount was paid");
    }

    /**
     * @notice Same purchase, no fee: the rBTC bought matches the fee-free expectation exactly.
     */
    function test_sovryn_withoutExitFeeBuyRbtcIsUnchanged() public onlySovrynMocMocks {
        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        uint256 rbtcBefore = _accumulatedRbtc();

        buyRbtcOne(USER, SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND);

        uint256 netPurchaseAmount = AMOUNT_TO_SPEND - feeCalculator.calculateFee(AMOUNT_TO_SPEND);
        assertApproxEqRel(_accumulatedRbtc() - rbtcBefore, netPurchaseAmount / s_btcPrice, _maxPurchaseSlippage());
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _enableExitFee() internal {
        MockIsusdToken(address(shareToken)).setExitFeeBps(EXIT_FEE_BPS);
    }

    function _afterExitFee(uint256 grossAmount) internal pure returns (uint256) {
        return grossAmount - (grossAmount * EXIT_FEE_BPS / BPS_DIVISOR);
    }

    function _accumulatedRbtc() internal view returns (uint256) {
        return IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
    }

    function _batchArrays()
        internal
        view
        returns (
            address[] memory users,
            uint256[] memory scheduleIndexes,
            uint64[] memory scheduleIds,
            uint256[] memory purchaseAmounts
        )
    {
        users = new address[](NUM_OF_SCHEDULES);
        scheduleIndexes = new uint256[](NUM_OF_SCHEDULES);
        scheduleIds = new uint64[](NUM_OF_SCHEDULES);
        purchaseAmounts = new uint256[](NUM_OF_SCHEDULES);

        for (uint256 i; i < NUM_OF_SCHEDULES; ++i) {
            users[i] = USER;
            scheduleIndexes[i] = i;
            scheduleIds[i] = dcaManager.getDcaSchedules(USER, address(stablecoin))[i].scheduleId;
            purchaseAmounts[i] = dcaManager.getDcaSchedules(USER, address(stablecoin))[i].purchaseAmount;
        }
    }

    /**
     * @dev Sums the amountSpent of every PurchaseRbtc__RbtcBought and reads the batch event's total spend.
     * RbtcBought indexes user, tokenSpent and scheduleId, leaving (rBtcBought, amountSpent) in data;
     * SuccessfulRbtcBatchPurchase indexes only the token, so its spend is the second data word.
     */
    function _batchSpendFromLogs() internal returns (uint256 perUserSpentTotal, uint256 batchSpent) {
        bytes32 boughtSig = keccak256("PurchaseRbtc__RbtcBought(address,address,uint256,uint64,uint256)");
        bytes32 batchSig = keccak256("PurchaseRbtc__SuccessfulRbtcBatchPurchase(address,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundBatch;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == boughtSig) {
                (, uint256 amountSpent) = abi.decode(logs[i].data, (uint256, uint256));
                perUserSpentTotal += amountSpent;
            } else if (logs[i].topics[0] == batchSig) {
                (, batchSpent) = abi.decode(logs[i].data, (uint256, uint256));
                foundBatch = true;
            }
        }
        assertTrue(foundBatch, "no PurchaseRbtc__SuccessfulRbtcBatchPurchase log recorded");
        assertGt(perUserSpentTotal, 0, "no PurchaseRbtc__RbtcBought logs recorded");
    }

    /// @dev refundedAmount is the only non-indexed field of DcaManager__DcaScheduleDeleted
    function _deletedEventAmount() internal returns (uint256 amount) {
        bytes32 sig = keccak256("DcaManager__DcaScheduleDeleted(address,address,uint64,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                amount = abi.decode(logs[i].data, (uint256));
                found = true;
            }
        }
        assertTrue(found, "no DcaManager__DcaScheduleDeleted log recorded");
    }

    /// @dev user and token are indexed; the amount is the only data word
    function _interestWithdrawnEventAmount() internal returns (uint256 amount) {
        bytes32 sig = keccak256("TokenLending__InterestWithdrawn(address,address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                amount = abi.decode(logs[i].data, (uint256));
                found = true;
            }
        }
        assertTrue(found, "no TokenLending__InterestWithdrawn log recorded");
    }
}
