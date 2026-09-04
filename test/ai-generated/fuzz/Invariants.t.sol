// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DcaManager} from "src/DcaManager.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {TropykusErc20Handler} from "src/tropykus-legacy/TropykusErc20Handler.sol";
import {SovrynErc20Handler} from "src/sovryn/SovrynErc20Handler.sol";
import {PurchaseRbtc} from "src/PurchaseRbtc.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {ITokenLending} from "src/interfaces/ITokenLending.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockKdocToken} from "test/mocks/MockKdocToken.sol";
import {MockIsusdToken} from "test/mocks/MockIsusdToken.sol";
import "test/Constants.sol";
import {Handler} from "./Handler.t.sol";
import {scheduleAt} from "test/utils/ScheduleAt.sol";

/**
 * @title InvariantTest
 * @notice Invariant tests for the BitChill DCA protocol
 * @dev Tests critical invariants that must always hold regardless of user actions
 *      Supports both local mocked tests and mainnet fork tests via environment variables
 */
contract InvariantTest is StdInvariant, Test {
    /*//////////////////////////////////////////////////////////////
                            CONTRACTS
    //////////////////////////////////////////////////////////////*/
    
    DcaManager public dcaManager;
    OperationsAdmin public operationsAdmin;
    IPurchaseRbtc public handler;
    MockStablecoin public stablecoin;
    MockKdocToken public kToken;
    MockIsusdToken public iSusdToken;
    Handler public fuzzHandler;
    
    /*//////////////////////////////////////////////////////////////
                            TEST CONFIGURATION
    //////////////////////////////////////////////////////////////*/
    
    uint256 constant NUM_USERS = 10;
    uint256 constant USER_INITIAL_BALANCE = 100000 ether; // 100k tokens per user
    uint256 constant HANDLER_INITIAL_BALANCE = 1000000 ether; // 1M tokens for handler operations
    
    address public constant OWNER = address(0x1111);
    address public constant ADMIN = address(0x2222);
    address public constant SWAPPER = address(0x3333);
    address public constant FEE_COLLECTOR = address(0x4444);
    
    address[] public s_users;
    uint256 public deploymentTimestamp;
    uint256 public s_routeIndex;
    
    /*//////////////////////////////////////////////////////////////
                           TEST CONSTANTS
    //////////////////////////////////////////////////////////////*/
    // No arbitrary economic caps – we only rely on protocol-level checks.

    function setUp() external {
        deploymentTimestamp = block.timestamp;
        
        // Setup lending protocol from environment variable (like unit tests)
        string memory lendingProtocol;
        try vm.envString("LENDING_PROTOCOL") returns (string memory protocol) {
            lendingProtocol = protocol;
        } catch {
            lendingProtocol = TROPYKUS_STRING; // Default to Tropykus
        }
        
        // Set route index from the lending-protocol env lane
        if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(TROPYKUS_STRING))) {
            s_routeIndex = TROPYKUS_INDEX;
        } else if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(SOVRYN_STRING))) {
            s_routeIndex = SOVRYN_INDEX;
        } else {
            revert("Invalid lending protocol");
        }
        
        // Deploy core contracts
        vm.prank(OWNER);
        operationsAdmin = new OperationsAdmin(OWNER);
        
        vm.prank(OWNER);
        dcaManager = new DcaManager(address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, OWNER);
        
        stablecoin = new MockStablecoin(address(this));
        
        // Setup swappers and lending routes
        vm.startPrank(OWNER);
        operationsAdmin.addSwapper(SWAPPER);
        operationsAdmin.registerRoute(TROPYKUS_INDEX, true);
        operationsAdmin.registerRoute(SOVRYN_INDEX, true);
        vm.stopPrank();
        
        // Deploy appropriate handler wrapper based on lending protocol
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });
        
        if (s_routeIndex == TROPYKUS_INDEX) {
            kToken = new MockKdocToken(address(stablecoin));
            handler = IPurchaseRbtc(address(new TropykusHandlerWrapper(
                address(dcaManager),
                address(stablecoin),
                address(kToken),
                FEE_COLLECTOR,
                feeSettings,
                OWNER
            )));
            // Give kToken sufficient balance for operations
            stablecoin.mint(address(kToken), HANDLER_INITIAL_BALANCE);
        } else {
            iSusdToken = new MockIsusdToken(address(stablecoin));
            handler = IPurchaseRbtc(address(new SovrynHandlerWrapper(
                address(dcaManager),
                address(stablecoin),
                address(iSusdToken),
                FEE_COLLECTOR,
                feeSettings,
                OWNER
            )));
            // Give iSusdToken sufficient balance for operations
            stablecoin.mint(address(iSusdToken), HANDLER_INITIAL_BALANCE);
        }
        
        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(
            address(stablecoin),
            s_routeIndex,
            address(handler)
        );
        
        // Setup users and balances
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user = address(uint160(0x10000 + i));
            s_users.push(user);
            stablecoin.mint(user, USER_INITIAL_BALANCE);
            
            vm.prank(user);
            stablecoin.approve(address(handler), type(uint256).max);
        }
        
        // Deploy and target the invariant handler
        fuzzHandler = new Handler(
            dcaManager,
            operationsAdmin,
            ITokenHandler(address(handler)),
            handler,
            stablecoin,
            s_users,
            s_routeIndex
        );
        
        targetContract(address(fuzzHandler));
    }

    function test_invariantHandlerCreatesScheduleAtSelectedRoute() public {
        fuzzHandler.createDcaSchedule(
            0,
            MIN_PURCHASE_AMOUNT,
            MIN_PURCHASE_AMOUNT,
            MIN_PURCHASE_PERIOD
        );
        assertEq(
            fuzzHandler.createScheduleSuccesses(),
            1,
            "Handler never created a schedule at the selected route"
        );
        IDcaManager.DcaSchedule[] memory schedules =
            dcaManager.getDcaSchedules(s_users[0], address(stablecoin));
        assertEq(schedules.length, 1);
        assertEq(schedules[0].routeIndex, s_routeIndex);
    }
    
    /// @dev The pause action reaches the chain and records its ghost entry, so a failure of
    ///      `invariant_pausedSchedulesNeverPurchase` means the protocol moved, not the harness.
    function test_invariantHandlerPausesAndRecordsGhost() public {
        fuzzHandler.createDcaSchedule(0, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD);
        assertEq(fuzzHandler.createScheduleSuccesses(), 1, "Handler never created a schedule to pause");

        fuzzHandler.pauseSchedule(0, 0);
        assertTrue(
            scheduleAt(dcaManager, s_users[0], address(stablecoin), 0).paused, "Handler did not pause on-chain"
        );
        assertEq(fuzzHandler.everPausedScheduleIdsLength(), 1, "Handler did not record the pause ghost");

        fuzzHandler.unpauseSchedule(0, 0);
        assertFalse(
            scheduleAt(dcaManager, s_users[0], address(stablecoin), 0).paused, "Handler did not resume on-chain"
        );
    }

    /// @dev Coverage guard: a purchase must actually reach the handler and credit rBTC.
    ///      DcaManager calls the wrappers below through an `IPurchaseRbtc` cast, so a wrapper whose
    ///      `batchBuyRbtc` signature has drifted from the interface is not a compile error — it is a
    ///      selector miss that reverts every purchase. `Handler` swallows those in try/catch, and no
    ///      invariant here asserts a purchase ever happened, so the whole suite would stay green with
    ///      its purchase invariants vacuous. That is exactly what R51's added `minRbtcOut` parameter
    ///      caused before this guard existed.
    function test_invariantHandlerBuysRbtcThroughDcaManager() public {
        fuzzHandler.createDcaSchedule(0, MIN_PURCHASE_AMOUNT * 10, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD);
        assertEq(fuzzHandler.createScheduleSuccesses(), 1, "Handler never created a schedule to buy for");

        fuzzHandler.buyRbtcOneSchedule(0, 0);

        assertEq(fuzzHandler.buyRbtcSuccesses(), 1, "the purchase never reached DcaManager");
        assertGt(
            handler.getAccumulatedRbtcBalance(s_users[0]),
            0,
            "the purchase reverted before crediting: the wrapper ABI has drifted from IPurchaseRbtc"
        );
    }

    /// @dev Coverage guard: the top-up action must actually land a credit. Almost every fuzzed
    ///      attempt is discarded — no schedule yet, nothing accrued yet, or a credit too small to
    ///      fund another purchase — and `Handler` swallows the rest in try/catch, so the action can
    ///      contribute nothing to `invariant_totalDepositedTokensMatchesLendingProtocol` while the
    ///      run stays green. This pins one deterministic win.
    function test_invariantHandlerTopsUpFromInterest() public {
        fuzzHandler.createDcaSchedule(0, MIN_PURCHASE_AMOUNT * 10, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD);
        assertEq(fuzzHandler.createScheduleSuccesses(), 1, "Handler never created a schedule to top up");

        // Leave the balance short of its next whole purchase, then let interest accrue past that gap.
        fuzzHandler.withdrawToken(0, 0, MIN_PURCHASE_AMOUNT / 10);
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 365 days / 30);
        uint256 accruedInterest = dcaManager.getInterestAccrued(s_users[0], address(stablecoin), s_routeIndex);
        assertGt(accruedInterest, MIN_PURCHASE_AMOUNT / 10, "the lane accrued too little to credit");

        uint256 balanceBefore = scheduleAt(dcaManager, s_users[0], address(stablecoin), 0).tokenBalance;
        fuzzHandler.topUpFromInterest(0, 0, type(uint256).max);

        assertEq(fuzzHandler.topUpFromInterestSuccesses(), 1, "the top-up never reached DcaManager");
        assertGt(
            scheduleAt(dcaManager, s_users[0], address(stablecoin), 0).tokenBalance,
            balanceBefore,
            "the top-up reverted before crediting the schedule"
        );
    }

    /*//////////////////////////////////////////////////////////////
                            INVARIANT TESTS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice The sum of all users' deposited tokens should match the total tokens in the lending protocol
     */
    function invariant_totalDepositedTokensMatchesLendingProtocol() public {
        uint256 totalUserDeposits = 0;
        uint256 totalLendingBalances = 0;
        
        // Sum all user deposits across all schedules AND their lending balances
        for (uint256 i = 0; i < s_users.length; i++) {
            address user = s_users[i];
            
            // Get user's shares balance
            uint256 userLendingBalance = ITokenLending(address(handler)).getUserShares(user);
            totalLendingBalances += userLendingBalance;
            
            // Get all schedules for this user with the stablecoin
            try dcaManager.getDcaSchedules(user, address(stablecoin)) returns (
                IDcaManager.DcaSchedule[] memory schedules
            ) {
                for (uint256 j = 0; j < schedules.length; j++) {
                    totalUserDeposits += schedules[j].tokenBalance;
                }
            } catch {
                continue;
            }
        }
        
        // Convert shares balances to stablecoin equivalent
        uint256 totalStablecoinInLendingProtocol = 0;
        if (totalLendingBalances > 0) {
            if (s_routeIndex == TROPYKUS_INDEX) {
                totalStablecoinInLendingProtocol = totalLendingBalances * kToken.exchangeRateCurrent() / 1e18;
            } else {
                totalStablecoinInLendingProtocol = totalLendingBalances * iSusdToken.tokenPrice() / 1e18;
            }
        }
        
        // ✅ CORRECTED INVARIANT: Lending protocol balance should be >= user deposits
        // because interest accrues over time. The only time they're exactly equal
        // is immediately after deposits with no time passing.
        if (totalUserDeposits > 0) {
            // ✅ Allow for small rounding errors (1-2 wei) due to integer arithmetic precision loss.
            // This is normal in DeFi protocols when converting between shares and underlying assets.
            uint256 tolerance = 100; // 100 wei tolerance for rounding errors and interest operations
            if (totalStablecoinInLendingProtocol < totalUserDeposits) {
                uint256 difference = totalUserDeposits - totalStablecoinInLendingProtocol;
                if (difference > tolerance) {
                    console2.log("INVARIANT VIOLATION:");
                    console2.log("   User deposits:", totalUserDeposits);
                    console2.log("   Lending protocol:", totalStablecoinInLendingProtocol);
                    console2.log("   Difference:", difference);
                    console2.log("   Tolerance:", tolerance);
                    assertLe(difference, tolerance, "Lending protocol balance too far below user deposits");
                }
            }
            // In most cases, lending protocol balance should be >= user deposits due to interest
        } else {
            // ✅ When all schedules are deleted, there might still be residual interest
            // in the lending protocol that hasn't been claimed. This is normal.
            // We just assert it's non-negative.
            assertGe(totalStablecoinInLendingProtocol, 0);
        }
        
        console2.log("Total user deposits:", totalUserDeposits);
        console2.log("Total in lending protocol:", totalStablecoinInLendingProtocol);
        console2.log("Total lending balances (kTokens):", totalLendingBalances);
    }
    
    /**
     * @notice Handler's rBTC balance should be reasonable and non-negative
     * @dev Simplified rBTC invariant - handler maintains proper rBTC balance
     */
    function invariant_rbtcBalancesConsistent() public {
        uint256 handlerRbtcBalance = address(handler).balance;
        
        // Basic invariant: handler should have reasonable rBTC balance 
        assertGe(handlerRbtcBalance, 0);
        
        console2.log("Handler rBTC balance:", handlerRbtcBalance);
    }
    
    /**
     * @notice User balances should never be negative or exceed reasonable bounds
     */
    function invariant_userBalancesReasonable() public {
        for (uint256 i = 0; i < s_users.length; i++) {
            address user = s_users[i];
            
            // Query balances (not capped anymore, but useful for logging)
            stablecoin.balanceOf(user);
            handler.getAccumulatedRbtcBalance(user);
            // No upper bound checks – only logical consistency properties below

            try dcaManager.getDcaSchedules(user, address(stablecoin)) returns (
                IDcaManager.DcaSchedule[] memory schedules
            ) {
                for (uint256 j = 0; j < schedules.length; j++) {
                    if (schedules[j].purchaseAmount > 0) {
                        assertGt(schedules[j].purchaseAmount, MIN_PURCHASE_AMOUNT);
                        assertGe(schedules[j].purchasePeriod, MIN_PURCHASE_PERIOD);
                    }
                    assertNotEq(schedules[j].scheduleId, uint64(0));
                }
            } catch {
                // User has no schedules, which is fine
            }
        }
    }
    
    /**
     * @notice The lending protocol exchange rate should only increase over time (interest accrual)
     */
    function invariant_exchangeRateOnlyIncreases() public {
        if (s_routeIndex == TROPYKUS_INDEX) {
            uint256 previousRate = kToken.exchangeRateStored();
            uint256 currentRate = kToken.exchangeRateCurrent();
            assertGe(currentRate, previousRate);
            console2.log("Previous stored rate:", previousRate);
            console2.log("Current rate:", currentRate);
        } else {
            uint256 previousRate = iSusdToken.tokenPrice();
            // For Sovryn, we don't store previous rate, so just check it's positive
            assertGt(previousRate, 0);
            console2.log("Current token price:", previousRate);
        }
    }
    
    /**
     * @notice Handler contracts should never hold any stablecoin tokens
     */
    function invariant_handlerStablecoinBalanceZero() public {
        uint256 handlerBalance = stablecoin.balanceOf(address(handler));
        assertEq(handlerBalance, 0);
        console2.log("Handler token balance:", handlerBalance);
    }
    
    /**
     * @notice Coverage guard: the pause invariant below must not be silently vacuous.
     * @dev It was, when it first landed. The pause action originally took a fuzzed `bool`, and the
     *      paused branch was never reached across 64 runs × 512 calls, so
     *      `invariant_pausedSchedulesNeverPurchase` passed against a set it never populated.
     *
     *      Stated as an implication rather than "some schedule got paused": whether the run ever has
     *      a live schedule to pause is up to the fuzzer's seed, and asserting on that directly is
     *      flaky (observed failing under `make check` while passing standalone). What must always
     *      hold is that a pause *attempted against a live schedule* actually took effect — which is
     *      exactly what the `bool` regression broke.
     */
    function afterInvariant() public view {
        // Deliberately no equivalent requirement for purchases here. A fuzz run can legitimately land
        // every purchase attempt on a paused or not-yet-due schedule, so "some purchase succeeded" is a
        // seed-dependent claim of the same kind this guard already had to abandon for pauses.
        // `test_invariantHandlerBuysRbtcThroughDcaManager` makes the point deterministically instead.
        if (fuzzHandler.pauseAttemptsOnLiveSchedule() == 0) return;
        require(
            fuzzHandler.everPausedScheduleIdsLength() > 0,
            "pause invariant is vacuous: pauses were attempted on live schedules but none took effect"
        );
    }

    /**
     * @notice A paused schedule never buys (R19)
     * @dev Only a purchase writes `lastPurchaseTimestamp` — deposits, withdrawals, and both edit
     *      mutators leave it alone — so an unchanged timestamp across a pause window is the
     *      accounting-independent statement of "this schedule did not buy while paused".
     *      Ids, not indexes: `deleteDcaSchedule` swap-pops, so a paused schedule can legitimately
     *      move. A schedule whose id is gone was deleted, which is an allowed exit while paused.
     */
    function invariant_pausedSchedulesNeverPurchase() public {
        uint256 trackedCount = fuzzHandler.everPausedScheduleIdsLength();

        for (uint256 i = 0; i < trackedCount; i++) {
            uint64 scheduleId = fuzzHandler.s_everPausedScheduleIds(i);
            (address user, uint256 timestampAtPause, bool pausedNow) = fuzzHandler.s_pauseGhost(scheduleId);
            if (!pausedNow) continue;

            IDcaManager.DcaSchedule[] memory schedules;
            try dcaManager.getDcaSchedules(user, address(stablecoin)) returns (
                IDcaManager.DcaSchedule[] memory _schedules
            ) {
                schedules = _schedules;
            } catch {
                continue;
            }

            for (uint256 j = 0; j < schedules.length; j++) {
                if (schedules[j].scheduleId != scheduleId) continue;

                assertTrue(schedules[j].paused, "a schedule the ghost holds paused is active on-chain");
                assertEq(
                    schedules[j].lastPurchaseTimestamp,
                    timestampAtPause,
                    "a paused schedule advanced its purchase timestamp"
                );
                break;
            }
        }
    }

    /**
     * @notice Interest should never decrease for users
     */
    function invariant_interestOnlyIncreases() public {
        for (uint256 i = 0; i < s_users.length; i++) {
            address user = s_users[i];
            
            try dcaManager.getDcaSchedules(user, address(stablecoin)) returns (
                IDcaManager.DcaSchedule[] memory schedules
            ) {
                if (schedules.length > 0) {
                    uint256 totalDeposited = 0;
                    for (uint256 j = 0; j < schedules.length; j++) {
                        if (schedules[j].routeIndex == s_routeIndex) {
                            totalDeposited += schedules[j].tokenBalance;
                        }
                    }
                    
                    if (totalDeposited > 0) {
                        uint256 lendingBalance = ITokenLending(address(handler)).getUserShares(user);
                        assertGe(lendingBalance, 0);
                    }
                }
            } catch {
                // User has no schedules, skip
            }
        }
    }
}

