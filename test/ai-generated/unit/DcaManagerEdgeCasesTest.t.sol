// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {DcaManager} from "../../../src/DcaManager.sol";
import {OperationsAdmin} from "../../../src/OperationsAdmin.sol";
import {MockStablecoin} from "../../mocks/MockStablecoin.sol";
import {MockKdocToken} from "../../mocks/MockKdocToken.sol";
import {TropykusErc20HandlerDex} from "../../../src/tropykus-legacy/TropykusErc20HandlerDex.sol";
import {IPurchaseUniswap} from "../../../src/interfaces/IPurchaseUniswap.sol";
import {ICoinPairPrice} from "../../../src/interfaces/ICoinPairPrice.sol";
import {MockMocOracle} from "../../mocks/MockMocOracle.sol";
import {MockWrbtcToken} from "../../mocks/MockWrbtcToken.sol";
import {IWRBTC} from "../../../src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {IDcaManager} from "../../../src/interfaces/IDcaManager.sol";
import {IFeeHandler} from "../../../src/interfaces/IFeeHandler.sol";
import "../../../script/Constants.sol";

/**
 * @title DcaManagerEdgeCasesTest
 * @notice Tests for DCA Manager edge cases and revert scenarios not covered elsewhere
 * @dev Covers item 5-A from the coverage plan: DCA Manager edge paths
 */
