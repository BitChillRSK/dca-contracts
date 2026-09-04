// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DcaManager} from "../../src/DcaManager.sol";
import {OperationsAdmin} from "../../src/OperationsAdmin.sol";
import {IdleDocHandlerMoc} from "../../src/idle/IdleDocHandlerMoc.sol";
import {TropykusDocHandlerMoc} from "../../src/tropykus-legacy/TropykusDocHandlerMoc.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {ITokenLending} from "../../src/interfaces/ITokenLending.sol";
import {IFeeHandler} from "../../src/interfaces/IFeeHandler.sol";
import {MockFeeOnTransferStablecoin} from "../mocks/MockFeeOnTransferStablecoin.sol";
import {MockKdocToken} from "../mocks/MockKdocToken.sol";
import {MockMocProxy} from "../mocks/MockMocProxy.sol";
import "../Constants.sol";
import {batchBuyOne, toBatch} from "../utils/BatchBuyOne.sol";
import {scheduleIdAt} from "test/utils/ScheduleAt.sol";

/**
 * @notice R41: hop 1 must deliver exactly what was requested or the whole deposit reverts.
 * @dev The stablecoin mock starts 1:1 (`feeBps == 0`) because DOC, USDRIF, and USDT0 are 1:1. A test turns the
 * transfer fee on to model a listed token that starts taking a cut, either before a deposit (which must now fail
 * closed) or after one already landed (where R20 withdraw accounting is unchanged). Hop-2 lag — a 1:1 stablecoin
 * that arrives in full and a lending market that mints shares worth less — is modelled on the kDOC mock instead,
 * because it no longer reaches mint through a fee-on-transfer stablecoin.
 */