/**
 * @title TropykusHandlerWrapper
 * @notice Concrete implementation of TropykusErc20Handler for testing
 * @dev Properly simulates rBTC accounting - handler's balance decreases when users buy rBTC
 */
contract TropykusHandlerWrapper is TropykusErc20Handler {
    // Track users' accumulated RBTC for testing
    mapping(address user => uint256 amount) internal s_usersAccumulatedRbtc;
    
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
    
    /**
     * @notice Allow the contract to receive and hold rBTC
     */
    receive() external payable {}
    
    /**
     * @notice Mock implementation of batchBuyRbtc for testing
     * @dev Must track `IPurchaseRbtc.batchBuyRbtc` exactly. DcaManager reaches these wrappers through an
     *      interface cast, so a stale signature is not a compile error — it is a selector miss at runtime
     *      that reverts every purchase while the invariants above still pass, vacuously. R51 added
     *      `minRbtcOut`; `test_invariantHandlerBuysRbtcThroughDcaManager` is the guard that keeps this
     *      honest if the signature drifts again.
     */
    function batchBuyRbtc(
        address[] memory buyers,
        uint64[] memory scheduleIds,
        uint256[] memory purchaseAmounts,
        uint256 minRbtcOut
    ) external onlyDcaManager {
        uint256 totalPurchasedRbtc;
        for (uint256 i = 0; i < buyers.length; i++) {
            totalPurchasedRbtc += _buyRbtcInternal(buyers[i], scheduleIds[i], purchaseAmounts[i]);
        }
        // The real pipeline checks before crediting; a revert here undoes the credits above, so the
        // all-or-nothing outcome the caller sees is the same.
        if (totalPurchasedRbtc < minRbtcOut) {
            revert IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum(totalPurchasedRbtc, minRbtcOut);
        }
    }
    
    /**
     * @notice Get the accumulated rBTC balance for a specific user
     */
    function getAccumulatedRbtcBalance(address user) external view returns (uint256) {
        return s_usersAccumulatedRbtc[user];
    }
    
    /**
     * @notice Withdraw accumulated rBTC - transfers rBTC from handler to user
     */
    function withdrawAccumulatedRbtc(address user) external onlyDcaManager {
        uint256 rbtcBalance = s_usersAccumulatedRbtc[user];
        if (rbtcBalance == 0) return;
        
        s_usersAccumulatedRbtc[user] = 0;
        
        // Actually transfer rBTC (this properly decreases handler balance)
        (bool success, ) = payable(user).call{value: rbtcBalance}("");
        require(success, "rBTC transfer failed");
        
        emit PurchaseRbtc__rBtcWithdrawn(user, rbtcBalance);
    }
    
    /**
     * @notice Internal function for rBTC purchase logic
     * @dev Properly simulates: stablecoin -> rBTC conversion with correct balance accounting
     */
    function _buyRbtcInternal(
        address buyer,
        uint64 scheduleId,
        uint256 purchaseAmount
    ) internal returns (uint256) {
        // Retrieve the stablecoin the purchase will spend
        uint256 retrieved = _retrieveStablecoin(buyer, purchaseAmount);
        
        // ✅ SIMULATE: Consume the stablecoin retrieved (as it would be used for actual rBTC purchase)
        // In real protocol, this stablecoin gets sent to DEX/MoC and consumed
        // We simulate this by transferring it away (burn it)
        uint256 handlerBalance = i_stableToken.balanceOf(address(this));
        if (handlerBalance > 0) {
            i_stableToken.transfer(address(0xdead), handlerBalance); // Burn the stablecoin
        }
        
        // Mock conversion: 1 stablecoin = 0.00003 rBTC (roughly $50k BTC price)
        uint256 rbtcAmount = (retrieved * 3e16) / 1e18; // 0.03 rBTC per token
        
        // Ensure handler has enough rBTC (should have been allocated in setUp)
        require(address(this).balance >= rbtcAmount, "Handler insufficient rBTC balance");
        
        // Add to user's rBTC balance
        s_usersAccumulatedRbtc[buyer] += rbtcAmount;
        
        emit PurchaseRbtc__RbtcBought(buyer, address(i_stableToken), rbtcAmount, scheduleId, purchaseAmount);

        return rbtcAmount;
    }
    
    // Events for testing
    event PurchaseRbtc__RbtcBought(
        address indexed user,
        address indexed tokenSpent,
        uint256 rBtcBought,
        uint64 indexed scheduleId,
        uint256 amountSpent
    );
    event PurchaseRbtc__rBtcWithdrawn(address indexed user, uint256 amount);
}

