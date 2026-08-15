// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SovrynDocHandlerMoc} from "src/SovrynDocHandlerMoc.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockIsusdToken} from "test/mocks/MockIsusdToken.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import "script/Constants.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";

contract SovrynDocHandlerMocTest is Test {
    address internal USER = address(0xBBB2);
    address internal FEE_COLLECTOR = address(0xFEE);

    MockStablecoin internal docToken;
    MockIsusdToken internal iSusdToken;
    MockMocProxy   internal mocProxy;
    SovrynDocHandlerMoc internal handler;

    function setUp() public {
        docToken = new MockStablecoin(address(this));
        iSusdToken = new MockIsusdToken(address(docToken));
        mocProxy = new MockMocProxy(address(docToken));

        vm.deal(address(mocProxy), 100 ether);

        handler = new SovrynDocHandlerMoc(
            address(this),
            address(docToken),
            address(iSusdToken),
            MIN_PURCHASE_AMOUNT,
            FEE_COLLECTOR,
            address(mocProxy),
            IFeeHandler.FeeSettings({
                minFeeRate: MIN_FEE_RATE,
                maxFeeRate: MAX_FEE_RATE_TEST,
                feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
                feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
            }),
            EXCHANGE_RATE_DECIMALS
        );

        docToken.mint(USER, 1000 ether);
        vm.prank(USER);
        docToken.approve(address(handler), type(uint256).max);

        vm.prank(address(handler));
        docToken.approve(address(mocProxy), type(uint256).max);

        docToken.mint(address(iSusdToken), 10000 ether);
    }

    function test_buyRbtc_flow() public {
        uint256 depositAmount = 600 ether;
        uint256 purchaseAmount = 120 ether;
        bytes32 scheduleId = keccak256("schedule");

        handler.depositToken(USER, depositAmount);
        handler.buyRbtc(USER, scheduleId, purchaseAmount);

        uint256 rbtcAccrued = handler.getAccumulatedRbtcBalance(USER);
        assertGt(rbtcAccrued, 0);

        vm.prank(address(this));
        handler.withdrawAccumulatedRbtc(USER);
        assertEq(handler.getAccumulatedRbtcBalance(USER), 0);
        assertGt(USER.balance, 0);
    }

    function test_batchBuyRbtc_flow() public {
        // Prepare users
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

        // Batch buy arrays
        address[] memory buyers = new address[](2);
        bytes32[] memory scheduleIds = new bytes32[](2);
        uint256[] memory purchaseAmounts = new uint256[](2);
        buyers[0] = user1;
        buyers[1] = user2;
        scheduleIds[0] = keccak256("sche0");
        scheduleIds[1] = keccak256("sche1");
        purchaseAmounts[0] = 60 ether;
        purchaseAmounts[1] = 140 ether;

        handler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts);

        uint256 accrued1 = handler.getAccumulatedRbtcBalance(user1);
        uint256 accrued2 = handler.getAccumulatedRbtcBalance(user2);
        assertGt(accrued1, 0);
        assertGt(accrued2, 0);
        uint256 totalDoc = purchaseAmounts[0] + purchaseAmounts[1];
        uint256 expectedTotal = totalDoc / BTC_PRICE;
        uint256 totalAccrued = accrued1 + accrued2;
        assertLe(totalAccrued, expectedTotal);
        assertGt(totalAccrued, expectedTotal * 95 / 100);
    }
} 