// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {HandlerTestHarness} from "../HandlerTestHarness.t.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";
import {LayerBankErc20HandlerDex} from "src/layerbank/LayerBankErc20HandlerDex.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "test/mocks/MockLayerBank.sol";
import {MockWrbtcToken} from "test/mocks/MockWrbtcToken.sol";
import {MockMocOracle} from "test/mocks/MockMocOracle.sol";
import {MockSwapRouter02} from "test/mocks/MockSwapRouter02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {handlerBatchBuyOne} from "test/utils/BatchBuyOne.sol";
import "script/Constants.sol";

/**
 * @title LayerBankErc20HandlerDexTest
 * @notice Unit tests for LayerBankErc20HandlerDex using the shared handler harness.
 */
contract LayerBankErc20HandlerDexTest is HandlerTestHarness {
    MockLayerBankAToken public aToken;
    MockLayerBankPool public pool;
    MockWrbtcToken public wrbtcToken;
    MockMocOracle public mocOracle;
    MockSwapRouter02 public mockRouter;
    LayerBankErc20HandlerDex public layerbankDexHandler;

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

        layerbankDexHandler = new LayerBankErc20HandlerDex(
            address(dcaManager),
            address(stablecoin),
            address(aToken),
            uniswapSettings,
            FEE_COLLECTOR,
            feeSettings,
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            OWNER
        );

        return ITokenHandler(address(layerbankDexHandler));
    }

    function getRouteIndex() internal pure override returns (uint256) {
        return LAYERBANK_INDEX;
    }

    function isDexHandler() internal pure override returns (bool) {
        return true;
    }

    function isLendingHandler() internal pure override returns (bool) {
        return true;
    }

    function getShareToken() internal view override returns (IERC20) {
        return IERC20(address(aToken));
    }

    function handlerShareBalance() internal view override returns (uint256) {
        return aToken.scaledBalanceOf(address(handler));
    }

    function setupHandlerSpecifics() internal override {
        aToken = new MockLayerBankAToken(address(stablecoin));
        pool = new MockLayerBankPool(aToken);
        aToken.setPool(address(pool));
        wrbtcToken = new MockWrbtcToken();
        mocOracle = new MockMocOracle();
        mockRouter = new MockSwapRouter02(wrbtcToken, BTC_PRICE);
        stablecoin.mint(address(aToken), 1000000 ether);
        vm.deal(address(mockRouter), 1000 ether);
    }

    function test_layerbankDex_depositPurchaseWithdraw() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        uint256 sharesBefore = layerbankDexHandler.getUserShares(USER);
        assertGt(sharesBefore, 0);
        assertEq(stablecoin.balanceOf(address(handler)), 0);

        uint64 scheduleId = 1;
        vm.prank(address(dcaManager));
        handlerBatchBuyOne(IPurchaseRbtc(address(handler)), USER, scheduleId, PURCHASE_AMOUNT);

        uint256 rbtcAccrued = layerbankDexHandler.getAccumulatedRbtcBalance(USER);
        assertGt(rbtcAccrued, 0);
        assertLt(layerbankDexHandler.getUserShares(USER), sharesBefore);

        vm.prank(address(dcaManager));
        layerbankDexHandler.withdrawAccumulatedRbtc(USER);
        assertEq(layerbankDexHandler.getAccumulatedRbtcBalance(USER), 0);
        assertGt(USER.balance, 0);
    }

    /**
     * @notice Virtual scaled books must stay ≤ handler `scaledBalanceOf` after odd-amount
     *         redeems against Aave-like round-nearest `rayDiv` burns. Same property R22
     *         established on the MoC leaf; the dex leaf shares `LayerBankErc20Handler`.
     * @dev Flipping `_stablecoinToShares` to `Rounding.Floor` lets `sum(getUserShares)`
     *      drift above `aToken.scaledBalanceOf(handler)` and fails this test.
     */
    function test_layerbankDex_virtualSharesRoundUp_keepsBooksSolvent() public {
        uint256 awkwardIndex = 1_070_000_000_000_000_000_000_000_123;
        aToken.setNormalizedIncome(awkwardIndex, true);

        address user2 = address(0xBEEF);
        stablecoin.mint(user2, USER_INITIAL_BALANCE);
        vm.prank(user2);
        stablecoin.approve(address(handler), type(uint256).max);

        vm.prank(address(dcaManager));
        handler.depositToken(USER, 5_000 ether);
        vm.prank(address(dcaManager));
        handler.depositToken(user2, 5_000 ether);

        uint256[] memory oddAmounts = new uint256[](12);
        oddAmounts[0] = 1;
        oddAmounts[1] = 3;
        oddAmounts[2] = 7;
        oddAmounts[3] = 11;
        oddAmounts[4] = 13;
        oddAmounts[5] = 17;
        oddAmounts[6] = 1 ether + 1;
        oddAmounts[7] = 1 ether + 3;
        oddAmounts[8] = 3 ether + 7;
        oddAmounts[9] = 7 ether + 1;
        oddAmounts[10] = 25 ether + 1;
        oddAmounts[11] = 100 ether + 13;

        for (uint256 i; i < oddAmounts.length; ++i) {
            vm.prank(address(dcaManager));
            handler.withdrawToken(USER, oddAmounts[i]);
            vm.prank(address(dcaManager));
            handler.withdrawToken(user2, oddAmounts[i] + 2);
        }

        uint256 virtualBooks =
            layerbankDexHandler.getUserShares(USER) + layerbankDexHandler.getUserShares(user2);
        uint256 actualScaled = aToken.scaledBalanceOf(address(handler));
        assertLe(
            virtualBooks,
            actualScaled,
            "round-up sizing must keep virtual scaled shares <= aToken.scaledBalanceOf(handler)"
        );
        assertGt(virtualBooks, 0, "solvency test must leave a live position");
    }
}