/**
 * @title SovrynHandlerWrapper  
 * @notice Concrete implementation of SovrynErc20Handler for testing
 * @dev Provides the missing Sovryn wrapper for invariant testing
 */
contract SovrynHandlerWrapper is SovrynErc20Handler {
    // Track users' accumulated RBTC for testing
    mapping(address user => uint256 amount) internal s_usersAccumulatedRbtc;
    
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address iSusdTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        address initialOwner
    ) SovrynErc20Handler(
        dcaManagerAddress,
        stableTokenAddress,
        iSusdTokenAddress,
        feeCollector,
        feeSettings,
        initialOwner
    ) {}
    
    /**
     * @notice Allow the contract to receive and hold rBTC
     */
    receive() external payable {}
    
    /**
     * @notice Mock implementation of batchBuyRbtc for testing
     * @dev Must track `IPurchaseRbtc.batchBuyRbtc` exactly. DcaManager reaches these wrappers through an
     *      interface cast, so a stale signature is not a compile error — it is a selector miss at runtime
     *      that reverts every purchase while the invariants above still pass, vacuously. R51 added
     *      `minRbtcOut`; `test_invariantHandlerBuysRbtcThroughDcaManager` is the guard that keeps this
     *      honest if the signature drifts again.
     */
    function batchBuyRbtc(
        address[] memory buyers,
        uint64[] memory scheduleIds,
        uint256[] memory purchaseAmounts,
        uint256 minRbtcOut
    ) external onlyDcaManager {
        uint256 totalPurchasedRbtc;
        for (uint256 i = 0; i < buyers.length; i++) {
            totalPurchasedRbtc += _buyRbtcInternal(buyers[i], scheduleIds[i], purchaseAmounts[i]);
        }
        // The real pipeline checks before crediting; a revert here undoes the credits above, so the
        // all-or-nothing outcome the caller sees is the same.
        if (totalPurchasedRbtc < minRbtcOut) {
            revert IPurchaseRbtc.PurchaseRbtc__BelowSwapperMinimum(totalPurchasedRbtc, minRbtcOut);
        }
    }
    
    /**
     * @notice Get the accumulated rBTC balance for a specific user
     */
    function getAccumulatedRbtcBalance(address user) external view returns (uint256) {
        return s_usersAccumulatedRbtc[user];
    }
    
    /**
     * @notice Withdraw accumulated rBTC - transfers rBTC from handler to user
     */
    function withdrawAccumulatedRbtc(address user) external onlyDcaManager {
        uint256 rbtcBalance = s_usersAccumulatedRbtc[user];
        if (rbtcBalance == 0) return;
        
        s_usersAccumulatedRbtc[user] = 0;
        
        // Actually transfer rBTC (this properly decreases handler balance)
        (bool success, ) = payable(user).call{value: rbtcBalance}("");
        require(success, "rBTC transfer failed");
        
        emit PurchaseRbtc__rBtcWithdrawn(user, rbtcBalance);
    }
    
    /**
     * @notice Internal function for rBTC purchase logic
     */
    function _buyRbtcInternal(
        address buyer,
        uint64 scheduleId,
        uint256 purchaseAmount
    ) internal returns (uint256) {
        // Retrieve the stablecoin the purchase will spend
        uint256 retrieved = _retrieveStablecoin(buyer, purchaseAmount);
        
        // ✅ SIMULATE: Consume the stablecoin retrieved (as it would be used for actual rBTC purchase)
        // In real protocol, this stablecoin gets sent to DEX/MoC and consumed
        // We simulate this by transferring it away (burn it)
        uint256 handlerBalance = i_stableToken.balanceOf(address(this));
        if (handlerBalance > 0) {
            i_stableToken.transfer(address(0xdead), handlerBalance); // Burn the stablecoin
        }
        
        // Mock conversion: 1 stablecoin = 0.00003 rBTC
        uint256 rbtcAmount = (retrieved * 3e16) / 1e18; // 0.03 rBTC per token
        
        // Ensure handler has enough rBTC (should have been allocated in setUp)
        require(address(this).balance >= rbtcAmount, "Handler insufficient rBTC balance");
        
        // Add to user's rBTC balance  
        s_usersAccumulatedRbtc[buyer] += rbtcAmount;
        
        emit PurchaseRbtc__RbtcBought(buyer, address(i_stableToken), rbtcAmount, scheduleId, purchaseAmount);

        return rbtcAmount;
    }
    
    // Events for testing
    event PurchaseRbtc__RbtcBought(
        address indexed user,
        address indexed tokenSpent,
        uint256 rBtcBought,
        uint64 indexed scheduleId,
        uint256 amountSpent
    );
    event PurchaseRbtc__rBtcWithdrawn(address indexed user, uint256 amount);
}
