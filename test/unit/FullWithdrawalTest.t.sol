//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {MockIsusdToken} from "../mocks/MockIsusdToken.sol";
import {MockKdocToken} from "../mocks/MockKdocToken.sol";
import "../../script/Constants.sol";

/**
 * @title FullWithdrawalTest
 * @notice R15. Two leftovers that share these files. `type(uint256).max` means "this schedule's whole
 * tokenBalance as it stands now", so a purchase landing between the UI's read and the transaction no longer
 * turns a withdrawal into a revert. And a user who locks nothing on a handler any more must not keep lending
 * shares mapped to them: share conversion rounds up on the way in and truncates on the way out, so the
 * remainder can be worth zero stablecoin, which is exactly the case the old interest path returned early on.
 */
contract FullWithdrawalTest is DcaDappTest {
    uint256 constant INTEREST_ACCRUAL_PERIOD = 30 days;
    /// @dev the whole redemption withheld: not SIP-0094, just the cheapest way to force a zero payout
    uint256 constant TOTAL_EXIT_FEE_BPS = 10_000;

    function setUp() public override {
        super.setUp();
    }

    /// @notice forcing a zero-value redemption is a mock switch, so those assertions need the local chain
    modifier onlyLocalMocks() {
        if (block.chainid != ANVIL_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAW-ALL SENTINEL
    //////////////////////////////////////////////////////////////*/

    function test_sentinelWithdrawsTheWholeScheduleBalance() external {
        bytes32 scheduleId = _scheduleId(SCHEDULE_INDEX);
        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);

        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, type(uint256).max);

        assertEq(_scheduleBalance(SCHEDULE_INDEX), 0, "the schedule was not emptied");
        assertApproxEqRel(
            stablecoin.balanceOf(USER) - userStablecoinBefore,
            AMOUNT_TO_DEPOSIT,
            MAX_SLIPPAGE_PERCENT,
            "the user was not paid the schedule balance"
        );
    }

    /**
     * @notice The race the sentinel exists for: the caller reads tokenBalance, the swapper spends part of it,
     * and the withdrawal for the stale figure reverts. The sentinel reads storage inside the transaction.
     */
    function test_sentinelResolvesAgainstTheLiveBalance() external {
        bytes32 scheduleId = _scheduleId(SCHEDULE_INDEX);
        uint256 staleBalance = _scheduleBalance(SCHEDULE_INDEX);

        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(stablecoin), SCHEDULE_INDEX, scheduleId);

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
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, staleBalance);

        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, type(uint256).max);

        assertEq(_scheduleBalance(SCHEDULE_INDEX), 0, "the schedule was not emptied");
        assertApproxEqRel(
            stablecoin.balanceOf(USER) - userStablecoinBefore,
            liveBalance,
            MAX_SLIPPAGE_PERCENT,
            "the user was not paid the live balance"
        );
    }

    /// @notice the sentinel does not turn an empty schedule into a no-op withdrawal
    function test_sentinelStillRevertsOnAnEmptySchedule() external {
        bytes32 scheduleId = _scheduleId(SCHEDULE_INDEX);
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, type(uint256).max);

        vm.expectRevert(IDcaManager.DcaManager__WithdrawalAmountMustBeGreaterThanZero.selector);
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, type(uint256).max);
    }

    /// @notice only the sentinel is special: every other oversized amount is still a revert
    function test_amountsAboveTheBalanceStillRevert() external {
        bytes32 scheduleId = _scheduleId(SCHEDULE_INDEX);
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
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, tokenBalance + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__WithdrawalAmountExceedsBalance.selector,
                address(stablecoin),
                type(uint256).max - 1,
                tokenBalance
            )
        );
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, type(uint256).max - 1);
    }

    /**
     * @notice Handler balances are pooled per user, so emptying one schedule must not reach into the funds
     * backing the others.
     */
    function test_sentinelLeavesTheOtherSchedulesUntouched() external {
        createSeveralDcaSchedules();
        uint256 scheduleBalance = _scheduleBalance(SCHEDULE_INDEX);
        bytes32 scheduleId = _scheduleId(SCHEDULE_INDEX);

        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, type(uint256).max);

        assertEq(_scheduleBalance(SCHEDULE_INDEX), 0, "the withdrawn schedule was not emptied");
        for (uint256 i = 1; i < NUM_OF_SCHEDULES; ++i) {
            assertEq(_scheduleBalance(i), scheduleBalance, "another schedule's principal was touched");
        }
        assertGt(
            stablecoinHandler.getUsersLendingTokenBalance(USER),
            0,
            "the shares backing the remaining schedules were burnt"
        );
    }

    /*//////////////////////////////////////////////////////////////
                          LENDING-SHARE DUST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deleting the last schedule closes the position. Before R15 the user had to remember a separate
     * interest call, and even that left the shares whose underlying truncates to zero mapped to them.
     */
    function test_deletingTheLastScheduleSweepsTheLendingPosition() external {
        updateExchangeRate(INTEREST_ACCRUAL_PERIOD);
        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);
        bytes32 scheduleId = _scheduleId(SCHEDULE_INDEX);

        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), SCHEDULE_INDEX, scheduleId);

        assertEq(stablecoinHandler.getUsersLendingTokenBalance(USER), 0, "lending shares stayed mapped to the user");
        assertGt(
            stablecoin.balanceOf(USER) - userStablecoinBefore,
            AMOUNT_TO_DEPOSIT,
            "the sweep did not pay out the interest left on the position"
        );
    }

    /// @notice the sweep only fires when nothing is locked: other schedules keep their shares
    function test_deletingOneOfSeveralSchedulesKeepsTheLendingPosition() external {
        createSeveralDcaSchedules();
        updateExchangeRate(INTEREST_ACCRUAL_PERIOD);
        bytes32 scheduleId = _scheduleId(SCHEDULE_INDEX);

        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), SCHEDULE_INDEX, scheduleId);

        assertGt(stablecoinHandler.getUsersLendingTokenBalance(USER), 0, "the other schedules' shares were burnt");
        uint256 remainingPrincipal;
        for (uint256 i; i < NUM_OF_SCHEDULES - 1; ++i) {
            remainingPrincipal += _scheduleBalance(i);
        }
        assertEq(
            remainingPrincipal,
            AMOUNT_TO_DEPOSIT - AMOUNT_TO_DEPOSIT / NUM_OF_SCHEDULES,
            "the surviving schedules lost principal"
        );
    }

    /// @notice principal out through the sentinel, then the interest call releases everything that is left
    function test_interestWithdrawalAfterAFullWithdrawalSweepsTheRemainder() external {
        updateExchangeRate(INTEREST_ACCRUAL_PERIOD);
        bytes32 scheduleId = _scheduleId(SCHEDULE_INDEX);

        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, type(uint256).max);
        assertGt(
            stablecoinHandler.getUsersLendingTokenBalance(USER),
            0,
            "a principal-only withdrawal should leave the interest shares behind"
        );

        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(_tokens(), _lendingProtocolIndexes());

        assertEq(stablecoinHandler.getUsersLendingTokenBalance(USER), 0, "lending shares stayed mapped to the user");
    }

    /// @notice one call for the whole position: the sentinel takes the principal, the interest call the rest
    function test_withdrawTokenAndInterestWithTheSentinelExitsThePosition() external {
        updateExchangeRate(INTEREST_ACCRUAL_PERIOD);
        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);
        bytes32 scheduleId = _scheduleId(SCHEDULE_INDEX);

        vm.prank(USER);
        dcaManager.withdrawTokenAndInterest(
            address(stablecoin), SCHEDULE_INDEX, scheduleId, type(uint256).max, s_lendingProtocolIndex
        );

        assertEq(_scheduleBalance(SCHEDULE_INDEX), 0, "the schedule was not emptied");
        assertEq(stablecoinHandler.getUsersLendingTokenBalance(USER), 0, "lending shares stayed mapped to the user");
        assertGt(
            stablecoin.balanceOf(USER) - userStablecoinBefore,
            AMOUNT_TO_DEPOSIT,
            "the user was not paid principal plus interest"
        );
    }

    /**
     * @notice The case the ordinary redeem helpers reject. Both revert when a redemption pays nothing, which
     * is right for a redemption the user asked to size in stablecoin and wrong for a sweep of shares that are
     * worth nothing: reverting there is what would keep the dust mapped forever.
     */
    function test_sweepDoesNotRevertWhenTheRedemptionPaysNothing() external onlyLocalMocks {
        updateExchangeRate(INTEREST_ACCRUAL_PERIOD);
        bytes32 scheduleId = _scheduleId(SCHEDULE_INDEX);

        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, type(uint256).max);
        assertGt(stablecoinHandler.getUsersLendingTokenBalance(USER), 0, "nothing was left to sweep");

        _forceZeroRedemptionPayout();
        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);

        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(_tokens(), _lendingProtocolIndexes());

        assertEq(stablecoinHandler.getUsersLendingTokenBalance(USER), 0, "the worthless shares stayed mapped");
        assertEq(stablecoin.balanceOf(USER), userStablecoinBefore, "a zero-value sweep should pay nothing");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _scheduleId(uint256 scheduleIndex) internal view returns (bytes32) {
        return dcaManager.getScheduleId(USER, address(stablecoin), scheduleIndex);
    }

    function _scheduleBalance(uint256 scheduleIndex) internal view returns (uint256) {
        return dcaManager.getScheduleTokenBalance(USER, address(stablecoin), scheduleIndex);
    }

    function _tokens() internal view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(stablecoin);
    }

    function _lendingProtocolIndexes() internal view returns (uint256[] memory lendingProtocolIndexes) {
        lendingProtocolIndexes = new uint256[](1);
        lendingProtocolIndexes[0] = s_lendingProtocolIndex;
    }

    /// @dev Tropykus: a market that reports success and transfers nothing. Sovryn: the whole payout withheld.
    function _forceZeroRedemptionPayout() internal {
        if (s_lendingProtocolIndex == TROPYKUS_INDEX) {
            MockKdocToken(address(lendingToken)).setSilentZeroPayout(true);
        } else {
            MockIsusdToken(address(lendingToken)).setExitFeeBps(TOTAL_EXIT_FEE_BPS);
        }
    }
}
