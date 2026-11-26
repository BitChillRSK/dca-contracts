// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {console2} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ILendingHandler} from "../../src/interfaces/ILendingHandler.sol";
import {ILayerBankAToken} from "../../src/layerbank/ILayerBankAToken.sol";
import {ILayerBankPool} from "../../src/layerbank/ILayerBankPool.sol";
import {DeployIdleHandler} from "../../script/DeployIdleHandler.s.sol";
import {MockLayerBankAToken} from "../mocks/MockLayerBank.sol";
import {MockIToken} from "../mocks/MockIToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "../Constants.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";
import {toBatch} from "test/utils/BatchBuyOne.sol";

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

/// @dev Sovryn's underlying-value read; `IiToken` declares only what `src/` calls.
interface ISovrynAssetBalance {
    function assetBalanceOf(address owner) external view returns (uint256);
}

/**
 * @title LendingShareWithdrawalTest
 * @notice R119: a user withdraws their lending shares as the venue's receipt token.
 * @dev Venue failure modes (illiquid, paused, resized transfer, re-entrant token) come from the LayerBank
 *      and Sovryn mocks, so those cases run on Anvil only. The rest also run on fork lanes, where the
 *      LayerBank cases redeem the received aTokens at the live Pool.
 */
contract LendingShareWithdrawalTest is DcaDappTest {
    event LendingHandler__UserSharesUpdated(address indexed user, uint256 previousShares, uint256 newShares);
    event LendingHandler__SharesWithdrawn(address indexed user, address indexed receiptToken, uint256 shares);

    address internal OTHER_USER = makeAddr("otherUser");
    ILendingHandler internal lendingHandler;
    address internal receiptToken;

    function setUp() public override {
        super.setUp();
        if (address(dcaManager) == address(0) || !isLendingLane) return;
        lendingHandler = ILendingHandler(address(stablecoinHandler));
        receiptToken = getShareToken(stablecoinType, s_routeIndex);

        // A second schedule on the same route, so the withdrawal has more than one balance to zero.
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

    function test_withdrawalMovesPositionAndZeroesRouteBalances() external onlyLendingLane {
        updateExchangeRate(100 days);
        uint256 principal = _routeBalance(USER);
        uint256 shares = lendingHandler.getUserShares(USER);
        uint256 moved = _expectedMovedShares(shares);
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
        emit LendingHandler__SharesWithdrawn(USER, receiptToken, moved);
        _withdrawShares(USER);

        assertLe(shares - moved, isLayerbank ? 1 : 0, "remainder above one LayerBank scaled share");
        assertEq(lendingHandler.getUserShares(USER), 0, "rounding remainder not forfeited");
        assertEq(_receiptShares(USER) - userSharesBefore, moved, "user did not receive the shares debited");
        assertEq(handlerShares - _receiptShares(address(stablecoinHandler)), moved, "handler shares off");
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerStablecoin, "handler stablecoin moved");
        assertGe(_receiptValue(USER) - userValueBefore + 2, principal, "receipt tokens worth less than principal");
        assertEq(_routeBalance(USER), 0, "a schedule on the route kept a balance");
    }

    function test_schedulesKeptAfterWithdrawalCanBeFundedAndBuy() external onlyLendingLane {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        _withdrawShares(USER);

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

    function test_withdrawalRevertsOnIdleRoute() external onlyLendingLane {
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__TokenIsNotLent.selector, address(stablecoin)));
        vm.prank(USER);
        dcaManager.withdrawLendingShares(address(stablecoin), IDLE_INDEX);
    }

    function test_withdrawalRevertsOnUnassignedLendingPair() external {
        // setUp registers every lending route but assigns a handler only on this lane's route.
        uint256 otherRoute = s_routeIndex == LAYERBANK_INDEX ? SOVRYN_INDEX : LAYERBANK_INDEX;
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__TokenNotAccepted.selector, address(stablecoin), otherRoute)
        );
        vm.prank(USER);
        dcaManager.withdrawLendingShares(address(stablecoin), otherRoute);
    }

    function test_withdrawalRevertsWithoutShares() external onlyLendingLane {
        vm.expectRevert(abi.encodeWithSelector(ILendingHandler.LendingHandler__NoSharesToWithdraw.selector, OTHER_USER));
        _withdrawShares(OTHER_USER);

        _withdrawShares(USER);
        vm.expectRevert(abi.encodeWithSelector(ILendingHandler.LendingHandler__NoSharesToWithdraw.selector, USER));
        _withdrawShares(USER);
    }

    function test_withdrawalBlockedThroughoutProtectedWindow() external onlyLendingLane {
        uint256 allowedFromBlock = block.number + dcaManager.PROTECTED_PURCHASE_WINDOW_BLOCKS();
        vm.prank(SWAPPER);
        dcaManager.activateProtectedPurchaseWindow();

        for (uint256 blockNumber = block.number; blockNumber < allowedFromBlock; ++blockNumber) {
            vm.roll(blockNumber);
            vm.expectRevert(
                abi.encodeWithSelector(IDcaManager.DcaManager__UserMutationsLocked.selector, allowedFromBlock)
            );
            _withdrawShares(USER);
        }

        vm.roll(allowedFromBlock);
        _withdrawShares(USER);
        assertEq(lendingHandler.getUserShares(USER), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         VENUE MOCKS (ANVIL)
    //////////////////////////////////////////////////////////////*/

    function test_illiquidVenue_stablecoinWithdrawRevertsButShareWithdrawalSucceeds() external onlyVenueMocks {
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
        uint256 moved = _expectedMovedShares(shares);
        uint256 expectedValue = _receiptValueOfShares(moved);

        _withdrawShares(USER);

        assertEq(_receiptShares(USER), moved);
        assertEq(_receiptValue(USER), expectedValue, "receipt tokens not worth the shares at the current rate");
        assertGt(expectedValue, principal, "position carries no interest");
        assertEq(lendingHandler.getUserShares(USER), 0);
        assertEq(lendingHandler.getUserShares(OTHER_USER), otherShares, "another user's shares moved");
        assertEq(_receiptShares(address(stablecoinHandler)), handlerShares - moved);
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerStablecoin);
        assertEq(_routeBalance(USER), 0);
        if (idleScheduleId != 0) {
            assertEq(dcaManager.getDcaSchedule(address(stablecoin), idleScheduleId).tokenBalance, idleBalance);
        }
    }

    function test_pausedVenue_withdrawalReverts() external onlyVenueMocks {
        _setRedeemsRevert(true);
        _setTransfersRevert(true);
        uint256 principal = _routeBalance(USER);
        uint256 shares = lendingHandler.getUserShares(USER);

        vm.expectRevert();
        _withdrawShares(USER);

        assertEq(_routeBalance(USER), principal);
        assertEq(lendingHandler.getUserShares(USER), shares);
    }

    /// @dev The user gets what moved and keeps the rest booked; a later withdrawal moves the remainder.
    function test_partialReceiptTransfer_debitsWhatMovedAndKeepsRemainder() external onlyVenueMocks {
        uint256 shares = lendingHandler.getUserShares(USER);
        uint256 moved = _expectedMovedShares(shares) - 2;
        uint256 handlerShares = _receiptShares(address(stablecoinHandler));
        _setTransferShareAdjustment(-2);

        vm.expectEmit(true, false, false, true, address(stablecoinHandler));
        emit LendingHandler__UserSharesUpdated(USER, shares, shares - moved);
        vm.expectEmit(true, true, false, true, address(stablecoinHandler));
        emit LendingHandler__SharesWithdrawn(USER, receiptToken, moved);
        _withdrawShares(USER);

        assertEq(_receiptShares(USER), moved);
        assertEq(lendingHandler.getUserShares(USER), shares - moved);
        assertEq(_receiptShares(address(stablecoinHandler)), handlerShares - moved);
        assertEq(_routeBalance(USER), 0);

        _setTransferShareAdjustment(0);
        uint256 remainder = shares - moved;
        uint256 recovered = _expectedMovedShares(remainder);
        vm.expectEmit(true, true, false, true, address(stablecoinHandler));
        emit LendingHandler__SharesWithdrawn(USER, receiptToken, recovered);
        _withdrawShares(USER);

        assertEq(lendingHandler.getUserShares(USER), 0);
        assertEq(_receiptShares(USER), moved + recovered);
        assertEq(_receiptShares(address(stablecoinHandler)), handlerShares - moved - recovered);
    }

    function test_receiptTransferMovingNothing_revertsWholeWithdrawal() external onlyVenueMocks {
        uint256 shares = lendingHandler.getUserShares(USER);
        _setTransferShareAdjustment(-int256(_expectedMovedShares(shares)));
        _assertWithdrawalRevertsWithMovedShares(0);
    }

    /// @dev Another user's shares back the excess, so only the share check stops it.
    function test_receiptTransferMovingMoreThanBooked_revertsWholeWithdrawal() external onlyVenueMocks {
        _depositAsOtherUser();
        uint256 shares = lendingHandler.getUserShares(USER);
        _setTransferShareAdjustment(int256(shares - _expectedMovedShares(shares)) + 1);
        _assertWithdrawalRevertsWithMovedShares(shares + 1);
    }

    /// @dev Half-up is live LayerBank's transfer rounding, round-up is upstream Aave's. Either way one
    ///      floored transfer moves the position or all but one scaled share, which is forfeited.
    function testFuzz_layerBankWithdrawalUnderEitherTransferRounding(uint256 index, bool roundUp)
        external
        onlyVenueMocks
    {
        if (!isLayerbank) {
            vm.skip(true);
            return;
        }
        index = bound(index, 1e27, 2e27);
        MockLayerBankAToken(receiptToken).setNormalizedIncome(index, true);
        MockLayerBankAToken(receiptToken).setRoundUpTransfer(roundUp);
        uint256 shares = lendingHandler.getUserShares(USER);
        uint256 handlerShares = _receiptShares(address(stablecoinHandler));

        _withdrawShares(USER);

        uint256 moved = _receiptShares(USER);
        assertEq(moved, roundUp ? shares : _expectedMovedShares(shares), "moved shares off");
        assertGe(moved + 1, shares, "more than one scaled share left behind");
        assertEq(lendingHandler.getUserShares(USER), 0);
        assertEq(handlerShares - _receiptShares(address(stablecoinHandler)), moved);
        assertEq(_routeBalance(USER), 0);

        assertEq(_receiptShares(address(stablecoinHandler)), handlerShares - moved);
        vm.expectRevert(abi.encodeWithSelector(ILendingHandler.LendingHandler__NoSharesToWithdraw.selector, USER));
        _withdrawShares(USER);
    }

    function test_reentryFromReceiptTokenCallback_reverts() external onlyVenueMocks {
        bytes memory reenter = abi.encodeCall(IDcaManager.withdrawLendingShares, (address(stablecoin), s_routeIndex));
        if (isLayerbank) MockLayerBankAToken(receiptToken).setTransferCallback(address(dcaManager), reenter);
        else MockIToken(receiptToken).setTransferCallback(address(dcaManager), reenter);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        _withdrawShares(USER);
    }

    /// @dev A purchase for another user nested in the receipt transfer hits the reentrancy guard, so
    ///      the whole share withdrawal reverts and neither user's books move.
    function test_purchaseFromReceiptTokenCallback_revertsWholeWithdrawal() external onlyVenueMocks {
        stablecoin.mint(OTHER_USER, AMOUNT_TO_DEPOSIT);
        vm.startPrank(OTHER_USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();
        uint64[] memory scheduleIds = new uint64[](1);
        scheduleIds[0] = scheduleIdAt(dcaManager, OTHER_USER, address(stablecoin), 0);
        bytes memory purchase =
            abi.encodeCall(IDcaManager.batchBuyRbtc, (toBatch(scheduleIds, address(stablecoin), s_routeIndex)));
        vm.prank(OWNER);
        operationsAdmin.addSwapper(receiptToken);
        if (isLayerbank) MockLayerBankAToken(receiptToken).setTransferCallback(address(dcaManager), purchase);
        else MockIToken(receiptToken).setTransferCallback(address(dcaManager), purchase);
        uint256 principal = _routeBalance(USER);
        uint256 shares = lendingHandler.getUserShares(USER);
        uint256 otherShares = lendingHandler.getUserShares(OTHER_USER);

        vm.prank(USER);
        (bool ok, bytes memory reason) = address(dcaManager)
            .call(abi.encodeCall(IDcaManager.withdrawLendingShares, (address(stablecoin), s_routeIndex)));
        assertFalse(ok);
        assertEq(bytes4(reason), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);

        assertEq(_routeBalance(USER), principal);
        assertEq(lendingHandler.getUserShares(USER), shares);
        assertEq(lendingHandler.getUserShares(OTHER_USER), otherShares);
        assertEq(_routeBalance(OTHER_USER), AMOUNT_TO_DEPOSIT);
    }

    /*//////////////////////////////////////////////////////////////
                         LAYERBANK FORK
    //////////////////////////////////////////////////////////////*/

    /// @dev Redeem all received shares, including any residue from the first floored Pool withdrawal.
    ///      Preserve pre-existing user shares and distinguish them from the handler's forfeited share.
    function test_fork_layerBankWithdrawalThenRedeemAtPool() external onlyLayerBankFork {
        ILayerBankPool pool = ILayerBankPool(ILayerBankAToken(receiptToken).POOL());
        // A separate user-held position must survive both Pool withdrawals unchanged in scaled units.
        vm.startPrank(USER);
        stablecoin.approve(address(pool), AMOUNT_TO_SPEND);
        pool.supply(address(stablecoin), AMOUNT_TO_SPEND, USER, 0);
        vm.stopPrank();

        uint256 principal = _routeBalance(USER);
        uint256 shares = lendingHandler.getUserShares(USER);
        uint256 moved = _expectedMovedShares(shares);
        uint256 scaledBefore = _receiptShares(USER);
        assertGt(scaledBefore, 0, "pre-existing wallet position was not seeded");
        uint256 handlerSharesBefore = _receiptShares(address(stablecoinHandler));
        uint256 handlerCashBefore = stablecoin.balanceOf(address(stablecoinHandler));

        _withdrawShares(USER);
        assertEq(_receiptShares(USER) - scaledBefore, moved, "aToken transfer did not move the half-up shares");
        assertEq(handlerSharesBefore - _receiptShares(address(stablecoinHandler)), moved);
        assertLe(shares - moved, 1, "handler forfeited more than one scaled share");
        assertEq(lendingHandler.getUserShares(USER), 0);
        assertEq(_routeBalance(USER), 0);

        uint256 index = pool.getReserveNormalizedIncome(address(stablecoin));
        assertGe(index, 1e27, "share-rounding bound assumes index >= RAY");
        uint256 amount = _redeemReceivedLayerBankShares(pool, index, moved, scaledBefore);
        // The two half-up deposit mints can lose one scaled share in total, and the transfer
        // can leave one more on the handler. The user's Pool residue is redeemed separately.
        // Convert that two-share bound to underlying units, rounding up.
        uint256 roundingTolerance = (2 * index + 1e27 - 1) / 1e27;
        assertApproxEqAbs(amount, principal, roundingTolerance, "redeemed position differs from principal");
        assertEq(_receiptShares(address(stablecoinHandler)), handlerSharesBefore - moved);
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), handlerCashBefore);
        console2.log("LayerBank share withdrawal: scaled shares moved", moved, "underlying redeemed", amount);
    }

    function test_fork_layerBankPausedReserveBlocksWithdrawal() external onlyLayerBankFork {
        _layerBankGovernance().setReservePause(address(stablecoin), true);
        // Aave `Errors.RESERVE_PAUSED`, raised by the Pool's `finalizeTransfer` under the aToken transfer.
        vm.expectRevert(bytes("29"));
        _withdrawShares(USER);
    }

    function test_fork_layerBankFrozenReserveAllowsWithdrawal() external onlyLayerBankFork {
        _layerBankGovernance().setReserveFreeze(address(stablecoin), true);
        uint256 moved = _expectedMovedShares(lendingHandler.getUserShares(USER));
        uint256 scaledBefore = _receiptShares(USER);
        _withdrawShares(USER);
        assertEq(_receiptShares(USER) - scaledBefore, moved);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _withdrawShares(address user) private {
        vm.prank(user);
        dcaManager.withdrawLendingShares(address(stablecoin), s_routeIndex);
    }

    /// @dev A floored underlying withdrawal can burn one fewer received share. Redeem that share too,
    ///      and prove that all received shares were consumed without touching pre-existing shares.
    function _redeemReceivedLayerBankShares(
        ILayerBankPool pool,
        uint256 index,
        uint256 receivedShares,
        uint256 preExistingShares
    ) private returns (uint256) {
        uint256 cashBefore = stablecoin.balanceOf(USER);
        uint256 amount = receivedShares * index / 1e27;
        uint256 expectedBurn = (amount * 1e27 + index / 2) / index;
        assertLe(expectedBurn, receivedShares, "Pool withdrawal would consume pre-existing shares");

        vm.prank(USER);
        pool.withdraw(address(stablecoin), amount, USER);
        assertEq(stablecoin.balanceOf(USER) - cashBefore, amount, "first Pool payout differs from request");
        uint256 remainingShares = receivedShares - expectedBurn;
        assertEq(_receiptShares(USER), preExistingShares + remainingShares, "first Pool burn differs from half-up");
        assertLe(remainingShares, 1, "floored Pool withdrawal left more than one received share");
        console2.log("LayerBank Pool floor withdrawal: underlying", amount, "remaining scaled shares", remainingShares);

        if (remainingShares != 0) {
            // Nearest underlying value of one scaled share maps back to that share for index >= RAY.
            uint256 remainderAmount = (remainingShares * index + 5e26) / 1e27;
            vm.prank(USER);
            pool.withdraw(address(stablecoin), remainderAmount, USER);
            amount += remainderAmount;
        }

        assertEq(_receiptShares(USER), preExistingShares, "received shares remain or pre-existing shares were spent");
        uint256 receivedCash = stablecoin.balanceOf(USER) - cashBefore;
        assertEq(receivedCash, amount, "total Pool payout differs from requests");
        return receivedCash;
    }

    /// @dev Expects the withdrawal to revert because the handler's receipt-share balance fell by `moved`.
    function _assertWithdrawalRevertsWithMovedShares(uint256 moved) private {
        uint256 principal = _routeBalance(USER);
        uint256 shares = lendingHandler.getUserShares(USER);
        uint256 handlerShares = _receiptShares(address(stablecoinHandler));
        vm.expectRevert(
            abi.encodeWithSelector(
                ILendingHandler.LendingHandler__ShareConsumptionMismatch.selector,
                shares,
                handlerShares,
                handlerShares - moved
            )
        );
        _withdrawShares(USER);

        assertEq(_routeBalance(USER), principal);
        assertEq(lendingHandler.getUserShares(USER), shares);
        assertEq(_receiptShares(USER), 0);
    }

    /// @dev Shares a withdrawal of `shares` moves: LayerBank's half-up `rayDiv` of the floored underlying
    ///      (live and mocked), the booked amount on venues that transfer share units.
    function _expectedMovedShares(uint256 shares) private view returns (uint256) {
        if (!isLayerbank) return shares;
        uint256 index =
            ILayerBankPool(ILayerBankAToken(receiptToken).POOL()).getReserveNormalizedIncome(address(stablecoin));
        return (shares * index / 1e27 * 1e27 + index / 2) / index;
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
        if (isSovryn) return ISovrynAssetBalance(receiptToken).assetBalanceOf(holder);
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

    function _setTransferShareAdjustment(int256 adjustment) private {
        if (isLayerbank) MockLayerBankAToken(receiptToken).setTransferShareAdjustment(adjustment);
        else MockIToken(receiptToken).setTransferShareAdjustment(adjustment);
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
