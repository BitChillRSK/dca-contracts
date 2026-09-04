// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {HandlerTestHarness} from "../HandlerTestHarness.t.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {IIdleErc20Handler} from "src/idle/IIdleErc20Handler.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";
import {IdleErc20HandlerDex} from "src/idle/IdleErc20HandlerDex.sol";
import {MockWrbtcToken} from "test/mocks/MockWrbtcToken.sol";
import {MockMocOracle} from "test/mocks/MockMocOracle.sol";
import {MockSwapRouter02} from "test/mocks/MockSwapRouter02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {handlerBatchBuyOne, NO_MIN_RBTC_OUT} from "test/utils/BatchBuyOne.sol";
import "test/Constants.sol";

/**
 * @title IdleErc20HandlerDexTest
 * @notice Unit tests for IdleErc20HandlerDex: deposit → Uniswap batch → withdraw rBTC.
 */
contract IdleErc20HandlerDexTest is HandlerTestHarness {
    MockWrbtcToken public wrbtcToken;
    MockMocOracle public mocOracle;
    MockSwapRouter02 public mockRouter;
    IdleErc20HandlerDex public idleDexHandler;

    function deployHandler() internal override returns (ITokenHandler) {
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        address[] memory intermediateTokens = new address[](0);
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;

        IPurchaseUniswap.UniswapSettings memory uniswapSettings = IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(address(wrbtcToken)),
            swapRouter02: ISwapRouter02(address(mockRouter)),
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracle: ICoinPairPrice(address(mocOracle))
        });

        idleDexHandler = new IdleErc20HandlerDex(
            address(dcaManager),
            address(stablecoin),
            uniswapSettings,
            FEE_COLLECTOR,
            feeSettings,
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            OWNER
        );

        return ITokenHandler(address(idleDexHandler));
    }

    function getRouteIndex() internal pure override returns (uint256) {
        return IDLE_INDEX;
    }

    function isDexHandler() internal pure override returns (bool) {
        return true;
    }

    function isLendingHandler() internal pure override returns (bool) {
        return false;
    }

    function getShareToken() internal pure override returns (IERC20) {
        return IERC20(address(0));
    }

    function setupHandlerSpecifics() internal override {
        wrbtcToken = new MockWrbtcToken();
        mocOracle = new MockMocOracle();
        mockRouter = new MockSwapRouter02(wrbtcToken, BTC_PRICE);
        vm.deal(address(mockRouter), 1000 ether);
    }

    function test_idleDex_depositPurchaseWithdraw() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        assertEq(idleDexHandler.getUsersIdleTokenBalance(USER), DEPOSIT_AMOUNT);
        assertEq(stablecoin.balanceOf(address(handler)), DEPOSIT_AMOUNT);

        uint64 scheduleId = 1;
        vm.prank(address(dcaManager));
        handlerBatchBuyOne(IPurchaseRbtc(address(handler)), USER, scheduleId, PURCHASE_AMOUNT);

        uint256 rbtcAccrued = idleDexHandler.getAccumulatedRbtcBalance(USER);
        assertGt(rbtcAccrued, 0);
        assertEq(idleDexHandler.getUsersIdleTokenBalance(USER), DEPOSIT_AMOUNT - PURCHASE_AMOUNT);
        assertEq(stablecoin.balanceOf(address(handler)), DEPOSIT_AMOUNT - PURCHASE_AMOUNT);

        vm.prank(address(dcaManager));
        idleDexHandler.withdrawAccumulatedRbtc(USER);
        assertEq(idleDexHandler.getAccumulatedRbtcBalance(USER), 0);
        assertGt(USER.balance, 0);
    }

    /// @notice Idle batch retrieval reverts on shortfall (does not clamp). Same rule as the MoC idle
    ///         leaf; a Uniswap batch must not silently change that and dilute other buyers.
    function test_idleDex_batchBuy_revertsIfBuyerShort() public {
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

        address[] memory buyers = new address[](2);
        buyers[0] = user1;
        buyers[1] = user2;
        uint64[] memory scheduleIds = new uint64[](2);
        scheduleIds[0] = 1;
        scheduleIds[1] = 2;
        uint256[] memory purchaseAmounts = new uint256[](2);
        purchaseAmounts[0] = DEPOSIT_AMOUNT * 2;
        purchaseAmounts[1] = DEPOSIT_AMOUNT / 2;

        vm.expectRevert(
            abi.encodeWithSelector(
                IIdleErc20Handler.IdleErc20Handler__InsufficientIdleBalance.selector,
                user1,
                DEPOSIT_AMOUNT * 2,
                DEPOSIT_AMOUNT
            )
        );
        vm.prank(address(dcaManager));
        idleDexHandler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts, NO_MIN_RBTC_OUT);

        assertEq(idleDexHandler.getUsersIdleTokenBalance(user1), DEPOSIT_AMOUNT);
        assertEq(idleDexHandler.getUsersIdleTokenBalance(user2), DEPOSIT_AMOUNT);
        assertEq(idleDexHandler.getAccumulatedRbtcBalance(user1), 0);
        assertEq(idleDexHandler.getAccumulatedRbtcBalance(user2), 0);
    }
}
