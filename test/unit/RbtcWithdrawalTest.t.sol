//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import "../../script/Constants.sol";

contract RbtcWithdrawalTest is DcaDappTest {
    function setUp() public override {
        super.setUp();
    }

    /////////////////////////////
    /// rBTC Withdrawal tests ///
    /////////////////////////////

    function testWithdrawRbtcAfterOnePurchase() external {
        uint256 fee = feeCalculator.calculateFee(AMOUNT_TO_SPEND);
        uint256 netPurchaseAmount = AMOUNT_TO_SPEND - fee;

        vm.prank(USER);
        IDcaManager.DcaDetails[] memory dcaDetails = dcaManager.getMyDcaSchedules(address(stablecoin));

        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(stablecoin), SCHEDULE_INDEX, dcaDetails[SCHEDULE_INDEX].scheduleId);

        uint256 rbtcBalanceBeforeWithdrawal = USER.balance;
        vm.prank(USER);
        uint256[] memory lendingProtocolIndexes = new uint256[](1);
        lendingProtocolIndexes[0] = s_lendingProtocolIndex;
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, lendingProtocolIndexes);
        uint256 rbtcBalanceAfterWithdrawal = USER.balance;

        if (keccak256(abi.encodePacked(swapType)) == keccak256(abi.encodePacked("mocSwaps"))) {
            // assertEq(rbtcBalanceAfterWithdrawal - rbtcBalanceBeforeWithdrawal, netPurchaseAmount / s_btcPrice);
            assertApproxEqRel( // MoC takes some commission so strict equality us not possible
                rbtcBalanceAfterWithdrawal - rbtcBalanceBeforeWithdrawal,
                netPurchaseAmount / s_btcPrice,
                0.25e16 // Allow a maximum difference of 0.25%
            );
        } else if (keccak256(abi.encodePacked(swapType)) == keccak256(abi.encodePacked("dexSwaps"))) {
            assertApproxEqRel( // The mock contract that simulates swapping on Uniswap allows for some slippage
                rbtcBalanceAfterWithdrawal - rbtcBalanceBeforeWithdrawal,
                netPurchaseAmount / s_btcPrice,
                MAX_SLIPPAGE_PERCENT // Allow a maximum difference of 0.5%
            );
        }
    }

    function testWithdrawRbtcAfterSeveralPurchases() external {
        super.createSeveralDcaSchedules();
        uint256 totalStablecoinSpent = super.makeSeveralPurchasesWithSeveralSchedules(); // 5 purchases
        uint256 rbtcBalanceBeforeWithdrawal = USER.balance;
        vm.prank(USER);
        uint256[] memory lendingProtocolIndexes = new uint256[](1);
        lendingProtocolIndexes[0] = s_lendingProtocolIndex;
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, lendingProtocolIndexes);
        uint256 rbtcBalanceAfterWithdrawal = USER.balance;
        // assertEq(rbtcBalanceAfterWithdrawal - rbtcBalanceBeforeWithdrawal, totalStablecoinSpent / s_btcPrice);

        // if (keccak256(abi.encodePacked(swapType)) == keccak256(abi.encodePacked("mocSwaps"))) {
        //     assertEq(rbtcBalanceAfterWithdrawal - rbtcBalanceBeforeWithdrawal, totalStablecoinSpent / s_btcPrice);
        // } else if (keccak256(abi.encodePacked(swapType)) == keccak256(abi.encodePacked("dexSwaps"))) {
        assertApproxEqRel( // The mock contract that simulates swapping on Uniswap allows for some slippage
            rbtcBalanceAfterWithdrawal - rbtcBalanceBeforeWithdrawal,
            totalStablecoinSpent / s_btcPrice,
            MAX_SLIPPAGE_PERCENT // Allow a maximum difference of 0.5% (on fork tests we saw this was necessary for both MoC and Uniswap swaps)
        );
        // }
    }

    function testCannotWithdrawBeforePurchasing() external {
        uint256 rbtcBalanceBeforeWithdrawal = USER.balance;
        // vm.expectRevert(IPurchaseRbtc.PurchaseRbtc__NoAccumulatedRbtcToWithdraw.selector);
        vm.prank(USER);
        uint256[] memory lendingProtocolIndexes = new uint256[](1);
        lendingProtocolIndexes[0] = s_lendingProtocolIndex;
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, lendingProtocolIndexes);
        uint256 rbtcBalanceAfterWithdrawal = USER.balance;
        assertEq(rbtcBalanceAfterWithdrawal, rbtcBalanceBeforeWithdrawal);
    }

    function testWithdrawRbtcFromTokenHandlerCreditsSignerOnly() external {
        super.makeSinglePurchase();

        uint256 userAccrued = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        assertGt(userAccrued, 0);

        address attacker = makeAddr("attacker");
        uint256 attackerBalanceBefore = attacker.balance;
        uint256 ownerBalanceBefore = OWNER.balance;

        vm.prank(attacker);
        vm.expectRevert(IPurchaseRbtc.PurchaseRbtc__NoAccumulatedRbtcToWithdraw.selector);
        dcaManager.withdrawRbtcFromTokenHandler(address(stablecoin), s_lendingProtocolIndex);

        assertEq(attacker.balance, attackerBalanceBefore);
        assertEq(OWNER.balance, ownerBalanceBefore);
        assertEq(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER), userAccrued);

        uint256 userBalanceBefore = USER.balance;
        vm.prank(USER);
        dcaManager.withdrawRbtcFromTokenHandler(address(stablecoin), s_lendingProtocolIndex);

        assertEq(USER.balance, userBalanceBefore + userAccrued);
        assertEq(attacker.balance, attackerBalanceBefore);
        assertEq(OWNER.balance, ownerBalanceBefore);
        assertEq(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER), 0);
    }
}
