//SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SovrynDocHandlerMoc} from "src/sovryn/SovrynDocHandlerMoc.sol";
import {IdleDocHandlerMoc} from "src/idle/IdleDocHandlerMoc.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockIToken} from "test/mocks/MockIToken.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
import "test/Constants.sol";
import {NO_MIN_RBTC_OUT} from "test/utils/BatchBuyOne.sol";

/**
 * @title BatchTailScheduleTest
 * @notice Lending tail purchases consume the available claim and preserve healthy buyers' allocation.
 * @dev R114 replaces R43's accepted tail revert. Nominal schedule debits remain separate from measured
 *      receipt shares. Reduced funding changes allocation weights before fees and output credits.
 */
contract BatchTailScheduleTest is Test {
    /// @dev This direct-call manager fixture has no schedule liabilities.
    function getLockedPrincipal(address, address, address) external pure returns (uint256) {
        return 0;
    }

    address internal ALICE = address(0xA11CE);
    address internal BOB = address(0xB0B);
    address internal FEE_COLLECTOR = address(0xFEE);

    MockStablecoin internal docToken;
    MockIToken internal iToken;
    MockMocProxy internal mocProxy;
    SovrynDocHandlerMoc internal lendingHandler;
    IdleDocHandlerMoc internal idleHandler;

    /// @dev not a multiple of the exchange rate, which is the whole point
    uint256 internal constant ALICE_DEPOSIT = 500 ether + 7;

    function setUp() public {
        docToken = new MockStablecoin(address(this));
        iToken = new MockIToken(address(docToken));
        mocProxy = new MockMocProxy(address(docToken));
        vm.deal(address(mocProxy), 1000 ether);

        IPurchaseFees.FeeSettings memory feeSettings = IPurchaseFees.FeeSettings({
            minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE_TEST, feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND
        });

        // dcaManager = this, so the test can call onlyDcaManager entry points directly
        lendingHandler = new SovrynDocHandlerMoc(
            address(this),
            address(docToken),
            address(iToken),
            FEE_COLLECTOR,
            address(mocProxy),
            feeSettings,
            address(this)
        );
        idleHandler = new IdleDocHandlerMoc(
            address(this), address(docToken), FEE_COLLECTOR, address(mocProxy), feeSettings, address(this)
        );

        address[2] memory users = [ALICE, BOB];
        for (uint256 i; i < users.length; ++i) {
            docToken.mint(users[i], 10_000 ether);
            vm.startPrank(users[i]);
            docToken.approve(address(lendingHandler), type(uint256).max);
            docToken.approve(address(idleHandler), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(address(lendingHandler));
        docToken.approve(address(mocProxy), type(uint256).max);
        vm.prank(address(idleHandler));
        docToken.approve(address(mocProxy), type(uint256).max);
        docToken.mint(address(iToken), 1_000_000 ether);

        // Advance so tokenPrice() is not a round number. The starting mock rate divides evenly and
        // would hide the shortfall; a live protocol rate never does.
        vm.warp(block.timestamp + 197 days + 13 hours + 7 minutes);
    }

    function test_lendingTail_singleScheduleSpendingFullBalancePurchases() external {
        lendingHandler.depositToken(ALICE, ALICE_DEPOSIT);
        uint256 before = iToken.balanceOf(address(lendingHandler));
        lendingHandler.batchBuyRbtc(_one(ALICE), _oneId(1), _one(ALICE_DEPOSIT), NO_MIN_RBTC_OUT);
        assertEq(lendingHandler.getUserShares(ALICE), 0);
        assertEq(iToken.balanceOf(address(lendingHandler)), 0);
        assertGt(before, 0);
        assertGt(lendingHandler.getAccumulatedRbtcBalance(ALICE), 0);
    }

    function test_lendingTail_doesNotBlockHealthyBuyerInSameBatch() external {
        lendingHandler.depositToken(ALICE, ALICE_DEPOSIT);
        lendingHandler.depositToken(BOB, 5_000 ether);
        address[] memory buyers = new address[](2);
        uint64[] memory scheduleIds = new uint64[](2);
        uint256[] memory amounts = new uint256[](2);
        buyers[0] = ALICE;
        buyers[1] = BOB;
        scheduleIds[0] = 1;
        scheduleIds[1] = 2;
        amounts[0] = ALICE_DEPOSIT;
        amounts[1] = 100 ether;
        uint256 bobBefore = lendingHandler.getUserShares(BOB);
        lendingHandler.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);
        assertEq(lendingHandler.getUserShares(ALICE), 0);
        assertGt(lendingHandler.getAccumulatedRbtcBalance(ALICE), 0);
        assertGt(lendingHandler.getAccumulatedRbtcBalance(BOB), 0);
        assertLt(lendingHandler.getUserShares(BOB), bobBefore);
        assertEq(iToken.balanceOf(address(lendingHandler)), lendingHandler.getUserShares(BOB));
    }

    function test_idleTail_singleScheduleSpendingFullBalanceSucceeds() external {
        idleHandler.depositToken(ALICE, ALICE_DEPOSIT);

        // Idle funding remains the nominal purchase amount.
        idleHandler.batchBuyRbtc(_one(ALICE), _oneId(1), _one(ALICE_DEPOSIT), NO_MIN_RBTC_OUT);

        assertEq(docToken.balanceOf(address(idleHandler)), 0);
        assertGt(idleHandler.getAccumulatedRbtcBalance(ALICE), 0);
    }

    function _one(address value) private pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = value;
    }

    function _oneId(uint64 value) private pure returns (uint64[] memory arr) {
        arr = new uint64[](1);
        arr[0] = value;
    }

    function _one(uint256 value) private pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }
}
