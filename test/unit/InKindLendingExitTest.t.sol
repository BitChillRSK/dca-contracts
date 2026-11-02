// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {console2} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ILendingHandler} from "../../src/interfaces/ILendingHandler.sol";
import {ILayerBankAToken} from "../../src/layerbank/ILayerBankAToken.sol";
import {ILayerBankPool} from "../../src/layerbank/ILayerBankPool.sol";
import {IiToken} from "../../src/sovryn-legacy/IiToken.sol";
import {DeployIdleHandler} from "../../script/DeployIdleHandler.s.sol";
import {MockLayerBankAToken} from "../mocks/MockLayerBank.sol";
import {MockIToken} from "../mocks/MockIToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "../Constants.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

/// @dev The slice of LayerBank's Aave-v3 governance surface the fork cases use to pause and freeze a reserve.
interface ILayerBankGovernance {
    function ADDRESSES_PROVIDER() external view returns (address);
    function getACLManager() external view returns (address);
    function getACLAdmin() external view returns (address);
    function getPoolConfigurator() external view returns (address);
    function addPoolAdmin(address admin) external;
    function setReservePause(address asset, bool paused) external;
    function setReserveFreeze(address asset, bool freeze) external;
}

/**
 * @title InKindLendingExitTest
 * @notice R119: a user takes their whole lending position as the venue's receipt token.
 * @dev Venue failure modes (illiquid, paused, short transfer, re-entrant token) come from the LayerBank
 *      and Sovryn mocks, so those cases run on Anvil only. The rest also run on fork lanes, where the
 *      LayerBank cases redeem the received aTokens at the live Pool.
 */
