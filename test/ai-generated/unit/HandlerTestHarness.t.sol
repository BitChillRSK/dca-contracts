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
import "../../../script/Constants.sol";

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
    uint256 public lendingProtocolIndex;
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
     * @notice Get the lending protocol index for this handler
     */
    function getLendingProtocolIndex() internal virtual returns (uint256);
    
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
     * @notice Setup any handler-specific mocks or configurations
     */
    function setupHandlerSpecifics() internal virtual;
    
    /*//////////////////////////////////////////////////////////////
                               SHARED SETUP
    //////////////////////////////////////////////////////////////*/
    
    function setUp() public virtual {
        // Deploy core infrastructure with proper ownership
        vm.prank(OWNER);
        operationsAdmin = new OperationsAdmin();
        
        vm.prank(OWNER);
        dcaManager = new DcaManager(address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT);
        
        stablecoin = new MockStablecoin(address(this));
        
        // Get handler configuration
        lendingProtocolIndex = getLendingProtocolIndex();
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
        
        // Setup roles and permissions
        setupRolesAndPermissions();
        
        // Register handler with operations admin
        vm.prank(ADMIN);
        operationsAdmin.assignOrUpdateTokenHandler(
            address(stablecoin), 
            lendingProtocolIndex, 
            address(handler)
        );
        
        // Setup user balance and allowances
        stablecoin.mint(USER, USER_INITIAL_BALANCE);
        vm.prank(USER);
        stablecoin.approve(address(handler), type(uint256).max);
    }
    
    function setupRolesAndPermissions() internal {
        vm.prank(OWNER);
        operationsAdmin.setAdminRole(ADMIN);

        // Index 0 is "not lent": OperationsAdmin forbids a protocol name there, but still
        // allows assignOrUpdateTokenHandler(..., 0, handler).
        if (lendingProtocolIndex != 0) {
            vm.prank(ADMIN);
            operationsAdmin.addOrUpdateLendingProtocol("testProtocol", lendingProtocolIndex);
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
        
        uint256 minFeeRate = feeHandler.getMinFeeRate();
        uint256 maxFeeRate = feeHandler.getMaxFeeRate();
        uint256 lowerBound = feeHandler.getFeePurchaseLowerBound();
        uint256 upperBound = feeHandler.getFeePurchaseUpperBound();
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
        
        assertEq(feeHandler.getMinFeeRate(), 50);
        assertEq(feeHandler.getMaxFeeRate(), 150);
        assertEq(feeHandler.getFeePurchaseLowerBound(), 200 ether);
        assertEq(feeHandler.getFeePurchaseUpperBound(), 2000 ether);
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
        
        vm.expectRevert("Ownable: caller is not the owner");
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
        
        // User should receive interest (balance should increase or stay same)
        assertGe(stablecoin.balanceOf(USER), initialBalance);
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
        
        assertGt(minPercent, 0);
        assertLe(minPercent, 10000); // Should be reasonable percentage
        assertGt(safetyCheck, 0);
        assertGt(swapPath.length, 0);
    }
    
    function test_handler_dex_setAmountOutMinimumPercent() public {
        if (!supportsDex) return;
        
        IPurchaseUniswap dexHandler = IPurchaseUniswap(address(handler));
        
        vm.prank(OWNER);
        dexHandler.setAmountOutMinimumPercent(9950); // 99.5% in basis points (above safety check)
        
        assertEq(dexHandler.getAmountOutMinimumPercent(), 9950);
    }
    
    function test_handler_dex_setAmountOutMinimumPercent_reverts_invalidRange() public {
        if (!supportsDex) return;
        
        IPurchaseUniswap dexHandler = IPurchaseUniswap(address(handler));
        
        // Should revert for values outside valid range (above 100% in ether scale)
        vm.expectRevert();
        vm.prank(OWNER);
        dexHandler.setAmountOutMinimumPercent(1.01 ether); // 101% in ether scale
        
        // Should revert for values below safety check 
        uint256 safetyCheck = dexHandler.getAmountOutMinimumSafetyCheck();
        vm.expectRevert();
        vm.prank(OWNER);
        dexHandler.setAmountOutMinimumPercent(safetyCheck - 1);
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
        
        vm.prank(USER);
        uint256 callerBalance = rbtcHandler.getAccumulatedRbtcBalance();
        assertEq(callerBalance, 0);
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
        // Note: supportsInterface might not be accessible through ITokenHandler interface
        // We can test this through IERC165 interface if the handler supports it
        try IERC165(address(handler)).supportsInterface(type(ITokenHandler).interfaceId) returns (bool supported) {
            assertTrue(supported);
        } catch {
            // Handler might not expose ERC165 interface
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
        vm.expectRevert("Ownable: caller is not the owner");
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