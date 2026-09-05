//SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SovrynDocHandlerMoc} from "src/sovryn/SovrynDocHandlerMoc.sol";
import {IdleDocHandlerMoc} from "src/idle/IdleDocHandlerMoc.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockIsusdToken} from "test/mocks/MockIsusdToken.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import "test/Constants.sol";
import {NO_MIN_RBTC_OUT_RATE} from "test/utils/BatchBuyOne.sol";

/**
 * @title BatchTailScheduleTest
@notice Pins what happens when a schedule spends its exact remaining balance on a lending route.
 *
 * @dev `TokenLending._stablecoinToShares` rounds the share debit **up** (deliberately: the per-user share
 * book must never drift above the shares the handler actually holds), while `depositToken` credits the
 * floor-rounded amount the lending protocol actually minted. So whenever the exchange rate does not
 * divide the deposit evenly — i.e. essentially always in production — spending the full remaining
 * balance asks for one more share than the user owns. Accrued interest normally covers that by orders
 * of magnitude, but the owner can sweep exactly that cushion whenever they like.
 *
 * R43 kept the shortfall as a **revert**, on the grounds that a tail schedule is a state the swapper bot
 * filters before batching, like a paused one. R66 supersedes that: the owner can reach this state after
 * the bot's snapshot, so it was one buyer's rounding dust against every other buyer's purchase in the
 * same tick. The revert is now a **skip** — these are the flipped tests R43's note asked for.
 *
 * What has *not* changed is the accounting. The shortfall is still not clamped and not forgiven: the row
 * keeps its principal and buys nothing, and the user's exits — withdraw the rest, deposit more, or lower
 * the purchase amount — are the same as before. Idle is unaffected either way: its balances are 1:1,
 * with no rate and no rounding.
 */
contract BatchTailScheduleTest is Test {
    address internal ALICE = address(0xA11CE);
    address internal BOB = address(0xB0B);
    address internal FEE_COLLECTOR = address(0xFEE);

    MockStablecoin internal docToken;
    MockIsusdToken internal iSusdToken;
    MockMocProxy internal mocProxy;
    SovrynDocHandlerMoc internal lendingHandler;
    IdleDocHandlerMoc internal idleHandler;

    /// @dev not a multiple of the exchange rate, which is the whole point
    uint256 internal constant ALICE_DEPOSIT = 500 ether + 7;

    function setUp() public {
        docToken = new MockStablecoin(address(this));
        iSusdToken = new MockIsusdToken(address(docToken));
        mocProxy = new MockMocProxy(address(docToken));
        vm.deal(address(mocProxy), 1000 ether);

        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        // dcaManager = this, so the test can call onlyDcaManager entry points directly
        lendingHandler = new SovrynDocHandlerMoc(
            address(this), address(docToken), address(iSusdToken), FEE_COLLECTOR, address(mocProxy), feeSettings, address(this)
        );
        idleHandler =
            new IdleDocHandlerMoc(address(this), address(docToken), FEE_COLLECTOR, address(mocProxy), feeSettings, address(this));

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
        docToken.mint(address(iSusdToken), 1_000_000 ether);

        // Advance so tokenPrice() is not a round number. The starting mock rate divides evenly and
        // would hide the shortfall; a live protocol rate never does.
        vm.warp(block.timestamp + 197 days + 13 hours + 7 minutes);
    }

    function test_lendingTail_singleScheduleSpendingFullBalanceIsSkipped() external {
        lendingHandler.depositToken(ALICE, ALICE_DEPOSIT);

        // One purchase, no draining loop: the round-up already asks for more shares than Alice owns,
        // and it is short by exactly one share.
        uint256 aliceShares = lendingHandler.getUserShares(ALICE);
        uint256[] memory unfundedRows =
            lendingHandler.batchBuyRbtc(_one(ALICE), _oneId(1), _one(ALICE_DEPOSIT), NO_MIN_RBTC_OUT_RATE);

        // Nothing moved: the shortfall is dropped, not clamped and not forgiven. A batch whose every
        // row goes this way redeems nothing and buys nothing, and still does not revert.
        assertEq(unfundedRows.length, 1, "the tail row should have been reported unfunded");
        assertEq(unfundedRows[0], 0);
        assertEq(lendingHandler.getUserShares(ALICE), aliceShares);
        assertEq(lendingHandler.getAccumulatedRbtcBalance(ALICE), 0);
        assertEq(docToken.balanceOf(address(lendingHandler)), 0, "an all-unfunded batch redeemed anyway");
        assertEq(docToken.balanceOf(FEE_COLLECTOR), 0, "an all-unfunded batch paid a fee");
    }

    function test_lendingTail_leavesEveryOtherBuyerInTheSameBatchAlone() external {
        lendingHandler.depositToken(ALICE, ALICE_DEPOSIT);
        lendingHandler.depositToken(BOB, 5_000 ether);

        address[] memory buyers = new address[](2);
        uint64[] memory scheduleIds = new uint64[](2);
        uint256[] memory purchaseAmounts = new uint256[](2);
        buyers[0] = ALICE;
        buyers[1] = BOB;
        scheduleIds[0] = 1;
        scheduleIds[1] = 2;
        purchaseAmounts[0] = ALICE_DEPOSIT; // tail schedule
        purchaseAmounts[1] = 100 ether; // perfectly healthy

        uint256 aliceShares = lendingHandler.getUserShares(ALICE);
        uint256 bobShares = lendingHandler.getUserShares(BOB);
        uint256[] memory unfundedRows =
            lendingHandler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts, NO_MIN_RBTC_OUT_RATE);

        // Bob did nothing wrong and buys: one tail schedule no longer poisons the whole tick.
        assertEq(unfundedRows.length, 1, "only Alice's tail row should have been reported unfunded");
        assertEq(unfundedRows[0], 0, "Alice's row is row 0");
        assertEq(lendingHandler.getUserShares(ALICE), aliceShares, "the tail row was charged shares");
        assertEq(lendingHandler.getAccumulatedRbtcBalance(ALICE), 0, "the tail row was credited rBTC");
        assertGt(lendingHandler.getAccumulatedRbtcBalance(BOB), 0, "Bob did not buy");
        assertLt(lendingHandler.getUserShares(BOB), bobShares, "Bob was not charged for his purchase");
    }

    function test_idleTail_singleScheduleSpendingFullBalanceSucceeds() external {
        idleHandler.depositToken(ALICE, ALICE_DEPOSIT);

        // Idle books are 1:1, so the exact-balance purchase the lending route rejects goes through.
        idleHandler.batchBuyRbtc(_one(ALICE), _oneId(1), _one(ALICE_DEPOSIT), NO_MIN_RBTC_OUT_RATE);

        assertEq(idleHandler.getUsersIdleTokenBalance(ALICE), 0);
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
