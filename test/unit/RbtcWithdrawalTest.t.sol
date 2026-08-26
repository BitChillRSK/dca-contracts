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
        IDcaManager.DcaDetails[] memory dcaDetails = dcaManager.getDcaSchedules(USER, address(stablecoin));

        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(stablecoin), SCHEDULE_INDEX, dcaDetails[SCHEDULE_INDEX].scheduleId);

        uint256 rbtcBalanceBeforeWithdrawal = USER.balance;
        vm.prank(USER);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes);
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
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes);
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
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes);
        uint256 rbtcBalanceAfterWithdrawal = USER.balance;
        assertEq(rbtcBalanceAfterWithdrawal, rbtcBalanceBeforeWithdrawal);
    }

    function testWithdrawRbtcFromTokenHandlerCreditsSignerOnly() external {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 10 ether);
        if (block.chainid == ANVIL_CHAIN_ID) {
            stablecoin.mint(attacker, AMOUNT_TO_DEPOSIT);
        } else {
            vm.prank(USER);
            stablecoin.transfer(attacker, AMOUNT_TO_DEPOSIT);
        }

        vm.startPrank(attacker);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();

        super.makeSinglePurchase();

        bytes32 attackerScheduleId = dcaManager.getDcaSchedule(attacker, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.prank(SWAPPER);
        dcaManager.buyRbtc(attacker, address(stablecoin), SCHEDULE_INDEX, attackerScheduleId);

        uint256 userAccrued = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER);
        uint256 attackerAccrued = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(attacker);
        assertGt(userAccrued, 0);
        assertGt(attackerAccrued, 0);

        uint256 userBalanceBefore = USER.balance;
        uint256 attackerBalanceBefore = attacker.balance;
        uint256 ownerBalanceBefore = OWNER.balance;

        vm.prank(attacker);
        dcaManager.withdrawRbtcFromTokenHandler(address(stablecoin), s_routeIndex);

        assertEq(attacker.balance, attackerBalanceBefore + attackerAccrued, "attacker did not receive only their rBTC");
        assertEq(USER.balance, userBalanceBefore, "USER native balance moved on attacker withdraw");
        assertEq(OWNER.balance, ownerBalanceBefore, "OWNER received rBTC");
        assertEq(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER), userAccrued);
        assertEq(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(attacker), 0);

        vm.prank(USER);
        dcaManager.withdrawRbtcFromTokenHandler(address(stablecoin), s_routeIndex);

        assertEq(USER.balance, userBalanceBefore + userAccrued, "USER did not receive only their rBTC");
        assertEq(attacker.balance, attackerBalanceBefore + attackerAccrued, "attacker balance changed on USER withdraw");
        assertEq(OWNER.balance, ownerBalanceBefore, "OWNER received rBTC");
        assertEq(IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(USER), 0);
    }
}
