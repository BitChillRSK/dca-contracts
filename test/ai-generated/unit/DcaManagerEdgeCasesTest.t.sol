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
import "../../Constants.sol";
import {UNUSED_SCHEDULE_ID, toBatch, batchOf} from "../../utils/BatchBuyOne.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

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
        operationsAdmin = new OperationsAdmin(OWNER);
        
        vm.prank(OWNER);
        dcaManager = new DcaManager(address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, OWNER);
        
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
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            OWNER
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
            TROPYKUS_INDEX       // routeIndex
        );
        
        // Try to delete with wrong ID
        uint64 wrongId = UNUSED_SCHEDULE_ID;
        
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, address(stablecoin), wrongId));
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), wrongId);
    }
    
    function test_deleteDcaSchedule_reverts_deletedId() public {
        // Create a schedule first
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether,           // depositAmount
            100 ether,           // purchaseAmount (less than half of deposit)
            MIN_PURCHASE_PERIOD, // purchasePeriod
            TROPYKUS_INDEX       // routeIndex
        );
        
        // Deleting the same schedule twice: the id is retired by the first call
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), scheduleId);

        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, address(stablecoin), scheduleId));
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), scheduleId);
    }
    
    function test_deleteDcaSchedule_reverts_notOwner() public {
        // Create a schedule as USER
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether,           // depositAmount
            100 ether,           // purchaseAmount (less than half of deposit)
            MIN_PURCHASE_PERIOD, // purchasePeriod
            TROPYKUS_INDEX       // routeIndex
        );
        
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        
        // Try to delete as different user
        address otherUser = address(0x9999);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__NotScheduleOwner.selector, address(stablecoin), scheduleId, USER));
        vm.prank(otherUser);
        dcaManager.deleteDcaSchedule(address(stablecoin), scheduleId);
    }
    
    /*//////////////////////////////////////////////////////////////
                           BUY RBTC EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    // NOTE: This test is disabled because it requires a complete swap execution
    // which depends on proper Uniswap mock setup that's complex in this test environment.
    // The time period validation is already tested in the integration tests in DcaDappTest.
    function skip_test_singleScheduleBatch_reverts_beforePeriodElapsed() public {
        // Create schedule 
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether,           // depositAmount
            100 ether,           // purchaseAmount (less than half of deposit)
            MIN_PURCHASE_PERIOD, // purchasePeriod
            TROPYKUS_INDEX       // routeIndex
        );
        
        // This test would require a successful first purchase to set lastPurchaseTimestamp
        // Then test that immediate second purchase fails due to time period validation
        // However, this requires complex Uniswap mock setup that's already covered
        // in the DcaDappTest integration tests where the full environment is set up properly
    }
    
    function test_singleScheduleBatch_skipsInvalidScheduleId() public {
        // Create schedule
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether,           // depositAmount
            100 ether,           // purchaseAmount (less than half of deposit)
            MIN_PURCHASE_PERIOD, // purchasePeriod
            TROPYKUS_INDEX       // routeIndex
        );
        
        uint64 wrongId = UNUSED_SCHEDULE_ID;

        // R66: an id addressing no live schedule is skipped, not reverted.
        vm.expectEmit(true, true, false, true, address(dcaManager));
        emit IDcaManager.DcaManager__PurchaseRowSkipped(
            address(stablecoin), wrongId, IDcaManager.PurchaseRowSkipReason.InexistentSchedule
        );
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(batchOf(address(stablecoin), wrongId, 0, TROPYKUS_INDEX));
    }
    
    function test_createSchedule_reverts_insufficientBalance() public {
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
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, 600 ether); // More than deposited
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
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), scheduleId, 0);
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

        IDcaManager.DcaSchedule memory schedule = scheduleAt(dcaManager, USER, address(stablecoin), 0);
        assertEq(schedule.routeIndex, TROPYKUS_INDEX);

        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        vm.prank(USER);
        dcaManager.withdrawTokenAndInterest(address(stablecoin), scheduleId, 100 ether);

        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), 0).tokenBalance, 400 ether);
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
    
    function test_createDcaSchedule_reverts_invalidRoute() public {
        uint256 invalidRouteIndex = 999;
        
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.createDcaSchedule(
            address(stablecoin),
            500 ether, // depositAmount
            100 ether, // purchaseAmount
            MIN_PURCHASE_PERIOD,
            invalidRouteIndex
        );
    }
    
    /*//////////////////////////////////////////////////////////////
                           BATCH OPERATIONS EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    function test_batchBuyRbtc_reverts_emptyArrays() public {
        bytes32[] memory emptyRows = new bytes32[](0);

        vm.expectRevert(IDcaManager.DcaManager__EmptyBatchPurchaseArrays.selector);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(
            toBatch(emptyRows, address(stablecoin), TROPYKUS_INDEX)
        );
    }

    /// @dev A batch carries one array, so its rows can no longer disagree in length with anything.
    ///      What is left to reject is a batch with no rows at all.
    function test_batchBuyRbtc_reverts_emptyBatch() public {
        bytes32[] memory emptyRows = new bytes32[](0);

        vm.expectRevert(IDcaManager.DcaManager__EmptyBatchPurchaseArrays.selector);
        vm.prank(SWAPPER);
        dcaManager.batchBuyRbtc(toBatch(emptyRows, address(stablecoin), TROPYKUS_INDEX));
    }
    
    /*//////////////////////////////////////////////////////////////
                           SCHEDULE MODIFICATION EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    function test_updatePurchaseAmount_reverts_zeroAmount() public {
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
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, 0);
    }
    
    function test_updatePurchaseAmount_reverts_inexistentScheduleId() public {
        uint64 fakeScheduleId = UNUSED_SCHEDULE_ID;
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), fakeScheduleId, 100 ether);
    }
    
    function test_updatePurchasePeriod_reverts_invalidPeriod() public {
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
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        vm.expectRevert(IDcaManager.DcaManager__PurchasePeriodMustBeGreaterThanMinimum.selector);
        vm.prank(USER);
        dcaManager.updatePurchasePeriod(address(stablecoin), scheduleId, MIN_PURCHASE_PERIOD - 1);
    }
    
    /*//////////////////////////////////////////////////////////////
                           RBTC WITHDRAWAL EDGE CASES
    //////////////////////////////////////////////////////////////*/
    
    function test_withdrawAllAccumulatedRbtc_emptyArray_reverts() public {
        uint256[] memory emptyRoutes = new uint256[](0);
        address[] memory emptyTokens = new address[](0);

        // An empty call used to succeed silently; it now reverts like batchBuyRbtc does.
        vm.expectRevert(IDcaManager.DcaManager__EmptyWithdrawalArrays.selector);
        dcaManager.withdrawAllAccumulatedRbtc(emptyTokens, emptyRoutes);
    }

    function test_withdrawAllAccumulatedRbtc_lengthMismatch_reverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        uint256[] memory emptyRoutes = new uint256[](0);

        vm.expectRevert(IDcaManager.DcaManager__ArraysLengthMismatch.selector);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, emptyRoutes);
    }
    
    function test_withdrawAllAccumulatedRbtc_invalidRoute_skips() public {
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

    function test_withdrawAllAccumulatedRbtcAndInterest_mixedValidInvalidPairs() public {
        // Positional pairs: the same token is named once per route it may hold a position on.
        address[] memory tokens = new address[](3);
        tokens[0] = address(stablecoin);
        tokens[1] = address(stablecoin);
        tokens[2] = address(stablecoin);

        uint256[] memory routes = new uint256[](3);
        routes[0] = TROPYKUS_INDEX;
        routes[1] = SOVRYN_INDEX;
        routes[2] = 0;
        // Unit tests are only run on one protocol at a time, so this array is valid for testing

        // Should not revert: the pairs whose route has no handler for this lane are skipped.
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, routes);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routes);
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
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.depositToken(address(stablecoin), scheduleId, 0);
    }
    
    function test_depositToken_reverts_inexistentScheduleId() public {
        uint64 fakeScheduleId = UNUSED_SCHEDULE_ID;
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.depositToken(address(stablecoin), fakeScheduleId, 100 ether);
    }
    
    /*//////////////////////////////////////////////////////////////
                           FUZZ TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_inexistentScheduleOperationsRevert() public {
        uint64 fakeScheduleId = UNUSED_SCHEDULE_ID;
        // Every id-addressed operation rejects a schedule the caller does not hold.
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.depositToken(address(stablecoin), fakeScheduleId, 100 ether);
        
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), fakeScheduleId, 100 ether);
        
        vm.expectRevert();
        vm.prank(USER);
        dcaManager.updatePurchasePeriod(address(stablecoin), fakeScheduleId, MIN_PURCHASE_PERIOD);
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
