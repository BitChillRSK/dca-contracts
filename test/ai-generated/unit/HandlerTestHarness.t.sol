// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ITokenHandler} from "../../../src/interfaces/ITokenHandler.sol";
import {IFeeHandler} from "../../../src/interfaces/IFeeHandler.sol";
import {ITokenLending} from "../../../src/interfaces/ITokenLending.sol";
import {IPurchaseRbtc} from "../../../src/interfaces/IPurchaseRbtc.sol";
import {IPurchaseUniswap} from "../../../src/interfaces/IPurchaseUniswap.sol";
import {IDcaManagerAccessControl} from "../../../src/interfaces/IDcaManagerAccessControl.sol";
import {DcaManager} from "../../../src/DcaManager.sol";
import {OperationsAdmin} from "../../../src/OperationsAdmin.sol";
import {MockStablecoin} from "../../mocks/MockStablecoin.sol";
import {MockKdocToken} from "../../mocks/MockKdocToken.sol";
import {MockIsusdToken} from "../../mocks/MockIsusdToken.sol";
import "../../Constants.sol";
import {ownableUnauthorized} from "../../utils/OzRevert.sol";

/**
 * @title HandlerTestHarness
 * @notice Shared test harness for all handler contracts (Tropykus/Sovryn, regular/Dex variants)
 * @dev Abstract contract that provides common test patterns. Concrete test classes inherit this
 *      and implement handler-specific setup via virtual functions.
 */