contract InKindLendingExitTest is DcaDappTest {
    event LendingHandler__UserSharesUpdated(address indexed user, uint256 previousShares, uint256 newShares);
    event LendingHandler__PositionExitedInKind(address indexed user, address indexed receiptToken, uint256 shares);

    address internal OTHER_USER = makeAddr("otherUser");
    ILendingHandler internal lendingHandler;
    address internal receiptToken;

    function setUp() public override {
        super.setUp();
        if (address(dcaManager) == address(0) || !isLendingLane) return;
        lendingHandler = ILendingHandler(address(stablecoinHandler));
        receiptToken = getShareToken(stablecoinType, s_routeIndex);

        // A second schedule on the same route, so the exit has more than one balance to zero.
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();
    }

    modifier onlyVenueMocks() {
        if (block.chainid != ANVIL_CHAIN_ID || !(isLayerbank || isSovryn)) {
            vm.skip(true);
            return;
        }
        _;
    }

    modifier onlyLayerBankFork() {
        if (block.chainid != RSK_MAINNET_CHAIN_ID || !isLayerbank) {
            vm.skip(true);
            return;
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                         EVERY LENDING LANE
    //////////////////////////////////////////////////////////////*/

    function test_exitMovesWholePositionAndZeroesRouteBalances() external onlyLendingLane {
        updateExchangeRate(100 days);
        uint256 principal = _routeBalance(USER);
        uint256 shares = lendingHandler.getUserShares(USER);
        uint256 handlerShares = _receiptShares(address(stablecoinHandler));
        uint256 handlerStablecoin = stablecoin.balanceOf(address(stablecoinHandler));
        uint256 userSharesBefore = _receiptShares(USER);
        uint256 userValueBefore = _receiptValue(USER);

        (uint64[] memory scheduleIds,) = dcaManager.getDcaSchedules(USER, address(stablecoin));
        for (uint256 i; i < scheduleIds.length; ++i) {
            vm.expectEmit(true, true, false, true, address(dcaManager));
            emit DcaManager__TokenBalanceUpdated(address(stablecoin), scheduleIds[i], 0);
        }
        vm.expectEmit(true, false, false, true, address(stablecoinHandler));
        emit LendingHandler__UserSharesUpdated(USER, shares, 0);
        vm.expectEmit(true, true, false, true, address(stablecoinHandler));
        emit LendingHandler__PositionExitedInKind(USER, receiptToken, shares);
        _exit(USER);

        assertEq(lendingHandler.getUserShares(USER), 0, "booked shares not zeroed");
        assertEq(_receiptShares(USER) - userSharesBefore, shares, "user did not receive exactly the booked shares");
        assertEq(handlerShares - _receiptShares(address(stablecoinHandler)), shares, "handler shares off");
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerStablecoin, "handler stablecoin moved");
        assertGe(_receiptValue(USER) - userValueBefore + 1, principal, "receipt tokens worth less than principal");
        assertEq(_routeBalance(USER), 0, "a schedule on the route kept a balance");
    }

    function test_schedulesKeptAfterExitCanBeFundedAndBuy() external onlyLendingLane {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        _exit(USER);

        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.depositToken(address(stablecoin), scheduleId, AMOUNT_TO_DEPOSIT);
        vm.stopPrank();
        assertGt(lendingHandler.getUserShares(USER), 0);

        buyRbtcOne(scheduleId);
        assertEq(
            scheduleAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX).tokenBalance,
            AMOUNT_TO_DEPOSIT - AMOUNT_TO_SPEND
        );
        assertGt(dcaManager.getAccumulatedRbtcBalance(USER, address(stablecoin), s_routeIndex), 0);
    }

    function test_exitRevertsOnIdleRoute() external onlyLendingLane {
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__TokenIsNotLent.selector, address(stablecoin)));
        vm.prank(USER);
        dcaManager.exitLendingPositionInKind(address(stablecoin), IDLE_INDEX);
    }

    function test_exitRevertsOnUnassignedLendingPair() external {
        // setUp registers every lending route but assigns a handler only on this lane's route.
        uint256 otherRoute = s_routeIndex == LAYERBANK_INDEX ? SOVRYN_INDEX : LAYERBANK_INDEX;
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__TokenNotAccepted.selector, address(stablecoin), otherRoute)
        );
        vm.prank(USER);
        dcaManager.exitLendingPositionInKind(address(stablecoin), otherRoute);
    }

    function test_exitRevertsWithoutShares() external onlyLendingLane {
        vm.expectRevert(abi.encodeWithSelector(ILendingHandler.LendingHandler__NoSharesToExit.selector, OTHER_USER));
        _exit(OTHER_USER);

        _exit(USER);
        vm.expectRevert(abi.encodeWithSelector(ILendingHandler.LendingHandler__NoSharesToExit.selector, USER));
        _exit(USER);
    }

    function test_exitBlockedThroughoutProtectedWindow() external onlyLendingLane {
        uint256 allowedFromBlock = block.number + dcaManager.PROTECTED_PURCHASE_WINDOW_BLOCKS();
        vm.prank(SWAPPER);
        dcaManager.activateProtectedPurchaseWindow();

        for (uint256 blockNumber = block.number; blockNumber < allowedFromBlock; ++blockNumber) {
            vm.roll(blockNumber);
            vm.expectRevert(
                abi.encodeWithSelector(IDcaManager.DcaManager__UserMutationsLocked.selector, allowedFromBlock)
            );
            _exit(USER);
        }

        vm.roll(allowedFromBlock);
        _exit(USER);
        assertEq(lendingHandler.getUserShares(USER), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         VENUE MOCKS (ANVIL)
    //////////////////////////////////////////////////////////////*/

    function test_illiquidVenue_cashWithdrawRevertsButExitSucceeds() external onlyVenueMocks {
        (uint64 idleScheduleId, uint256 idleBalance) = _scheduleOnIdleRoute();
        _depositAsOtherUser();
        updateExchangeRate(100 days);
        _setRedeemsRevert(true);

        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);

        uint256 principal = _routeBalance(USER);
        uint256 shares = lendingHandler.getUserShares(USER);
        uint256 otherShares = lendingHandler.getUserShares(OTHER_USER);
        uint256 handlerShares = _receiptShares(address(stablecoinHandler));
        uint256 handlerStablecoin = stablecoin.balanceOf(address(stablecoinHandler));
        uint256 expectedValue = _receiptValueOfShares(shares);

        _exit(USER);

        assertEq(_receiptShares(USER), shares);
        assertEq(_receiptValue(USER), expectedValue, "receipt tokens not worth the position at the current rate");
        assertGt(expectedValue, principal, "position carries no interest");
        assertEq(lendingHandler.getUserShares(USER), 0);
        assertEq(lendingHandler.getUserShares(OTHER_USER), otherShares, "another user's shares moved");
        assertEq(_receiptShares(address(stablecoinHandler)), handlerShares - shares);
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerStablecoin);
        assertEq(_routeBalance(USER), 0);
        if (idleScheduleId != 0) {
            assertEq(dcaManager.getDcaSchedule(address(stablecoin), idleScheduleId).tokenBalance, idleBalance);
        }
    }

    function test_pausedVenue_exitReverts() external onlyVenueMocks {
        _setRedeemsRevert(true);
        _setTransfersRevert(true);
        uint256 principal = _routeBalance(USER);
        uint256 shares = lendingHandler.getUserShares(USER);

        vm.expectRevert();
        _exit(USER);

        assertEq(_routeBalance(USER), principal);
        assertEq(lendingHandler.getUserShares(USER), shares);
    }

    function test_shortReceiptTransfer_revertsWholeExit() external onlyVenueMocks {
        if (isLayerbank) MockLayerBankAToken(receiptToken).setShortTransfer(true);
        else MockIToken(receiptToken).setShortTransfer(true);
        uint256 principal = _routeBalance(USER);
        uint256 shares = lendingHandler.getUserShares(USER);
        uint256 handlerShares = _receiptShares(address(stablecoinHandler));

        vm.expectRevert(
            abi.encodeWithSelector(
                ILendingHandler.LendingHandler__ShareConsumptionMismatch.selector,
                shares,
                handlerShares,
                handlerShares - shares + 1
            )
        );
        _exit(USER);

        assertEq(_routeBalance(USER), principal);
        assertEq(lendingHandler.getUserShares(USER), shares);
    }

    function test_reentryFromReceiptTokenCallback_reverts() external onlyVenueMocks {
        bytes memory reenter =
            abi.encodeCall(IDcaManager.exitLendingPositionInKind, (address(stablecoin), s_routeIndex));
        if (isLayerbank) MockLayerBankAToken(receiptToken).setTransferCallback(address(dcaManager), reenter);
        else MockIToken(receiptToken).setTransferCallback(address(dcaManager), reenter);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        _exit(USER);
    }

    /*//////////////////////////////////////////////////////////////
                         LAYERBANK FORK
    //////////////////////////////////////////////////////////////*/

    /// @dev The received aTokens redeem at the live Pool from the user's own address, for the full position.
    function test_fork_layerBankExitThenRedeemAtPool() external onlyLayerBankFork {
        ILayerBankPool pool = ILayerBankPool(ILayerBankAToken(receiptToken).POOL());
        uint256 principal = _routeBalance(USER);
        uint256 shares = lendingHandler.getUserShares(USER);
        uint256 scaledBefore = _receiptShares(USER);

        _exit(USER);
        assertEq(_receiptShares(USER) - scaledBefore, shares, "aToken transfer did not move exactly the shares");

        uint256 amount = shares * pool.getReserveNormalizedIncome(address(stablecoin)) / 1e27;
        uint256 stablecoinBefore = stablecoin.balanceOf(USER);
        vm.prank(USER);
        pool.withdraw(address(stablecoin), amount, USER);
        assertEq(stablecoin.balanceOf(USER) - stablecoinBefore, amount);
        assertApproxEqAbs(amount, principal, 2, "redeemed position differs from principal");
        console2.log("LayerBank in-kind exit: scaled shares moved", shares, "underlying redeemed", amount);
    }

    function test_fork_layerBankPausedReserveBlocksExit() external onlyLayerBankFork {
        _layerBankGovernance().setReservePause(address(stablecoin), true);
        // Aave `Errors.RESERVE_PAUSED`, raised by the Pool's `finalizeTransfer` under the aToken transfer.
        vm.expectRevert(bytes("29"));
        _exit(USER);
    }

    function test_fork_layerBankFrozenReserveAllowsExit() external onlyLayerBankFork {
        _layerBankGovernance().setReserveFreeze(address(stablecoin), true);
        uint256 shares = lendingHandler.getUserShares(USER);
        uint256 scaledBefore = _receiptShares(USER);
        _exit(USER);
        assertEq(_receiptShares(USER) - scaledBefore, shares);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _exit(address user) private {
        vm.prank(user);
        dcaManager.exitLendingPositionInKind(address(stablecoin), s_routeIndex);
    }

    function _routeBalance(address user) private view returns (uint256 total) {
        (, IDcaManager.DcaSchedule[] memory schedules) = dcaManager.getDcaSchedules(user, address(stablecoin));
        for (uint256 i; i < schedules.length; ++i) {
            if (schedules[i].routeIndex == s_routeIndex) total += schedules[i].tokenBalance;
        }
    }

    /// @dev aToken scaled balance, or iToken/kToken balance: the unit `getUserShares` books.
    function _receiptShares(address holder) private view returns (uint256) {
        if (isLayerbank) return ILayerBankAToken(receiptToken).scaledBalanceOf(holder);
        return IERC20(receiptToken).balanceOf(holder);
    }

    /// @dev What `holder`'s receipt tokens redeem for at the venue's current rate.
    function _receiptValue(address holder) private returns (uint256) {
        if (isLayerbank) return IERC20(receiptToken).balanceOf(holder);
        if (isSovryn) return IiToken(receiptToken).assetBalanceOf(holder);
        return IERC20(receiptToken).balanceOf(holder) * shareToken.exchangeRateCurrent() / 1e18;
    }

    function _receiptValueOfShares(uint256 shares) private view returns (uint256) {
        if (isLayerbank) return shares * MockLayerBankAToken(receiptToken).getNormalizedIncome() / 1e27;
        return shares * MockIToken(receiptToken).tokenPrice() / 1e18;
    }

    function _setRedeemsRevert(bool enabled) private {
        if (isLayerbank) MockLayerBankAToken(receiptToken).setRevertOnBurn(enabled);
        else MockIToken(receiptToken).setRevertOnBurn(enabled);
    }

    function _setTransfersRevert(bool enabled) private {
        if (isLayerbank) MockLayerBankAToken(receiptToken).setRevertOnTransfer(enabled);
        else MockIToken(receiptToken).setRevertOnTransfer(enabled);
    }

    /// @dev A funded schedule on the idle route, where a MoC idle handler exists for this lane's token.
    function _scheduleOnIdleRoute() private returns (uint64 scheduleId, uint256 balance) {
        if (!isMocSwaps) return (0, 0);
        address idleHandler = new DeployIdleHandler()
            .deployIdleDocHandlerMoc(
                DeployIdleHandler.DeployParams({
                dcaManager: address(dcaManager),
                stablecoin: address(stablecoin),
                mocProxy: address(mocProxy),
                feeCollector: FEE_COLLECTOR,
                initialOwner: OWNER
            })
            );
        vm.prank(OWNER);
        operationsAdmin.assignHandler(address(stablecoin), IDLE_INDEX, idleHandler);

        vm.startPrank(USER);
        stablecoin.approve(idleHandler, AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, IDLE_INDEX
        );
        vm.stopPrank();
        (uint64[] memory scheduleIds,) = dcaManager.getDcaSchedules(USER, address(stablecoin));
        return (scheduleIds[scheduleIds.length - 1], AMOUNT_TO_DEPOSIT);
    }

    function _depositAsOtherUser() private {
        stablecoin.mint(OTHER_USER, AMOUNT_TO_DEPOSIT);
        vm.startPrank(OTHER_USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();
    }

    function _layerBankGovernance() private returns (ILayerBankGovernance configurator) {
        ILayerBankGovernance provider =
            ILayerBankGovernance(ILayerBankGovernance(ILayerBankAToken(receiptToken).POOL()).ADDRESSES_PROVIDER());
        ILayerBankGovernance aclManager = ILayerBankGovernance(provider.getACLManager());
        vm.prank(provider.getACLAdmin());
        aclManager.addPoolAdmin(address(this));
        return ILayerBankGovernance(provider.getPoolConfigurator());
    }
}
