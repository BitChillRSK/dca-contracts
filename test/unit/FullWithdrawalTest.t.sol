//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import "../Constants.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

/**
 * @title FullWithdrawalTest
 * @notice R15. `type(uint256).max` means "this schedule's whole tokenBalance as it stands now", so a
 * purchase landing between the UI's read and the transaction no longer turns a withdrawal into a revert.
 */
contract FullWithdrawalTest is DcaDappTest {
    uint256 constant INTEREST_ACCRUAL_PERIOD = 30 days;
    /// @dev share conversion rounds up, so a stablecoin payout can differ from the requested amount by dust
    uint256 constant PAYOUT_TOLERANCE = 1e6;

    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAW-ALL SENTINEL
    //////////////////////////////////////////////////////////////*/

    function test_sentinelWithdrawsTheWholeScheduleBalance() external {
        uint64 scheduleId = _scheduleId(SCHEDULE_INDEX);
        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);

        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, type(uint256).max);

        assertEq(_scheduleBalance(SCHEDULE_INDEX), 0, "the schedule was not emptied");
        assertApproxEqAbs(
            stablecoin.balanceOf(USER) - userStablecoinBefore,
            AMOUNT_TO_DEPOSIT,
            PAYOUT_TOLERANCE,
            "the user was not paid the schedule balance"
        );
    }

    /**
     * @notice The race the sentinel exists for: the caller reads tokenBalance, the swapper spends part of it,
     * and the withdrawal for the stale figure reverts. The sentinel reads storage inside the transaction.
     */
    function test_sentinelResolvesAgainstTheLiveBalance() external {
        uint64 scheduleId = _scheduleId(SCHEDULE_INDEX);
        uint256 staleBalance = _scheduleBalance(SCHEDULE_INDEX);

        buyRbtcOne(scheduleId);

        uint256 liveBalance = _scheduleBalance(SCHEDULE_INDEX);
        assertLt(liveBalance, staleBalance, "the purchase did not move the balance");

        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__WithdrawalAmountExceedsBalance.selector,
                address(stablecoin),
                staleBalance,
                liveBalance
            )
        );
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, staleBalance);

        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, type(uint256).max);

        assertEq(_scheduleBalance(SCHEDULE_INDEX), 0, "the schedule was not emptied");
        assertApproxEqAbs(
            stablecoin.balanceOf(USER) - userStablecoinBefore,
            liveBalance,
            PAYOUT_TOLERANCE,
            "the user was not paid the live balance"
        );
    }

    /// @notice the sentinel does not turn an empty schedule into a no-op withdrawal
    function test_sentinelStillRevertsOnAnEmptySchedule() external {
        uint64 scheduleId = _scheduleId(SCHEDULE_INDEX);
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, type(uint256).max);

        vm.expectRevert(IDcaManager.DcaManager__WithdrawalAmountMustBeGreaterThanZero.selector);
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, type(uint256).max);
    }

    /// @notice only the sentinel is special: every other oversized amount is still a revert
    function test_amountsAboveTheBalanceStillRevert() external {
        uint64 scheduleId = _scheduleId(SCHEDULE_INDEX);
        uint256 tokenBalance = _scheduleBalance(SCHEDULE_INDEX);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__WithdrawalAmountExceedsBalance.selector,
                address(stablecoin),
                tokenBalance + 1,
                tokenBalance
            )
        );
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, tokenBalance + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__WithdrawalAmountExceedsBalance.selector,
                address(stablecoin),
                type(uint256).max - 1,
                tokenBalance
            )
        );
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, type(uint256).max - 1);
    }

    /**
     * @notice Handler balances are pooled per user, so emptying one schedule must not reach into the funds
     * backing the others.
     */
    function test_sentinelLeavesTheOtherSchedulesUntouched() external {
        createSeveralDcaSchedules();
        uint256 scheduleBalance = _scheduleBalance(SCHEDULE_INDEX);
        uint64 scheduleId = _scheduleId(SCHEDULE_INDEX);

        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, type(uint256).max);

        assertEq(_scheduleBalance(SCHEDULE_INDEX), 0, "the withdrawn schedule was not emptied");
        for (uint256 i = 1; i < NUM_OF_SCHEDULES; ++i) {
            assertEq(_scheduleBalance(i), scheduleBalance, "another schedule's principal was touched");
        }
        if (isLendingLane) {
            assertGt(
                stablecoinHandler.getUserShares(USER),
                0,
                "the shares backing the remaining schedules were burnt"
            );
        }
    }

    /// @notice the sentinel plus the pre-existing interest path still pays principal + interest in one call
    function test_withdrawTokenAndInterestWithTheSentinelExitsThePosition() external onlyLendingLane {
        updateExchangeRate(INTEREST_ACCRUAL_PERIOD);
        uint256 principal = _scheduleBalance(SCHEDULE_INDEX);
        uint256 interest = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);
        uint64 scheduleId = _scheduleId(SCHEDULE_INDEX);

        vm.prank(USER);
        dcaManager.withdrawTokenAndInterest(address(stablecoin), scheduleId, type(uint256).max
        );

        assertEq(_scheduleBalance(SCHEDULE_INDEX), 0, "the schedule was not emptied");
        assertApproxEqAbs(
            stablecoin.balanceOf(USER) - userStablecoinBefore,
            principal + interest,
            PAYOUT_TOLERANCE,
            "the user was not paid principal plus interest"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _scheduleId(uint256 scheduleIndex) internal view returns (uint64) {
        return scheduleIdAt(dcaManager, USER, address(stablecoin), scheduleIndex);
    }

    function _scheduleBalance(uint256 scheduleIndex) internal view returns (uint256) {
        return scheduleAt(dcaManager, USER, address(stablecoin), scheduleIndex).tokenBalance;
    }
}
