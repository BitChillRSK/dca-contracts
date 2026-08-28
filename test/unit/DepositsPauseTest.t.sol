//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IOperationsAdmin} from "../../src/interfaces/IOperationsAdmin.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import "./TestsHelper.t.sol";

/**
 * @notice R48: governance can stop new stablecoin deposits on one `(token, routeIndex)` pair.
 * @dev The pause must be a one-way valve: nothing a user needs to get their money out may consult it.
 */
contract DepositsPauseTest is DcaDappTest {
    uint256 private constant SECOND_IDLE_INDEX = 10;
    /// @dev A live lending share round-trip loses a few wei to rounding, and how many depends on the
    ///      forked block. The point here is that the exit paid out while paused, not the exact share
    ///      math, which the lending suites own. `withdrawStablecoin` already asserts the ledger.
    uint256 private constant WITHDRAWAL_ROUNDING_TOLERANCE = 1e12; // 0.0001%, Foundry's 1e18 scale

    function setUp() public override {
        super.setUp();
    }

    function _pauseDeposits(bool paused) private {
        vm.prank(OWNER);
        operationsAdmin.setDepositsPaused(address(stablecoin), s_routeIndex, paused);
    }

    function _depositsPausedRevert() private view returns (bytes memory) {
        return abi.encodeWithSelector(
            IDcaManager.DcaManager__DepositsPaused.selector, address(stablecoin), s_routeIndex
        );
    }

    /*//////////////////////////////////////////////////////////////
                             DEPOSITS BLOCKED
    //////////////////////////////////////////////////////////////*/

    function testPausedRouteRejectsDeposit() external {
        _pauseDeposits(true);

        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);
        uint256 handlerStablecoinBefore = stablecoin.balanceOf(address(stablecoinHandler));
        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        uint256 scheduleBalanceBefore =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance;

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        vm.expectRevert(_depositsPausedRevert());
        dcaManager.depositToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, AMOUNT_TO_DEPOSIT);
        vm.stopPrank();

        assertEq(stablecoin.balanceOf(USER), userStablecoinBefore, "the user paid on a paused route");
        assertEq(
            stablecoin.balanceOf(address(stablecoinHandler)),
            handlerStablecoinBefore,
            "the handler took cash on a paused route"
        );
        assertEq(
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance,
            scheduleBalanceBefore
        );
    }

    function testPausedRouteRejectsScheduleCreation() external {
        _pauseDeposits(true);

        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);
        uint256 numOfSchedulesBefore = dcaManager.getDcaSchedules(USER, address(stablecoin)).length;

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        vm.expectRevert(_depositsPausedRevert());
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();

        assertEq(stablecoin.balanceOf(USER), userStablecoinBefore, "the user paid on a paused route");
        assertEq(dcaManager.getDcaSchedules(USER, address(stablecoin)).length, numOfSchedulesBefore);
    }

    /// @dev With no allowance a deposit would revert inside the handler. The pause error is what
    ///      surfaces, so the check provably runs before the token is touched at all.
    function testPauseIsCheckedBeforeTheTokenIsTouched() external {
        _pauseDeposits(true);

        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), 0);
        vm.expectRevert(_depositsPausedRevert());
        dcaManager.depositToken(address(stablecoin), SCHEDULE_INDEX, scheduleId, AMOUNT_TO_DEPOSIT);
        vm.stopPrank();
    }

    function testUnpausingRestoresDeposits() external {
        _pauseDeposits(true);
        _pauseDeposits(false);

        (uint256 userBalanceAfterDeposit, uint256 userBalanceBeforeDeposit) = super.depositStablecoin();
        assertEq(userBalanceAfterDeposit - userBalanceBeforeDeposit, AMOUNT_TO_DEPOSIT);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();
        assertEq(dcaManager.getDcaSchedules(USER, address(stablecoin)).length, 2);
    }

    /// @dev An incident on one pair must not stop deposits anywhere else.
    function testPausingAnotherPairLeavesThisOneOpen() external {
        DummyTokenHandler otherTokenStub = new DummyTokenHandler();
        address otherToken = makeAddr("r48DepositOtherToken");

        vm.startPrank(OWNER);
        operationsAdmin.assignTokenHandler(otherToken, IDLE_INDEX, address(otherTokenStub));
        operationsAdmin.setDepositsPaused(otherToken, IDLE_INDEX, true);
        vm.stopPrank();

        (uint256 userBalanceAfterDeposit, uint256 userBalanceBeforeDeposit) = super.depositStablecoin();
        assertEq(userBalanceAfterDeposit - userBalanceBeforeDeposit, AMOUNT_TO_DEPOSIT);
    }

    /// @dev Same token, a second route: only the named pair closes.
    function testPausingASecondRouteLeavesTheLiveOneOpen() external {
        DummyTokenHandler otherRouteStub = new DummyTokenHandler();

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(SECOND_IDLE_INDEX, false);
        operationsAdmin.assignTokenHandler(address(stablecoin), SECOND_IDLE_INDEX, address(otherRouteStub));
        operationsAdmin.setDepositsPaused(address(stablecoin), SECOND_IDLE_INDEX, true);
        vm.stopPrank();

        (uint256 userBalanceAfterDeposit, uint256 userBalanceBeforeDeposit) = super.depositStablecoin();
        assertEq(userBalanceAfterDeposit - userBalanceBeforeDeposit, AMOUNT_TO_DEPOSIT);
    }

    /*//////////////////////////////////////////////////////////////
                       EVERYTHING ELSE STAYS OPEN
    //////////////////////////////////////////////////////////////*/

    function testPausedRouteStillPurchases() external {
        _pauseDeposits(true);
        super.makeSinglePurchase();
    }

    function testPausedRouteStillWithdrawsStablecoin() external {
        _pauseDeposits(true);

        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);
        super.withdrawStablecoin();
        assertApproxEqRel(
            stablecoin.balanceOf(USER) - userStablecoinBefore,
            AMOUNT_TO_DEPOSIT,
            WITHDRAWAL_ROUNDING_TOLERANCE,
            "the exit did not pay the user on a paused route"
        );
    }

    function testPausedRouteStillPaysAccumulatedRbtc() external {
        super.makeSinglePurchase();
        _pauseDeposits(true);

        uint256 rbtcAccumulated = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        assertGt(rbtcAccumulated, 0, "nothing was bought to withdraw");

        uint256 userRbtcBefore = USER.balance;
        vm.prank(USER);
        dcaManager.withdrawRbtcFromTokenHandler(address(stablecoin), s_routeIndex);
        assertEq(USER.balance - userRbtcBefore, rbtcAccumulated);
    }

    function testPausedRouteStillPaysInterest() external onlyLendingLane {
        updateExchangeRate(10 days);
        _pauseDeposits(true);

        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;

        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);
        assertGt(stablecoin.balanceOf(USER), userStablecoinBefore, "no interest was paid on a paused route");
    }

    function testPausedRouteStillAllowsScheduleEdits() external {
        _pauseDeposits(true);

        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        uint256 newPurchaseAmount = AMOUNT_TO_SPEND / 2;
        uint256 newPurchasePeriod = MIN_PURCHASE_PERIOD * 2;

        vm.startPrank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), SCHEDULE_INDEX, scheduleId, newPurchaseAmount);
        dcaManager.updatePurchasePeriod(address(stablecoin), SCHEDULE_INDEX, scheduleId, newPurchasePeriod);
        vm.stopPrank();

        IDcaManager.DcaSchedule memory schedule =
            dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX);
        assertEq(schedule.purchaseAmount, newPurchaseAmount);
        assertEq(schedule.purchasePeriod, newPurchasePeriod);
    }

    function testPausedRouteStillAllowsDeletion() external {
        _pauseDeposits(true);

        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        uint256 userStablecoinBefore = stablecoin.balanceOf(USER);

        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), SCHEDULE_INDEX, scheduleId);

        assertEq(dcaManager.getDcaSchedules(USER, address(stablecoin)).length, 0);
        assertGt(stablecoin.balanceOf(USER), userStablecoinBefore, "the refund never reached the user");
    }
}
