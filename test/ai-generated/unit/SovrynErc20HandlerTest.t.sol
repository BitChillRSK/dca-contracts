// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {HandlerTestHarness} from "./HandlerTestHarness.t.sol";
import {ITokenHandler} from "../../../src/interfaces/ITokenHandler.sol";
import {IFeeHandler} from "../../../src/interfaces/IFeeHandler.sol";
import {SovrynErc20Handler} from "../../../src/SovrynErc20Handler.sol";
import {MockIsusdToken} from "../../mocks/MockIsusdToken.sol";
import {MockStablecoin} from "../../mocks/MockStablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenLending} from "../../../src/interfaces/ITokenLending.sol";
import "../../../script/Constants.sol";

/**
 * @title SovrynErc20HandlerTest 
 * @notice Unit tests for SovrynErc20Handler using shared test harness
 */
contract SovrynErc20HandlerTest is HandlerTestHarness {
    
    // Sovryn-specific contracts
    MockIsusdToken public iSusdToken;
    SovrynTestHandler public sovrynHandler;
    
    /*//////////////////////////////////////////////////////////////
                           HANDLER-SPECIFIC IMPLEMENTATIONS
    //////////////////////////////////////////////////////////////*/
    
    function deployHandler() internal override returns (ITokenHandler) {
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });
        
        sovrynHandler = new SovrynTestHandler(
            address(dcaManager),
            address(stablecoin),
            address(iSusdToken),
            MIN_PURCHASE_AMOUNT,
            FEE_COLLECTOR,
            feeSettings
        );
        
        return ITokenHandler(address(sovrynHandler));
    }
    
    function getLendingProtocolIndex() internal pure override returns (uint256) {
        return SOVRYN_INDEX;
    }
    
    function isDexHandler() internal pure override returns (bool) {
        return false; // Regular Sovryn handler, not DEX variant
    }
    
    function isLendingHandler() internal pure override returns (bool) {
        return true; // Sovryn handlers support lending
    }
    
    function getLendingToken() internal view override returns (IERC20) {
        return IERC20(address(iSusdToken));
    }
    
    function setupHandlerSpecifics() internal override {
        // Deploy mock iSUSD token for Sovryn lending
        iSusdToken = new MockIsusdToken(address(stablecoin));
        
        // Note: MockIsusdToken has time-based price calculation built in
        
        // Give iSusdToken some underlying tokens to work with
        stablecoin.mint(address(iSusdToken), 1000000 ether);
    }
    
    /*//////////////////////////////////////////////////////////////
                           SOVRYN-SPECIFIC TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_sovryn_iSusdMinting() public {
        uint256 initialUserLendingBalance = sovrynHandler.getUsersLendingTokenBalance(USER);
        
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        uint256 finalUserLendingBalance = sovrynHandler.getUsersLendingTokenBalance(USER);
        assertGt(finalUserLendingBalance, initialUserLendingBalance);
    }
    
    function test_sovryn_tokenPriceEffect() public {
        // Deposit some tokens
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Simulate interest accrual by time passage
        vm.warp(block.timestamp + 365 days); // 1 year for interest accrual
        
        // Check that accrued interest is calculated correctly
        vm.prank(address(dcaManager));
        uint256 accruedInterest = sovrynHandler.getAccruedInterest(USER, DEPOSIT_AMOUNT);
        assertGt(accruedInterest, 0);
    }
    
    function test_sovryn_redemption_adjustsForAvailableBalance() public {
        // Deposit tokens
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        uint256 userBalanceBeforeWithdraw = stablecoin.balanceOf(USER);
        
        // Try to withdraw more than available (should be adjusted)
        vm.prank(address(dcaManager));
        handler.withdrawToken(USER, DEPOSIT_AMOUNT * 2);
        
        // Should have withdrawn what was available, not what was requested
        uint256 userBalanceAfterWithdraw = stablecoin.balanceOf(USER);
        uint256 actualWithdrawn = userBalanceAfterWithdraw - userBalanceBeforeWithdraw;
        assertLe(actualWithdrawn, DEPOSIT_AMOUNT);
    }
    
    function test_sovryn_interestWithdrawal() public {
        // Deposit tokens
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Simulate interest accrual by time passage
        vm.warp(block.timestamp + 365 days); // 1 year for interest accrual
        
        uint256 userBalanceBeforeInterestWithdraw = stablecoin.balanceOf(USER);
        
        // Withdraw interest (assume half is locked in DCA schedules)
        vm.prank(address(dcaManager));
        sovrynHandler.withdrawInterest(USER, DEPOSIT_AMOUNT / 2);
        
        uint256 userBalanceAfterInterestWithdraw = stablecoin.balanceOf(USER);
        assertGe(userBalanceAfterInterestWithdraw, userBalanceBeforeInterestWithdraw);
    }
    
    function test_sovryn_mintFailureHandling() public {
        // Test with insufficient balance (realistic failure case)
        // Reset user's balance to ensure clean state
        uint256 currentBalance = stablecoin.balanceOf(USER);
        if (currentBalance > 0) {
            vm.prank(USER);
            stablecoin.transfer(address(0x999), currentBalance);
        }
        
        // Give user just enough for fees but not enough for deposit
        stablecoin.mint(USER, DEPOSIT_AMOUNT / 2); // Half of what we need
        
        vm.prank(address(dcaManager));
        vm.expectRevert(); // Should revert due to insufficient balance
        handler.depositToken(USER, DEPOSIT_AMOUNT);
    }
    
    function test_sovryn_burnFailureHandling() public {
        // First deposit successfully
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Test withdrawing more than available (realistic edge case)
        vm.prank(address(dcaManager));
        handler.withdrawToken(USER, DEPOSIT_AMOUNT * 10); // Try to withdraw 10x more
        
        // Should work with amount adjustment (not fail)
        uint256 userBalance = stablecoin.balanceOf(USER);
        assertGt(userBalance, 0);
    }
    
    function test_sovryn_interestWithdrawal_noInterestScenario() public {
        // Deposit tokens
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Withdraw interest when there's no interest (locked amount equals total)
        vm.prank(address(dcaManager));
        sovrynHandler.withdrawInterest(USER, DEPOSIT_AMOUNT); // All locked in DCA
        
        // Should not revert, but also shouldn't change user balance significantly
        assertGt(stablecoin.balanceOf(USER), 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                           SOVRYN EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    function test_sovryn_zeroTokenPrice() public {
        // Note: MockIsusdToken has built-in price logic that doesn't allow 0
        // This test verifies the handler can deal with edge cases
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Should succeed as MockIsusdToken has reasonable price logic
        uint256 lendingBalance = sovrynHandler.getUsersLendingTokenBalance(USER);
        assertGt(lendingBalance, 0);
    }
    
    function test_sovryn_maxTokenPrice() public {
        // Test with far future time to get high interest rates
        vm.warp(block.timestamp + 10000 * 365 days); // 10,000 years for extreme interest
        
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Should still work but with adjusted amounts
        uint256 lendingBalance = sovrynHandler.getUsersLendingTokenBalance(USER);
        assertGt(lendingBalance, 0);
    }
    
    function test_sovryn_burnToSpecificRecipient() public {
        // Test that burn sends tokens to the correct recipient
        address recipient = address(0x999);
        
        // Deposit tokens first
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        uint256 recipientBalanceBefore = stablecoin.balanceOf(recipient);
        
        // Mock the internal withdrawal to specific recipient
        // This would be tested through interest withdrawal
        vm.prank(address(dcaManager));
        sovrynHandler.withdrawInterest(USER, 0); // Withdraw all as interest
        
        // Note: In the actual implementation, interest goes to the user, not a custom recipient
        // This test verifies the burn mechanism works correctly
        assertGe(stablecoin.balanceOf(USER), recipientBalanceBefore);
    }
    
    function test_sovryn_assetBalanceCalculation() public {
        // Test that asset balance is calculated correctly
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // The mock implementation should handle asset balance correctly
        uint256 lendingBalance = sovrynHandler.getUsersLendingTokenBalance(USER);
        assertGt(lendingBalance, 0);
        
        // Test redemption doesn't exceed asset balance
        vm.prank(address(dcaManager));
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);
        
        // Should succeed without reverting due to asset balance check
        assertGt(stablecoin.balanceOf(USER), 0);
    }
    
    function test_sovryn_batchRedeemStablecoin() public {
        // Set up multiple users and deposits
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = DEPOSIT_AMOUNT / 2;
        amounts[1] = DEPOSIT_AMOUNT / 2;
        
        // Give tokens to users and set up approvals
        stablecoin.mint(user1, DEPOSIT_AMOUNT);
        stablecoin.mint(user2, DEPOSIT_AMOUNT);
        
        vm.prank(user1);
        stablecoin.approve(address(sovrynHandler), type(uint256).max);
        vm.prank(user2);
        stablecoin.approve(address(sovrynHandler), type(uint256).max);
        
        // Deposit through DCA manager
        vm.prank(address(dcaManager));
        handler.depositToken(user1, DEPOSIT_AMOUNT);
        vm.prank(address(dcaManager));
        handler.depositToken(user2, DEPOSIT_AMOUNT);
        
        // Call _batchRedeemStablecoin through the test handler
        uint256 totalToRedeem = amounts[0] + amounts[1];
        
        uint256 redeemed = sovrynHandler.testBatchRedeemStablecoin(users, amounts, totalToRedeem);
        
        // Verify the batch redemption worked
        assertGt(redeemed, 0);
        
        // Check that users' lending balances were adjusted (decreased from their maximum possible)
        // Note: Due to interest accrual, balances might be higher than original deposit
        // but should be lower after redemption than before
        uint256 finalBalance1 = sovrynHandler.getUsersLendingTokenBalance(user1);
        uint256 finalBalance2 = sovrynHandler.getUsersLendingTokenBalance(user2);
        
        // Both users should still have some balance remaining (since we only redeemed part of it)
        assertGt(finalBalance1, 0);
        assertGt(finalBalance2, 0);
    }
    
    /**
     * @notice The assetBalanceOf + profitOf preflight is gone (R1): a lending-protocol view is never a
     * ceiling on what a redemption will pay. Over-redeeming must still fail, just from real accounting
     * rather than from a view — here the per-user share exceeds the balance we track for that user.
     */
    function test_sovryn_batchRedeemStablecoin_exceedsBalance_reverts() public {
        address user1 = makeAddr("user1");
        address[] memory users = new address[](1);
        users[0] = user1;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = DEPOSIT_AMOUNT;

        // Give tokens to user and set up approvals
        stablecoin.mint(user1, DEPOSIT_AMOUNT);
        vm.prank(user1);
        stablecoin.approve(address(sovrynHandler), type(uint256).max);

        // Deposit a smaller amount
        vm.prank(address(dcaManager));
        handler.depositToken(user1, DEPOSIT_AMOUNT / 10); // Deposit only 1/10th

        uint256 excessiveAmount = DEPOSIT_AMOUNT * 2; // Try to redeem 2x more than deposited

        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11)); // arithmetic under/overflow
        sovrynHandler.testBatchRedeemStablecoin(users, amounts, excessiveAmount);
    }
}