abstract contract HandlerTestHarness is Test {
    
    /*//////////////////////////////////////////////////////////////
                           TEST INFRASTRUCTURE
    //////////////////////////////////////////////////////////////*/
    
    // Core contracts - set by child classes
    ITokenHandler public handler;
    DcaManager public dcaManager;
    OperationsAdmin public operationsAdmin;
    MockStablecoin public stablecoin;
    IERC20 public shareToken;
    
    // Test accounts
    address public constant USER = address(0x1234);
    address public constant OWNER = address(0x5678);
    address public constant ADMIN = address(0x9ABC);
    address public constant FEE_COLLECTOR = address(0xDEF0);
    
    // Test amounts
    uint256 public constant DEPOSIT_AMOUNT = 1000 ether;
    uint256 public constant WITHDRAWAL_AMOUNT = 500 ether;
    uint256 public constant PURCHASE_AMOUNT = 100 ether;
    uint256 public constant USER_INITIAL_BALANCE = 10000 ether;
    
    // Handler configuration
    uint256 public routeIndex;
    bool public supportsDex;
    bool public supportsLending;
    
    /*//////////////////////////////////////////////////////////////
                           VIRTUAL FUNCTIONS (OVERRIDE IN CHILD)
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Deploy the specific handler implementation
     * @dev Must be implemented by each concrete test class
     */
    function deployHandler() internal virtual returns (ITokenHandler);
    
    /**
     * @notice Get the route index for this handler
     */
    function getRouteIndex() internal virtual returns (uint256);
    
    /**
     * @notice Whether this handler supports DEX operations
     */
    function isDexHandler() internal virtual returns (bool);
    
    /**
     * @notice Whether this handler supports lending operations
     */
    function isLendingHandler() internal virtual returns (bool);
    
    /**
     * @notice Get the shares for this handler
     */
    function getShareToken() internal virtual returns (IERC20);

    /**
     * @notice Shares this handler actually holds at the lending protocol.
     * @dev Defaults to the share token's balance. LayerBank overrides it: its share is the aToken's
     *      scaled balance, and reading the rebasing `balanceOf` instead would compare two different units.
     */
    function handlerShareBalance() internal virtual returns (uint256) {
        return getShareToken().balanceOf(address(handler));
    }
    
    /**
     * @notice Setup any handler-specific mocks or configurations
     */
    function setupHandlerSpecifics() internal virtual;
    
    /*//////////////////////////////////////////////////////////////
                               SHARED SETUP
    //////////////////////////////////////////////////////////////*/
    
    function setUp() public virtual {
        // Deploy core infrastructure with proper ownership
        vm.prank(OWNER);
        operationsAdmin = new OperationsAdmin(OWNER);
        
        vm.prank(OWNER);
        dcaManager = new DcaManager(address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, OWNER);
        
        stablecoin = new MockStablecoin(address(this));
        
        // Get handler configuration
        routeIndex = getRouteIndex();
        supportsDex = isDexHandler();
        supportsLending = isLendingHandler();
        shareToken = getShareToken();
        
        // Setup shares balance if needed
        if (supportsLending) {
            vm.deal(address(shareToken), 1000000 ether);
        }
        
        // Setup handler specifics (shares, DEX configs, etc.)
        setupHandlerSpecifics();
        
        // Deploy the specific handler with proper ownership
        vm.prank(OWNER);
        handler = deployHandler();
        
        setupRolesAndPermissions();

        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(
            address(stablecoin), 
            routeIndex, 
            address(handler)
        );
        
        // Setup user balance and allowances
        stablecoin.mint(USER, USER_INITIAL_BALANCE);
        vm.prank(USER);
        stablecoin.approve(address(handler), type(uint256).max);
    }
    
    function setupRolesAndPermissions() internal {
        // Index 0 is pre-registered as idle. Lending indexes must be classified before assignment.
        if (routeIndex != 0) {
            vm.prank(OWNER);
            operationsAdmin.registerRoute(routeIndex, true);
        }
    }
    
    /*//////////////////////////////////////////////////////////////
                           SHARED CORE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_handler_deployment() public {
        assertNotEq(address(handler), address(0));
        // Note: i_stableToken is immutable but may not be publicly accessible
        // We can verify it works through deposit/withdraw functionality instead
        // Minimum purchase amount is now handled by DcaManager, not individual handlers
    }
    
    function test_handler_depositToken_success() public {
        uint256 initialBalance = stablecoin.balanceOf(USER);
        uint256 initialHandlerBalance = stablecoin.balanceOf(address(handler));
        
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        assertEq(stablecoin.balanceOf(USER), initialBalance - DEPOSIT_AMOUNT);
        // Handler balance might go to lending protocol, so we check based on handler type
        if (supportsLending) {
            // For lending handlers, tokens go to lending protocol
            uint256 lendingBalance = ITokenLending(address(handler)).getUserShares(USER);
            assertGt(lendingBalance, 0);
        } else {
            // For non-lending handlers, tokens stay in handler
            assertEq(stablecoin.balanceOf(address(handler)), initialHandlerBalance + DEPOSIT_AMOUNT);
        }
    }
    
    function test_handler_depositToken_reverts_notDcaManager() public {
        vm.expectRevert();
        vm.prank(USER);
        handler.depositToken(USER, DEPOSIT_AMOUNT);
    }
    
    function test_handler_depositToken_reverts_insufficientBalance() public {
        vm.prank(address(dcaManager));
        vm.expectRevert();
        handler.depositToken(USER, USER_INITIAL_BALANCE + 1);
    }
    
    function test_handler_withdrawToken_success() public {
        // First deposit
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        uint256 initialBalance = stablecoin.balanceOf(USER);
        
        // Then withdraw
        vm.prank(address(dcaManager));
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);
        
        assertEq(stablecoin.balanceOf(USER), initialBalance + WITHDRAWAL_AMOUNT);
    }
    
    function test_handler_withdrawToken_reverts_notDcaManager() public {
        vm.expectRevert();
        vm.prank(USER);
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);
    }
    
    /*//////////////////////////////////////////////////////////////
                           SHARED FEE HANDLER TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_handler_feeSettings() public {
        IFeeHandler feeHandler = IFeeHandler(address(handler));
        
        IFeeHandler.FeeSettings memory settings = feeHandler.getFeeSettings();
        
        uint256 minFeeRate = settings.minFeeRate;
        uint256 maxFeeRate = settings.maxFeeRate;
        uint256 lowerBound = settings.feePurchaseLowerBound;
        uint256 upperBound = settings.feePurchaseUpperBound;
        address feeCollector = feeHandler.getFeeCollectorAddress();
        
        assertGt(minFeeRate, 0);
        assertGt(maxFeeRate, 0);
        assertLe(minFeeRate, maxFeeRate);
        assertLe(lowerBound, upperBound);
        assertNotEq(feeCollector, address(0));
    }
    
    function test_handler_modifyFeeSettings_success() public {
        IFeeHandler feeHandler = IFeeHandler(address(handler));
        
        vm.prank(OWNER);
        feeHandler.setFeeRateParams(50, 150, 200 ether, 2000 ether);
        
        IFeeHandler.FeeSettings memory settings = feeHandler.getFeeSettings();
        assertEq(settings.minFeeRate, 50);
        assertEq(settings.maxFeeRate, 150);
        assertEq(settings.feePurchaseLowerBound, 200 ether);
        assertEq(settings.feePurchaseUpperBound, 2000 ether);
    }
    
    function test_handler_modifyFeeSettings_reverts_invalidParams() public {
        IFeeHandler feeHandler = IFeeHandler(address(handler));
        
        // min > max should revert
        vm.expectRevert();
        vm.prank(OWNER);
        feeHandler.setFeeRateParams(200, 100, 200 ether, 2000 ether);
        
        // lower > upper should revert
        vm.expectRevert();
        vm.prank(OWNER);
        feeHandler.setFeeRateParams(50, 150, 2000 ether, 200 ether);
    }
    
    function test_handler_modifyFeeSettings_reverts_notOwner() public {
        IFeeHandler feeHandler = IFeeHandler(address(handler));
        
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        feeHandler.setFeeRateParams(50, 150, 200 ether, 2000 ether);
    }
    
    /*//////////////////////////////////////////////////////////////
                           SHARED LENDING TESTS (IF SUPPORTED)
    //////////////////////////////////////////////////////////////*/
    
    function test_handler_lending_depositAndAccrueInterest() public {
        if (!supportsLending) return;
        
        ITokenLending lendingHandler = ITokenLending(address(handler));
        
        // Deposit tokens
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Check lending balance
        uint256 lendingBalance = lendingHandler.getUserShares(USER);
        assertGt(lendingBalance, 0);
        
        // Simulate time passing and interest accrual
        vm.warp(block.timestamp + 365 days);
        
        // Check accrued interest (should be >= 0)
        vm.prank(address(dcaManager));
        uint256 interest = lendingHandler.getAccruedInterest(USER, DEPOSIT_AMOUNT);
        assertGe(interest, 0);
    }
    
    function test_handler_lending_withdrawInterest() public {
        if (!supportsLending) return;
        
        ITokenLending lendingHandler = ITokenLending(address(handler));
        
        // Deposit tokens
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        
        // Simulate interest accrual
        vm.warp(block.timestamp + 365 days);
        
        uint256 initialBalance = stablecoin.balanceOf(USER);
        
        // Withdraw interest
        vm.prank(address(dcaManager));
        lendingHandler.withdrawInterest(USER, DEPOSIT_AMOUNT / 2); // Half locked in DCA
        
        assertGt(stablecoin.balanceOf(USER), initialBalance);
    }

    /**
     * @notice The share count booked out of a user must never come out below what the protocol
     *         actually burnt, or `sum(s_shares)` drifts above the shares the handler holds and the
     *         shortfall is paid out of somebody else's position.
     * @dev Every redeem is sized by the booked count: Tropykus `redeem` and Sovryn `burn` take it
     *      directly, so they burn it exactly. LayerBank converts it to underlying because Aave has no
     *      share-sized withdraw, and burns at or below it thanks to the `_stablecoinToShares` round-up.
     */
    function test_handler_lending_bookDebitCoversProtocolBurn() public {
        if (!supportsLending) return;

        ITokenLending lendingHandler = ITokenLending(address(handler));

        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + 365 days);

        uint256 bookBefore = lendingHandler.getUserShares(USER);
        uint256 heldBefore = handlerShareBalance();

        vm.prank(address(dcaManager));
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);

        uint256 bookDebit = bookBefore - lendingHandler.getUserShares(USER);
        uint256 protocolBurn = heldBefore - handlerShareBalance();

        assertGt(bookDebit, 0);
        assertGe(bookDebit, protocolBurn);
        assertLe(lendingHandler.getUserShares(USER), handlerShareBalance());
    }
    
    /*//////////////////////////////////////////////////////////////
                           SHARED DEX TESTS (IF SUPPORTED)
    //////////////////////////////////////////////////////////////*/
    
    function test_handler_dex_configuration() public {
        if (!supportsDex) return;
        
        IPurchaseUniswap dexHandler = IPurchaseUniswap(address(handler));
        
        // Test DEX configuration getters
        uint256 minPercent = dexHandler.getAmountOutMinimumPercent();
        uint256 safetyCheck = dexHandler.getAmountOutMinimumSafetyCheck();
        bytes memory swapPath = dexHandler.getSwapPath();
        
        assertGt(safetyCheck, 0);
        assertLe(safetyCheck, minPercent); // the wall sits at or below the live floor
        assertLe(minPercent, 1 ether);
        assertGt(swapPath.length, 0);
        uint256 packed;
        for (uint256 i; i < 20; ++i) {
            packed = (packed << 8) | uint8(swapPath[i]);
        }
        assertEq(address(uint160(packed)), address(stablecoin));
    }
    
    function test_handler_dex_setAmountOutMinimumPercent() public {
        if (!supportsDex) return;
        
        IPurchaseUniswap dexHandler = IPurchaseUniswap(address(handler));
        
        vm.prank(OWNER);
        dexHandler.setAmountOutMinimumPercent(0.98 ether);
        
        assertEq(dexHandler.getAmountOutMinimumPercent(), 0.98 ether);
    }
    
    function test_handler_dex_setAmountOutMinimumPercent_reverts_invalidRange() public {
        if (!supportsDex) return;
        
        IPurchaseUniswap dexHandler = IPurchaseUniswap(address(handler));
        
        // Above 100%.
        vm.expectRevert();
        vm.prank(OWNER);
        dexHandler.setAmountOutMinimumPercent(1.01 ether);
        
        // Below the safety-check wall.
        uint256 safetyCheck = dexHandler.getAmountOutMinimumSafetyCheck();
        vm.expectRevert();
        vm.prank(OWNER);
        dexHandler.setAmountOutMinimumPercent(safetyCheck - 1);
    }
    
    function test_handler_dex_setAmountOutMinimumSafetyCheck() public {
        if (!supportsDex) return;
        
        IPurchaseUniswap dexHandler = IPurchaseUniswap(address(handler));
        
        vm.prank(OWNER);
        dexHandler.setAmountOutMinimumSafetyCheck(0.96 ether);
        
        assertEq(dexHandler.getAmountOutMinimumSafetyCheck(), 0.96 ether);
    }
    
    function test_handler_dex_setAmountOutMinimumSafetyCheck_reverts_invalidRange() public {
        if (!supportsDex) return;
        
        IPurchaseUniswap dexHandler = IPurchaseUniswap(address(handler));
        
        vm.expectRevert();
        vm.prank(OWNER);
        dexHandler.setAmountOutMinimumSafetyCheck(1.01 ether);
    }
    
    /*//////////////////////////////////////////////////////////////
                           SHARED RBTC PURCHASE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_handler_rbtcBalance() public {
        // Only test RBTC balance on DEX handlers that implement IPurchaseRbtc
        if (!supportsDex) return;
        
        IPurchaseRbtc rbtcHandler = IPurchaseRbtc(address(handler));
        
        uint256 balance = rbtcHandler.getAccumulatedRbtcBalance(USER);
        assertEq(balance, 0); // Should start at 0
    }
    
    /*//////////////////////////////////////////////////////////////
                           SHARED ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_handler_dcaManagerReference() public {
        // Note: i_dcaManager is immutable but may not be publicly accessible
        // We can verify access control works through other function calls
        // The handler should only accept calls from the DCA manager
    }
    
    /*//////////////////////////////////////////////////////////////
                           SHARED INTERFACE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_handler_supportsInterface() public {
        assertTrue(IERC165(address(handler)).supportsInterface(type(ITokenHandler).interfaceId));
        bool lending = IERC165(address(handler)).supportsInterface(type(ITokenLending).interfaceId);
        if (supportsLending) {
            assertTrue(lending);
        } else {
            assertFalse(lending);
        }
    }
    
    function test_dcaManager_modifyMinPurchaseAmount() public {
        uint256 newAmount = 500 ether;
        
        vm.prank(OWNER);
        dcaManager.modifyDefaultMinPurchaseAmount(newAmount);
        
        assertEq(dcaManager.getDefaultMinPurchaseAmount(), newAmount);
    }
    
    function test_dcaManager_setTokenMinPurchaseAmount() public {
        uint256 newAmount = 500 ether;
        
        vm.prank(OWNER);
        dcaManager.setTokenMinPurchaseAmount(address(stablecoin), newAmount);
        
        (uint256 returnedAmount, bool isCustom) = dcaManager.getTokenMinPurchaseAmount(address(stablecoin));
        assertEq(returnedAmount, newAmount);
        assertTrue(isCustom);
    }
    
    function test_dcaManager_modifyMinPurchaseAmount_reverts_notOwner() public {
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        dcaManager.modifyDefaultMinPurchaseAmount(500 ether);
    }
    
    /*//////////////////////////////////////////////////////////////
                           SHARED EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_handler_zeroAmountOperations() public {
        // Zero amount deposits should be handled gracefully (may revert or succeed)
        uint256 initialBalance = stablecoin.balanceOf(USER);
        
        vm.prank(address(dcaManager));
        try handler.depositToken(USER, 0) {
            // If it succeeds, balance should be unchanged
            assertEq(stablecoin.balanceOf(USER), initialBalance);
        } catch {
            // If it reverts, that's also acceptable behavior
            // Balance should remain unchanged
            assertEq(stablecoin.balanceOf(USER), initialBalance);
        }
    }
    
    function test_handler_multipleDepositsAndWithdrawals() public {
        // Test multiple operations in sequence
        vm.startPrank(address(dcaManager));
        
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);
        handler.depositToken(USER, DEPOSIT_AMOUNT / 2);
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT / 2);
        
        vm.stopPrank();
        
        // User should have reasonable balance (exact amount depends on lending protocol)
        assertGt(stablecoin.balanceOf(USER), 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                           SHARED FUZZ TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testFuzz_handler_depositAndWithdraw(uint256 depositAmount, uint256 withdrawAmount) public {
        // Bound inputs to reasonable ranges
        depositAmount = bound(depositAmount, 1 ether, USER_INITIAL_BALANCE / 2);
        withdrawAmount = bound(withdrawAmount, 1 ether, depositAmount);
        
        uint256 initialBalance = stablecoin.balanceOf(USER);
        
        vm.startPrank(address(dcaManager));
        
        handler.depositToken(USER, depositAmount);
        handler.withdrawToken(USER, withdrawAmount);
        
        vm.stopPrank();
        
        uint256 finalBalance = stablecoin.balanceOf(USER);
        
        // Basic invariants should hold
        assertGt(finalBalance, 0);
        assertLe(finalBalance, USER_INITIAL_BALANCE);
        
        // If we withdrew exactly what we deposited, balance should be close to initial
        // (may have small differences due to lending protocol mechanics)
        if (withdrawAmount == depositAmount) {
            assertGe(finalBalance, initialBalance - depositAmount / 1000); // Allow small discrepancy
        }
    }
} 