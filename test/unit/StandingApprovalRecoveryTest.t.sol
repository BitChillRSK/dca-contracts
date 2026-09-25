// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SovrynDocHandlerMoc} from "src/sovryn/SovrynDocHandlerMoc.sol";
import {SovrynErc20HandlerDex} from "src/sovryn/SovrynErc20HandlerDex.sol";
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
 * @title StandingApprovalRecoveryTest
 * @notice R83: that a standing approval cleared from outside the handler is recoverable by anyone, and
 *         that the callback shape keeping the lending allowance out of reach is still absent.
 * @dev The grants are made only in the constructor, so without a restore a cleared allowance would be
 *      terminal on a handler that cannot be upgraded. Runs on every lane — it builds its own handlers and
 *      never reads the lane env. `dcaManager` is this test contract, so the `onlyDcaManager` entry points
 *      are callable directly.
 */
contract StandingApprovalRecoveryTest is Test {
    address internal constant USER = address(0xD0C0);
    address internal constant FEE_COLLECTOR = address(0xFEE);
    /// @dev Neither the owner nor the DcaManager: the restore must work for a passer-by.
    address internal constant STRANGER = address(0x5747A);
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

    /// @dev The only shipped shape that holds both approvals at once, so it has two functions to call.
    MockIsusdToken internal bothHalvesISusd;
    SovrynErc20HandlerDex internal bothHalvesHandler;

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
            _feeSettings(),
            address(this)
        );

        wrBtc = new MockWrbtcToken();
        router = new MockSwapRouter02(wrBtc, BTC_PRICE);
        oracle = new MockMocOracle();
        vm.deal(address(router), 1000 ether);

        dexHandler = new IdleErc20HandlerDex(
            address(this),
            address(docToken),
            _uniswapSettings(),
            FEE_COLLECTOR,
            _feeSettings(),
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            address(this)
        );

        bothHalvesISusd = new MockIsusdToken(address(docToken));
        bothHalvesHandler = new SovrynErc20HandlerDex(
            address(this),
            address(docToken),
            address(bothHalvesISusd),
            _uniswapSettings(),
            FEE_COLLECTOR,
            _feeSettings(),
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            address(this)
        );

        docToken.mint(USER, 20 * DEPOSIT_AMOUNT);
        vm.startPrank(USER);
        docToken.approve(address(handler), type(uint256).max);
        docToken.approve(address(dexHandler), type(uint256).max);
        docToken.approve(address(bothHalvesHandler), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice A lending MoC leaf approves its lending spender and nobody else.
    function test_lendingMocLeaf_approvesOnlyItsLendingSpender() public {
        assertEq(docToken.allowance(address(handler), address(iSusdToken)), type(uint256).max);
        assertEq(docToken.allowance(address(handler), address(mocProxy)), 0, "MoC redemption needs no allowance");
        assertEq(
            docToken.allowance(address(handler), address(0)), 0, "the approval ran before the spender was assigned"
        );
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

    /**
     * @notice A cleared lending allowance stops deposits, and any caller can put it back.
     * @dev The failed deposit is the negative control: without it, the restore below would pass on a
     *      path that was never broken.
     */
    function test_clearedLendingAllowance_stopsDepositsUntilAnyoneRestoresIt() public {
        vm.prank(address(handler));
        docToken.approve(address(iSusdToken), 0);

        (bool deposited,) = address(handler).call(abi.encodeCall(handler.depositToken, (USER, DEPOSIT_AMOUNT)));
        assertFalse(deposited, "a cleared allowance should stop the deposit, not pass silently");

        vm.prank(STRANGER);
        handler.restoreLendingApproval();

        assertEq(
            docToken.allowance(address(handler), address(iSusdToken)),
            type(uint256).max,
            "the standing allowance should be back at max"
        );
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        assertGt(handler.getUserShares(USER), 0, "the deposit path should be live again");
    }

    /**
     * @notice A cleared router allowance stops buys, and any caller can put it back.
     * @dev The failed batch is the negative control, as above.
     */
    function test_clearedRouterAllowance_stopsBuysUntilAnyoneRestoresIt() public {
        dexHandler.depositToken(USER, DEPOSIT_AMOUNT);

        vm.prank(address(dexHandler));
        docToken.approve(address(router), 0);

        (bool bought,) = address(dexHandler)
            .call(abi.encodeCall(IPurchaseRbtc.batchBuyRbtc, (_buyers(), _scheduleIds(), _amounts(), 0)));
        assertFalse(bought, "a cleared allowance should stop the buy, not pass silently");

        vm.prank(STRANGER);
        dexHandler.restoreSwapRouterApproval();

        handlerBatchBuyOne(IPurchaseRbtc(address(dexHandler)), USER, SCHEDULE_ID, PURCHASE_AMOUNT);
        assertGt(dexHandler.getAccumulatedRbtcBalance(USER), 0, "the buy path should be live again");
    }

    /// @notice On a handler that lends and swaps, each approval is restored by its own function.
    function test_lendingDexLeaf_restoresEachApprovalThroughItsOwnFunction() public {
        vm.startPrank(address(bothHalvesHandler));
        docToken.approve(address(bothHalvesISusd), 0);
        docToken.approve(address(router), 0);
        vm.stopPrank();

        vm.startPrank(STRANGER);
        bothHalvesHandler.restoreLendingApproval();
        bothHalvesHandler.restoreSwapRouterApproval();
        vm.stopPrank();

        assertEq(
            docToken.allowance(address(bothHalvesHandler), address(bothHalvesISusd)),
            type(uint256).max,
            "the lending approval was not restored"
        );
        assertEq(
            docToken.allowance(address(bothHalvesHandler), address(router)),
            type(uint256).max,
            "the router approval was not restored"
        );
    }

    /**
     * @notice Restoring an allowance that is already whole changes nothing, however often it is called.
     * @dev Both functions are unpermissioned, so they are callable in any state and at any rate.
     */
    function test_restoringAnIntactApprovalIsIdempotent() public {
        vm.startPrank(STRANGER);
        bothHalvesHandler.restoreLendingApproval();
        bothHalvesHandler.restoreLendingApproval();
        bothHalvesHandler.restoreSwapRouterApproval();
        bothHalvesHandler.restoreSwapRouterApproval();
        vm.stopPrank();

        assertEq(docToken.allowance(address(bothHalvesHandler), address(bothHalvesISusd)), type(uint256).max);
        assertEq(docToken.allowance(address(bothHalvesHandler), address(router)), type(uint256).max);
    }

    /**
     * @notice A lending handler answers no flash-loan callback, which is what bounds its standing
     *         allowance to its own deposits.
     * @dev Aave-style pools repay a flash loan from the caller-named `receiverAddress`, so an approver
     *      that answers `executeOperation` pays a stranger's premium.
     */
    function test_handlerAnswersNoFlashLoanCallback() public {
        (bool answered,) = address(handler)
            .call(
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

        (bool fellThrough,) = address(handler).call(abi.encodeWithSignature("someUnknownHook()"));
        assertFalse(fellThrough, "the handler has a fallback");

        // Native rBTC still arrives, so the refusal above is the missing hook and not a dead contract.
        vm.deal(address(this), 1 ether);
        (bool received,) = address(handler).call{value: 1 ether}("");
        assertTrue(received, "the handler should still accept native rBTC");
    }

    function _uniswapSettings() private view returns (IPurchaseUniswap.UniswapSettings memory) {
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;
        return IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(address(wrBtc)),
            swapRouter02: IUniswapV3SwapRouter(address(router)),
            swapIntermediateTokens: new address[](0),
            swapPoolFeeRates: poolFeeRates,
            mocOracle: ICoinPairPrice(address(oracle))
        });
    }

    function _feeSettings() private pure returns (IFeeHandler.FeeSettings memory) {
        return IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });
    }

    /// @dev The one-buyer batch `handlerBatchBuyOne` builds, spelled out so the call can be low-level.
    function _buyers() private pure returns (address[] memory buyers) {
        buyers = new address[](1);
        buyers[0] = USER;
    }

    function _scheduleIds() private pure returns (uint64[] memory scheduleIds) {
        scheduleIds = new uint64[](1);
        scheduleIds[0] = SCHEDULE_ID;
    }

    function _amounts() private pure returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = PURCHASE_AMOUNT;
    }
}