contract DcaManagerEdgeCasesTest is Test {
    
    /*//////////////////////////////////////////////////////////////
                               CONTRACTS
    //////////////////////////////////////////////////////////////*/
    
    DcaManager public dcaManager;
    OperationsAdmin public operationsAdmin;
    MockStablecoin public stablecoin;
    MockKdocToken public kToken;
    TropykusErc20HandlerDex public handler;
    MockWrbtcToken public wrbtcToken;
    MockMocOracle public mocOracle;
    
    /*//////////////////////////////////////////////////////////////
                               TEST ACCOUNTS
    //////////////////////////////////////////////////////////////*/
    
    address public constant OWNER = address(0x1111);
    address public constant ADMIN = address(0x2222);
    address public constant SWAPPER = address(0x3333);
    address public constant USER = address(0x4444);
    address public constant FEE_COLLECTOR = address(0x5555);
    
    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/
    
    function setUp() public {
        // Deploy contracts
        vm.prank(OWNER);
        operationsAdmin = new OperationsAdmin();
        
        vm.prank(OWNER);
        dcaManager = new DcaManager(address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT);
        
        stablecoin = new MockStablecoin(address(this));
        kToken = new MockKdocToken(address(stablecoin));
        wrbtcToken = new MockWrbtcToken();
        mocOracle = new MockMocOracle();
        
        // Setup roles
        vm.startPrank(OWNER);
        operationsAdmin.addSwapper(SWAPPER);
        operationsAdmin.registerRoute(TROPYKUS_INDEX, true);
        vm.stopPrank();
        
        // Deploy and register handler
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
            swapRouter02: ISwapRouter02(address(0x777)),
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracle: ICoinPairPrice(address(mocOracle))
        });
        
        vm.prank(OWNER);
        handler = new TropykusErc20HandlerDex(
            address(dcaManager),
            address(stablecoin),
            address(kToken),
            uniswapSettings,
            FEE_COLLECTOR,
            feeSettings,
            9970,
            9900
        );
        
        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(
            address(stablecoin),
            TROPYKUS_INDEX,
            address(handler)
        );
        
        // Setup user
        stablecoin.mint(USER, 10000 ether);
        vm.prank(USER);
        stablecoin.approve(address(handler), type(uint256).max);
    }
    
    /*//////////////////////////////////////////////////////////////
                           DELETE DCA SCHEDULE EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    function test_deleteDcaSchedule_reverts_wrongId() public {
        // Create a schedule first
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether,           // depositAmount
            100 ether,           // purchaseAmount (less than half of deposit)
            MIN_PURCHASE_PERIOD, // purchasePeriod
            TROPYKUS_INDEX       // lendingProtocolIndex
        );
        
        // Try to delete with wrong ID
        bytes32 wrongId = keccak256("wrong_id");
        
        vm.expectRevert(IDcaManager.DcaManager__ScheduleIdAndIndexMismatch.selector);
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), 0, wrongId);
    }
    
    function test_deleteDcaSchedule_reverts_wrongIndex() public {
        // Create a schedule first
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether,           // depositAmount
            100 ether,           // purchaseAmount (less than half of deposit)
            MIN_PURCHASE_PERIOD, // purchasePeriod
            TROPYKUS_INDEX       // lendingProtocolIndex
        );
        
        // Try to delete with wrong index (index that doesn't exist)
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector); // Should revert due to array bounds check
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), 999, keccak256("dummy_id"));
    }
    
    function test_deleteDcaSchedule_reverts_notOwner() public {
        // Create a schedule as USER
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether,           // depositAmount
            100 ether,           // purchaseAmount (less than half of deposit)
            MIN_PURCHASE_PERIOD, // purchasePeriod
            TROPYKUS_INDEX       // lendingProtocolIndex
        );
        
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).scheduleId;
        
        // Try to delete as different user
        address otherUser = address(0x9999);
        vm.expectRevert(IDcaManager.DcaManager__InexistentScheduleIndex.selector);
        vm.prank(otherUser);
        dcaManager.deleteDcaSchedule(address(stablecoin), 0, scheduleId);
    }
    
    /*//////////////////////////////////////////////////////////////
                           BUY RBTC EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    // NOTE: This test is disabled because it requires a complete swap execution
    // which depends on proper Uniswap mock setup that's complex in this test environment.
    // The time period validation is already tested in the integration tests in DcaDappTest.
    function skip_test_buyRbtc_reverts_beforePeriodElapsed() public {
        // Create schedule 
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether,           // depositAmount
            100 ether,           // purchaseAmount (less than half of deposit)
            MIN_PURCHASE_PERIOD, // purchasePeriod
            TROPYKUS_INDEX       // lendingProtocolIndex
        );
        
        // This test would require a successful first purchase to set lastPurchaseTimestamp
        // Then test that immediate second purchase fails due to time period validation
        // However, this requires complex Uniswap mock setup that's already covered
        // in the DcaDappTest integration tests where the full environment is set up properly
    }
    
    function test_buyRbtc_reverts_invalidScheduleId() public {
        // Create schedule
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether,           // depositAmount
            100 ether,           // purchaseAmount (less than half of deposit)
            MIN_PURCHASE_PERIOD, // purchasePeriod
            TROPYKUS_INDEX       // lendingProtocolIndex
        );
        
        bytes32 wrongId = keccak256("invalid_id");
        
        vm.expectRevert(IDcaManager.DcaManager__ScheduleIdAndIndexMismatch.selector);
        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(stablecoin), 0, wrongId);
    }
    
    function test_buyRbtc_reverts_insufficientBalance() public {
        // Create schedule with purchase amount above the deposit (should fail validation)
        bytes memory encodedRevert = abi.encodeWithSelector(
            IDcaManager.DcaManager__PurchaseAmountExceedsBalance.selector,
            address(stablecoin),
            501 ether,
            500 ether
        );
        vm.expectRevert(encodedRevert);
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether,  // depositAmount
            501 ether, // purchaseAmount exceeds deposit
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );
    }
    
    /*//////////////////////////////////////////////////////////////
                           WITHDRAW TOKEN EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    function test_withdrawToken_reverts_moreThanBalance() public {
        // Create schedule and deposit tokens
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether, // depositAmount
            100 ether, // purchaseAmount
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );
        
        // Get the schedule ID after creation
        vm.prank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).scheduleId;
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), 0, scheduleId, 600 ether); // More than deposited
    }
    
    function test_withdrawToken_reverts_zeroAmount() public {
        // Create a schedule first
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether, // depositAmount
            100 ether, // purchaseAmount
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );
        
        // Get the schedule ID after creation
        vm.prank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).scheduleId;
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), 0, scheduleId, 0);
    }

    function test_withdrawTokenAndInterest_succeedsOnLendingScheduleWithoutCallerIndex() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether,
            100 ether,
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );

        IDcaManager.DcaDetails memory schedule = dcaManager.getDcaSchedule(USER, address(stablecoin), 0);
        assertEq(schedule.lendingProtocolIndex, TROPYKUS_INDEX);

        vm.prank(USER);
        dcaManager.withdrawTokenAndInterest(address(stablecoin), 0, schedule.scheduleId, 100 ether);

        assertEq(dcaManager.getDcaSchedule(USER, address(stablecoin), 0).tokenBalance, 400 ether);
    }
    
    /*//////////////////////////////////////////////////////////////
                           SCHEDULE CREATION EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    function test_createDcaSchedule_reverts_zeroPurchaseAmount() public {
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether, // depositAmount
            0, // Zero purchaseAmount
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );
    }
    
    function test_createDcaSchedule_reverts_zeroDepositAmount() public {
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            0, // Zero depositAmount
            100 ether, // purchaseAmount
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );
    }
    
    function test_createDcaSchedule_reverts_invalidPurchasePeriod() public {
        vm.expectRevert(IDcaManager.DcaManager__PurchasePeriodMustBeGreaterThanMinimum.selector);
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether, // depositAmount
            100 ether, // purchaseAmount
            MIN_PURCHASE_PERIOD - 1, // Below minimum
            TROPYKUS_INDEX
        );
    }
    
    function test_createDcaSchedule_reverts_maxSchedulesExceeded() public {
        // Create maximum number of schedules
        for (uint256 i = 0; i < MAX_SCHEDULES_PER_TOKEN; i++) {
            vm.prank(USER);
            dcaManager.createDcaSchedule(
                address(stablecoin),
                100 ether, // depositAmount
                50 ether,  // purchaseAmount
                MIN_PURCHASE_PERIOD,
                TROPYKUS_INDEX
            );
        }
        
        // Try to create one more
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__MaxSchedulesPerTokenReached.selector, address(stablecoin)));
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            100 ether, // depositAmount
            50 ether,  // purchaseAmount
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );
    }
    
    function test_createDcaSchedule_reverts_invalidLendingProtocol() public {
        uint256 invalidProtocolIndex = 999;
        
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether, // depositAmount
            100 ether, // purchaseAmount
            MIN_PURCHASE_PERIOD,
            invalidProtocolIndex
        );
    }
    
    /*//////////////////////////////////////////////////////////////
                           BATCH OPERATIONS EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    function test_batchBuyRbtc_reverts_emptyArrays() public {
        address[] memory emptyUsers = new address[](0);
        uint256[] memory emptyIndexes = new uint256[](0);
        bytes32[] memory emptyIds = new bytes32[](0);
        uint256[] memory emptyAmounts = new uint256[](0);
        
        vm.expectRevert(IDcaManager.DcaManager__EmptyBatchPurchaseArrays.selector);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            emptyUsers,
            address(stablecoin),
            emptyIndexes,
            emptyIds,
            emptyAmounts,
            TROPYKUS_INDEX
        );
    }
    
    function test_batchBuyRbtc_reverts_arrayLengthMismatch() public {
        address[] memory users = new address[](2);
        users[0] = USER;
        users[1] = address(0x9999);
        
        uint256[] memory indexes = new uint256[](1); // Different length
        indexes[0] = 0;
        
        bytes32[] memory ids = new bytes32[](2);
        uint256[] memory amounts = new uint256[](2);
        
        vm.expectRevert(IDcaManager.DcaManager__BatchPurchaseArraysLengthMismatch.selector);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            users,
            address(stablecoin),
            indexes,
            ids,
            amounts,
            TROPYKUS_INDEX
        );
    }
    
    /*//////////////////////////////////////////////////////////////
                           SCHEDULE MODIFICATION EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    function test_setPurchaseAmount_reverts_zeroAmount() public {
        // Create a schedule first
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether, // depositAmount
            100 ether, // purchaseAmount
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );
        
        // Get the schedule ID after creation
        vm.prank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).scheduleId;
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.setPurchaseAmount(address(stablecoin), 0, scheduleId, 0);
    }
    
    function test_setPurchaseAmount_reverts_invalidScheduleIndex() public {
        bytes32 fakeScheduleId = keccak256("fake");
        vm.expectRevert(); // Should revert due to array bounds
        vm.prank(USER);
        dcaManager.setPurchaseAmount(address(stablecoin), 999, fakeScheduleId, 100 ether);
    }
    
    function test_setPurchasePeriod_reverts_invalidPeriod() public {
        // Create a schedule first
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether, // depositAmount
            100 ether, // purchaseAmount
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );
        
        // Get the schedule ID after creation
        vm.prank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).scheduleId;
        vm.expectRevert(IDcaManager.DcaManager__PurchasePeriodMustBeGreaterThanMinimum.selector);
        vm.prank(USER);
        dcaManager.setPurchasePeriod(address(stablecoin), 0, scheduleId, MIN_PURCHASE_PERIOD - 1);
    }
    
    /*//////////////////////////////////////////////////////////////
                           RBTC WITHDRAWAL EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    function test_withdrawAllAccumulatedRbtc_emptyArray() public {
        uint256[] memory emptyProtocols = new uint256[](0);
        
        // Should not revert, just do nothing
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, emptyProtocols);
    }
    
    function test_withdrawAllAccumulatedRbtc_invalidProtocol_skips() public {
        // First create a DCA schedule so user has deposited tokens
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether,
            100 ether,
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );
        
        uint256[] memory invalidProtocols = new uint256[](1);
        invalidProtocols[0] = 999; // Invalid protocol
        
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        // Should not revert, just skip invalid combinations
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, invalidProtocols);
    }

    function test_withdrawAllAccumulatedRbtcAndInterest_mixedValidInvalidCombinations() public {      
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        
        uint256[] memory protocols = new uint256[](3);
        protocols[0] = TROPYKUS_INDEX;
        protocols[1] = SOVRYN_INDEX;
        protocols[2] = 0;
        // Unit tests are only run on one protocol at a time, so this array is valid for testing

        
        // Should not revert, should skip stablecoin + Sovryn combination
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, protocols);
        dcaManager.withdrawAllAccumulatedInterest(tokens, protocols);
    }
    
    /*//////////////////////////////////////////////////////////////
                           DEPOSIT TOKEN EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    function test_depositToken_reverts_zeroAmount() public {
        // Create a schedule first
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether, // depositAmount
            100 ether, // purchaseAmount
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );
        
        // Get the schedule ID after creation
        vm.prank(USER);
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).scheduleId;
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.depositToken(address(stablecoin), 0, scheduleId, 0);
    }
    
    function test_depositToken_reverts_invalidScheduleIndex() public {
        bytes32 fakeScheduleId = keccak256("fake");
        vm.expectRevert(); // Should revert due to array bounds
        vm.prank(USER);
        dcaManager.depositToken(address(stablecoin), 999, fakeScheduleId, 100 ether);
    }
    
    /*//////////////////////////////////////////////////////////////
                           FUZZ TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testFuzz_invalidScheduleOperations(uint256 invalidIndex) public {
        vm.assume(invalidIndex > 0 && invalidIndex < type(uint256).max);
        
        bytes32 fakeScheduleId = keccak256("fake");
        // All operations with invalid index should revert
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.depositToken(address(stablecoin), invalidIndex, fakeScheduleId, 100 ether);
        
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.setPurchaseAmount(address(stablecoin), invalidIndex, fakeScheduleId, 100 ether);
        
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.setPurchasePeriod(address(stablecoin), invalidIndex, fakeScheduleId, MIN_PURCHASE_PERIOD);
    }
    
    function testFuzz_invalidAmounts(uint256 seed) public {
        // Test with zero amounts
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            0, // Zero depositAmount
            100 ether,
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );
        
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            100 ether,
            0, // Zero purchaseAmount
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );
        
        // Test with invalid purchase amounts (more than deposit)
        uint256 deposit = bound(seed, 100 ether, 1000 ether);
        uint256 purchaseAmount = deposit + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                IDcaManager.DcaManager__PurchaseAmountExceedsBalance.selector,
                address(stablecoin),
                purchaseAmount,
                deposit
            )
        );
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            deposit,
            purchaseAmount,
            MIN_PURCHASE_PERIOD,
            TROPYKUS_INDEX
        );
    }
} 