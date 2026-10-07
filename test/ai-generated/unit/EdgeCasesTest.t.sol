// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockKdocToken} from "test/mocks/MockKdocToken.sol";
import {MockIToken} from "test/mocks/MockIToken.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import {MockMocOracle} from "test/mocks/MockMocOracle.sol";
import {MockSwapRouter02} from "test/mocks/MockSwapRouter02.sol";
import {MockWrbtcToken} from "test/mocks/MockWrbtcToken.sol";
import {TropykusDocHandlerMoc} from "src/tropykus-legacy/TropykusDocHandlerMoc.sol";
import {SovrynDocHandlerMoc} from "src/sovryn/SovrynDocHandlerMoc.sol";
import {TropykusHandlerDex} from "src/tropykus-legacy/TropykusHandlerDex.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
import "test/Constants.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {IUniswapV3SwapRouter} from "../../../src/interfaces/IUniswapV3SwapRouter.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";
import {handlerBatchBuyOne, UNUSED_SCHEDULE_ID} from "../../utils/BatchBuyOne.sol";
import {IPurchaseRbtc} from "../../../src/interfaces/IPurchaseRbtc.sol";

contract EdgeCasesTest is Test {
    /// @dev This direct-call manager fixture has no schedule liabilities.
    function getLockedPrincipal(address, address, address) external pure returns (uint256) {
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                              UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploy common mocks for handlers expecting DOC/kDOC
    function _deployTropykusMocHandler(bool fundProxy)
        internal
        returns (TropykusDocHandlerMoc, MockStablecoin, MockKdocToken, MockMocProxy)
    {
        MockStablecoin doc = new MockStablecoin(address(this));
        MockKdocToken kdoc = new MockKdocToken(address(doc));
        MockMocProxy mocProxy = new MockMocProxy(address(doc));
        if (fundProxy) {
            vm.deal(address(mocProxy), 10 ether);
        }
        TropykusDocHandlerMoc handler = new TropykusDocHandlerMoc(
            address(this), // dcaManager (tests acts as manager)
            address(doc),
            address(kdoc),
            address(0xFEE),
            address(mocProxy),
            IPurchaseFees.FeeSettings({
                minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE_TEST, feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND
            }),
            address(this)
        );
        // Grant handler approvals
        vm.prank(address(handler));
        doc.approve(address(mocProxy), type(uint256).max);
        return (handler, doc, kdoc, mocProxy);
    }

    /*//////////////////////////////////////////////////////////////
                PurchaseMoc – failure branch (no rBTC)
    //////////////////////////////////////////////////////////////*/
    function test_PurchaseMoc_batchBuyRbtc_reverts_when_noRbtcReturned() public {
        (TropykusDocHandlerMoc handler, MockStablecoin doc,,) = _deployTropykusMocHandler(false); // proxy not funded
        address USER = address(0xA0);
        doc.mint(USER, 1000 ether);
        vm.prank(USER);
        doc.approve(address(handler), type(uint256).max);

        // Deposit so the handler owns kDOC → needed for redemption inside batchBuyRbtc
        handler.depositToken(USER, 500 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseRbtc.PurchaseRbtc__RbtcBatchPurchaseFailed.selector, address(doc))
        );
        handlerBatchBuyOne(IPurchaseRbtc(address(handler)), USER, UNUSED_SCHEDULE_ID, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                       PurchaseUniswap setters reverts
    //////////////////////////////////////////////////////////////*/
    function _deployDexHandler()
        internal
        returns (TropykusHandlerDex, MockStablecoin, MockKdocToken, MockSwapRouter02, MockWrbtcToken, MockMocOracle)
    {
        // Stablecoin & kDOC mocks
        MockStablecoin doc = new MockStablecoin(address(this));
        MockKdocToken kdoc = new MockKdocToken(address(doc));
        // WRBTC & router & oracle mocks
        MockWrbtcToken wrbtc = new MockWrbtcToken();
        MockSwapRouter02 router = new MockSwapRouter02(wrbtc, BTC_PRICE); // price intentionally normal
        MockMocOracle oracle = new MockMocOracle();

        IPurchaseUniswap.UniswapSettings memory uniSettings = IPurchaseUniswap.UniswapSettings({
            wrbtc: IWRBTC(address(wrbtc)),
            swapRouter: IUniswapV3SwapRouter(address(router)),
            swapIntermediateTokens: new address[](0),
            swapPoolFeeRates: new uint24[](1), // will be ignored for empty path
            mocOracle: ICoinPairPrice(address(oracle))
        });

        TropykusHandlerDex dex = new TropykusHandlerDex(
            address(this),
            address(doc),
            address(kdoc),
            uniSettings,
            address(0xFEE),
            IPurchaseFees.FeeSettings({
                minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE_TEST, feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND
            }),
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            address(this)
        );

        return (dex, doc, kdoc, router, wrbtc, oracle);
    }

    function test_setPurchasePath_reverts_on_length_mismatch() public {
        (TropykusHandlerDex dex,,,,,) = _deployDexHandler();
        address[] memory tokens = new address[](1);
        tokens[0] = address(0x1);
        uint24[] memory fees = new uint24[](3);
        fees[0] = 3000;
        fees[1] = 3000;
        fees[2] = 3000;
        vm.expectRevert();
        dex.setPurchasePath(tokens, fees);
    }

    function test_setAmountOutMinimumPercent_reverts_when_too_high() public {
        (TropykusHandlerDex dex,,,,,) = _deployDexHandler();
        vm.expectRevert();
        dex.setAmountOutMinimumPercent(1.1 ether);
    }

    function test_setAmountOutMinimumSafetyCheck_reverts_when_too_high() public {
        (TropykusHandlerDex dex,,,,,) = _deployDexHandler();
        vm.expectRevert();
        dex.setAmountOutMinimumSafetyCheck(1.1 ether);
    }

    function test_setMocOracle_reverts_on_zero_address() public {
        (TropykusHandlerDex dex,,,,,) = _deployDexHandler();
        vm.expectRevert();
        dex.setMocOracle(address(0));
    }

    function test_batchBuyRbtc_reverts_on_outdated_oracle() public {
        (TropykusHandlerDex dex, MockStablecoin doc,,,, MockMocOracle oracle) = _deployDexHandler();
        // Invalidate oracle price
        oracle.setInvalidPrice();

        address USER = address(0xC0);
        doc.mint(USER, 1000 ether);
        vm.prank(USER);
        doc.approve(address(dex), type(uint256).max);
        dex.depositToken(USER, 600 ether);

        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__OutdatedPrice.selector);
        handlerBatchBuyOne(IPurchaseRbtc(address(dex)), USER, UNUSED_SCHEDULE_ID, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
               SovrynHandler branch – withdrawInterest early exit
    //////////////////////////////////////////////////////////////*/
    function test_withdrawInterest_returns_early_when_no_interest() public {
        // Mocks
        MockStablecoin doc = new MockStablecoin(address(this));
        MockIToken iToken = new MockIToken(address(doc));
        MockMocProxy proxy = new MockMocProxy(address(doc));
        vm.deal(address(proxy), 10 ether);

        SovrynDocHandlerMoc handler = new SovrynDocHandlerMoc(
            address(this),
            address(doc),
            address(iToken),
            address(0xFEE),
            address(proxy),
            IPurchaseFees.FeeSettings({
                minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE_TEST, feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND
            }),
            address(this)
        );
        // Prepare user deposit
        address USER = address(0xD0);
        doc.mint(USER, 500 ether);
        vm.prank(USER);
        doc.approve(address(handler), type(uint256).max);
        handler.depositToken(USER, 500 ether);

        uint256 userBalanceBefore = doc.balanceOf(USER);
        uint256 contractBalanceBefore = doc.balanceOf(address(handler));

        // Locked amount equals total lending, so function should early return and no state changes
        handler.withdrawInterest(USER, 500 ether);

        assertEq(doc.balanceOf(USER), userBalanceBefore, "unexpected transfer");
        assertEq(doc.balanceOf(address(handler)), contractBalanceBefore, "handler balance changed");
    }
}
