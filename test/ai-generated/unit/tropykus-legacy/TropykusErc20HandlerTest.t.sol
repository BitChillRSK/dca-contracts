// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {HandlerTestHarness} from "../HandlerTestHarness.t.sol";
import {ITokenHandler} from "../../../../src/interfaces/ITokenHandler.sol";
import {IFeeHandler} from "../../../../src/interfaces/IFeeHandler.sol";
import {IPurchaseUniswap} from "../../../../src/interfaces/IPurchaseUniswap.sol";
import {TropykusErc20Handler} from "../../../../src/tropykus-legacy/TropykusErc20Handler.sol";
import {MockKdocToken} from "../../../mocks/MockKdocToken.sol";
import {MockStablecoin} from "../../../mocks/MockStablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenLending} from "../../../../src/interfaces/ITokenLending.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../../../Constants.sol";

/**
 * @title TropykusErc20HandlerTest 
 * @notice Unit tests for TropykusErc20Handler using shared test harness
 */
contract TropykusErc20HandlerTest is HandlerTestHarness {
    
    // Tropykus-specific contracts
    MockKdocToken public kToken;
    TropykusTestHandler public tropykusHandler;
    
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
        
        tropykusHandler = new TropykusTestHandler(
            address(dcaManager),
            address(stablecoin),
            address(kToken),
            FEE_COLLECTOR,
            feeSettings,
            OWNER
        );
        
        return ITokenHandler(address(tropykusHandler));
    }
    
    function getRouteIndex() internal pure override returns (uint256) {
        return TROPYKUS_INDEX;
    }
    
    function isDexHandler() internal pure override returns (bool) {
        return false; // Regular Tropykus handler, not DEX variant
    }
    
    function isLendingHandler() internal pure override returns (bool) {
        return true; // Tropykus handlers support lending
    }
    
    function getShareToken() internal view override returns (IERC20) {
        return IERC20(address(kToken));
    }
    
    function setupHandlerSpecifics() internal override {
        // Deploy mock kToken for Tropykus lending
        kToken = new MockKdocToken(address(stablecoin));
        
        // Note: MockKdocToken has built-in time-based exchange rate calculation
        
        // Give kToken some underlying tokens to work with
        stablecoin.mint(address(kToken), 1000000 ether);
    }
    
    /*//////////////////////////////////////////////////////////////
                           TROPYKUS-SPECIFIC TESTS
    //////////////////////////////////////////////////////////////*/

    function test_tropykus_exchangeRateDecimalsHardcoded() public {
        assertEq(tropykusHandler.EXCHANGE_RATE_DECIMALS(), 1e18);
    }
    
    function test_tropykus_kTokenMinting() public {
        uint256 initialKTokenBalance = kToken.balanceOf(address(handler));
        
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        uint256 finalKTokenBalance = kToken.balanceOf(address(handler));
        assertGt(finalKTokenBalance, initialKTokenBalance);
    }
    
    function test_tropykus_exchangeRateEffect() public {
        // Deposit some tokens
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Simulate interest accrual by advancing time to increase exchange rate
        vm.warp(block.timestamp + 365 days); // 1 year for 5% interest accrual
        
        // IMPORTANT: Call exchangeRateCurrent() first to accrue interest after time warp
        // This updates the stored exchange rate based on the new timestamp
        kToken.exchangeRateCurrent();
        
        // Check that accrued interest is calculated correctly
        vm.prank(address(dcaManager));
        uint256 accruedInterest = tropykusHandler.getAccruedInterest(USER, DEPOSIT_AMOUNT);
        assertGt(accruedInterest, 0);
    }

    /// @notice Write paths call `exchangeRateCurrent` (mutates stored); views call `exchangeRateStored`.
    function test_tropykus_writeUsesCurrentRate_viewUsesStored() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        uint256 storedAtDeposit = kToken.exchangeRateStored();
        vm.warp(block.timestamp + 365 days);

        vm.prank(address(dcaManager));
        assertEq(tropykusHandler.getAccruedInterest(USER, DEPOSIT_AMOUNT), 0);

        uint256 userBefore = stablecoin.balanceOf(USER);
        vm.expectCall(address(kToken), abi.encodeWithSelector(kToken.exchangeRateCurrent.selector));
        vm.prank(address(dcaManager));
        tropykusHandler.withdrawInterest(USER, DEPOSIT_AMOUNT);
        assertGt(stablecoin.balanceOf(USER), userBefore);
        assertGt(kToken.exchangeRateStored(), storedAtDeposit);
    }
    
    function test_tropykus_redemption_adjustsForAvailableBalance() public {
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
    
    function test_tropykus_interestWithdrawal() public {
        // Deposit tokens
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Simulate interest accrual by advancing time
        vm.warp(block.timestamp + 365 days); // 1 year for interest accrual
        
        uint256 userBalanceBeforeInterestWithdraw = stablecoin.balanceOf(USER);
        
        // Withdraw interest (assume half is locked in DCA schedules)
        vm.prank(address(dcaManager));
        tropykusHandler.withdrawInterest(USER, DEPOSIT_AMOUNT / 2);
        
        uint256 userBalanceAfterInterestWithdraw = stablecoin.balanceOf(USER);
        assertGe(userBalanceAfterInterestWithdraw, userBalanceBeforeInterestWithdraw);
    }
    
    function test_tropykus_mintFailureHandling() public {
        // Hop-1 insufficient balance (same as the Sovryn/LayerBank twin). The zero-mint guard is
        // `test_tropykus_zeroMintReverts`.
        uint256 currentBalance = stablecoin.balanceOf(USER);
        if (currentBalance > 0) {
            vm.prank(USER);
            stablecoin.transfer(address(0x999), currentBalance);
        }

        stablecoin.mint(USER, DEPOSIT_AMOUNT / 2);

        vm.prank(address(dcaManager));
        vm.expectRevert();
        handler.depositToken(USER, DEPOSIT_AMOUNT);
    }

    function test_tropykus_zeroMintReverts() public {
        kToken.setForceZeroMint(true);

        vm.prank(address(dcaManager));
        vm.expectRevert(ITokenLending.TokenLending__LendingProtocolDepositFailed.selector);
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        assertEq(tropykusHandler.getUserShares(USER), 0);
        assertEq(kToken.balanceOf(address(handler)), 0);
    }
    
    function test_tropykus_redeemFailureHandling() public {
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
    
    /**
     * @notice R1 / R20. A Compound-style market can return the success code and still pay nothing. The kToken
     * is burnt either way, and `DcaManager` has already debited the schedule by then, so accepting that as a
     * successful withdrawal would hand the user a zero transfer and destroy their principal. The measured
     * delta, not the return code, decides whether the redemption happened.
     */
    function test_tropykus_zeroPayoutRedeemReverts() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        uint256 kTokenBalanceBefore = tropykusHandler.getUserShares(USER);
        uint256 userBalanceBefore = stablecoin.balanceOf(USER);

        kToken.setSilentZeroPayout(true);

        vm.prank(address(dcaManager));
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenLending.TokenLending__ZeroStablecoinReceived.selector, WITHDRAWAL_AMOUNT
            )
        );
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);

        // the revert must leave both the user's stablecoin and their lending position untouched
        assertEq(stablecoin.balanceOf(USER), userBalanceBefore);
        assertEq(tropykusHandler.getUserShares(USER), kTokenBalanceBefore);
    }

    /**
     * @notice Interest withdrawals go through the same redeem path and must not pay zero either.
     */
    function test_tropykus_zeroPayoutInterestWithdrawalReverts() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + 365 days);

        uint256 kTokenBalanceBefore = tropykusHandler.getUserShares(USER);
        uint256 userBalanceBefore = stablecoin.balanceOf(USER);

        kToken.setSilentZeroPayout(true);

        // the accrued amount is derived from exchangeRateStored while the redeem uses exchangeRateCurrent, so
        // the revert argument is not predictable here; that the guard fires at all is what matters
        vm.prank(address(dcaManager));
        vm.expectRevert();
        tropykusHandler.withdrawInterest(USER, DEPOSIT_AMOUNT / 2);

        assertEq(stablecoin.balanceOf(USER), userBalanceBefore);
        assertEq(tropykusHandler.getUserShares(USER), kTokenBalanceBefore);
    }

    /*//////////////////////////////////////////////////////////////
                           TROPYKUS EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice `redeem` burns exactly the share count the base booked out, so the two agree to the wei.
     * @dev This is what share-sizing buys over `redeemUnderlying`, where Tropykus would derive the burn
     *      from its own rate and the book could come out below it.
     */
    function test_tropykus_bookDebitEqualsKtokenBurn() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + 365 days);

        uint256 bookBefore = tropykusHandler.getUserShares(USER);
        uint256 heldBefore = kToken.balanceOf(address(handler));

        vm.prank(address(dcaManager));
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);

        uint256 bookDebit = bookBefore - tropykusHandler.getUserShares(USER);
        assertGt(bookDebit, 0);
        assertEq(bookDebit, heldBefore - kToken.balanceOf(address(handler)));
    }

    function test_tropykus_zeroTimeExchangeRate() public {
        // Test at deployment time when exchange rate is at starting value
        uint256 exchangeRate = kToken.exchangeRateCurrent();
        assertGt(exchangeRate, 0); // Should never be zero
        
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Should work with starting exchange rate
        uint256 lendingBalance = tropykusHandler.getUserShares(USER);
        assertGt(lendingBalance, 0);
    }
    
    function test_tropykus_futureExchangeRate() public {
        // Test with future time when exchange rate is higher
        vm.warp(block.timestamp + 365 days * 10); // 10 years in the future
        
        uint256 exchangeRate = kToken.exchangeRateCurrent();
        assertGt(exchangeRate, 0.02e18); // Should be higher than starting rate
        
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Should still work but with adjusted amounts
        uint256 lendingBalance = tropykusHandler.getUserShares(USER);
        assertGt(lendingBalance, 0);
    }

    function test_tropykus_batchRetrieveStablecoin_exceedsBalance_reverts() public {
        address user1 = makeAddr("user1");
        address[] memory users = new address[](1);
        users[0] = user1;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = DEPOSIT_AMOUNT;

        stablecoin.mint(user1, DEPOSIT_AMOUNT);
        vm.prank(user1);
        stablecoin.approve(address(tropykusHandler), type(uint256).max);

        vm.prank(address(dcaManager));
        handler.depositToken(user1, DEPOSIT_AMOUNT / 10);

        uint256 excessiveAmount = DEPOSIT_AMOUNT * 2;
        uint256 available = tropykusHandler.getUserShares(user1);
        uint256 exchangeRate = kToken.exchangeRateCurrent();
        uint256 totalKtokenToRedeem =
            Math.mulDiv(excessiveAmount, EXCHANGE_RATE_DECIMALS, exchangeRate, Math.Rounding.Ceil);
        uint256 requested = Math.mulDiv(totalKtokenToRedeem, amounts[0], excessiveAmount, Math.Rounding.Ceil);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenLending.TokenLending__InsufficientShares.selector, user1, requested, available
            )
        );
        tropykusHandler.testBatchRetrieveStablecoin(users, amounts, excessiveAmount);
    }

    function test_tropykus_batchRetrieveStablecoin_zeroPayout_reverts() public {
        address user1 = makeAddr("user1");
        address[] memory users = new address[](1);
        users[0] = user1;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = DEPOSIT_AMOUNT / 2;

        stablecoin.mint(user1, DEPOSIT_AMOUNT);
        vm.prank(user1);
        stablecoin.approve(address(tropykusHandler), type(uint256).max);

        vm.prank(address(dcaManager));
        handler.depositToken(user1, DEPOSIT_AMOUNT);

        uint256 kTokenBalanceBefore = tropykusHandler.getUserShares(user1);

        kToken.setSilentZeroPayout(true);

        vm.expectRevert(
            abi.encodeWithSelector(ITokenLending.TokenLending__ZeroStablecoinReceived.selector, amounts[0])
        );
        tropykusHandler.testBatchRetrieveStablecoin(users, amounts, amounts[0]);

        assertEq(tropykusHandler.getUserShares(user1), kTokenBalanceBefore);
    }
}

/**
 * @title TropykusTestHandler
 * @notice Concrete implementation of TropykusErc20Handler for testing
 * @dev Implements abstract functions to make testing possible
 */
contract TropykusTestHandler is TropykusErc20Handler {
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address kTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        address initialOwner
    ) TropykusErc20Handler(
        dcaManagerAddress,
        stableTokenAddress, 
        kTokenAddress,
        feeCollector,
        feeSettings,
        initialOwner
    ) {}
    
    function testBatchRetrieveStablecoin(
        address[] memory users,
        uint256[] memory purchaseAmounts,
        uint256 totalStablecoinAmount
    ) external returns (uint256) {
        return _batchRetrieveStablecoin(users, purchaseAmounts, totalStablecoinAmount);
    }
} 