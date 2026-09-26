// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {HandlerTestHarness} from "../HandlerTestHarness.t.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {IdleErc20Handler} from "src/idle/IdleErc20Handler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "test/Constants.sol";

/**
 * @title IdleErc20HandlerTest
 * @notice Unit tests for idle (non-lending) deposit/withdraw accounting after the per-user ledger
 *         removal. Schedule liability lives in DcaManager; this handler only holds pooled cash.
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

        idleHandler = new IdleTestHandler(address(dcaManager), address(stablecoin), FEE_COLLECTOR, feeSettings, OWNER);
        return ITokenHandler(address(idleHandler));
    }

    function getRouteIndex() internal pure override returns (uint256) {
        return IDLE_INDEX;
    }

    function isDexHandler() internal pure override returns (bool) {
        return false;
    }

    function isLendingHandler() internal pure override returns (bool) {
        return false;
    }

    function getShareToken() internal pure override returns (IERC20) {
        return IERC20(address(0));
    }

    function setupHandlerSpecifics() internal override {}

    function test_idle_deposit_staysOnHandler() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        assertEq(stablecoin.balanceOf(address(handler)), DEPOSIT_AMOUNT);
    }

    function test_idle_withdraw_paysRequestedFromPool() public {
        address other = address(0xBEEF);
        stablecoin.mint(other, DEPOSIT_AMOUNT);
        vm.prank(other);
        stablecoin.approve(address(handler), type(uint256).max);

        vm.startPrank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        handler.depositToken(other, DEPOSIT_AMOUNT);
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);
        vm.stopPrank();

        assertEq(stablecoin.balanceOf(address(handler)), DEPOSIT_AMOUNT * 2 - WITHDRAWAL_AMOUNT);
        assertEq(stablecoin.balanceOf(USER), USER_INITIAL_BALANCE - DEPOSIT_AMOUNT + WITHDRAWAL_AMOUNT);
    }

    function test_idle_batchRetrieveStablecoin_sumsPurchaseAmounts() public {
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
        amounts[0] = DEPOSIT_AMOUNT / 2;
        amounts[1] = DEPOSIT_AMOUNT / 4;

        uint256 total = idleHandler.testBatchRetrieveStablecoin(users, amounts);
        assertEq(total, amounts[0] + amounts[1]);
        // Funding is bookkeeping only: cash stays on the handler until MoC / Uniswap spends it.
        assertEq(stablecoin.balanceOf(address(handler)), DEPOSIT_AMOUNT * 2);
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
        FeeSettings memory feeSettings,
        address initialOwner
    ) IdleErc20Handler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, initialOwner) {}

    function testBatchRetrieveStablecoin(address[] calldata users, uint256[] calldata purchaseAmounts)
        external
        returns (uint256)
    {
        return _batchRetrieveStablecoin(users, purchaseAmounts);
    }
}
