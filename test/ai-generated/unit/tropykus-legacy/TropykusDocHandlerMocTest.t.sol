// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {TropykusDocHandlerMoc} from "src/tropykus-legacy/TropykusDocHandlerMoc.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockKdocToken} from "test/mocks/MockKdocToken.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import "script/Constants.sol";
import {handlerBatchBuyOne} from "test/utils/BatchBuyOne.sol";

/**
 * @title TropykusDocHandlerMocTest
 * @notice Minimal unit-tests that execute the TropykusDocHandlerMoc code-paths
 *         not covered by the generic handler harness – namely the MoC-specific
 *         DOC → rBTC redemption flow.
 */
contract TropykusDocHandlerMocTest is Test {
    // Test actors
    address internal USER = address(0xAAA1);
    address internal FEE_COLLECTOR = address(0xFEE);

    // Mocks / system under test
    MockStablecoin internal docToken;
    MockKdocToken  internal kDocToken;
    MockMocProxy   internal mocProxy;
    TropykusDocHandlerMoc internal handler;

    function setUp() public {
        // Deploy mocks
        docToken = new MockStablecoin(address(this));
        kDocToken = new MockKdocToken(address(docToken));
        mocProxy  = new MockMocProxy(address(docToken));

        // Give the MoC proxy some RBTC to redeem
        vm.deal(address(mocProxy), 100 ether);

        // Deploy the handler – set dcaManager to this test contract so we can
        // invoke onlyDcaManager functions directly.
        handler = new TropykusDocHandlerMoc(
            address(this),           // dcaManagerAddress
            address(docToken),
            address(kDocToken),
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

        // Fund USER with DOC and give approval
        docToken.mint(USER, 1000 ether);
        vm.prank(USER);
        docToken.approve(address(handler), type(uint256).max);

        // Grant allowance from handler to the MoC proxy so redeemFreeDoc succeeds
        vm.prank(address(handler));
        docToken.approve(address(mocProxy), type(uint256).max);

        // Also mint some kDOC to handler so Mint/redeem can work
        docToken.mint(address(kDocToken), 10000 ether);
    }

    function test_lengthOneBatch_flow() public {
        uint256 depositAmount = 500 ether;
        uint256 purchaseAmount = 100 ether;
        uint64 scheduleId = 1;

        // Deposit DOC on behalf of USER (onlyDcaManager)
        handler.depositToken(USER, depositAmount);

        // Perform rBTC purchase – redeems the buyer's shares, then redeems DOC at MoC
        handlerBatchBuyOne(IPurchaseRbtc(address(handler)), USER, scheduleId, purchaseAmount);

        // Verify rBTC was accounted
        uint256 rbtcAccrued = handler.getAccumulatedRbtcBalance(USER);
        assertGt(rbtcAccrued, 0);

        // Withdraw rBTC – ensure native balance transfer occurs
        vm.prank(address(this));
        handler.withdrawAccumulatedRbtc(USER);
        assertEq(handler.getAccumulatedRbtcBalance(USER), 0);
        assertGt(USER.balance, 0);
    }

    function test_batchBuyRbtc_flow() public {
        // Prepare three users and deposits
        address user1 = address(0xA11);
        address user2 = address(0xA22);
        address user3 = address(0xA33);

        uint256 deposit1 = 400 ether;
        uint256 deposit2 = 600 ether;
        uint256 deposit3 = 800 ether;

        // Mint DOC and approve handler for each user
        address[3] memory users = [user1, user2, user3];
        uint256[3] memory deposits = [deposit1, deposit2, deposit3];
        for (uint256 i = 0; i < users.length; i++) {
            docToken.mint(users[i], deposits[i]);
            vm.prank(users[i]);
            docToken.approve(address(handler), type(uint256).max);
            // Deposit on behalf of user (onlyDcaManager)
            handler.depositToken(users[i], deposits[i]);
        }

        // Prepare batch purchase data
        address[] memory buyers = new address[](3);
        uint64[] memory scheduleIds = new uint64[](3);
        uint256[] memory purchaseAmounts = new uint256[](3);
        uint256 purchaseBase = 50 ether;
        for (uint256 i = 0; i < buyers.length; i++) {
            buyers[i] = users[i];
            scheduleIds[i] = uint64(i + 1);
            purchaseAmounts[i] = purchaseBase * (i + 1); // 50,100,150 DOC
        }

        // Execute batch buy (onlyDcaManager)
        handler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts);

        // Validate each user received rBTC proportionally
        uint256 totalAccrued;
        for (uint256 i = 0; i < buyers.length; i++) {
            uint256 accrued = handler.getAccumulatedRbtcBalance(buyers[i]);
            assertGt(accrued, 0);
            totalAccrued += accrued;
        }
        // Total rBTC equals DOC spent / BTC_PRICE (within rounding)
        uint256 totalDocSpent;
        for (uint256 i = 0; i < purchaseAmounts.length; i++) {
            totalDocSpent += purchaseAmounts[i];
        }
        uint256 expectedRbtc = totalDocSpent / BTC_PRICE;
        // Users receive rBTC minus protocol fees
        assertLe(totalAccrued, expectedRbtc);
        assertGt(totalAccrued, expectedRbtc * 95 / 100); // at least 95% after fees
    }
} 