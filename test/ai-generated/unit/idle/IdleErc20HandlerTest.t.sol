// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {HandlerTestHarness} from "../HandlerTestHarness.t.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {IdleErc20Handler} from "src/idle/IdleErc20Handler.sol";
import {IIdleErc20Handler} from "src/idle/IIdleErc20Handler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "script/Constants.sol";

/**
 * @title IdleErc20HandlerTest
 * @notice Unit tests for idle (non-lending) deposit/withdraw accounting.
 */
contract IdleErc20HandlerTest is HandlerTestHarness {
    IdleTestHandler public idleHandler;

    function deployHandler() internal override returns (ITokenHandler) {
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        idleHandler = new IdleTestHandler(address(dcaManager), address(stablecoin), FEE_COLLECTOR, feeSettings);
        return ITokenHandler(address(idleHandler));
    }

    function getLendingProtocolIndex() internal pure override returns (uint256) {
        return IDLE_INDEX;
    }

    function isDexHandler() internal pure override returns (bool) {
        return false;
    }

    function isLendingHandler() internal pure override returns (bool) {
        return false;
    }

    function getLendingToken() internal pure override returns (IERC20) {
        return IERC20(address(0));
    }

    function setupHandlerSpecifics() internal override {}

    function test_idle_deposit_staysOnHandler() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        assertEq(stablecoin.balanceOf(address(handler)), DEPOSIT_AMOUNT);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), DEPOSIT_AMOUNT);
    }

    function test_idle_withdraw_debitsOnlyCaller() public {
        address other = address(0xBEEF);
        stablecoin.mint(other, DEPOSIT_AMOUNT);
        vm.prank(other);
        stablecoin.approve(address(handler), type(uint256).max);

        vm.startPrank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        handler.depositToken(other, DEPOSIT_AMOUNT);
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);
        vm.stopPrank();

        assertEq(idleHandler.getUsersIdleTokenBalance(USER), DEPOSIT_AMOUNT - WITHDRAWAL_AMOUNT);
        assertEq(idleHandler.getUsersIdleTokenBalance(other), DEPOSIT_AMOUNT);
        assertEq(stablecoin.balanceOf(address(handler)), DEPOSIT_AMOUNT * 2 - WITHDRAWAL_AMOUNT);
    }

    function test_idle_withdraw_clampsToOwnBalance() public {
        address other = address(0xBEEF);
        stablecoin.mint(other, DEPOSIT_AMOUNT);
        vm.prank(other);
        stablecoin.approve(address(handler), type(uint256).max);

        vm.startPrank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        handler.depositToken(other, DEPOSIT_AMOUNT);

        uint256 userBalanceBefore = stablecoin.balanceOf(USER);
        vm.expectEmit(true, false, false, true, address(handler));
        emit IIdleErc20Handler.IdleErc20Handler__AmountAdjusted(USER, DEPOSIT_AMOUNT * 2, DEPOSIT_AMOUNT);
        handler.withdrawToken(USER, DEPOSIT_AMOUNT * 2);
        vm.stopPrank();

        assertEq(stablecoin.balanceOf(USER), userBalanceBefore + DEPOSIT_AMOUNT);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), 0);
        assertEq(idleHandler.getUsersIdleTokenBalance(other), DEPOSIT_AMOUNT);
        assertEq(stablecoin.balanceOf(address(handler)), DEPOSIT_AMOUNT);
        assertEq(stablecoin.balanceOf(other), 0);
    }

    function test_idle_retrieveStablecoin_clampsToOwnBalance() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        vm.expectEmit(true, false, false, true, address(handler));
        emit IIdleErc20Handler.IdleErc20Handler__AmountAdjusted(USER, DEPOSIT_AMOUNT * 2, DEPOSIT_AMOUNT);
        uint256 retrieved = idleHandler.testRetrieveStablecoin(USER, DEPOSIT_AMOUNT * 2);

        assertEq(retrieved, DEPOSIT_AMOUNT);
        assertEq(idleHandler.getUsersIdleTokenBalance(USER), 0);
        // DOC stays on the handler until a purchase or withdraw moves it
        assertEq(stablecoin.balanceOf(address(handler)), DEPOSIT_AMOUNT);
    }

    function test_idle_withdraw_revertsWhenIdleIsZero() public {
        vm.prank(address(dcaManager));
        vm.expectRevert(
            abi.encodeWithSelector(IIdleErc20Handler.IdleErc20Handler__ZeroStablecoinPaid.selector, DEPOSIT_AMOUNT)
        );
        handler.withdrawToken(USER, DEPOSIT_AMOUNT);
    }

    function test_idle_batchRetrieveStablecoin_revertsIfInsufficient() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        stablecoin.mint(user1, DEPOSIT_AMOUNT);
        stablecoin.mint(user2, DEPOSIT_AMOUNT);
        vm.prank(user1);
        stablecoin.approve(address(handler), type(uint256).max);
        vm.prank(user2);
        stablecoin.approve(address(handler), type(uint256).max);

        vm.startPrank(address(dcaManager));
        handler.depositToken(user1, DEPOSIT_AMOUNT);
        handler.depositToken(user2, DEPOSIT_AMOUNT);
        vm.stopPrank();

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = DEPOSIT_AMOUNT * 2;
        amounts[1] = DEPOSIT_AMOUNT / 2;

        vm.expectRevert(
            abi.encodeWithSelector(
                IIdleErc20Handler.IdleErc20Handler__InsufficientIdleBalance.selector,
                user1,
                DEPOSIT_AMOUNT * 2,
                DEPOSIT_AMOUNT
            )
        );
        idleHandler.testBatchRetrieveStablecoin(users, amounts, amounts[0] + amounts[1]);

        assertEq(idleHandler.getUsersIdleTokenBalance(user1), DEPOSIT_AMOUNT);
        assertEq(idleHandler.getUsersIdleTokenBalance(user2), DEPOSIT_AMOUNT);
    }
}

/**
 * @title IdleTestHandler
 * @notice Concrete IdleErc20Handler for deposit/withdraw/take unit tests.
 */
contract IdleTestHandler is IdleErc20Handler {
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings
    ) IdleErc20Handler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings) {}

    function testRetrieveStablecoin(address user, uint256 amount) external returns (uint256) {
        return _retrieveStablecoin(user, amount);
    }

    function testBatchRetrieveStablecoin(
        address[] memory users,
        uint256[] memory purchaseAmounts,
        uint256 totalStablecoinAmount
    ) external returns (uint256) {
        return _batchRetrieveStablecoin(users, purchaseAmounts, totalStablecoinAmount);
    }
}
