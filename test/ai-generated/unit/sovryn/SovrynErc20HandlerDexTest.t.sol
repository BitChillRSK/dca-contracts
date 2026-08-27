// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {HandlerTestHarness} from "../HandlerTestHarness.t.sol";
import {ITokenHandler} from "../../../../src/interfaces/ITokenHandler.sol";
import {IFeeHandler} from "../../../../src/interfaces/IFeeHandler.sol";
import {IPurchaseUniswap} from "../../../../src/interfaces/IPurchaseUniswap.sol";
import {IWRBTC} from "../../../../src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "../../../../src/interfaces/ICoinPairPrice.sol";
import {SovrynErc20HandlerDex} from "../../../../src/sovryn/SovrynErc20HandlerDex.sol";
import {MockIsusdToken} from "../../../mocks/MockIsusdToken.sol";
import {MockWrbtcToken} from "../../../mocks/MockWrbtcToken.sol";
import {MockMocOracle} from "../../../mocks/MockMocOracle.sol";
import {MockSwapRouter02} from "../../../mocks/MockSwapRouter02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../../../script/Constants.sol";
import {handlerBatchBuyOne} from "test/utils/BatchBuyOne.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {ownableUnauthorized} from "../../../utils/OzRevert.sol";

/**
 * @title SovrynErc20HandlerDexTest 
 * @notice Unit tests for SovrynErc20HandlerDex (DEX variant) using shared test harness
 */
