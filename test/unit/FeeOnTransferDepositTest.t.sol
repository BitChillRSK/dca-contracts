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
import "../../script/Constants.sol";
import {batchBuyOne} from "../utils/BatchBuyOne.sol";

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
    uint256 internal constant RECEIVED = 99 ether; // hop 1: user → handler
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

        token = new MockFeeOnTransferStablecoin();
        token.setFeeBps(FEE_BPS);
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

    function test_create_creditsReceived_idleBooksMatch() public {
        uint256 otherIdleBefore = _createIdle(OTHER, MIN_PURCHASE_AMOUNT);
        uint256 userSpentBefore = token.balanceOf(USER);

        vm.prank(USER);
        dcaManager.createDcaSchedule(address(token), REQUESTED, RECEIVED, MIN_PURCHASE_PERIOD, IDLE_INDEX);

        IDcaManager.DcaDetails memory schedule = dcaManager.getDcaSchedules(USER, address(token))[0];
        assertEq(schedule.tokenBalance, RECEIVED);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), RECEIVED);
        assertEq(token.balanceOf(USER), userSpentBefore - REQUESTED);
        assertEq(idleHandler.getUsersIdleTokenBalance(OTHER), otherIdleBefore);
        assertEq(dcaManager.getDcaSchedules(OTHER, address(token))[0].tokenBalance, otherIdleBefore);
    }

    function test_depositToken_creditsReceived_notRequested() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(token), REQUESTED, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, IDLE_INDEX);
        bytes32 scheduleId = dcaManager.getDcaSchedules(USER, address(token))[0].scheduleId;

        vm.prank(USER);
        dcaManager.depositToken(address(token), 0, scheduleId, REQUESTED);

        IDcaManager.DcaDetails memory schedule = dcaManager.getDcaSchedules(USER, address(token))[0];
        assertEq(schedule.tokenBalance, RECEIVED * 2);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), RECEIVED * 2);
    }

    function test_create_reverts_whenPurchaseAmountGreaterThanReceived() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__PurchaseAmountExceedsBalance.selector, address(token), REQUESTED, RECEIVED
            )
        );
        dcaManager.createDcaSchedule(address(token), REQUESTED, REQUESTED, MIN_PURCHASE_PERIOD, IDLE_INDEX);
    }

    function test_create_allowsPurchaseAmountEqualToReceived() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(token), REQUESTED, RECEIVED, MIN_PURCHASE_PERIOD, IDLE_INDEX);

        IDcaManager.DcaDetails memory schedule = dcaManager.getDcaSchedules(USER, address(token))[0];
        assertEq(schedule.tokenBalance, RECEIVED);
        assertEq(schedule.purchaseAmount, RECEIVED);
    }

    function test_setPurchaseAmount_reverts_whenGreaterThanReceived() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(token), REQUESTED, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, IDLE_INDEX);
        bytes32 scheduleId = dcaManager.getDcaSchedules(USER, address(token))[0].scheduleId;

        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__PurchaseAmountExceedsBalance.selector, address(token), REQUESTED, RECEIVED
            )
        );
        dcaManager.setPurchaseAmount(address(token), 0, scheduleId, REQUESTED);
    }

    function test_buyAndWithdraw_keepIdleBooksInLockstep() public {
        uint256 otherIdleBefore = _createIdle(OTHER, MIN_PURCHASE_AMOUNT);

        vm.prank(USER);
        dcaManager.createDcaSchedule(address(token), REQUESTED, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, IDLE_INDEX);
        bytes32 scheduleId = dcaManager.getDcaSchedules(USER, address(token))[0].scheduleId;

        vm.prank(SWAPPER);
        batchBuyOne(dcaManager, USER, address(token), 0, scheduleId, MIN_PURCHASE_AMOUNT, IDLE_INDEX);

        uint256 afterBuy = RECEIVED - MIN_PURCHASE_AMOUNT;
        assertEq(dcaManager.getDcaSchedules(USER, address(token))[0].tokenBalance, afterBuy);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), afterBuy);
        assertGt(dcaManager.getAccumulatedRbtcBalance(USER, address(token), IDLE_INDEX), 0);

        uint256 userBalanceBefore = token.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(address(token), 0, scheduleId, afterBuy);

        // R20: principal falls by the requested amount even if outbound FOT pays the user less.
        assertEq(dcaManager.getDcaSchedules(USER, address(token))[0].tokenBalance, 0);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), 0);
        assertLt(token.balanceOf(USER) - userBalanceBefore, afterBuy);
        assertGt(token.balanceOf(USER), userBalanceBefore);
        assertEq(idleHandler.getUsersIdleTokenBalance(OTHER), otherIdleBefore);
    }

    function test_zeroReceivedDeposit_reverts() public {
        token.setFeeBps(10_000);

        vm.prank(USER);
        vm.expectRevert(ITokenHandler.TokenHandler__ZeroStablecoinReceived.selector);
        dcaManager.createDcaSchedule(address(token), REQUESTED, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, IDLE_INDEX);
    }

    function test_create_tropykus_creditsHop1_shareBookIsSecondHop() public {
        uint256 otherUnderlyingBefore = _createTropykus(OTHER, MIN_PURCHASE_AMOUNT);
        uint256 userSpentBefore = token.balanceOf(USER);

        vm.prank(USER);
        dcaManager.createDcaSchedule(address(token), REQUESTED, RECEIVED, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);

        IDcaManager.DcaDetails memory schedule = dcaManager.getDcaSchedules(USER, address(token))[0];
        assertEq(schedule.tokenBalance, RECEIVED);
        uint256 userUnderlying = _tropykusUnderlying(USER);
        assertApproxEqAbs(userUnderlying, _afterFee(RECEIVED), LENDING_ROUNDING_SLACK);
        assertLt(userUnderlying, RECEIVED);
        assertEq(token.balanceOf(USER), userSpentBefore - REQUESTED);
        assertApproxEqAbs(_tropykusUnderlying(OTHER), otherUnderlyingBefore, LENDING_ROUNDING_SLACK);
        assertEq(dcaManager.getDcaSchedules(OTHER, address(token))[0].tokenBalance, RECEIVED);
    }

    function test_depositTwice_tropykus_hop1Sums_underlyingLags() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(token), REQUESTED, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        bytes32 scheduleId = dcaManager.getDcaSchedules(USER, address(token))[0].scheduleId;

        vm.prank(USER);
        dcaManager.depositToken(address(token), 0, scheduleId, REQUESTED);
        vm.prank(USER);
        dcaManager.depositToken(address(token), 0, scheduleId, REQUESTED);

        IDcaManager.DcaDetails memory schedule = dcaManager.getDcaSchedules(USER, address(token))[0];
        assertEq(schedule.tokenBalance, RECEIVED * 3);
        uint256 userUnderlying = _tropykusUnderlying(USER);
        assertApproxEqAbs(userUnderlying, _afterFee(RECEIVED) * 3, LENDING_ROUNDING_SLACK);
        assertLt(userUnderlying, RECEIVED * 3);
    }

    function test_tropykus_withdraw_stillWorksWhenShareBookLags() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(token), REQUESTED, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        bytes32 scheduleId = dcaManager.getDcaSchedules(USER, address(token))[0].scheduleId;

        uint256 userBefore = token.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(address(token), 0, scheduleId, RECEIVED);

        assertEq(dcaManager.getDcaSchedules(USER, address(token))[0].tokenBalance, 0);
        assertApproxEqAbs(_tropykusUnderlying(USER), 0, LENDING_ROUNDING_SLACK);
        assertGt(token.balanceOf(USER), userBefore);
    }

    function test_tropykus_batchBuy_ofOverstatedBalance_reverts() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(token), REQUESTED, RECEIVED, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        bytes32 scheduleId = dcaManager.getDcaSchedules(USER, address(token))[0].scheduleId;

        address[] memory buyers = new address[](1);
        buyers[0] = USER;
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = 0;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = scheduleId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = RECEIVED;

        uint256 availableShares = tropykusHandler.getUserShares(USER);
        uint256 rate = kToken.exchangeRateStored();
        uint256 requestedShares = (RECEIVED * EXCHANGE_RATE_DECIMALS + rate - 1) / rate;
        vm.prank(SWAPPER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenLending.TokenLending__InsufficientShares.selector,
                USER,
                requestedShares,
                availableShares
            )
        );
        dcaManager.batchBuyRbtc(buyers, address(token), indexes, ids, amounts, TROPYKUS_INDEX);

        // Revert leaves the schedule intact; the lending clamp still lets the user withdraw.
        assertEq(dcaManager.getDcaSchedules(USER, address(token))[0].tokenBalance, RECEIVED);
        uint256 userBefore = token.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(address(token), 0, scheduleId, RECEIVED);
        assertEq(dcaManager.getDcaSchedules(USER, address(token))[0].tokenBalance, 0);
        assertGt(token.balanceOf(USER), userBefore);
    }

    function test_deleteDcaSchedule_reportsHandlerSpent_notUserReceived() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(token), REQUESTED, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, IDLE_INDEX);
        bytes32 scheduleId = dcaManager.getDcaSchedules(USER, address(token))[0].scheduleId;

        uint256 userBefore = token.balanceOf(USER);
        vm.expectEmit(true, true, true, true, address(idleHandler));
        emit ITokenHandler.TokenHandler__TokenWithdrawn(address(token), USER, RECEIVED);
        vm.expectEmit(false, false, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__DcaScheduleDeleted(USER, address(token), scheduleId, RECEIVED);
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(token), 0, scheduleId);

        assertEq(idleHandler.getUsersIdleTokenBalance(USER), 0);
        uint256 userGained = token.balanceOf(USER) - userBefore;
        assertLt(userGained, RECEIVED);
        assertGt(userGained, 0);
    }

    function _createIdle(address who, uint256 purchaseAmount) private returns (uint256 received) {
        vm.prank(who);
        dcaManager.createDcaSchedule(address(token), REQUESTED, purchaseAmount, MIN_PURCHASE_PERIOD, IDLE_INDEX);
        received = dcaManager.getDcaSchedules(who, address(token))[0].tokenBalance;
        assertEq(received, RECEIVED);
        assertEq(idleHandler.getUsersIdleTokenBalance(who), RECEIVED);
    }

    function _createTropykus(address who, uint256 purchaseAmount) private returns (uint256 underlying) {
        vm.prank(who);
        dcaManager.createDcaSchedule(address(token), REQUESTED, purchaseAmount, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        assertEq(dcaManager.getDcaSchedules(who, address(token))[0].tokenBalance, RECEIVED);
        underlying = _tropykusUnderlying(who);
        assertApproxEqAbs(underlying, _afterFee(RECEIVED), LENDING_ROUNDING_SLACK);
        assertLt(underlying, RECEIVED);
    }

    function _afterFee(uint256 amount) private pure returns (uint256) {
        return amount * (BPS_DIVISOR - FEE_BPS) / BPS_DIVISOR;
    }

    function _tropykusUnderlying(address who) private view returns (uint256) {
        uint256 shares = tropykusHandler.getUserShares(who);
        uint256 rate = kToken.exchangeRateStored();
        return shares * rate / EXCHANGE_RATE_DECIMALS;
    }
}
