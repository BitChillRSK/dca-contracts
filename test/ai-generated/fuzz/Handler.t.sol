// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {DcaManager} from "src/DcaManager.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {toBatch} from "test/utils/BatchBuyOne.sol";
import "test/Constants.sol";

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
    uint256 public routeIndex;
    
    // Test role addresses (should match the invariant test setup)
    address public constant OWNER = address(0x1111);
    address public constant SWAPPER = address(0x3333);
    
    /*//////////////////////////////////////////////////////////////
                            TEST STATE
    //////////////////////////////////////////////////////////////*/
    
    address[] public s_users;

    /*//////////////////////////////////////////////////////////////
                        PAUSE GHOST STATE (R19)
    //////////////////////////////////////////////////////////////*/

    /// @dev Keyed by `scheduleId`, not by index: `deleteDcaSchedule` swap-pops, so an index does not
    ///      identify a schedule across calls while an id does (`AGENTS.md` invariant 7).
    struct PausedSchedule {
        address user;
        uint256 lastPurchaseTimestampAtPause;
        bool pausedNow;
    }

    mapping(uint64 scheduleId => PausedSchedule) public s_pauseGhost;
    uint64[] public s_everPausedScheduleIds;


    // ----------------------------------------------------------------------------
    //  NOTE: We intentionally keep *only* lower-bounds that mirror on-chain
    //  require() checks so that handler calls never revert when `fail_on_revert`
    //  is active.  No arbitrary upper caps – we rely on vm.assume instead.
    // ----------------------------------------------------------------------------
    uint256 constant MIN_DEPOSIT_AMOUNT   = MIN_PURCHASE_AMOUNT;

    // Upper-bound safety helpers (prevent overflow / gas OOM without masking logic)
    uint256 constant INTERNAL_UPPER_AMOUNT = 1e32;   // ≈ 10^14 ether – far above realistic amounts
    uint256 constant INTERNAL_UPPER_PERIOD = 520 weeks; // 10 years – prevents overflow on timestamp math
    
    // Track the number of calls for debugging
    uint256 public depositCalls;
    uint256 public withdrawCalls;
    uint256 public createScheduleCalls;
    uint256 public createScheduleSuccesses;
    uint256 public updateScheduleCalls;
    uint256 public buyRbtcCalls;
    /// @dev `buyRbtcCalls` counts attempts, not outcomes. A purchase that never reaches the handler
    ///      leaves every purchase invariant vacuously true, so the suite must be able to count wins too.
    uint256 public buyRbtcSuccesses;
    uint256 public pauseCalls;
    uint256 public pauseAttemptsOnLiveSchedule;
    /// @dev Attempts and wins for the interest top-up. Most attempts are discarded (no schedule, no
    ///      accrued interest yet, or a credit too small to fund another purchase), so a run that
    ///      never landed one would leave the reconciliation invariants untouched by this path.
    uint256 public topUpFromInterestCalls;
    uint256 public topUpFromInterestSuccesses;
    
    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    
    constructor(
        DcaManager _dcaManager,
        OperationsAdmin _operationsAdmin,
        ITokenHandler _tokenHandler,
        IPurchaseRbtc _handler,
        MockStablecoin _stablecoin,
        address[] memory _users,
        uint256 _routeIndex
    ) {
        dcaManager = _dcaManager;
        operationsAdmin = _operationsAdmin;
        tokenHandler = _tokenHandler;
        handler = _handler;
        stablecoin = _stablecoin;
        s_users = _users;
        routeIndex = _routeIndex;
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
        vm.assume(purchaseAmount <= depositAmount);

        // Prevent pathological gas / overflow situations without shrinking search-space too much
        depositAmount  = bound(depositAmount,  MIN_DEPOSIT_AMOUNT,  INTERNAL_UPPER_AMOUNT);
        purchasePeriod = bound(purchasePeriod, MIN_PURCHASE_PERIOD, INTERNAL_UPPER_PERIOD);
        purchaseAmount = bound(purchaseAmount, MIN_PURCHASE_AMOUNT, depositAmount);

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
            routeIndex
        ) {
            createScheduleSuccesses++;
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
        IDcaManager.DcaSchedule[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
        vm.assume(schedules.length > 0);

        scheduleIndex = bound(scheduleIndex, 0, schedules.length - 1);

        // Mint tokens if needed
        uint256 userBalance = stablecoin.balanceOf(user);
        if (userBalance < depositAmount) {
            stablecoin.mint(user, depositAmount - userBalance);
        }
        
        stablecoin.approve(address(tokenHandler), depositAmount);
        
        uint64 scheduleId = dcaManager.getDcaSchedule(user, address(stablecoin), scheduleIndex).scheduleId;
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
        
        IDcaManager.DcaSchedule[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
        vm.assume(schedules.length > 0);

        scheduleIndex = bound(scheduleIndex, 0, schedules.length - 1);

        uint256 currentBalance = schedules[scheduleIndex].tokenBalance;
        vm.assume(currentBalance > 0);

        withdrawalAmount = bound(withdrawalAmount, 1, currentBalance);
        
        uint64 scheduleId = dcaManager.getDcaSchedule(user, address(stablecoin), scheduleIndex).scheduleId;
        try dcaManager.withdrawToken(address(stablecoin), scheduleIndex, scheduleId, withdrawalAmount) {
            // Success
        } catch {
            // Ignore failures
        }
        
        vm.stopPrank();
    }
    
    /**
     * @notice Apply intent-specific schedule edits. Combined updates take two or three calls.
     */
    function applyScheduleEdits(
        uint256 userSeed,
        uint256 scheduleIndex,
        uint256 depositAmount,
        uint256 purchaseAmount,
        uint256 purchasePeriod
    ) external {
        updateScheduleCalls++;
        
        address user = s_users[userSeed % s_users.length];
        
        vm.startPrank(user);
        
        IDcaManager.DcaSchedule[] memory schedules;
        try dcaManager.getDcaSchedules(user, address(stablecoin)) returns (IDcaManager.DcaSchedule[] memory _schedules) {
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
        uint64 scheduleId = schedules[scheduleIndex].scheduleId;
        uint256 currentBalance = schedules[scheduleIndex].tokenBalance;

        if (depositAmount > 0) {
            vm.assume(depositAmount >= MIN_PURCHASE_AMOUNT);
            depositAmount = bound(depositAmount, MIN_PURCHASE_AMOUNT, INTERNAL_UPPER_AMOUNT);
        }

        if (purchaseAmount > 0) {
            uint256 maxPurchase = currentBalance + (depositAmount > 0 ? depositAmount : 0);
            vm.assume(purchaseAmount >= MIN_PURCHASE_AMOUNT);
            vm.assume(maxPurchase >= MIN_PURCHASE_AMOUNT);
            vm.assume(purchaseAmount <= maxPurchase);
            purchaseAmount = bound(purchaseAmount, MIN_PURCHASE_AMOUNT, INTERNAL_UPPER_AMOUNT);
        }

        if (purchasePeriod > 0) {
            vm.assume(purchasePeriod >= MIN_PURCHASE_PERIOD);
            purchasePeriod = bound(purchasePeriod, MIN_PURCHASE_PERIOD, INTERNAL_UPPER_PERIOD);
        }

        if (depositAmount > 0) {
            uint256 userBalance = stablecoin.balanceOf(user);
            if (userBalance < depositAmount) {
                stablecoin.mint(user, depositAmount - userBalance);
            }
            stablecoin.approve(address(tokenHandler), depositAmount);
            try dcaManager.depositToken(address(stablecoin), scheduleIndex, scheduleId, depositAmount) {
                // Success
            } catch {
                // Ignore failures
            }
        }

        if (purchaseAmount > 0) {
            try dcaManager.updatePurchaseAmount(address(stablecoin), scheduleIndex, scheduleId, purchaseAmount) {
                // Success
            } catch {
                // Ignore failures
            }
        }

        if (purchasePeriod > 0) {
            try dcaManager.updatePurchasePeriod(address(stablecoin), scheduleIndex, scheduleId, purchasePeriod) {
                // Success
            } catch {
                // Ignore failures
            }
        }
        
        vm.stopPrank();
    }
    
    /**
     * @notice Pause purchases on a random schedule (R19)
     * @dev Pause and resume are two selectors rather than one taking a flag. The invariant fuzzer
     *      explores *which function* it calls far better than it explores argument values: with a
     *      `bool` (or a parity-derived seed) the paused branch was never once reached across
     *      64 runs × 512 calls, which made the pause invariant silently vacuous. Selector choice is
     *      the lever that actually varies, so the flag is encoded in the selector.
     *      Resume must stay reachable — a one-way pause would starve the purchase actions of
     *      eligible rows and quietly hollow out the rest of the suite.
     */
    function pauseSchedule(uint256 userSeed, uint256 scheduleIndex) external {
        _setSchedulePaused(userSeed, scheduleIndex, true);
    }

    /**
     * @notice Resume purchases on a random schedule (R19)
     */
    function unpauseSchedule(uint256 userSeed, uint256 scheduleIndex) external {
        _setSchedulePaused(userSeed, scheduleIndex, false);
    }

    /**
     * @dev Scans from the seeded user for one that actually holds a schedule instead of returning
     *      empty-handed. Picking blind wasted most calls early in a run, when few users have any.
     */
    function _setSchedulePaused(uint256 userSeed, uint256 scheduleIndex, bool paused) private {
        pauseCalls++;

        uint256 numOfUsers = s_users.length;
        for (uint256 k; k < numOfUsers; ++k) {
            // Reduce the seed before adding the offset: the fuzzer hands out words near
            // type(uint256).max, and `userSeed + k` on one of those panics with an overflow.
            address user = s_users[(userSeed % numOfUsers + k) % numOfUsers];

            IDcaManager.DcaSchedule[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
            if (schedules.length == 0) continue;

            uint256 index = bound(scheduleIndex, 0, schedules.length - 1);
            uint64 scheduleId = schedules[index].scheduleId;

            if (paused) pauseAttemptsOnLiveSchedule++;

            vm.prank(user);
            try dcaManager.setSchedulePaused(address(stablecoin), index, scheduleId, paused) {
                if (paused) {
                    if (s_pauseGhost[scheduleId].user == address(0)) s_everPausedScheduleIds.push(scheduleId);
                    // Re-snapshot on every pause: the schedule may have bought legitimately while active.
                    s_pauseGhost[scheduleId] = PausedSchedule({
                        user: user,
                        lastPurchaseTimestampAtPause: schedules[index].lastPurchaseTimestamp,
                        pausedNow: true
                    });
                } else {
                    s_pauseGhost[scheduleId].pausedNow = false;
                }
            } catch {
                // Ignore failures
            }
            return;
        }
    }

    /**
     * @notice Every schedule that has ever been paused, for the pause invariant to walk.
     */
    function everPausedScheduleIdsLength() external view returns (uint256) {
        return s_everPausedScheduleIds.length;
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
        
        IDcaManager.DcaSchedule[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
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
     * @notice Simulate buying rBTC for one schedule via a length-1 batch (mock implementation)
     * @dev R39 removed the single-schedule `buyRbtc` selector; a length-1 `batchBuyRbtc` is that path.
     */
    function buyRbtcOneSchedule(
        uint256 userSeed,
        uint256 scheduleIndex
    ) external {
        buyRbtcCalls++;
        
        address user = s_users[userSeed % s_users.length];
        
        IDcaManager.DcaSchedule[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
        vm.assume(schedules.length > 0);

        scheduleIndex = bound(scheduleIndex, 0, schedules.length - 1);

        IDcaManager.DcaSchedule memory schedule = schedules[scheduleIndex];
        vm.assume(schedule.tokenBalance >= schedule.purchaseAmount);
        
        // Advance time if needed to make purchase possible. Widen first: the packed
        // uint48 timestamp + uint32 period would overflow the packed type, not uint256.
        uint256 nextValidTime = uint256(schedule.lastPurchaseTimestamp) + uint256(schedule.purchasePeriod);
        if (block.timestamp < nextValidTime) {
            vm.warp(nextValidTime);
        }
        
        // Calculate rBTC needed and ensure handler has enough (just-in-time provisioning)
        // Mock conversion rate: 1 stablecoin = 0.00003 rBTC (from wrapper implementation)
        uint256 rbtcNeeded = (uint256(schedule.purchaseAmount) * 3e16) / 1e18; // 0.03 rBTC per token
        uint256 currentHandlerBalance = address(handler).balance;
        if (currentHandlerBalance < rbtcNeeded) {
            vm.deal(address(handler), currentHandlerBalance + rbtcNeeded);
        }
        
        // Simulate the swapper role making the purchase using a length-1 batchBuyRbtc
        vm.startPrank(SWAPPER);
        
        address[] memory buyers = new address[](1);
        uint256[] memory scheduleIndexes = new uint256[](1);
        uint64[] memory scheduleIds = new uint64[](1);
        uint256[] memory purchaseAmounts = new uint256[](1);
        buyers[0] = user;
        scheduleIndexes[0] = scheduleIndex;
        scheduleIds[0] = schedule.scheduleId;
        purchaseAmounts[0] = schedule.purchaseAmount;

        try dcaManager.batchBuyRbtc(
            toBatch(buyers, address(stablecoin), scheduleIndexes, scheduleIds, purchaseAmounts, schedule.routeIndex)
        ) {
            buyRbtcSuccesses++;
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
        uint256[] memory scheduleIndexes
    ) external {
        vm.assume(userSeeds.length > 0);
        vm.assume(userSeeds.length == scheduleIndexes.length);
        vm.assume(userSeeds.length <= s_users.length); // Prevent array bounds issues
        
        address[] memory buyers = new address[](userSeeds.length);
        uint256[] memory boundedScheduleIndexes = new uint256[](userSeeds.length);
        uint64[] memory scheduleIds = new uint64[](userSeeds.length);
        uint256[] memory purchaseAmounts = new uint256[](userSeeds.length);
        uint256 totalRbtcNeeded = 0;
        
        // Prepare batch data and calculate total rBTC needed
        for (uint256 i = 0; i < userSeeds.length; i++) {
            address user = s_users[userSeeds[i] % s_users.length];
            buyers[i] = user;
            
            IDcaManager.DcaSchedule[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
            vm.assume(schedules.length > 0);
            
            boundedScheduleIndexes[i] = bound(scheduleIndexes[i], 0, schedules.length - 1);
            IDcaManager.DcaSchedule memory schedule = schedules[boundedScheduleIndexes[i]];
            
            vm.assume(schedule.tokenBalance >= schedule.purchaseAmount);
            vm.assume(schedule.routeIndex == routeIndex);
            
            scheduleIds[i] = schedule.scheduleId;
            purchaseAmounts[i] = schedule.purchaseAmount;
            
            // Calculate rBTC needed for this purchase
            uint256 rbtcForThisPurchase = (uint256(schedule.purchaseAmount) * 3e16) / 1e18;
            totalRbtcNeeded += rbtcForThisPurchase;
            
            // Advance time if needed
            uint256 nextValidTime = uint256(schedule.lastPurchaseTimestamp) + uint256(schedule.purchasePeriod);
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
            toBatch(
            buyers,
            address(stablecoin),
            boundedScheduleIndexes,
            scheduleIds,
            purchaseAmounts,
            routeIndex
            )
        ) {
            buyRbtcSuccesses++;
        } catch {
            // Ignore failures
        }
        vm.stopPrank();
    }
    
    /**
     * @notice Withdraw accumulated rBTC for a random user
     */
    function withdrawRbtcFromTokenHandler(uint256 userSeed) external {
        address user = s_users[userSeed % s_users.length];
        
        vm.startPrank(user);
        try dcaManager.withdrawRbtcFromTokenHandler(address(stablecoin), routeIndex) {
            // Success
        } catch {
            // Ignore failures
        }
        vm.stopPrank();
    }
    
    /**
     * @notice Withdraw all accumulated rBTC across all protocols
     */
    function withdrawAllAccumulatedRbtc(uint256 userSeed) external {
        address user = s_users[userSeed % s_users.length];
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = routeIndex;
        
        vm.startPrank(user);
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        try dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes) {
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
        uint256 withdrawalAmount
    ) external {
        address user = s_users[userSeed % s_users.length];
        
        vm.startPrank(user);
        
        IDcaManager.DcaSchedule[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
        vm.assume(schedules.length > 0);
        
        scheduleIndex = bound(scheduleIndex, 0, schedules.length - 1);
        uint256 currentBalance = schedules[scheduleIndex].tokenBalance;
        vm.assume(currentBalance > 0);
        
        withdrawalAmount = bound(withdrawalAmount, 1, currentBalance);
        
        uint64 scheduleId = dcaManager.getDcaSchedule(user, address(stablecoin), scheduleIndex).scheduleId;
        try dcaManager.withdrawTokenAndInterest(
            address(stablecoin),
            scheduleIndex,
            scheduleId,
            withdrawalAmount
        ) {
            // Success
        } catch {
            // Ignore failures
        }
        vm.stopPrank();
    }
    
    /**
     * @notice Credit part of a user's accrued lending interest to one of their schedules.
     * @dev Moves no cash, so it is the one action that raises principal without a matching deposit.
     *      Interleaved with withdrawals and purchases it is the sequence most likely to push the
     *      deposited-vs-lending reconciliation off, which is what `fail_on_revert = false` fuzzing
     *      over tens of thousands of calls is for.
     */
    function topUpFromInterest(uint256 userSeed, uint256 scheduleIndex, uint256 amountSeed) external {
        address user = s_users[userSeed % s_users.length];
        topUpFromInterestCalls++;

        IDcaManager.DcaSchedule[] memory schedules = dcaManager.getDcaSchedules(user, address(stablecoin));
        if (schedules.length == 0) return;
        scheduleIndex = bound(scheduleIndex, 0, schedules.length - 1);

        // Non-lending routes revert this getter rather than returning zero.
        uint256 accruedInterest;
        try dcaManager.getInterestAccrued(user, address(stablecoin), routeIndex) returns (uint256 accrued) {
            accruedInterest = accrued;
        } catch {
            return;
        }
        if (accruedInterest == 0) return;

        vm.prank(user);
        try dcaManager.topUpFromInterest(
            address(stablecoin), scheduleIndex, schedules[scheduleIndex].scheduleId, bound(amountSeed, 1, accruedInterest)
        ) {
            topUpFromInterestSuccesses++;
        } catch {
            // A credit too small to fund another purchase, or a route with no handler.
        }
    }

    /**
     * @notice Withdraw all accumulated interest for a token
     */
    function withdrawAllAccumulatedInterest(uint256 userSeed) external {
        address user = s_users[userSeed % s_users.length];
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = routeIndex;
        
        vm.startPrank(user);
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        try dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes) {
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
        newMinPurchasePeriod = bound(newMinPurchasePeriod, 1 days, 365 days);
        
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
    function modifyMinPurchaseAmount(uint256 newMinPurchaseAmount) external {
        newMinPurchaseAmount = bound(newMinPurchaseAmount, 1 ether, 1000 ether);
        
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
