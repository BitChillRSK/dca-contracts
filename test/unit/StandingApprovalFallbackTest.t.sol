// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SovrynDocHandlerMoc} from "src/sovryn/SovrynDocHandlerMoc.sol";
import {IdleErc20HandlerDex} from "src/idle/IdleErc20HandlerDex.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IUniswapV3SwapRouter} from "src/interfaces/IUniswapV3SwapRouter.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {MockMocOracle} from "test/mocks/MockMocOracle.sol";
import {MockSwapRouter02} from "test/mocks/MockSwapRouter02.sol";
import {MockWrbtcToken} from "test/mocks/MockWrbtcToken.sol";
import {handlerBatchBuyOne} from "test/utils/BatchBuyOne.sol";
import {MockDecrementingStablecoin} from "test/mocks/MockDecrementingStablecoin.sol";
import {MockIsusdToken} from "test/mocks/MockIsusdToken.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import "test/Constants.sol";

/**
 * @title StandingApprovalFallbackTest
 * @notice The deposit path's allowance top-up on a decrementing stablecoin, and the callback shape that
 *         keeps a standing lending allowance out of reach.
 * @dev The standing approval granted at construction is what every deposit normally spends, so the
 *      top-up in `LendingErc20Handler._depositToken` only fires for a token that decrements far enough
 *      to fall short. Runs on every lane: it builds its own handler and never reads the lane env.
 *      `dcaManager` is this test contract so the `onlyDcaManager` entry points are callable directly.
 */
