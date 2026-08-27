// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {HandlerTestHarness} from "../HandlerTestHarness.t.sol";
import {ITokenHandler} from "../../../../src/interfaces/ITokenHandler.sol";
import {IFeeHandler} from "../../../../src/interfaces/IFeeHandler.sol";
import {IPurchaseUniswap} from "../../../../src/interfaces/IPurchaseUniswap.sol";
import {IWRBTC} from "../../../../src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "../../../../src/interfaces/ICoinPairPrice.sol";
import {TropykusErc20HandlerDex} from "../../../../src/tropykus-legacy/TropykusErc20HandlerDex.sol";
import {MockKToken} from "../../../mocks/MockKToken.sol";
import {MockWrbtcToken} from "../../../mocks/MockWrbtcToken.sol";
import {MockMocOracle} from "../../../mocks/MockMocOracle.sol";
import {MockSwapRouter02} from "../../../mocks/MockSwapRouter02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../../../script/Constants.sol";
import {handlerBatchBuyOne} from "test/utils/BatchBuyOne.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";

/**
 * @title TropykusErc20HandlerDexTest 
 * @notice Unit tests for TropykusErc20HandlerDex (DEX variant) using shared test harness
 */
contract TropykusErc20HandlerDexTest is HandlerTestHarness {

    event PurchaseUniswap_AmountOutMinimumPercentUpdated(uint256 oldValue, uint256 newValue);
    event PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(uint256 oldValue, uint256 newValue);
    
    // Tropykus DEX-specific contracts
    MockKToken public kToken;
    MockWrbtcToken public wrbtcToken;
    MockMocOracle public mocOracle;
    MockSwapRouter02 public mockRouter;
    TropykusErc20HandlerDex public tropykusDexHandler;
    
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
        
        address[] memory intermediateTokens = new address[](0); // No intermediate tokens for direct swap
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000; // 0.3% fee
        
        IPurchaseUniswap.UniswapSettings memory uniswapSettings = IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(address(wrbtcToken)),
            swapRouter02: ISwapRouter02(address(mockRouter)),
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracle: ICoinPairPrice(address(mocOracle))
        });
        
        tropykusDexHandler = new TropykusErc20HandlerDex(
            address(dcaManager),
            address(stablecoin),
            address(kToken),
            uniswapSettings,
            FEE_COLLECTOR,
            feeSettings,
            9970, // 99.7% minimum output
            9900 // 99% safety check
        );
        
        return ITokenHandler(address(tropykusDexHandler));
    }
    
    function getRouteIndex() internal pure override returns (uint256) {
        return TROPYKUS_INDEX;
    }
    
    function isDexHandler() internal pure override returns (bool) {
        return true; // This is the DEX variant
    }
    
    function isLendingHandler() internal pure override returns (bool) {
        return true; // Tropykus handlers support lending
    }
    
    function getShareToken() internal view override returns (IERC20) {
        return IERC20(address(kToken));
    }
    
    function setupHandlerSpecifics() internal override {
        // Deploy mock tokens
        kToken = new MockKToken(address(stablecoin));
        wrbtcToken = new MockWrbtcToken();
        mocOracle = new MockMocOracle();
        mockRouter = new MockSwapRouter02(wrbtcToken, BTC_PRICE);
        
        // Note: MockKToken has built-in time-based exchange rate calculation
        
        // Note: Oracle price setup would need MockMocProxy price methods
        
        // Give tokens some initial balances
        stablecoin.mint(address(kToken), 1000000 ether);
        vm.deal(address(mockRouter), 1000 ether); // Give router some ETH for WRBTC deposits
    }
    
    /*//////////////////////////////////////////////////////////////
                           TROPYKUS DEX-SPECIFIC TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_tropykusDex_deployment() public {
        // Verify DEX-specific configuration
        assertEq(tropykusDexHandler.getAmountOutMinimumPercent(), 9970); // 99.7%
        assertEq(tropykusDexHandler.getAmountOutMinimumSafetyCheck(), 9900); // 99%
        assertNotEq(address(tropykusDexHandler.getMocOracle()), address(0));
        assertGt(tropykusDexHandler.getSwapPath().length, 0);
    }
    
    function test_tropykusDex_setAmountOutMinimumPercent_success() public {
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumPercent(9950); // 99.5% in basis points (above safety check)
        
        assertEq(tropykusDexHandler.getAmountOutMinimumPercent(), 9950);
    }
    
    function test_tropykusDex_setAmountOutMinimumPercent_reverts_invalidRange() public {
        // Test upper bound (over 100% in ether scale)
        vm.expectRevert();
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumPercent(1.01 ether); // 101% in ether scale
        
        // Test lower bound (below safety check)
        uint256 safetyCheck = tropykusDexHandler.getAmountOutMinimumSafetyCheck();
        vm.expectRevert();
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumPercent(safetyCheck - 1);
    }
    
    function test_tropykusDex_setAmountOutMinimumPercent_reverts_notOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(USER);
        tropykusDexHandler.setAmountOutMinimumPercent(9500);
    }
    
    function test_tropykusDex_setAmountOutMinimumSafetyCheck_success() public {
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumSafetyCheck(9000); // 90% in basis points
        
        assertEq(tropykusDexHandler.getAmountOutMinimumSafetyCheck(), 9000);
    }
    
    function test_tropykusDex_setAmountOutMinimumSafetyCheck_reverts_invalidRange() public {
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumSafetyCheckTooHigh.selector);
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumSafetyCheck(1.01 ether); // 101% in ether scale
    }

    function test_tropykusDex_setAmountOutMinimumSafetyCheck_reverts_aboveCurrentPercent() public {
        uint256 percent = tropykusDexHandler.getAmountOutMinimumPercent();
        uint256 safetyBefore = tropykusDexHandler.getAmountOutMinimumSafetyCheck();

        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooLow.selector);
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumSafetyCheck(percent + 1);

        assertEq(tropykusDexHandler.getAmountOutMinimumSafetyCheck(), safetyBefore);
        assertEq(tropykusDexHandler.getAmountOutMinimumPercent(), percent);
    }

    function test_tropykusDex_setAmountOutMinimumPercent_allowsEqualityWithSafety() public {
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumPercent(0.99 ether);
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumSafetyCheck(0.95 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(0.99 ether, 0.95 ether);
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumPercent(0.95 ether);

        assertEq(tropykusDexHandler.getAmountOutMinimumPercent(), 0.95 ether);
        assertEq(tropykusDexHandler.getAmountOutMinimumSafetyCheck(), 0.95 ether);
    }

    function test_tropykusDex_setAmountOutMinimumSafetyCheck_allowsEqualityWithPercent() public {
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumPercent(0.99 ether);

        uint256 safetyBefore = tropykusDexHandler.getAmountOutMinimumSafetyCheck();
        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(safetyBefore, 0.99 ether);
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumSafetyCheck(0.99 ether);

        assertEq(tropykusDexHandler.getAmountOutMinimumSafetyCheck(), 0.99 ether);
        assertEq(tropykusDexHandler.getAmountOutMinimumPercent(), 0.99 ether);
    }

    function test_tropykusDex_setSlippageSettings_bothAtHundredPercent() public {
        uint256 percentBefore = tropykusDexHandler.getAmountOutMinimumPercent();
        uint256 safetyBefore = tropykusDexHandler.getAmountOutMinimumSafetyCheck();

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(percentBefore, 1 ether);
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumPercent(1 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(safetyBefore, 1 ether);
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumSafetyCheck(1 ether);

        assertEq(tropykusDexHandler.getAmountOutMinimumPercent(), 1 ether);
        assertEq(tropykusDexHandler.getAmountOutMinimumSafetyCheck(), 1 ether);
    }

    function test_tropykusDex_setSlippageSettings_raiseThenLower() public {
        uint256 percentBefore = tropykusDexHandler.getAmountOutMinimumPercent();
        uint256 safetyBefore = tropykusDexHandler.getAmountOutMinimumSafetyCheck();

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(percentBefore, 0.995 ether);
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumPercent(0.995 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(safetyBefore, 0.95 ether);
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumSafetyCheck(0.95 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(0.995 ether, 0.997 ether);
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumPercent(0.997 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(0.95 ether, 0.96 ether);
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumSafetyCheck(0.96 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(0.997 ether, 0.96 ether);
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumPercent(0.96 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(0.96 ether, 0.90 ether);
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumSafetyCheck(0.90 ether);

        assertEq(tropykusDexHandler.getAmountOutMinimumPercent(), 0.96 ether);
        assertEq(tropykusDexHandler.getAmountOutMinimumSafetyCheck(), 0.90 ether);
    }

    function test_tropykusDex_constructor_allows_equal_percent_and_safety() public {
        TropykusErc20HandlerDex handler = _deployTropykusDexWithSlippage(0.99 ether, 0.99 ether);
        assertEq(handler.getAmountOutMinimumPercent(), 0.99 ether);
        assertEq(handler.getAmountOutMinimumSafetyCheck(), 0.99 ether);
    }

    function test_tropykusDex_constructor_allows_both_at_hundred_percent() public {
        TropykusErc20HandlerDex handler = _deployTropykusDexWithSlippage(1 ether, 1 ether);
        assertEq(handler.getAmountOutMinimumPercent(), 1 ether);
        assertEq(handler.getAmountOutMinimumSafetyCheck(), 1 ether);
    }

    function test_tropykusDex_constructor_reverts_when_percent_too_high() public {
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooHigh.selector);
        _deployTropykusDexWithSlippage(1.01 ether, 0.99 ether);
    }

    function test_tropykusDex_constructor_reverts_when_safety_too_high() public {
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumSafetyCheckTooHigh.selector);
        _deployTropykusDexWithSlippage(1 ether, 1.01 ether);
    }

    function test_tropykusDex_constructor_reverts_when_percent_below_safety() public {
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooLow.selector);
        _deployTropykusDexWithSlippage(0.98 ether, 0.99 ether);
    }
    
    function test_tropykusDex_setPurchasePath_success() public {
        address[] memory intermediateTokens = new address[](0); // Direct swap, no intermediates
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000; // 0.3%
        
        vm.prank(OWNER);
        tropykusDexHandler.setPurchasePath(intermediateTokens, poolFeeRates);
        
        bytes memory expectedPath = abi.encodePacked(
            address(stablecoin),
            uint24(3000),
            address(wrbtcToken)
        );
        assertEq(tropykusDexHandler.getSwapPath(), expectedPath);
    }
    
    function test_tropykusDex_setPurchasePath_reverts_invalidLength() public {
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = address(0x123);
        uint24[] memory poolFeeRates = new uint24[](1); // Should be 2 for 1 intermediate token
        poolFeeRates[0] = 3000;
        
        vm.expectRevert();
        vm.prank(OWNER);
        tropykusDexHandler.setPurchasePath(intermediateTokens, poolFeeRates);
    }
    
    function test_tropykusDex_setPurchasePath_reverts_notOwner() public {
        address[] memory intermediateTokens = new address[](0);
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;
        
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(USER);
        tropykusDexHandler.setPurchasePath(intermediateTokens, poolFeeRates);
    }
    
    /*//////////////////////////////////////////////////////////////
                           TROPYKUS DEX ORACLE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_tropykusDex_oraclePrice() public {
        uint256 price = tropykusDexHandler.getMocOracle().getPrice();
        assertGt(price, 0); // Should be greater than 0 by default
    }
    
    function test_tropykusDex_oraclePriceValidation() public {
        // Set oracle to return 0 (should cause issues)
        mocOracle.setPrice(0);
        
        // This might cause issues in swap calculations
        // The exact behavior depends on implementation
        uint256 price = tropykusDexHandler.getMocOracle().getPrice();
        assertEq(price, 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                           TROPYKUS DEX SWAP PATH TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_tropykusDex_swapPathValidation() public {
        bytes memory path = tropykusDexHandler.getSwapPath();
        assertGt(path.length, 0);
        
        // The path should include both input and output tokens
        // Exact validation depends on how the path is structured
        assertTrue(path.length >= 43); // Minimum for single-hop path (20 + 3 + 20 bytes)
    }
    
    /*//////////////////////////////////////////////////////////////
                           COMBINED FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_tropykusDex_depositAndLendingCombined() public {
        // Test that DEX handler maintains lending functionality
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Check lending balance (inherited from Tropykus base)
        uint256 lendingBalance = tropykusDexHandler.getUserShares(USER);
        assertGt(lendingBalance, 0);
        
        // Check kToken balance increased
        uint256 kTokenBalance = kToken.balanceOf(address(handler));
        assertGt(kTokenBalance, 0);
    }
    
    function test_tropykusDex_withdrawWithDexCapabilities() public {
        // Deposit first
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Withdraw (should use Tropykus redemption, not DEX)
        uint256 userBalanceBefore = stablecoin.balanceOf(USER);
        
        vm.prank(address(dcaManager));
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);
        
        uint256 userBalanceAfter = stablecoin.balanceOf(USER);
        assertGt(userBalanceAfter, userBalanceBefore);
    }
    
    /*//////////////////////////////////////////////////////////////
                           EDGE CASES FOR DEX VARIANT
    //////////////////////////////////////////////////////////////*/
    
    function test_tropykusDex_extremeSlippageSettings() public {
        // Test with extreme but valid slippage settings
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumSafetyCheck(5000); // Lower safety check first
        
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumPercent(5000); // 50% (very high slippage)
        
        assertEq(tropykusDexHandler.getAmountOutMinimumPercent(), 5000);
        
        vm.prank(OWNER);
        tropykusDexHandler.setAmountOutMinimumPercent(9999); // 99.99% (very low slippage)
        
        assertEq(tropykusDexHandler.getAmountOutMinimumPercent(), 9999);
    }
    
    function test_tropykusDex_oracleFailure() public {
        // Test behavior when oracle fails
        // This depends on how the handler deals with oracle failures
        mocOracle.setInvalidPrice();
        
        // Accessing price info should show invalid state
        (, bool isValid, ) = tropykusDexHandler.getMocOracle().getPriceInfo();
        assertFalse(isValid);
    }
    
    function test_tropykusDex_swapPathEdgeCases() public {
        // Test with multi-hop path
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = address(0x123); // Intermediate token
        uint24[] memory poolFeeRates = new uint24[](2);
        poolFeeRates[0] = 3000;
        poolFeeRates[1] = 3000;
        
        vm.prank(OWNER);
        tropykusDexHandler.setPurchasePath(intermediateTokens, poolFeeRates);
        
        bytes memory expectedPath = abi.encodePacked(
            address(stablecoin),
            uint24(3000),
            address(0x123), // Intermediate token
            uint24(3000), 
            address(wrbtcToken)
        );
        assertEq(tropykusDexHandler.getSwapPath(), expectedPath);
        assertEq(tropykusDexHandler.getSwapPath().length, 66); // 3 addresses + 2 fees
    }

    function test_tropykusDex_withdrawInterestPaysUser() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        uint256 userBalanceBefore = stablecoin.balanceOf(USER);
        
        vm.prank(address(dcaManager));
        tropykusDexHandler.withdrawInterest(USER, 0);
        
        assertGt(stablecoin.balanceOf(USER), userBalanceBefore);
        assertEq(stablecoin.balanceOf(address(tropykusDexHandler)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                           PURCHASE PIPELINE COVERAGE
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Test that batchBuyRbtc funds the purchase by redeeming the buyer's lending shares
     * @dev Covers the shared PurchaseRbtc pipeline resolving _retrieveStablecoin to LendingErc20Handler
     */
    function test_tropykusDex_lengthOneBatchRedeemsSharesForPurchase() public {
        // Setup: User deposits tokens first
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Verify initial state
        uint256 initialLendingBalance = tropykusDexHandler.getUserShares(USER);
        assertGt(initialLendingBalance, 0);
        
        uint256 purchaseAmount = 100 ether;
        bytes32 mockScheduleId = keccak256("test_schedule");
        
        // Call batchBuyRbtc, which redeems shares through _retrieveStablecoin
        vm.prank(address(dcaManager));
        handlerBatchBuyOne(IPurchaseRbtc(address(tropykusDexHandler)), USER, mockScheduleId, purchaseAmount);
        
        // Verify the shares were redeemed - lending balance should be reduced
        uint256 finalLendingBalance = tropykusDexHandler.getUserShares(USER);
        assertLt(finalLendingBalance, initialLendingBalance);
        
        // Verify RBTC was accumulated
        uint256 rbtcBalance = tropykusDexHandler.getAccumulatedRbtcBalance(USER);
        assertGt(rbtcBalance, 0);
    }
    
    /**
     * @notice Test that batchBuyRbtc funds the purchase by redeeming every buyer's lending shares
     * @dev Covers the shared PurchaseRbtc pipeline resolving _batchRetrieveStablecoin to LendingErc20Handler
     */
    function test_tropykusDex_batchBuyRbtcRedeemsSharesForPurchase() public {
        // Setup: Multiple users deposit tokens
        address user1 = address(0x2001);
        address user2 = address(0x2002);
        uint256 depositAmount1 = 500 ether;
        uint256 depositAmount2 = 300 ether;
        
        // Give users stablecoin balance and approve handler
        stablecoin.mint(user1, depositAmount1);
        stablecoin.mint(user2, depositAmount2);
        
        vm.prank(user1);
        stablecoin.approve(address(handler), type(uint256).max);
        vm.prank(user2);
        stablecoin.approve(address(handler), type(uint256).max);
        
        vm.prank(address(dcaManager));
        handler.depositToken(user1, depositAmount1);
        vm.prank(address(dcaManager));
        handler.depositToken(user2, depositAmount2);
        
        // Verify initial state
        uint256 initialBalance1 = tropykusDexHandler.getUserShares(user1);
        uint256 initialBalance2 = tropykusDexHandler.getUserShares(user2);
        assertGt(initialBalance1, 0);
        assertGt(initialBalance2, 0);
        
        // Prepare batch purchase data
        address[] memory buyers = new address[](2);
        buyers[0] = user1;
        buyers[1] = user2;
        
        bytes32[] memory scheduleIds = new bytes32[](2);
        scheduleIds[0] = keccak256("schedule1");
        scheduleIds[1] = keccak256("schedule2");
        
        uint256[] memory purchaseAmounts = new uint256[](2);
        purchaseAmounts[0] = 100 ether;
        purchaseAmounts[1] = 80 ether;
        
        // Call batchBuyRbtc, which redeems shares through _batchRetrieveStablecoin
        vm.prank(address(dcaManager));
        tropykusDexHandler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts);
        
        // Verify the shares were redeemed - lending balances should be reduced
        uint256 finalBalance1 = tropykusDexHandler.getUserShares(user1);
        uint256 finalBalance2 = tropykusDexHandler.getUserShares(user2);
        assertLt(finalBalance1, initialBalance1);
        assertLt(finalBalance2, initialBalance2);
        
        // Verify RBTC was accumulated for both users
        uint256 rbtcBalance1 = tropykusDexHandler.getAccumulatedRbtcBalance(user1);
        uint256 rbtcBalance2 = tropykusDexHandler.getAccumulatedRbtcBalance(user2);
        assertGt(rbtcBalance1, 0);
        assertGt(rbtcBalance2, 0);
    }

    function _deployTropykusDexWithSlippage(uint256 amountOutMinimumPercent, uint256 amountOutMinimumSafetyCheck)
        private
        returns (TropykusErc20HandlerDex)
    {
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        address[] memory intermediateTokens = new address[](0);
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;

        IPurchaseUniswap.UniswapSettings memory uniswapSettings = IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(address(wrbtcToken)),
            swapRouter02: ISwapRouter02(address(mockRouter)),
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracle: ICoinPairPrice(address(mocOracle))
        });

        return new TropykusErc20HandlerDex(
            address(dcaManager),
            address(stablecoin),
            address(kToken),
            uniswapSettings,
            FEE_COLLECTOR,
            feeSettings,
            amountOutMinimumPercent,
            amountOutMinimumSafetyCheck
        );
    }
} 