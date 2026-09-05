// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IdleDocHandlerMoc} from "src/idle/IdleDocHandlerMoc.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import "test/Constants.sol";
import {handlerBatchBuyOne, NO_MIN_RBTC_OUT_RATE} from "test/utils/BatchBuyOne.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";

/**
 * @title IdleDocHandlerMocTest
 * @notice MoC purchase paths for the idle DOC handler. No shares.
 */
contract IdleDocHandlerMocTest is Test {
    address internal USER = address(0xAAA1);
    address internal FEE_COLLECTOR = address(0xFEE);

    MockStablecoin internal docToken;
    MockMocProxy internal mocProxy;
    IdleDocHandlerMoc internal handler;

    function setUp() public {
        docToken = new MockStablecoin(address(this));
        mocProxy = new MockMocProxy(address(docToken));
        vm.deal(address(mocProxy), 100 ether);

        handler = new IdleDocHandlerMoc(
            address(this),
            address(docToken),
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

        docToken.mint(USER, 1000 ether);
        vm.prank(USER);
        docToken.approve(address(handler), type(uint256).max);

        vm.prank(address(handler));
        docToken.approve(address(mocProxy), type(uint256).max);
    }

    function test_lengthOneBatch_flow() public {
        uint256 depositAmount = 500 ether;
        uint256 purchaseAmount = 100 ether;
        uint64 scheduleId = 1;

        handler.depositToken(USER, depositAmount);
        assertEq(docToken.balanceOf(address(handler)), depositAmount);
        assertEq(handler.getUsersIdleTokenBalance(USER), depositAmount);

        handlerBatchBuyOne(IPurchaseRbtc(address(handler)), USER, scheduleId, purchaseAmount);

        uint256 rbtcAccrued = handler.getAccumulatedRbtcBalance(USER);
        assertGt(rbtcAccrued, 0);
        assertEq(handler.getUsersIdleTokenBalance(USER), depositAmount - purchaseAmount);
        assertEq(docToken.balanceOf(address(handler)), depositAmount - purchaseAmount);

        handler.withdrawAccumulatedRbtc(USER);
        assertEq(handler.getAccumulatedRbtcBalance(USER), 0);
        assertGt(USER.balance, 0);
    }

    function test_batchBuyRbtc_flow() public {
        address user1 = address(0xB11);
        address user2 = address(0xB22);
        uint256 deposit1 = 300 ether;
        uint256 deposit2 = 700 ether;

        address[2] memory users = [user1, user2];
        uint256[2] memory deposits = [deposit1, deposit2];
        for (uint256 i = 0; i < users.length; i++) {
            docToken.mint(users[i], deposits[i]);
            vm.prank(users[i]);
            docToken.approve(address(handler), type(uint256).max);
            handler.depositToken(users[i], deposits[i]);
        }

        address[] memory buyers = new address[](2);
        uint64[] memory scheduleIds = new uint64[](2);
        uint256[] memory purchaseAmounts = new uint256[](2);
        buyers[0] = user1;
        buyers[1] = user2;
        scheduleIds[0] = 1;
        scheduleIds[1] = 2;
        purchaseAmounts[0] = 60 ether;
        purchaseAmounts[1] = 140 ether;

        handler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts, NO_MIN_RBTC_OUT_RATE);

        uint256 accrued1 = handler.getAccumulatedRbtcBalance(user1);
        uint256 accrued2 = handler.getAccumulatedRbtcBalance(user2);
        assertGt(accrued1, 0);
        assertGt(accrued2, 0);
        uint256 expectedTotal = (purchaseAmounts[0] + purchaseAmounts[1]) / BTC_PRICE;
        assertLe(accrued1 + accrued2, expectedTotal);
        assertGt(accrued1 + accrued2, expectedTotal * 95 / 100);

        assertEq(handler.getUsersIdleTokenBalance(user1), deposit1 - purchaseAmounts[0]);
        assertEq(handler.getUsersIdleTokenBalance(user2), deposit2 - purchaseAmounts[1]);
        assertEq(docToken.balanceOf(address(handler)), deposit1 + deposit2 - purchaseAmounts[0] - purchaseAmounts[1]);
    }

    function test_lengthOneBatch_doesNotMintShareToken() public {
        handler.depositToken(USER, 500 ether);
        handlerBatchBuyOne(IPurchaseRbtc(address(handler)), USER, 1, 100 ether);

        // The only ERC20 this test deployed is DOC; it stays on the handler minus the purchase.
        assertEq(docToken.balanceOf(address(handler)), 400 ether);
        assertEq(handler.getUsersIdleTokenBalance(USER), 400 ether);
    }
}