contract StandingApprovalFallbackTest is Test {
    address internal constant USER = address(0xD0C0);
    address internal constant FEE_COLLECTOR = address(0xFEE);
    uint256 internal constant DEPOSIT_AMOUNT = 500 ether;
    uint256 internal constant PURCHASE_AMOUNT = 100 ether;
    uint64 internal constant SCHEDULE_ID = 1;

    MockDecrementingStablecoin internal docToken;
    MockIsusdToken internal iSusdToken;
    MockMocProxy internal mocProxy;
    SovrynDocHandlerMoc internal handler;

    MockWrbtcToken internal wrBtc;
    MockSwapRouter02 internal router;
    MockMocOracle internal oracle;
    IdleErc20HandlerDex internal dexHandler;

    function setUp() public {
        docToken = new MockDecrementingStablecoin(address(this));
        iSusdToken = new MockIsusdToken(address(docToken));
        mocProxy = new MockMocProxy(address(docToken));

        handler = new SovrynDocHandlerMoc(
            address(this),
            address(docToken),
            address(iSusdToken),
            FEE_COLLECTOR,
            address(mocProxy),
            IFeeHandler.FeeSettings({
                minFeeRate: MIN_FEE_RATE,
                maxFeeRate: MAX_FEE_RATE_TEST,
                feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
                feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
            }),
            address(this)
        );

        wrBtc = new MockWrbtcToken();
        router = new MockSwapRouter02(wrBtc, BTC_PRICE);
        oracle = new MockMocOracle();
        vm.deal(address(router), 1000 ether);

        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;
        dexHandler = new IdleErc20HandlerDex(
            address(this),
            address(docToken),
            IPurchaseUniswap.UniswapSettings({
                wrBtcToken: IWRBTC(address(wrBtc)),
                swapRouter02: IUniswapV3SwapRouter(address(router)),
                swapIntermediateTokens: new address[](0),
                swapPoolFeeRates: poolFeeRates,
                mocOracle: ICoinPairPrice(address(oracle))
            }),
            FEE_COLLECTOR,
            IFeeHandler.FeeSettings({
                minFeeRate: MIN_FEE_RATE,
                maxFeeRate: MAX_FEE_RATE_TEST,
                feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
                feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
            }),
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            address(this)
        );

        docToken.mint(USER, 20 * DEPOSIT_AMOUNT);
        vm.startPrank(USER);
        docToken.approve(address(handler), type(uint256).max);
        docToken.approve(address(dexHandler), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice A decrementing token still deposits against the standing approval, which just shrinks.
    function test_decrementingToken_spendsTheStandingApproval() public {
        assertEq(docToken.allowance(address(handler), address(iSusdToken)), type(uint256).max);

        handler.depositToken(USER, DEPOSIT_AMOUNT);

        assertEq(
            docToken.allowance(address(handler), address(iSusdToken)),
            type(uint256).max - DEPOSIT_AMOUNT,
            "the standing allowance should have been spent, not rewritten"
        );
        assertGt(handler.getUserShares(USER), 0);
    }

    /// @notice An allowance that no longer covers the deposit is repaired back to `max`, and the deposit lands.
    function test_shortAllowance_isRepairedByTheDeposit() public {
        vm.prank(address(handler));
        docToken.approve(address(iSusdToken), DEPOSIT_AMOUNT - 1); // one wei short of the next deposit

        handler.depositToken(USER, DEPOSIT_AMOUNT);

        assertGt(handler.getUserShares(USER), 0, "the repair should have let the deposit through");
        assertEq(
            docToken.allowance(address(handler), address(iSusdToken)),
            type(uint256).max - DEPOSIT_AMOUNT,
            "the repair should restore the standing max, not just this deposit"
        );
    }

    /**
     * @notice An allowance cleared from outside the handler recovers on the next deposit, with no
     *         operator action and no redeploy.
     * @dev The grant happens only in the constructor, so without the repair this state would be
     *      terminal. It is reachable: two of the three shipped stablecoins sit behind upgradeable
     *      proxies, and this handler cannot stop one of them clearing an allowance.
     */
    function test_clearedAllowance_recoversWithoutOperatorAction() public {
        vm.prank(address(handler));
        docToken.approve(address(iSusdToken), 0);

        handler.depositToken(USER, DEPOSIT_AMOUNT);

        assertGt(handler.getUserShares(USER), 0, "a cleared allowance bricked the deposit path");
        assertEq(
            docToken.allowance(address(handler), address(iSusdToken)),
            type(uint256).max - DEPOSIT_AMOUNT,
            "the standing allowance should be back"
        );
    }

    /**
     * @notice A lending handler answers no flash-loan callback, which is what bounds its standing
     *         allowance to its own deposits.
     * @dev Aave-style pools repay a flash loan from the caller-named `receiverAddress`, so an approver
     *      that answers `executeOperation` pays a stranger's premium. Declaring neither that nor a
     *      `fallback` is the precondition the leaf headers carry.
     */
    function test_handlerAnswersNoFlashLoanCallback() public {
        (bool answered,) = address(handler).call(
            abi.encodeWithSignature(
                "executeOperation(address,uint256,uint256,address,bytes)",
                address(docToken),
                DEPOSIT_AMOUNT,
                0,
                address(this),
                ""
            )
        );
        assertFalse(answered, "the handler answered a flash-loan callback");

        // Nor does it accept unknown calldata through a fallback, which would decode as a false return.
        (bool fellThrough,) = address(handler).call(abi.encodeWithSignature("someUnknownHook()"));
        assertFalse(fellThrough, "the handler has a fallback");

        // Native rBTC still arrives, so the refusal above is the missing hook and not a dead contract.
        vm.deal(address(this), 1 ether);
        (bool received,) = address(handler).call{value: 1 ether}("");
        assertTrue(received, "the handler should still accept native rBTC");
    }

    /**
     * @notice The router allowance recovers the same way, so a cleared allowance does not brick buys.
     * @dev This is the half with no second line of defence: before the standing approval, every purchase
     *      re-approved the router, so a cleared allowance healed on the next buy. Granting once in the
     *      constructor removed that, and the repair in `_purchaseRbtc` is what puts it back.
     */
    function test_clearedRouterAllowance_recoversOnTheNextPurchase() public {
        dexHandler.depositToken(USER, DEPOSIT_AMOUNT);

        vm.prank(address(dexHandler));
        docToken.approve(address(router), 0);

        handlerBatchBuyOne(IPurchaseRbtc(address(dexHandler)), USER, SCHEDULE_ID, PURCHASE_AMOUNT);

        assertGt(dexHandler.getAccumulatedRbtcBalance(USER), 0, "a cleared allowance bricked the buy path");
        assertGt(
            docToken.allowance(address(dexHandler), address(router)),
            PURCHASE_AMOUNT,
            "the standing router allowance should be back"
        );
    }
}
