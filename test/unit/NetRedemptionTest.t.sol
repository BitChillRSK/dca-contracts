//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {Vm} from "forge-std/Test.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {MockIsusdToken} from "../mocks/MockIsusdToken.sol";
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
        if (s_lendingProtocolIndex != SOVRYN_INDEX || !isMocSwaps || block.chainid != ANVIL_CHAIN_ID) {
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
    function test_sovryn_buyRbtcSpendsTheNetRedeemedAmount() public onlySovrynMocMocks {
        _enableExitFee();

        bytes32 scheduleId = dcaManager.getScheduleId(USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 rbtcBefore = _accumulatedRbtc();

        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(stablecoin), SCHEDULE_INDEX, scheduleId);

        uint256 rbtcBought = _accumulatedRbtc() - rbtcBefore;
        uint256 netRedeemed = _afterExitFee(AMOUNT_TO_SPEND);
        uint256 expected = (netRedeemed - feeCalculator.calculateFee(netRedeemed)) / s_btcPrice;

        assertApproxEqRel(rbtcBought, expected, MAX_SLIPPAGE_PERCENT);
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
            bytes32[] memory scheduleIds,
            uint256[] memory purchaseAmounts
        ) = _batchArrays();

        uint256 handlerRbtcBefore = address(stablecoinHandler).balance;
        uint256 creditedBefore = _accumulatedRbtc();

        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            users, address(stablecoin), scheduleIndexes, scheduleIds, purchaseAmounts, s_lendingProtocolIndex
        );

        uint256 received = address(stablecoinHandler).balance - handlerRbtcBefore;
        uint256 credited = _accumulatedRbtc() - creditedBefore;

        assertGt(credited, 0);
        assertLe(credited, received, "credited more rBTC than the handler received");
    }

    /**
     * @notice The clamp desync: DcaManager used to deduct the requested amount even when the handler paid
     * less, silently burning the difference from the schedule.
     */
    function test_sovryn_withdrawTokenDeductsOnlyWhatWasPaid() public onlySovrynMocMocks {
        _enableExitFee();

        bytes32 scheduleId = dcaManager.getScheduleId(USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 scheduleBalanceBefore = dcaManager.getScheduleTokenBalance(USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 userDocBefore = stablecoin.balanceOf(USER);

        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, WITHDRAWAL_AMOUNT);

        uint256 paid = stablecoin.balanceOf(USER) - userDocBefore;
        uint256 deducted =
            scheduleBalanceBefore - dcaManager.getScheduleTokenBalance(USER, address(stablecoin), SCHEDULE_INDEX);

        assertLt(paid, WITHDRAWAL_AMOUNT, "the exit fee should have produced a shortfall");
        assertApproxEqAbs(paid, _afterExitFee(WITHDRAWAL_AMOUNT), ROUNDING_TOLERANCE);
        assertEq(deducted, paid, "schedule balance must only drop by what the user was paid");
    }

    /**
     * @notice The unpaid remainder stays claimable instead of vanishing from the schedule.
     */
    function test_sovryn_shortfallStaysWithdrawable() public onlySovrynMocMocks {
        _enableExitFee();

        bytes32 scheduleId = dcaManager.getScheduleId(USER, address(stablecoin), SCHEDULE_INDEX);
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, WITHDRAWAL_AMOUNT);

        uint256 remaining = dcaManager.getScheduleTokenBalance(USER, address(stablecoin), SCHEDULE_INDEX);
        assertGt(remaining, AMOUNT_TO_DEPOSIT - WITHDRAWAL_AMOUNT, "shortfall was not credited back");

        uint256 userDocBefore = stablecoin.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, remaining);
        assertGt(stablecoin.balanceOf(USER) - userDocBefore, 0, "remainder was not claimable");
    }

    /**
     * @notice The schedule is gone by the time the handler pays, so the event must at least stop overstating.
     */
    function test_sovryn_deleteDcaScheduleReportsTheAmountActuallyPaid() public onlySovrynMocMocks {
        _enableExitFee();

        bytes32 scheduleId = dcaManager.getScheduleId(USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 userDocBefore = stablecoin.balanceOf(USER);

        vm.recordLogs();
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), SCHEDULE_INDEX, scheduleId);

        uint256 paid = stablecoin.balanceOf(USER) - userDocBefore;
        assertLt(paid, AMOUNT_TO_DEPOSIT, "the exit fee should have produced a shortfall");
        assertEq(_deletedEventAmount(), paid, "the event overstates what the user was paid");
    }

    /**
     * @notice Sovryn pays the user directly here, so the handler cannot read its own delta: it must measure
     * the user's.
     */
    function test_sovryn_withdrawInterestPaysAndReportsNet() public onlySovrynMocMocks {
        vm.warp(block.timestamp + 365 days); // the mock's exchange rate grows 5% a year
        _enableExitFee();

        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        uint256[] memory lendingProtocolIndexes = new uint256[](1);
        lendingProtocolIndexes[0] = s_lendingProtocolIndex;

        uint256 userDocBefore = stablecoin.balanceOf(USER);

        vm.recordLogs();
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, lendingProtocolIndexes);

        uint256 paid = stablecoin.balanceOf(USER) - userDocBefore;
        assertGt(paid, 0, "no interest was paid");
        assertEq(_interestWithdrawnEventAmount(), paid, "the event overstates the interest paid");
    }

    /*//////////////////////////////////////////////////////////////
                           EXIT FEE DISABLED
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pre-activation, and Sovryn's fail-open path, both pay 100%. No haircut may appear where there
     * is no fee.
     */
    function test_sovryn_withoutExitFeeWithdrawalStaysOneToOne() public onlySovrynMocMocks {
        assertEq(MockIsusdToken(address(lendingToken)).getExitFeeBps(), 0);

        bytes32 scheduleId = dcaManager.getScheduleId(USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 scheduleBalanceBefore = dcaManager.getScheduleTokenBalance(USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 userDocBefore = stablecoin.balanceOf(USER);

        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, WITHDRAWAL_AMOUNT);

        uint256 paid = stablecoin.balanceOf(USER) - userDocBefore;
        uint256 deducted =
            scheduleBalanceBefore - dcaManager.getScheduleTokenBalance(USER, address(stablecoin), SCHEDULE_INDEX);

        assertGe(paid, WITHDRAWAL_AMOUNT, "a fee-free redemption must not pay less than requested");
        assertApproxEqAbs(paid, WITHDRAWAL_AMOUNT, ROUNDING_TOLERANCE);
        assertEq(deducted, WITHDRAWAL_AMOUNT, "nothing should be credited back when the full amount was paid");
    }

    /**
     * @notice Same purchase, no fee: the rBTC bought matches the fee-free expectation exactly.
     */
    function test_sovryn_withoutExitFeeBuyRbtcIsUnchanged() public onlySovrynMocMocks {
        bytes32 scheduleId = dcaManager.getScheduleId(USER, address(stablecoin), SCHEDULE_INDEX);
        uint256 rbtcBefore = _accumulatedRbtc();

        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(stablecoin), SCHEDULE_INDEX, scheduleId);

        uint256 netPurchaseAmount = AMOUNT_TO_SPEND - feeCalculator.calculateFee(AMOUNT_TO_SPEND);
        assertApproxEqRel(_accumulatedRbtc() - rbtcBefore, netPurchaseAmount / s_btcPrice, MAX_SLIPPAGE_PERCENT);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _enableExitFee() internal {
        MockIsusdToken(address(lendingToken)).setExitFeeBps(EXIT_FEE_BPS);
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
            bytes32[] memory scheduleIds,
            uint256[] memory purchaseAmounts
        )
    {
        users = new address[](NUM_OF_SCHEDULES);
        scheduleIndexes = new uint256[](NUM_OF_SCHEDULES);
        scheduleIds = new bytes32[](NUM_OF_SCHEDULES);
        purchaseAmounts = new uint256[](NUM_OF_SCHEDULES);

        for (uint256 i; i < NUM_OF_SCHEDULES; ++i) {
            users[i] = USER;
            scheduleIndexes[i] = i;
            scheduleIds[i] = dcaManager.getDcaSchedules(USER, address(stablecoin))[i].scheduleId;
            purchaseAmounts[i] = dcaManager.getDcaSchedules(USER, address(stablecoin))[i].purchaseAmount;
        }
    }

    /// @dev refundedAmount is the only non-indexed field of DcaManager__DcaScheduleDeleted
    function _deletedEventAmount() internal returns (uint256 amount) {
        bytes32 sig = keccak256("DcaManager__DcaScheduleDeleted(address,address,bytes32,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (,,, amount) = abi.decode(logs[i].data, (address, address, bytes32, uint256));
                found = true;
            }
        }
        assertTrue(found, "no DcaManager__DcaScheduleDeleted log recorded");
    }

    /// @dev every field of TokenLending__InterestWithdrawn is indexed, so the amount is the last topic
    function _interestWithdrawnEventAmount() internal returns (uint256 amount) {
        bytes32 sig = keccak256("TokenLending__InterestWithdrawn(address,address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                amount = uint256(logs[i].topics[3]);
                found = true;
            }
        }
        assertTrue(found, "no TokenLending__InterestWithdrawn log recorded");
    }
}
