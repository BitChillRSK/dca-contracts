// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockKdocToken} from "test/mocks/MockKdocToken.sol";
import {MockIsusdToken} from "test/mocks/MockIsusdToken.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import {MockMocOracle} from "test/mocks/MockMocOracle.sol";
import {MockSwapRouter02} from "test/mocks/MockSwapRouter02.sol";
import {MockWrbtcToken} from "test/mocks/MockWrbtcToken.sol";
import {TropykusDocHandlerMoc} from "src/TropykusDocHandlerMoc.sol";
import {SovrynDocHandlerMoc} from "src/SovrynDocHandlerMoc.sol";
import {TropykusErc20HandlerDex} from "src/TropykusErc20HandlerDex.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import "script/Constants.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";

contract NonPayableReceiver {
    // no receive() / fallback() & no payable functions
}

contract EdgeCasesTest is Test {
    /*//////////////////////////////////////////////////////////////
                              UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploy common mocks for handlers expecting DOC/kDOC
    function _deployTropykusMocHandler(bool fundProxy) internal returns (TropykusDocHandlerMoc, MockStablecoin, MockKdocToken, MockMocProxy) {
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
            MIN_PURCHASE_AMOUNT,
            address(0xFEE),
            address(mocProxy),
            IFeeHandler.FeeSettings({
                minFeeRate: MIN_FEE_RATE,
                maxFeeRate: MAX_FEE_RATE_TEST,
                feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
                feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
            }),
            EXCHANGE_RATE_DECIMALS
        );
        // Grant handler approvals
        vm.prank(address(handler));
        doc.approve(address(mocProxy), type(uint256).max);
        return (handler, doc, kdoc, mocProxy);
    }

    /*//////////////////////////////////////////////////////////////
                PurchaseMoc – failure branch (no rBTC)
    //////////////////////////////////////////////////////////////*/
    function test_PurchaseMoc_buyRbtc_reverts_when_noRbtcReturned() public {
        (TropykusDocHandlerMoc handler, MockStablecoin doc,,) = _deployTropykusMocHandler(false); // proxy not funded
        address USER = address(0xA0);
        doc.mint(USER, 1000 ether);
        vm.prank(USER);
        doc.approve(address(handler), type(uint256).max);

        // Deposit so the handler owns kDOC → needed for redemption inside buyRbtc
        handler.depositToken(USER, 500 ether);

        vm.expectRevert();
        handler.buyRbtc(USER, bytes32("schedule"), 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                      PurchaseRbtc.withdrawStuckRbtc
    //////////////////////////////////////////////////////////////*/
    function test_withdrawStuckRbtc_rescues_to_backup_address() public {
        (TropykusDocHandlerMoc handler, MockStablecoin doc,,) = _deployTropykusMocHandler(true);
        address RESCUE = address(0xBEEF);
        NonPayableReceiver stuck = new NonPayableReceiver();

        // Fund stuck contract via handler buy flow
        doc.mint(address(stuck), 600 ether);
        vm.prank(address(stuck));
        doc.approve(address(handler), type(uint256).max);
        handler.depositToken(address(stuck), 600 ether);
        handler.buyRbtc(address(stuck), bytes32("sched"), 200 ether);

        uint256 rescueBalanceBefore = RESCUE.balance;
        uint256 stuckAccrued = handler.getAccumulatedRbtcBalance(address(stuck));
        assertGt(stuckAccrued, 0, "setup failed - no accrued rBTC");

        // Owner (test contract) calls rescue
        handler.withdrawStuckRbtc(address(stuck), RESCUE);

        assertEq(handler.getAccumulatedRbtcBalance(address(stuck)), 0, "mapping not cleared");
        assertEq(RESCUE.balance, rescueBalanceBefore + stuckAccrued, "funds not rescued");
    }

    /*//////////////////////////////////////////////////////////////
                       PurchaseUniswap setters reverts
    //////////////////////////////////////////////////////////////*/
    function _deployDexHandler() internal returns (TropykusErc20HandlerDex, MockStablecoin, MockKdocToken, MockSwapRouter02, MockWrbtcToken, MockMocOracle) {
        // Stablecoin & kDOC mocks
        MockStablecoin doc = new MockStablecoin(address(this));
        MockKdocToken kdoc = new MockKdocToken(address(doc));
        // WRBTC & router & oracle mocks
        MockWrbtcToken wrbtc = new MockWrbtcToken();
        MockSwapRouter02 router = new MockSwapRouter02(wrbtc, BTC_PRICE); // price intentionally normal
        MockMocOracle oracle = new MockMocOracle();

        IPurchaseUniswap.UniswapSettings memory uniSettings = IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(address(wrbtc)),
            swapRouter02: ISwapRouter02(address(router)),
            swapIntermediateTokens: new address[](0),
            swapPoolFeeRates: new uint24[](1), // will be ignored for empty path
            mocOracle: ICoinPairPrice(address(oracle))
        });

        TropykusErc20HandlerDex dex = new TropykusErc20HandlerDex(
            address(this),
            address(doc),
            address(kdoc),
            uniSettings,
            MIN_PURCHASE_AMOUNT,
            address(0xFEE),
            IFeeHandler.FeeSettings({
                minFeeRate: MIN_FEE_RATE,
                maxFeeRate: MAX_FEE_RATE_TEST,
                feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
                feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
            }),
            0.997 ether, // amountOutMinimumPercent
            0.99 ether,  // amountOutMinimumSafetyCheck
            EXCHANGE_RATE_DECIMALS
        );

        return (dex, doc, kdoc, router, wrbtc, oracle);
    }

    function test_setPurchasePath_reverts_on_length_mismatch() public {
        (TropykusErc20HandlerDex dex,, ,, ,) = _deployDexHandler();
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
        (TropykusErc20HandlerDex dex,, ,, ,) = _deployDexHandler();
        vm.expectRevert();
        dex.setAmountOutMinimumPercent(1.1 ether);
    }

    function test_setAmountOutMinimumSafetyCheck_reverts_when_too_high() public {
        (TropykusErc20HandlerDex dex,, ,, ,) = _deployDexHandler();
        vm.expectRevert();
        dex.setAmountOutMinimumSafetyCheck(1.1 ether);
    }

    function test_updateMocOracle_reverts_on_zero_address() public {
        (TropykusErc20HandlerDex dex,, ,, ,) = _deployDexHandler();
        vm.expectRevert();
        dex.updateMocOracle(address(0));
    }

    function test_buyRbtc_reverts_on_outdated_oracle() public {
        (TropykusErc20HandlerDex dex, MockStablecoin doc,,,, MockMocOracle oracle) = _deployDexHandler();
        // Invalidate oracle price
        oracle.setInvalidPrice();

        address USER = address(0xC0);
        doc.mint(USER, 1000 ether);
        vm.prank(USER);
        doc.approve(address(dex), type(uint256).max);
        dex.depositToken(USER, 600 ether);

        vm.expectRevert();
        dex.buyRbtc(USER, bytes32("sched"), 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
               SovrynErc20Handler branch – withdrawInterest early exit
    //////////////////////////////////////////////////////////////*/
    function test_withdrawInterest_returns_early_when_no_interest() public {
        // Mocks
        MockStablecoin doc = new MockStablecoin(address(this));
        MockIsusdToken isusd = new MockIsusdToken(address(doc));
        MockMocProxy proxy = new MockMocProxy(address(doc));
        vm.deal(address(proxy), 10 ether);

        SovrynDocHandlerMoc handler = new SovrynDocHandlerMoc(
            address(this),
            address(doc),
            address(isusd),
            MIN_PURCHASE_AMOUNT,
            address(0xFEE),
            address(proxy),
            IFeeHandler.FeeSettings({
                minFeeRate: MIN_FEE_RATE,
                maxFeeRate: MAX_FEE_RATE_TEST,
                feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
                feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
            }),
            EXCHANGE_RATE_DECIMALS
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