contract FeeOnTransferDepositTest is Test {
    address internal constant OWNER = address(0x1111);
    address internal constant ADMIN = address(0x2222);
    address internal constant SWAPPER = address(0x3333);
    address internal constant FEE_COLLECTOR = address(0x5555);
    address internal constant FOT_FEE_RECIPIENT = address(0xFEE1);
    address internal constant USER = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);

    uint256 internal constant FEE_BPS = 100; // 1%
    uint256 internal constant BPS_DIVISOR = 10_000;
    uint256 internal constant REQUESTED = 100 ether;
    uint256 internal constant RECEIVED = 99 ether; // what hop 1 would deliver under FEE_BPS
    uint256 internal constant LENDING_ROUNDING_SLACK = 100;

    DcaManager internal dcaManager;
    OperationsAdmin internal operationsAdmin;
    MockFeeOnTransferStablecoin internal token;
    MockMocProxy internal mocProxy;

    IdleDocHandlerMoc internal idleHandler;
    TropykusDocHandlerMoc internal tropykusHandler;
    MockKdocToken internal kToken;

    function setUp() public {
        vm.prank(OWNER);
        operationsAdmin = new OperationsAdmin(OWNER);

        vm.prank(OWNER);
        dcaManager = new DcaManager(
            address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, OWNER
        );

        // Starts 1:1; each test opts into the transfer fee where it wants one.
        token = new MockFeeOnTransferStablecoin();
        token.setFeeRecipient(FOT_FEE_RECIPIENT);

        mocProxy = new MockMocProxy(address(token));
        vm.deal(address(mocProxy), 100 ether);

        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        idleHandler = new IdleDocHandlerMoc(
            address(dcaManager), address(token), FEE_COLLECTOR, address(mocProxy), feeSettings, OWNER
        );
        kToken = new MockKdocToken(address(token));
        tropykusHandler = new TropykusDocHandlerMoc(
            address(dcaManager),
            address(token),
            address(kToken),
            FEE_COLLECTOR,
            address(mocProxy),
            feeSettings,
            OWNER
        );

        vm.startPrank(OWNER);
        operationsAdmin.addSwapper(SWAPPER);
        operationsAdmin.registerRoute(TROPYKUS_INDEX, true);
        operationsAdmin.assignTokenHandler(address(token), IDLE_INDEX, address(idleHandler));
        operationsAdmin.assignTokenHandler(address(token), TROPYKUS_INDEX, address(tropykusHandler));
        vm.stopPrank();

        vm.prank(address(idleHandler));
        token.approve(address(mocProxy), type(uint256).max);
        vm.prank(address(tropykusHandler));
        token.approve(address(mocProxy), type(uint256).max);

        token.mint(USER, 10_000 ether);
        token.mint(OTHER, 10_000 ether);
        vm.prank(USER);
        token.approve(address(idleHandler), type(uint256).max);
        vm.prank(USER);
        token.approve(address(tropykusHandler), type(uint256).max);
        vm.prank(OTHER);
        token.approve(address(idleHandler), type(uint256).max);
        vm.prank(OTHER);
        token.approve(address(tropykusHandler), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                   HOP 1 MISMATCH REVERTS THE DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_create_revertsWhenTransferFeeTakesACut() public {
        uint256 otherIdleBefore = _createIdle(OTHER, MIN_PURCHASE_AMOUNT);
        token.setFeeBps(FEE_BPS);
        uint256 userBefore = token.balanceOf(USER);

        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(ITokenHandler.TokenHandler__DepositAmountMismatch.selector, REQUESTED, RECEIVED)
        );
        dcaManager.createDcaSchedule(address(token), REQUESTED, RECEIVED, MIN_PURCHASE_PERIOD, IDLE_INDEX);

        // Full rollback: no schedule, no idle credit, no cash moved, no transfer fee paid.
        assertEq(dcaManager.getDcaSchedules(USER, address(token)).length, 0);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), 0);
        assertEq(token.balanceOf(USER), userBefore);
        assertEq(token.balanceOf(FOT_FEE_RECIPIENT), 0);

        // Another user's funds are untouched.
        assertEq(idleHandler.getUsersIdleTokenBalance(OTHER), otherIdleBefore);
        assertEq(dcaManager.getDcaSchedules(OTHER, address(token))[0].tokenBalance, otherIdleBefore);
    }

    function test_depositToken_revertsWhenTransferFeeTakesACut() public {
        uint256 otherIdleBefore = _createIdle(OTHER, MIN_PURCHASE_AMOUNT);
        uint64 scheduleId = _createIdleSchedule(USER, MIN_PURCHASE_AMOUNT, IDLE_INDEX);

        token.setFeeBps(FEE_BPS);
        uint256 userBefore = token.balanceOf(USER);

        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(ITokenHandler.TokenHandler__DepositAmountMismatch.selector, REQUESTED, RECEIVED)
        );
        dcaManager.depositToken(scheduleId, REQUESTED);

        // The first, fee-free deposit survives; the second one credits nothing at all.
        assertEq(dcaManager.getDcaSchedules(USER, address(token))[0].tokenBalance, REQUESTED);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), REQUESTED);
        assertEq(token.balanceOf(USER), userBefore);
        assertEq(token.balanceOf(FOT_FEE_RECIPIENT), 0);
        assertEq(idleHandler.getUsersIdleTokenBalance(OTHER), otherIdleBefore);
    }

    function test_zeroReceivedDeposit_revertsWithTheSameError() public {
        token.setFeeBps(BPS_DIVISOR);
        uint256 userBefore = token.balanceOf(USER);

        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(ITokenHandler.TokenHandler__DepositAmountMismatch.selector, REQUESTED, 0)
        );
        dcaManager.createDcaSchedule(address(token), REQUESTED, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, IDLE_INDEX);

        assertEq(dcaManager.getDcaSchedules(USER, address(token)).length, 0);
        assertEq(token.balanceOf(USER), userBefore);
    }

    function test_create_revertsWhenTransferCreditsMoreThanRequested() public {
        uint256 extra = 1 ether;
        token.setExtraCredit(extra);
        uint256 userBefore = token.balanceOf(USER);

        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenHandler.TokenHandler__DepositAmountMismatch.selector, REQUESTED, REQUESTED + extra
            )
        );
        dcaManager.createDcaSchedule(address(token), REQUESTED, REQUESTED, MIN_PURCHASE_PERIOD, IDLE_INDEX);

        assertEq(dcaManager.getDcaSchedules(USER, address(token)).length, 0);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), 0);
        assertEq(token.balanceOf(USER), userBefore);
    }

    function test_create_lending_revertsBeforeMintingAnyShares() public {
        token.setFeeBps(FEE_BPS);
        uint256 userBefore = token.balanceOf(USER);

        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(ITokenHandler.TokenHandler__DepositAmountMismatch.selector, REQUESTED, RECEIVED)
        );
        dcaManager.createDcaSchedule(address(token), REQUESTED, RECEIVED, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);

        // Hop 2 never runs, so the lending market sees neither cash nor a share mint.
        assertEq(dcaManager.getDcaSchedules(USER, address(token)).length, 0);
        assertEq(tropykusHandler.getUserShares(USER), 0);
        assertEq(token.balanceOf(address(kToken)), 0);
        assertEq(token.balanceOf(USER), userBefore);
    }

    /*//////////////////////////////////////////////////////////////
                        1:1 DEPOSITS ARE UNCHANGED
    //////////////////////////////////////////////////////////////*/

    function test_create_creditsRequested_whenTokenIsOneToOne() public {
        uint256 otherIdleBefore = _createIdle(OTHER, MIN_PURCHASE_AMOUNT);
        uint256 userBefore = token.balanceOf(USER);

        vm.prank(USER);
        dcaManager.createDcaSchedule(address(token), REQUESTED, REQUESTED, MIN_PURCHASE_PERIOD, IDLE_INDEX);

        IDcaManager.DcaSchedule memory schedule = dcaManager.getDcaSchedules(USER, address(token))[0];
        assertEq(schedule.tokenBalance, REQUESTED);
        assertEq(schedule.purchaseAmount, REQUESTED);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), REQUESTED);
        assertEq(token.balanceOf(USER), userBefore - REQUESTED);
        assertEq(idleHandler.getUsersIdleTokenBalance(OTHER), otherIdleBefore);
    }

    function test_depositToken_creditsRequested_whenTokenIsOneToOne() public {
        uint64 scheduleId = _createIdleSchedule(USER, MIN_PURCHASE_AMOUNT, IDLE_INDEX);
        uint256 userBefore = token.balanceOf(USER);

        vm.prank(USER);
        dcaManager.depositToken(scheduleId, REQUESTED);

        assertEq(dcaManager.getDcaSchedules(USER, address(token))[0].tokenBalance, REQUESTED * 2);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), REQUESTED * 2);
        assertEq(token.balanceOf(USER), userBefore - REQUESTED);
    }

    /*//////////////////////////////////////////////////////////////
              A LISTED TOKEN THAT TURNS ITS FEE ON LATER
    //////////////////////////////////////////////////////////////*/

    function test_buyAndWithdraw_keepIdleBooksInLockstep() public {
        uint256 otherIdleBefore = _createIdle(OTHER, MIN_PURCHASE_AMOUNT);
        uint64 scheduleId = _createIdleSchedule(USER, MIN_PURCHASE_AMOUNT, IDLE_INDEX);

        // The deposit already landed 1:1; the token only starts charging afterwards.
        token.setFeeBps(FEE_BPS);

        vm.prank(SWAPPER);
        batchBuyOne(dcaManager, USER, address(token), scheduleId, IDLE_INDEX);

        uint256 afterBuy = REQUESTED - MIN_PURCHASE_AMOUNT;
        assertEq(dcaManager.getDcaSchedules(USER, address(token))[0].tokenBalance, afterBuy);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), afterBuy);
        assertGt(dcaManager.getAccumulatedRbtcBalance(USER, address(token), IDLE_INDEX), 0);

        uint256 userBalanceBefore = token.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(scheduleId, afterBuy);

        // R20: principal falls by the requested amount even if outbound FOT pays the user less.
        assertEq(dcaManager.getDcaSchedules(USER, address(token))[0].tokenBalance, 0);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), 0);
        assertLt(token.balanceOf(USER) - userBalanceBefore, afterBuy);
        assertGt(token.balanceOf(USER), userBalanceBefore);
        assertEq(idleHandler.getUsersIdleTokenBalance(OTHER), otherIdleBefore);
    }

    function test_deleteDcaSchedule_reportsHandlerSpent_notUserReceived() public {
        uint64 scheduleId = _createIdleSchedule(USER, MIN_PURCHASE_AMOUNT, IDLE_INDEX);
        token.setFeeBps(FEE_BPS);

        uint256 userBefore = token.balanceOf(USER);
        vm.expectEmit(true, true, true, true, address(idleHandler));
        emit ITokenHandler.TokenHandler__TokenWithdrawn(address(token), USER, REQUESTED);
        vm.expectEmit(true, true, true, true, address(dcaManager));
        emit IDcaManager.DcaManager__DcaScheduleDeleted(USER, address(token), scheduleId, REQUESTED);
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(scheduleId);

        assertEq(idleHandler.getUsersIdleTokenBalance(USER), 0);
        uint256 userGained = token.balanceOf(USER) - userBefore;
        assertLt(userGained, REQUESTED);
        assertGt(userGained, 0);
    }

    /*//////////////////////////////////////////////////////////////
             HOP 2: A LENDING MARKET THAT CREDITS LESS CASH
    //////////////////////////////////////////////////////////////*/

    function test_create_tropykus_creditsHop1_shareBookIsSecondHop() public {
        kToken.setMintShortfallBps(FEE_BPS);
        uint256 otherUnderlyingBefore = _createTropykus(OTHER, MIN_PURCHASE_AMOUNT);
        uint256 userBefore = token.balanceOf(USER);

        vm.prank(USER);
        dcaManager.createDcaSchedule(address(token), REQUESTED, REQUESTED, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);

        IDcaManager.DcaSchedule memory schedule = dcaManager.getDcaSchedules(USER, address(token))[0];
        assertEq(schedule.tokenBalance, REQUESTED);
        uint256 userUnderlying = _tropykusUnderlying(USER);
        assertApproxEqAbs(userUnderlying, _afterShortfall(REQUESTED), LENDING_ROUNDING_SLACK);
        assertLt(userUnderlying, REQUESTED);
        assertEq(token.balanceOf(USER), userBefore - REQUESTED);
        assertApproxEqAbs(_tropykusUnderlying(OTHER), otherUnderlyingBefore, LENDING_ROUNDING_SLACK);
        assertEq(dcaManager.getDcaSchedules(OTHER, address(token))[0].tokenBalance, REQUESTED);
    }

    function test_depositTwice_tropykus_hop1Sums_underlyingLags() public {
        kToken.setMintShortfallBps(FEE_BPS);
        uint64 scheduleId = _createTropykusSchedule(USER, MIN_PURCHASE_AMOUNT);

        vm.prank(USER);
        dcaManager.depositToken(scheduleId, REQUESTED);
        vm.prank(USER);
        dcaManager.depositToken(scheduleId, REQUESTED);

        assertEq(dcaManager.getDcaSchedules(USER, address(token))[0].tokenBalance, REQUESTED * 3);
        uint256 userUnderlying = _tropykusUnderlying(USER);
        assertApproxEqAbs(userUnderlying, _afterShortfall(REQUESTED) * 3, LENDING_ROUNDING_SLACK);
        assertLt(userUnderlying, REQUESTED * 3);
    }

    function test_tropykus_withdraw_stillWorksWhenShareBookLags() public {
        kToken.setMintShortfallBps(FEE_BPS);
        uint64 scheduleId = _createTropykusSchedule(USER, MIN_PURCHASE_AMOUNT);

        uint256 userBefore = token.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(scheduleId, REQUESTED);

        assertEq(dcaManager.getDcaSchedules(USER, address(token))[0].tokenBalance, 0);
        assertApproxEqAbs(_tropykusUnderlying(USER), 0, LENDING_ROUNDING_SLACK);
        uint256 userGained = token.balanceOf(USER) - userBefore;
        assertApproxEqAbs(userGained, _afterShortfall(REQUESTED), LENDING_ROUNDING_SLACK);
        assertLt(userGained, REQUESTED);
    }

    function test_tropykus_batchBuy_ofOverstatedBalance_reverts() public {
        kToken.setMintShortfallBps(FEE_BPS);
        uint64 scheduleId = _createTropykusSchedule(USER, REQUESTED);

        address[] memory buyers = new address[](1);
        buyers[0] = USER;
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        uint64[] memory ids = new uint64[](1);
        ids[0] = scheduleId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = REQUESTED;

        uint256 availableShares = tropykusHandler.getUserShares(USER);
        uint256 rate = kToken.exchangeRateStored();
        uint256 requestedShares = (REQUESTED * EXCHANGE_RATE_DECIMALS + rate - 1) / rate;
        vm.prank(SWAPPER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenLending.TokenLending__InsufficientShares.selector, USER, requestedShares, availableShares
            )
        );
        dcaManager.batchBuyRbtc(toBatch(ids, buyers, address(token), TROPYKUS_INDEX));

        // Revert leaves the schedule intact; the lending clamp still lets the user withdraw.
        assertEq(dcaManager.getDcaSchedules(USER, address(token))[0].tokenBalance, REQUESTED);
        uint256 userBefore = token.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(scheduleId, REQUESTED);
        assertEq(dcaManager.getDcaSchedules(USER, address(token))[0].tokenBalance, 0);
        assertGt(token.balanceOf(USER), userBefore);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _createIdleSchedule(address who, uint256 purchaseAmount, uint256 routeIndex)
        private
        returns (uint64 scheduleId)
    {
        vm.prank(who);
        dcaManager.createDcaSchedule(address(token), REQUESTED, purchaseAmount, MIN_PURCHASE_PERIOD, routeIndex);
        scheduleId = scheduleIdAt(dcaManager, who, address(token), 0);
    }

    function _createTropykusSchedule(address who, uint256 purchaseAmount) private returns (uint64 scheduleId) {
        vm.prank(who);
        dcaManager.createDcaSchedule(address(token), REQUESTED, purchaseAmount, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        scheduleId = scheduleIdAt(dcaManager, who, address(token), 0);
    }

    function _createIdle(address who, uint256 purchaseAmount) private returns (uint256 credited) {
        _createIdleSchedule(who, purchaseAmount, IDLE_INDEX);
        credited = dcaManager.getDcaSchedules(who, address(token))[0].tokenBalance;
        assertEq(credited, REQUESTED);
        assertEq(idleHandler.getUsersIdleTokenBalance(who), REQUESTED);
    }

    function _createTropykus(address who, uint256 purchaseAmount) private returns (uint256 underlying) {
        _createTropykusSchedule(who, purchaseAmount);
        assertEq(dcaManager.getDcaSchedules(who, address(token))[0].tokenBalance, REQUESTED);
        underlying = _tropykusUnderlying(who);
        assertApproxEqAbs(underlying, _afterShortfall(REQUESTED), LENDING_ROUNDING_SLACK);
        assertLt(underlying, REQUESTED);
    }

    function _afterShortfall(uint256 amount) private pure returns (uint256) {
        return amount * (BPS_DIVISOR - FEE_BPS) / BPS_DIVISOR;
    }

    function _tropykusUnderlying(address who) private view returns (uint256) {
        uint256 shares = tropykusHandler.getUserShares(who);
        uint256 rate = kToken.exchangeRateStored();
        return shares * rate / EXCHANGE_RATE_DECIMALS;
    }
}