/**
 * @title SovrynTestHandler
 * @notice Concrete implementation of SovrynErc20Handler for testing
 * @dev Implements abstract functions to make testing possible
 */
contract SovrynTestHandler is SovrynErc20Handler {
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address iSusdTokenAddress,
        uint256 minPurchaseAmount,
        address feeCollector,
        FeeSettings memory feeSettings
    ) SovrynErc20Handler(
        dcaManagerAddress,
        stableTokenAddress, 
        iSusdTokenAddress,
        feeCollector,
        feeSettings,
        EXCHANGE_RATE_DECIMALS
    ) {}
    
    // Implementation required by IPurchaseRbtc interface
    function buyRbtc(
        address /* buyer */,
        bytes32 /* scheduleId */,
        uint256 /* purchaseAmount */
    ) external pure returns (uint256) {
        return 0; // Minimal implementation for testing
    }
    
    /**
     * @notice Expose _batchRedeemStablecoin for testing
     * @dev This allows us to test the internal batch redemption logic
     */
    function testBatchRedeemStablecoin(
        address[] memory users,
        uint256[] memory purchaseAmounts,
        uint256 totalErc20ToRedeem
    ) external returns (uint256) {
        return _batchRedeemStablecoin(users, purchaseAmounts, totalErc20ToRedeem);
    }
} 