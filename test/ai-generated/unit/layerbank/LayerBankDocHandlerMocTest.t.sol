// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {LayerBankDocHandlerMoc} from "src/layerbank/LayerBankDocHandlerMoc.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "test/mocks/MockLayerBank.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import "script/Constants.sol";

/**
 * @title LayerBankDocHandlerMocTest
 * @notice MoC purchase paths for the LayerBank DOC handler.
 */
contract LayerBankDocHandlerMocTest is Test {
    address internal USER = address(0xAAA1);
    address internal FEE_COLLECTOR = address(0xFEE);

    MockStablecoin internal docToken;
    MockLayerBankAToken internal aToken;
    MockLayerBankPool internal pool;
    MockMocProxy internal mocProxy;
    LayerBankDocHandlerMoc internal handler;

    function setUp() public {
        docToken = new MockStablecoin(address(this));
        aToken = new MockLayerBankAToken(address(docToken));
        pool = new MockLayerBankPool(aToken);
        aToken.setPool(address(pool));
        mocProxy = new MockMocProxy(address(docToken));

        vm.deal(address(mocProxy), 100 ether);

        handler = new LayerBankDocHandlerMoc(
            address(this),
            address(docToken),
            address(aToken),
            FEE_COLLECTOR,
            address(mocProxy),
            IFeeHandler.FeeSettings({
                minFeeRate: MIN_FEE_RATE,
                maxFeeRate: MAX_FEE_RATE_TEST,
                feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
                feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
            })
        );

        docToken.mint(USER, 1000 ether);
        vm.prank(USER);
        docToken.approve(address(handler), type(uint256).max);

        vm.prank(address(handler));
        docToken.approve(address(mocProxy), type(uint256).max);

        docToken.mint(address(aToken), 10000 ether);
    }

    function test_buyRbtc_flow() public {
        uint256 depositAmount = 500 ether;
        uint256 purchaseAmount = 100 ether;
        bytes32 scheduleId = keccak256("schedule");

        handler.depositToken(USER, depositAmount);
        uint256 sharesBefore = handler.getUserShares(USER);
        assertGt(sharesBefore, 0);

        handler.buyRbtc(USER, scheduleId, purchaseAmount);

        uint256 rbtcAccrued = handler.getAccumulatedRbtcBalance(USER);
        assertGt(rbtcAccrued, 0);
        assertLt(handler.getUserShares(USER), sharesBefore);

        handler.withdrawAccumulatedRbtc(USER);
        assertEq(handler.getAccumulatedRbtcBalance(USER), 0);
        assertGt(USER.balance, 0);
    }

    function test_batchBuyRbtc_flow() public {
        address user1 = address(0xA11);
        address user2 = address(0xA22);
        address user3 = address(0xA33);

        uint256 deposit1 = 400 ether;
        uint256 deposit2 = 600 ether;
        uint256 deposit3 = 800 ether;

        address[3] memory users = [user1, user2, user3];
        uint256[3] memory deposits = [deposit1, deposit2, deposit3];
        for (uint256 i = 0; i < users.length; i++) {
            docToken.mint(users[i], deposits[i]);
            vm.prank(users[i]);
            docToken.approve(address(handler), type(uint256).max);
            handler.depositToken(users[i], deposits[i]);
        }

        address[] memory buyers = new address[](3);
        bytes32[] memory scheduleIds = new bytes32[](3);
        uint256[] memory purchaseAmounts = new uint256[](3);
        uint256 purchaseBase = 50 ether;
        for (uint256 i = 0; i < buyers.length; i++) {
            buyers[i] = users[i];
            scheduleIds[i] = keccak256(abi.encodePacked("schedule", i));
            purchaseAmounts[i] = purchaseBase * (i + 1);
        }

        handler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts);

        uint256 totalAccrued;
        for (uint256 i = 0; i < buyers.length; i++) {
            uint256 accrued = handler.getAccumulatedRbtcBalance(buyers[i]);
            assertGt(accrued, 0);
            totalAccrued += accrued;
        }
        uint256 totalDocSpent;
        for (uint256 i = 0; i < purchaseAmounts.length; i++) {
            totalDocSpent += purchaseAmounts[i];
        }
        uint256 expectedRbtc = totalDocSpent / BTC_PRICE;
        assertLe(totalAccrued, expectedRbtc);
        assertGt(totalAccrued, expectedRbtc * 95 / 100);
    }
}