contract SovrynErc20HandlerDexTest is HandlerTestHarness {

    event PurchaseUniswap_AmountOutMinimumPercentUpdated(uint256 oldValue, uint256 newValue);
    event PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(uint256 oldValue, uint256 newValue);
    
    // Sovryn DEX-specific contracts
    MockIsusdToken public iSusdToken;
    MockWrbtcToken public wrbtcToken;
    MockMocOracle public mocOracle;
    MockSwapRouter02 public mockRouter;
    SovrynErc20HandlerDex public sovrynDexHandler;
    
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
        
        sovrynDexHandler = new SovrynErc20HandlerDex(
            address(dcaManager),
            address(stablecoin),
            address(iSusdToken),
            uniswapSettings,
            FEE_COLLECTOR,
            feeSettings,
            9970, // 99.7% minimum output
            9900, // 99% safety check
            OWNER
        );
        
        return ITokenHandler(address(sovrynDexHandler));
    }
    
    function getRouteIndex() internal pure override returns (uint256) {
        return SOVRYN_INDEX;
    }
    
    function isDexHandler() internal pure override returns (bool) {
        return true; // This is the DEX variant
    }
    
    function isLendingHandler() internal pure override returns (bool) {
        return true; // Sovryn handlers support lending
    }
    
    function getShareToken() internal view override returns (IERC20) {
        return IERC20(address(iSusdToken));
    }
    
    function setupHandlerSpecifics() internal override {
        // Deploy mock tokens
        iSusdToken = new MockIsusdToken(address(stablecoin));
        wrbtcToken = new MockWrbtcToken();
        mocOracle = new MockMocOracle();
        mockRouter = new MockSwapRouter02(wrbtcToken, BTC_PRICE);
        
        // Note: MockIsusdToken has built-in token price logic
        // Setup oracle price (e.g., 1 Stablecoin = 0.00003 BTC) - will need oracle mock methods
        
        // Give tokens some initial balances
        stablecoin.mint(address(iSusdToken), 1000000 ether);
        vm.deal(address(mockRouter), 1000 ether); // Give router some ETH for WRBTC deposits
    }
    
    /*//////////////////////////////////////////////////////////////
                           SOVRYN DEX-SPECIFIC TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_sovrynDex_deployment() public {
        // Verify DEX-specific configuration
        assertEq(sovrynDexHandler.getAmountOutMinimumPercent(), 9970); // 99.7%
        assertEq(sovrynDexHandler.getAmountOutMinimumSafetyCheck(), 9900); // 99%
        assertNotEq(address(sovrynDexHandler.getMocOracle()), address(0));
        assertGt(sovrynDexHandler.getSwapPath().length, 0);
    }
    
    function test_sovrynDex_setAmountOutMinimumPercent_success() public {
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumPercent(9950); // 99.5% in basis points (above safety check)
        
        assertEq(sovrynDexHandler.getAmountOutMinimumPercent(), 9950);
    }
    
    function test_sovrynDex_setAmountOutMinimumPercent_reverts_invalidRange() public {
        // Test upper bound (over 100% in ether scale)
        vm.expectRevert();
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumPercent(1.01 ether); // 101% in ether scale
        
        // Test lower bound (below safety check)
        uint256 safetyCheck = sovrynDexHandler.getAmountOutMinimumSafetyCheck();
        vm.expectRevert();
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumPercent(safetyCheck - 1);
    }
    
    /**
     * @notice R1 / R20. When the redeem pays less than planned — SIP-0094's exit fee, or any short
     * redemption — the batch must not hand out more WRBTC than the swap produced. The per-user weights are
     * shares of the planned net total, so they still sum to one; dividing by the smaller actual spend would
     * credit each buyer a slice of rBTC the handler never received.
     */
    function test_sovrynDex_batchBuyRbtcCreditsNoMoreRbtcThanReceived() public {
        address buyerOne = makeAddr("dexBuyerOne");
        address buyerTwo = makeAddr("dexBuyerTwo");

        stablecoin.mint(buyerOne, DEPOSIT_AMOUNT);
        stablecoin.mint(buyerTwo, DEPOSIT_AMOUNT);
        vm.prank(buyerOne);
        stablecoin.approve(address(sovrynDexHandler), type(uint256).max);
        vm.prank(buyerTwo);
        stablecoin.approve(address(sovrynDexHandler), type(uint256).max);

        vm.startPrank(address(dcaManager));
        sovrynDexHandler.depositToken(buyerOne, DEPOSIT_AMOUNT);
        sovrynDexHandler.depositToken(buyerTwo, DEPOSIT_AMOUNT);
        vm.stopPrank();

        iSusdToken.setExitFeeBps(10); // the 0.10% Sovryn approved

        address[] memory buyers = new address[](2);
        buyers[0] = buyerOne;
        buyers[1] = buyerTwo;
        bytes32[] memory scheduleIds = new bytes32[](2);
        scheduleIds[0] = bytes32(uint256(1));
        scheduleIds[1] = bytes32(uint256(2));
        uint256[] memory purchaseAmounts = new uint256[](2);
        purchaseAmounts[0] = DEPOSIT_AMOUNT / 4;
        purchaseAmounts[1] = DEPOSIT_AMOUNT / 2;

        uint256 handlerWrbtcBefore = wrbtcToken.balanceOf(address(sovrynDexHandler));

        vm.prank(address(dcaManager));
        sovrynDexHandler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts);

        uint256 received = wrbtcToken.balanceOf(address(sovrynDexHandler)) - handlerWrbtcBefore;
        uint256 credited = sovrynDexHandler.getAccumulatedRbtcBalance(buyerOne)
            + sovrynDexHandler.getAccumulatedRbtcBalance(buyerTwo);

        assertGt(credited, 0);
        assertLe(credited, received, "credited more rBTC than the handler received");
    }

    function test_sovrynDex_setAmountOutMinimumPercent_reverts_notOwner() public {
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        sovrynDexHandler.setAmountOutMinimumPercent(9500);
    }
    
    function test_sovrynDex_setAmountOutMinimumSafetyCheck_success() public {
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumSafetyCheck(9000); // 90% in basis points
        
        assertEq(sovrynDexHandler.getAmountOutMinimumSafetyCheck(), 9000);
    }
    
    function test_sovrynDex_setAmountOutMinimumSafetyCheck_reverts_invalidRange() public {
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumSafetyCheckTooHigh.selector);
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumSafetyCheck(1.01 ether); // 101% in ether scale
    }

    function test_sovrynDex_setAmountOutMinimumSafetyCheck_reverts_aboveCurrentPercent() public {
        uint256 percent = sovrynDexHandler.getAmountOutMinimumPercent();
        uint256 safetyBefore = sovrynDexHandler.getAmountOutMinimumSafetyCheck();

        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooLow.selector);
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumSafetyCheck(percent + 1);

        assertEq(sovrynDexHandler.getAmountOutMinimumSafetyCheck(), safetyBefore);
        assertEq(sovrynDexHandler.getAmountOutMinimumPercent(), percent);
    }

    function test_sovrynDex_setAmountOutMinimumPercent_allowsEqualityWithSafety() public {
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumPercent(0.99 ether);
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumSafetyCheck(0.95 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(0.99 ether, 0.95 ether);
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumPercent(0.95 ether);

        assertEq(sovrynDexHandler.getAmountOutMinimumPercent(), 0.95 ether);
        assertEq(sovrynDexHandler.getAmountOutMinimumSafetyCheck(), 0.95 ether);
    }

    function test_sovrynDex_setAmountOutMinimumSafetyCheck_allowsEqualityWithPercent() public {
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumPercent(0.99 ether);

        uint256 safetyBefore = sovrynDexHandler.getAmountOutMinimumSafetyCheck();
        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(safetyBefore, 0.99 ether);
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumSafetyCheck(0.99 ether);

        assertEq(sovrynDexHandler.getAmountOutMinimumSafetyCheck(), 0.99 ether);
        assertEq(sovrynDexHandler.getAmountOutMinimumPercent(), 0.99 ether);
    }

    function test_sovrynDex_setSlippageSettings_bothAtHundredPercent() public {
        uint256 percentBefore = sovrynDexHandler.getAmountOutMinimumPercent();
        uint256 safetyBefore = sovrynDexHandler.getAmountOutMinimumSafetyCheck();

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(percentBefore, 1 ether);
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumPercent(1 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(safetyBefore, 1 ether);
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumSafetyCheck(1 ether);

        assertEq(sovrynDexHandler.getAmountOutMinimumPercent(), 1 ether);
        assertEq(sovrynDexHandler.getAmountOutMinimumSafetyCheck(), 1 ether);
    }

    function test_sovrynDex_setSlippageSettings_raiseThenLower() public {
        uint256 percentBefore = sovrynDexHandler.getAmountOutMinimumPercent();
        uint256 safetyBefore = sovrynDexHandler.getAmountOutMinimumSafetyCheck();

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(percentBefore, 0.995 ether);
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumPercent(0.995 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(safetyBefore, 0.95 ether);
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumSafetyCheck(0.95 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(0.995 ether, 0.997 ether);
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumPercent(0.997 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(0.95 ether, 0.96 ether);
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumSafetyCheck(0.96 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(0.997 ether, 0.96 ether);
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumPercent(0.96 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(0.96 ether, 0.90 ether);
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumSafetyCheck(0.90 ether);

        assertEq(sovrynDexHandler.getAmountOutMinimumPercent(), 0.96 ether);
        assertEq(sovrynDexHandler.getAmountOutMinimumSafetyCheck(), 0.90 ether);
    }

    function test_sovrynDex_constructor_allows_equal_percent_and_safety() public {
        SovrynErc20HandlerDex handler = _deploySovrynDexWithSlippage(0.99 ether, 0.99 ether);
        assertEq(handler.getAmountOutMinimumPercent(), 0.99 ether);
        assertEq(handler.getAmountOutMinimumSafetyCheck(), 0.99 ether);
    }

    function test_sovrynDex_constructor_allows_both_at_hundred_percent() public {
        SovrynErc20HandlerDex handler = _deploySovrynDexWithSlippage(1 ether, 1 ether);
        assertEq(handler.getAmountOutMinimumPercent(), 1 ether);
        assertEq(handler.getAmountOutMinimumSafetyCheck(), 1 ether);
    }

    function test_sovrynDex_constructor_reverts_when_percent_too_high() public {
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooHigh.selector);
        _deploySovrynDexWithSlippage(1.01 ether, 0.99 ether);
    }

    function test_sovrynDex_constructor_reverts_when_safety_too_high() public {
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumSafetyCheckTooHigh.selector);
        _deploySovrynDexWithSlippage(1 ether, 1.01 ether);
    }

    function test_sovrynDex_constructor_reverts_when_percent_below_safety() public {
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooLow.selector);
        _deploySovrynDexWithSlippage(0.98 ether, 0.99 ether);
    }
    
    function test_sovrynDex_setPurchasePath_success() public {
        address[] memory intermediateTokens = new address[](0); // Direct swap, no intermediates
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000; // 0.3%
        
        vm.prank(OWNER);
        sovrynDexHandler.setPurchasePath(intermediateTokens, poolFeeRates);
        
        bytes memory expectedPath = abi.encodePacked(
            address(stablecoin),
            uint24(3000),
            address(wrbtcToken)
        );
        assertEq(sovrynDexHandler.getSwapPath(), expectedPath);
    }
    
    function test_sovrynDex_setPurchasePath_reverts_invalidLength() public {
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = address(0x123);
        uint24[] memory poolFeeRates = new uint24[](1); // Should be 2 for 1 intermediate token
        poolFeeRates[0] = 3000;
        
        vm.expectRevert();
        vm.prank(OWNER);
        sovrynDexHandler.setPurchasePath(intermediateTokens, poolFeeRates);
    }
    
    function test_sovrynDex_setPurchasePath_reverts_notOwner() public {
        address[] memory intermediateTokens = new address[](0);
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;
        
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        sovrynDexHandler.setPurchasePath(intermediateTokens, poolFeeRates);
    }
    
    /*//////////////////////////////////////////////////////////////
                           SOVRYN DEX ORACLE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_sovrynDex_oraclePrice() public {
        uint256 price = sovrynDexHandler.getMocOracle().getPrice();
        assertGt(price, 0); // Should be greater than 0 by default
    }
    
    function test_sovrynDex_oraclePriceValidation() public {
        // Set oracle to return 0 (should cause issues)
        mocOracle.setPrice(0);
        
        // This might cause issues in swap calculations
        // The exact behavior depends on implementation
        uint256 price = sovrynDexHandler.getMocOracle().getPrice();
        assertEq(price, 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                           SOVRYN DEX SWAP PATH TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_sovrynDex_swapPathValidation() public {
        bytes memory path = sovrynDexHandler.getSwapPath();
        assertGt(path.length, 0);
        
        // The path should include both input and output tokens
        // Exact validation depends on how the path is structured
        assertTrue(path.length >= 43); // Minimum for single-hop path (20 + 3 + 20 bytes)
    }
    
    /*//////////////////////////////////////////////////////////////
                           COMBINED FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_sovrynDex_depositAndLendingCombined() public {
        // Test that DEX handler maintains lending functionality
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Check lending balance (inherited from Sovryn base)
        uint256 lendingBalance = sovrynDexHandler.getUserShares(USER);
        assertGt(lendingBalance, 0);
        
        // Check iSUSD balance (in our mock, handler holds tokens instead of burning)
        uint256 iSusdBalance = iSusdToken.balanceOf(address(handler));
        assertGt(iSusdBalance, 0); // Mock implementation holds tokens in handler
        
        // But user should have lending balance
        assertGt(lendingBalance, 0);
    }
    
    function test_sovrynDex_withdrawWithDexCapabilities() public {
        // Deposit first
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Withdraw (should use Sovryn redemption, not DEX)
        uint256 userBalanceBefore = stablecoin.balanceOf(USER);
        
        vm.prank(address(dcaManager));
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);
        
        uint256 userBalanceAfter = stablecoin.balanceOf(USER);
        assertGt(userBalanceAfter, userBalanceBefore);
    }
    
    function test_sovrynDex_interestWithLendingProtocol() public {
        // Deposit tokens
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Simulate interest accrual by time passage
        vm.warp(block.timestamp + 365 days); // 1 year for interest accrual
        
        // Check accrued interest
        vm.prank(address(dcaManager));
        uint256 accruedInterest = sovrynDexHandler.getAccruedInterest(USER, DEPOSIT_AMOUNT);
        assertGt(accruedInterest, 0);
        
        // Withdraw interest
        uint256 userBalanceBeforeInterestWithdraw = stablecoin.balanceOf(USER);
        
        vm.prank(address(dcaManager));
        sovrynDexHandler.withdrawInterest(USER, DEPOSIT_AMOUNT / 2);
        
        uint256 userBalanceAfterInterestWithdraw = stablecoin.balanceOf(USER);
        assertGe(userBalanceAfterInterestWithdraw, userBalanceBeforeInterestWithdraw);
    }
    
    /*//////////////////////////////////////////////////////////////
                           EDGE CASES FOR SOVRYN DEX VARIANT
    //////////////////////////////////////////////////////////////*/
    
    function test_sovrynDex_extremeSlippageSettings() public {
        // Test with extreme but valid slippage settings
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumSafetyCheck(5000); // Lower safety check first
        
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumPercent(5000); // 50% (very high slippage)
        
        assertEq(sovrynDexHandler.getAmountOutMinimumPercent(), 5000);
        
        vm.prank(OWNER);
        sovrynDexHandler.setAmountOutMinimumPercent(9999); // 99.99% (very low slippage)
        
        assertEq(sovrynDexHandler.getAmountOutMinimumPercent(), 9999);
    }
    
    function test_sovrynDex_oracleFailure() public {
        // Test behavior when oracle fails
        mocOracle.setInvalidPrice();
        
        // Accessing price info should show invalid state
        (, bool isValid, ) = sovrynDexHandler.getMocOracle().getPriceInfo();
        assertFalse(isValid);
    }
    
    function test_sovrynDex_swapPathEdgeCases() public {
        // Test with multi-hop path
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = address(0x456); // Intermediate token
        uint24[] memory poolFeeRates = new uint24[](2);
        poolFeeRates[0] = 3000;
        poolFeeRates[1] = 3000;
        
        vm.prank(OWNER);
        sovrynDexHandler.setPurchasePath(intermediateTokens, poolFeeRates);
        
        bytes memory expectedPath = abi.encodePacked(
            address(stablecoin),
            uint24(3000),
            address(0x456), // Intermediate token  
            uint24(3000),
            address(wrbtcToken)
        );
        assertEq(sovrynDexHandler.getSwapPath(), expectedPath);
        assertEq(sovrynDexHandler.getSwapPath().length, 66); // 3 addresses + 2 fees
    }
    
    /*//////////////////////////////////////////////////////////////
                           SOVRYN-SPECIFIC LENDING + DEX INTEGRATION
    //////////////////////////////////////////////////////////////*/
    
    function test_sovrynDex_lendingProtocolIntegration() public {
        // Test that Sovryn's iSUSD burn works with DEX
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Check that user has lending balance but handler has no tokens
        uint256 lendingBalance = sovrynDexHandler.getUserShares(USER);
        uint256 handlerBalance = iSusdToken.balanceOf(address(handler));
        
        assertGt(lendingBalance, 0);
        assertGt(handlerBalance, 0); // Mock implementation holds tokens in handler (unlike real Sovryn)
    }
    
    function test_sovrynDex_withdrawInterestPaysUser() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        uint256 userBalanceBefore = stablecoin.balanceOf(USER);
        
        vm.prank(address(dcaManager));
        sovrynDexHandler.withdrawInterest(USER, 0);
        
        assertGt(stablecoin.balanceOf(USER), userBalanceBefore);
        assertEq(stablecoin.balanceOf(address(sovrynDexHandler)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                           PURCHASE PIPELINE COVERAGE
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Test that batchBuyRbtc funds the purchase by redeeming the buyer's lending shares
     * @dev Covers the shared PurchaseRbtc pipeline resolving _retrieveStablecoin to LendingErc20Handler
     */
    function test_sovrynDex_lengthOneBatchRedeemsSharesForPurchase() public {
        // Setup: User deposits tokens first
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Verify initial state
        uint256 initialLendingBalance = sovrynDexHandler.getUserShares(USER);
        assertGt(initialLendingBalance, 0);
        
        uint256 purchaseAmount = 100 ether;
        bytes32 mockScheduleId = keccak256("test_schedule");
        
        // Call batchBuyRbtc, which redeems shares through _retrieveStablecoin
        vm.prank(address(dcaManager));
        handlerBatchBuyOne(IPurchaseRbtc(address(sovrynDexHandler)), USER, mockScheduleId, purchaseAmount);
        
        // Verify the shares were redeemed - lending balance should be reduced
        uint256 finalLendingBalance = sovrynDexHandler.getUserShares(USER);
        assertLt(finalLendingBalance, initialLendingBalance);
        
        // Verify RBTC was accumulated
        uint256 rbtcBalance = sovrynDexHandler.getAccumulatedRbtcBalance(USER);
        assertGt(rbtcBalance, 0);
    }
    
    /**
     * @notice Test that batchBuyRbtc funds the purchase by redeeming every buyer's lending shares
     * @dev Covers the shared PurchaseRbtc pipeline resolving _batchRetrieveStablecoin to LendingErc20Handler
     */
    function test_sovrynDex_batchBuyRbtcRedeemsSharesForPurchase() public {
        // Setup: Multiple users deposit tokens
        address user1 = address(0x1001);
        address user2 = address(0x1002);
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
        uint256 initialBalance1 = sovrynDexHandler.getUserShares(user1);
        uint256 initialBalance2 = sovrynDexHandler.getUserShares(user2);
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
        sovrynDexHandler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts);
        
        // Verify the shares were redeemed - lending balances should be reduced
        uint256 finalBalance1 = sovrynDexHandler.getUserShares(user1);
        uint256 finalBalance2 = sovrynDexHandler.getUserShares(user2);
        assertLt(finalBalance1, initialBalance1);
        assertLt(finalBalance2, initialBalance2);
        
        // Verify RBTC was accumulated for both users
        uint256 rbtcBalance1 = sovrynDexHandler.getAccumulatedRbtcBalance(user1);
        uint256 rbtcBalance2 = sovrynDexHandler.getAccumulatedRbtcBalance(user2);
        assertGt(rbtcBalance1, 0);
        assertGt(rbtcBalance2, 0);
    }

    function _deploySovrynDexWithSlippage(uint256 amountOutMinimumPercent, uint256 amountOutMinimumSafetyCheck)
        private
        returns (SovrynErc20HandlerDex)
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

        return new SovrynErc20HandlerDex(
            address(dcaManager),
            address(stablecoin),
            address(iSusdToken),
            uniswapSettings,
            FEE_COLLECTOR,
            feeSettings,
            amountOutMinimumPercent,
            amountOutMinimumSafetyCheck,
            OWNER
        );
    }
} 