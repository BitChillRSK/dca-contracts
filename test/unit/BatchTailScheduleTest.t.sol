//SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SovrynDocHandlerMoc} from "src/sovryn/SovrynDocHandlerMoc.sol";
import {IdleDocHandlerMoc} from "src/idle/IdleDocHandlerMoc.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockIsusdToken} from "test/mocks/MockIsusdToken.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import {ITokenLending} from "src/interfaces/ITokenLending.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import "script/Constants.sol";

/**
 * @title BatchTailScheduleTest
 * @notice Pins today's behavior when a schedule spends its exact remaining balance on a lending route.
 *
 * @dev **This documents a known rough edge, not a desired property. R43 owns the decision.**
 *
 * `TokenLending._stablecoinToShares` rounds the share debit **up** (deliberately: the per-user share
 * book must never drift above the shares the handler actually holds), while `depositToken` credits the
 * floor-rounded amount the lending protocol actually minted. So whenever the exchange rate does not
 * divide the deposit evenly — i.e. essentially always in production — spending the full remaining
 * balance asks for one more share than the user owns, and `_batchRetrieveStablecoin` reverts with
 * `TokenLending__InsufficientShares` rather than clamping.
 *
 * Two consequences worth keeping visible:
 *   1. No draining loop is needed. A single purchase of the exact remaining balance is already short.
 *   2. The revert happens inside the per-buyer loop, so one schedule at its tail fails the whole
 *      batch — every healthy buyer in the same tick is rolled back with it.
 *
 * R39 removed `buyRbtc`, whose `_redeemShares` path clamped the shortfall to the shares held. That was
 * the only path that could clear a tail schedule, so these tests are the record of what replaced it.
 * Idle is unaffected: its balances are 1:1, with no rate and no rounding.
 *
 * If R43 makes the batch clamp, these tests should be flipped, not deleted.
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

    function test_lendingTail_singleScheduleSpendingFullBalanceRevertsOnShares() external {
        lendingHandler.depositToken(ALICE, ALICE_DEPOSIT);

        // One purchase, no draining loop: the round-up already asks for more shares than Alice owns,
        // and it is short by exactly one share.
        uint256 aliceShares = lendingHandler.getUserShares(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenLending.TokenLending__InsufficientShares.selector, ALICE, aliceShares + 1, aliceShares
            )
        );
        lendingHandler.batchBuyRbtc(_one(ALICE), _one(keccak256("alice")), _one(ALICE_DEPOSIT));

        // Nothing moved: the shortfall is rejected, not clamped.
        assertEq(lendingHandler.getUserShares(ALICE), aliceShares);
        assertEq(lendingHandler.getAccumulatedRbtcBalance(ALICE), 0);
    }

    function test_lendingTail_takesDownEveryOtherBuyerInTheSameBatch() external {
        lendingHandler.depositToken(ALICE, ALICE_DEPOSIT);
        lendingHandler.depositToken(BOB, 5_000 ether);

        address[] memory buyers = new address[](2);
        bytes32[] memory scheduleIds = new bytes32[](2);
        uint256[] memory purchaseAmounts = new uint256[](2);
        buyers[0] = ALICE;
        buyers[1] = BOB;
        scheduleIds[0] = keccak256("alice");
        scheduleIds[1] = keccak256("bob");
        purchaseAmounts[0] = ALICE_DEPOSIT; // tail schedule
        purchaseAmounts[1] = 100 ether; // perfectly healthy

        uint256 aliceShares = lendingHandler.getUserShares(ALICE);
        uint256 bobShares = lendingHandler.getUserShares(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenLending.TokenLending__InsufficientShares.selector, ALICE, aliceShares + 1, aliceShares
            )
        );
        lendingHandler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts);

        // Bob did nothing wrong and still bought nothing: one tail schedule poisons the whole tick.
        assertEq(lendingHandler.getAccumulatedRbtcBalance(BOB), 0);
        assertEq(lendingHandler.getUserShares(BOB), bobShares);
    }

    function test_idleTail_singleScheduleSpendingFullBalanceSucceeds() external {
        idleHandler.depositToken(ALICE, ALICE_DEPOSIT);

        // Idle books are 1:1, so the exact-balance purchase the lending route rejects goes through.
        idleHandler.batchBuyRbtc(_one(ALICE), _one(keccak256("alice")), _one(ALICE_DEPOSIT));

        assertEq(idleHandler.getUsersIdleTokenBalance(ALICE), 0);
        assertGt(idleHandler.getAccumulatedRbtcBalance(ALICE), 0);
    }

    function _one(address value) private pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = value;
    }

    function _one(bytes32 value) private pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = value;
    }

    function _one(uint256 value) private pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }
}
