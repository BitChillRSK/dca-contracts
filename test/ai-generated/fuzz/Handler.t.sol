// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {DcaManager} from "src/DcaManager.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import "script/Constants.sol";

/**
 * @title Handler
 * @notice Handler contract for invariant testing
 * @dev Provides controlled randomized actions for invariant testing
 */
contract Handler is Test {
    /*//////////////////////////////////////////////////////////////
                            CONTRACTS
    //////////////////////////////////////////////////////////////*/
    
    DcaManager public dcaManager;
    OperationsAdmin public operationsAdmin;
    ITokenHandler public tokenHandler;
    IPurchaseRbtc public handler; // For rBTC balance checks and provisioning
    MockStablecoin public stablecoin;
    
    // Test role addresses (should match the invariant test setup)
    address public constant OWNER = address(0x1111);
    address public constant SWAPPER = address(0x3333);
    
    /*//////////////////////////////////////////////////////////////
                            TEST STATE
    //////////////////////////////////////////////////////////////*/
    
    address[] public s_users;
    
    // ----------------------------------------------------------------------------
    //  NOTE: We intentionally keep *only* lower-bounds that mirror on-chain
    //  require() checks so that handler calls never revert when `fail_on_revert`
    //  is active.  No arbitrary upper caps – we rely on vm.assume instead.
    // ----------------------------------------------------------------------------
    uint256 constant MIN_DEPOSIT_AMOUNT   = MIN_PURCHASE_AMOUNT * 2; // protocol-level rule

    // Upper-bound safety helpers (prevent overflow / gas OOM without masking logic)
    uint256 constant INTERNAL_UPPER_AMOUNT = 1e32;   // ≈ 10^14 ether – far above realistic amounts
    uint256 constant INTERNAL_UPPER_PERIOD = 520 weeks; // 10 years – prevents overflow on timestamp math
    
    // Track the number of calls for debugging
    uint256 public depositCalls;
    uint256 public withdrawCalls;
    uint256 public createScheduleCalls;
    uint256 public updateScheduleCalls;
    uint256 public buyRbtcCalls;
    
    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    
    constructor(
        DcaManager _dcaManager,
        OperationsAdmin _operationsAdmin,
        ITokenHandler _tokenHandler,
        IPurchaseRbtc _handler,
        MockStablecoin _stablecoin,
        address[] memory _users
    ) {
        dcaManager = _dcaManager;
        operationsAdmin = _operationsAdmin;
        tokenHandler = _tokenHandler;
        handler = _handler;
        stablecoin = _stablecoin;
        s_users = _users;
    }
    
    /*//////////////////////////////////////////////////////////////
                            HANDLER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Create a new DCA schedule for a random user
     */
    function createDcaSchedule(
        uint256 userSeed,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod
    ) external {
        createScheduleCalls++;
        
        address user = s_users[userSeed % s_users.length];
        
        // ---------------------------------------------------------------------
        // Assumptions – ensure inputs respect on-chain require() conditions.
        // ---------------------------------------------------------------------
        vm.assume(depositAmount >= MIN_DEPOSIT_AMOUNT);
        vm.assume(purchasePeriod >= MIN_PURCHASE_PERIOD);
        vm.assume(purchaseAmount >= MIN_PURCHASE_AMOUNT);
        vm.assume(purchaseAmount <= depositAmount / 2);

        // Prevent pathological gas / overflow situations without shrinking search-space too much
        depositAmount  = bound(depositAmount,  MIN_DEPOSIT_AMOUNT,  INTERNAL_UPPER_AMOUNT);
        purchasePeriod = bound(purchasePeriod, MIN_PURCHASE_PERIOD, INTERNAL_UPPER_PERIOD);
        purchasePeriod = (purchasePeriod / 1 days) * 1 days;
        purchaseAmount = bound(purchaseAmount, MIN_PURCHASE_AMOUNT, depositAmount / 2);

        // Mint enough tokens for the user and approve handler without arbitrary caps
        uint256 userBalance = stablecoin.balanceOf(user);
        if (userBalance < depositAmount) {
            stablecoin.mint(user, depositAmount - userBalance);
        }
        
        vm.startPrank(user);
        stablecoin.approve(address(tokenHandler), depositAmount);
        
        try dcaManager.createDcaSchedule(
            address(stablecoin),
            depositAmount,
            purchaseAmount,
            purchasePeriod,
            TROPYKUS_INDEX
        ) {
            // Success
        } catch {
            // Ignore failures (might be due to max schedules reached, etc.)
        }
        
        vm.stopPrank();
    }
    
    /**
     * @notice Deposit additional tokens to an existing schedule
     */
    function depositToken(
        uint256 userSeed,
        uint256 scheduleIndex,
        uint256 depositAmount
    ) external {
        depositCalls++;
        
        address user = s_users[userSeed % s_users.length];
        
        // -----------------------------------------------------------------
        // Assumptions to satisfy on-chain checks
        // -----------------------------------------------------------------
        vm.assume(depositAmount >= MIN_PURCHASE_AMOUNT);
        depositAmount = bound(depositAmount, MIN_PURCHASE_AMOUNT, INTERNAL_UPPER_AMOUNT);
        
        vm.startPrank(user);
        
        // Fetch schedules – must exist so we assume
        IDcaManager.DcaDetails[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
        vm.assume(schedules.length > 0);

        scheduleIndex = bound(scheduleIndex, 0, schedules.length - 1);

        // Mint tokens if needed
        uint256 userBalance = stablecoin.balanceOf(user);
        if (userBalance < depositAmount) {
            stablecoin.mint(user, depositAmount - userBalance);
        }
        
        stablecoin.approve(address(tokenHandler), depositAmount);
        
        bytes32 scheduleId = dcaManager.getScheduleId(user, address(stablecoin), scheduleIndex);
        try dcaManager.depositToken(address(stablecoin), scheduleIndex, scheduleId, depositAmount) {
            // Success
        } catch {
            // Ignore failures
        }
        
        vm.stopPrank();
    }
    
    /**
     * @notice Withdraw tokens from an existing schedule
     */
    function withdrawToken(
        uint256 userSeed,
        uint256 scheduleIndex,
        uint256 withdrawalAmount
    ) external {
        withdrawCalls++;
        
        address user = s_users[userSeed % s_users.length];
        
        vm.startPrank(user);
        
        IDcaManager.DcaDetails[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
        vm.assume(schedules.length > 0);

        scheduleIndex = bound(scheduleIndex, 0, schedules.length - 1);

        uint256 currentBalance = schedules[scheduleIndex].tokenBalance;
        vm.assume(currentBalance > 0);

        withdrawalAmount = bound(withdrawalAmount, 1, currentBalance);
        
        bytes32 scheduleId = dcaManager.getScheduleId(user, address(stablecoin), scheduleIndex);
        try dcaManager.withdrawToken(address(stablecoin), scheduleIndex, scheduleId, withdrawalAmount) {
            // Success
        } catch {
            // Ignore failures
        }
        
        vm.stopPrank();
    }
    
    /**
     * @notice Update an existing DCA schedule
     */
    function updateDcaSchedule(
        uint256 userSeed,
        uint256 scheduleIndex,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod
    ) external {
        updateScheduleCalls++;
        
        address user = s_users[userSeed % s_users.length];
        
        vm.startPrank(user);
        
        // Check if user has any schedules
        IDcaManager.DcaDetails[] memory schedules;
        try dcaManager.getDcaSchedules(user, address(stablecoin)) returns (IDcaManager.DcaDetails[] memory _schedules) {
            schedules = _schedules;
        } catch {
            vm.stopPrank();
            return;
        }
        
        if (schedules.length == 0) {
            vm.stopPrank();
            return;
        }
        
        scheduleIndex = bound(scheduleIndex, 0, schedules.length - 1);
        
        // -------------------- ASSUMPTIONS ---------------------------
        if (depositAmount > 0) {
            vm.assume(depositAmount >= MIN_PURCHASE_AMOUNT);
            depositAmount = bound(depositAmount, MIN_PURCHASE_AMOUNT, INTERNAL_UPPER_AMOUNT);
        }

        if (purchaseAmount > 0) {
            vm.assume(purchaseAmount >= MIN_PURCHASE_AMOUNT);
            // Must also satisfy _validatePurchaseAmount
            vm.assume(purchaseAmount <= schedules[scheduleIndex].tokenBalance / 2 + depositAmount / 2);
            purchaseAmount = bound(purchaseAmount, MIN_PURCHASE_AMOUNT, INTERNAL_UPPER_AMOUNT);
        }

        if (purchasePeriod > 0) {
            vm.assume(purchasePeriod >= MIN_PURCHASE_PERIOD);
            purchasePeriod = bound(purchasePeriod, MIN_PURCHASE_PERIOD, INTERNAL_UPPER_PERIOD);
            purchasePeriod = (purchasePeriod / 1 days) * 1 days;
        }

        // Mint tokens for additional deposit if needed
        if (depositAmount > 0) {
            uint256 userBalance = stablecoin.balanceOf(user);
            if (userBalance < depositAmount) {
                stablecoin.mint(user, depositAmount - userBalance);
            }
            stablecoin.approve(address(tokenHandler), depositAmount);
        }
        
        bytes32 scheduleId = dcaManager.getScheduleId(user, address(stablecoin), scheduleIndex);
        try dcaManager.updateDcaSchedule(
            address(stablecoin),
            scheduleIndex,
            scheduleId,
            depositAmount,
            purchaseAmount,
            purchasePeriod
        ) {
            // Success
        } catch {
            // Ignore failures
        }
        
        vm.stopPrank();
    }
    
    /**
     * @notice Delete a DCA schedule
     */
    function deleteDcaSchedule(
        uint256 userSeed,
        uint256 scheduleIndex
    ) external {
        address user = s_users[userSeed % s_users.length];
        
        vm.startPrank(user);
        
        IDcaManager.DcaDetails[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
        vm.assume(schedules.length > 0);

        scheduleIndex = bound(scheduleIndex, 0, schedules.length - 1);
        
        try dcaManager.deleteDcaSchedule(address(stablecoin), scheduleIndex, schedules[scheduleIndex].scheduleId) {
            // Success
        } catch {
            // Ignore failures
        }
        
        vm.stopPrank();
    }
    
    /**
     * @notice Simulate buying rBTC for a user (mock implementation)
     */
    function buyRbtc(
        uint256 userSeed,
        uint256 scheduleIndex
    ) external {
        buyRbtcCalls++;
        
        address user = s_users[userSeed % s_users.length];
        
        IDcaManager.DcaDetails[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
        vm.assume(schedules.length > 0);

        scheduleIndex = bound(scheduleIndex, 0, schedules.length - 1);

        IDcaManager.DcaDetails memory schedule = schedules[scheduleIndex];
        vm.assume(schedule.tokenBalance >= schedule.purchaseAmount);
        
        // Advance time if needed to make purchase possible
        uint256 nextValidTime = schedule.lastPurchaseTimestamp + schedule.purchasePeriod;
        if (block.timestamp < nextValidTime) {
            vm.warp(nextValidTime);
        }
        
        // Calculate rBTC needed and ensure handler has enough (just-in-time provisioning)
        // Mock conversion rate: 1 stablecoin = 0.00003 rBTC (from wrapper implementation)
        uint256 rbtcNeeded = (schedule.purchaseAmount * 3e16) / 1e18; // 0.03 rBTC per token
        uint256 currentHandlerBalance = address(handler).balance;
        if (currentHandlerBalance < rbtcNeeded) {
            vm.deal(address(handler), currentHandlerBalance + rbtcNeeded);
        }
        
        // Simulate the swapper role making the purchase using DcaManager's buyRbtc
        vm.startPrank(SWAPPER);
        
        try dcaManager.buyRbtc(user, address(stablecoin), scheduleIndex, schedule.scheduleId) {
            // Success
        } catch {
            // Ignore failures
        }
        
        vm.stopPrank();
    }
    
    /**
     * @notice Simulate batch buying rBTC for multiple users (mock implementation)
     */
    function batchBuyRbtc(
        uint256[] memory userSeeds,
        uint256[] memory scheduleIndexes,
        uint256 lendingProtocolIndex
    ) external {
        vm.assume(userSeeds.length > 0);
        vm.assume(userSeeds.length == scheduleIndexes.length);
        vm.assume(userSeeds.length <= s_users.length); // Prevent array bounds issues
        
        lendingProtocolIndex = bound(lendingProtocolIndex, 1, 2); // TROPYKUS_INDEX or SOVRYN_INDEX
        
        address[] memory buyers = new address[](userSeeds.length);
        uint256[] memory boundedScheduleIndexes = new uint256[](userSeeds.length);
        bytes32[] memory scheduleIds = new bytes32[](userSeeds.length);
        uint256[] memory purchaseAmounts = new uint256[](userSeeds.length);
        uint256 totalRbtcNeeded = 0;
        
        // Prepare batch data and calculate total rBTC needed
        for (uint256 i = 0; i < userSeeds.length; i++) {
            address user = s_users[userSeeds[i] % s_users.length];
            buyers[i] = user;
            
            IDcaManager.DcaDetails[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
            vm.assume(schedules.length > 0);
            
            boundedScheduleIndexes[i] = bound(scheduleIndexes[i], 0, schedules.length - 1);
            IDcaManager.DcaDetails memory schedule = schedules[boundedScheduleIndexes[i]];
            
            vm.assume(schedule.tokenBalance >= schedule.purchaseAmount);
            vm.assume(schedule.lendingProtocolIndex == lendingProtocolIndex);
            
            scheduleIds[i] = schedule.scheduleId;
            purchaseAmounts[i] = schedule.purchaseAmount;
            
            // Calculate rBTC needed for this purchase
            uint256 rbtcForThisPurchase = (schedule.purchaseAmount * 3e16) / 1e18;
            totalRbtcNeeded += rbtcForThisPurchase;
            
            // Advance time if needed
            uint256 nextValidTime = schedule.lastPurchaseTimestamp + schedule.purchasePeriod;
            if (block.timestamp < nextValidTime) {
                vm.warp(nextValidTime);
            }
        }
        
        // Ensure handler has enough rBTC for the entire batch
        uint256 currentHandlerBalance = address(handler).balance;
        if (currentHandlerBalance < totalRbtcNeeded) {
            vm.deal(address(handler), currentHandlerBalance + totalRbtcNeeded);
        }
        
        // Execute batch purchase
        vm.startPrank(SWAPPER);
        try dcaManager.batchBuyRbtc(
            buyers,
            address(stablecoin),
            boundedScheduleIndexes,
            scheduleIds,
            purchaseAmounts,
            lendingProtocolIndex
        ) {
            // Success
        } catch {
            // Ignore failures
        }
        vm.stopPrank();
    }
    
    /**
     * @notice Withdraw accumulated rBTC for a random user
     */
    function withdrawRbtcFromTokenHandler(
        uint256 userSeed,
        uint256 lendingProtocolIndex
    ) external {
        address user = s_users[userSeed % s_users.length];
        lendingProtocolIndex = bound(lendingProtocolIndex, 1, 2);
        
        vm.startPrank(user);
        try dcaManager.withdrawRbtcFromTokenHandler(address(stablecoin), lendingProtocolIndex) {
            // Success
        } catch {
            // Ignore failures
        }
        vm.stopPrank();
    }
    
    /**
     * @notice Withdraw all accumulated rBTC across all protocols
     */
    function withdrawAllAccumulatedRbtc(
        uint256 userSeed,
        uint256[] memory lendingProtocolIndexes
    ) external {
        address user = s_users[userSeed % s_users.length];
        
        // Bound and filter lending protocol indexes
        for (uint256 i = 0; i < lendingProtocolIndexes.length; i++) {
            lendingProtocolIndexes[i] = bound(lendingProtocolIndexes[i], 1, 2);
        }
        
        vm.startPrank(user);
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        try dcaManager.withdrawAllAccumulatedRbtc(tokens, lendingProtocolIndexes) {
            // Success  
        } catch {
            // Ignore failures
        }
        vm.stopPrank();
    }
    
    /**
     * @notice Withdraw token and interest from a schedule
     */
    function withdrawTokenAndInterest(
        uint256 userSeed,
        uint256 scheduleIndex,
        uint256 withdrawalAmount,
        uint256 lendingProtocolIndex
    ) external {
        address user = s_users[userSeed % s_users.length];
        lendingProtocolIndex = bound(lendingProtocolIndex, 1, 2);
        
        vm.startPrank(user);
        
        IDcaManager.DcaDetails[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
        vm.assume(schedules.length > 0);
        
        scheduleIndex = bound(scheduleIndex, 0, schedules.length - 1);
        uint256 currentBalance = schedules[scheduleIndex].tokenBalance;
        vm.assume(currentBalance > 0);
        
        withdrawalAmount = bound(withdrawalAmount, 1, currentBalance);
        
        bytes32 scheduleId = dcaManager.getScheduleId(user, address(stablecoin), scheduleIndex);
        try dcaManager.withdrawTokenAndInterest(
            address(stablecoin),
            scheduleIndex,
            scheduleId,
            withdrawalAmount,
            lendingProtocolIndex
        ) {
            // Success
        } catch {
            // Ignore failures
        }
        vm.stopPrank();
    }
    
    /**
     * @notice Withdraw all accumulated interest for a token
     */
    function withdrawAllAccumulatedInterest(
        uint256 userSeed,
        uint256[] memory lendingProtocolIndexes
    ) external {
        address user = s_users[userSeed % s_users.length];
        
        // Bound lending protocol indexes
        for (uint256 i = 0; i < lendingProtocolIndexes.length; i++) {
            lendingProtocolIndexes[i] = bound(lendingProtocolIndexes[i], 1, 2);
        }
        
        vm.startPrank(user);
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        try dcaManager.withdrawAllAccumulatedInterest(tokens, lendingProtocolIndexes) {
            // Success
        } catch {
            // Ignore failures
        }
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                        ADMINISTRATIVE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test modifying minimum purchase period (owner-only)
     */
    function modifyMinPurchasePeriod(uint256 newMinPurchasePeriod) external {
        newMinPurchasePeriod = bound(newMinPurchasePeriod, 1, 365) * 1 days;
        
        vm.startPrank(OWNER);
        try dcaManager.modifyMinPurchasePeriod(newMinPurchasePeriod) {
            // Success
        } catch {
            // Ignore failures
        }
        vm.stopPrank();
    }
    
    /**
     * @notice Test modifying maximum schedules per token (owner-only)
     */
    function modifyMaxSchedulesPerToken(uint256 newMaxSchedules) external {
        newMaxSchedules = bound(newMaxSchedules, 1, 50);
        
        vm.startPrank(OWNER);
        try dcaManager.modifyMaxSchedulesPerToken(newMaxSchedules) {
            // Success
        } catch {
            // Ignore failures
        }
        vm.stopPrank();
    }
    
    /**
     * @notice Test modifying minimum purchase amount on DCA manager (owner-only)
     */
    function modifyMinPurchaseAmount(
        uint256 newMinPurchaseAmount,
        uint256 lendingProtocolIndex
    ) external {
        newMinPurchaseAmount = bound(newMinPurchaseAmount, 1 ether, 1000 ether);
        lendingProtocolIndex = bound(lendingProtocolIndex, 1, 2);
        
        vm.startPrank(OWNER);
        try dcaManager.modifyDefaultMinPurchaseAmount(newMinPurchaseAmount) {
            // Success - this tests the default minimum purchase amount
        } catch {
            // Ignore failures
        }
        
        // Test setting custom amount for specific token
        try dcaManager.setTokenMinPurchaseAmount(address(stablecoin), newMinPurchaseAmount) {
            // Success - this tests setting custom amount per token
        } catch {
            // Ignore failures
        }
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
    
    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    function getCallCounts() external view returns (
        uint256 deposits,
        uint256 withdrawals,
        uint256 creates,
        uint256 updates,
        uint256 buys
    ) {
        return (depositCalls, withdrawCalls, createScheduleCalls, updateScheduleCalls, buyRbtcCalls);
    }
}
