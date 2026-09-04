//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {TropykusDocHandlerMoc} from "../../src/tropykus-legacy/TropykusDocHandlerMoc.sol";
import {SovrynDocHandlerMoc} from "../../src/sovryn/SovrynDocHandlerMoc.sol";
import {IShareToken} from "../interfaces/IShareToken.sol";
import {IkToken} from "../../src/tropykus-legacy/IkToken.sol";
import {MocHelperConfig} from "../../script/MocHelperConfig.s.sol";
import "../Constants.sol";
import {scheduleIdAt} from "test/utils/ScheduleAt.sol";

contract StablecoinLendingTest is DcaDappTest {
    uint256 constant SHARE_TOKEN_STARTING_EXCHANGE_RATE = 2e16;

    // Events
    event TokenLending__InterestWithdrawn(address indexed user, address indexed token, uint256 amount);

    // No `setUp` override: `vm.skip(true)` at the end of a `setUp` that already ran `super.setUp()`
    // is reported as `FAIL: FOUNDRY::SKIP` by some Foundry builds (CI pins `version: stable`, which
    // drifts from local). Every test below gates on a lane modifier instead — same coverage, no
    // cheatcode in `setUp`.

    /////////////////////////////////////
    ///// Stablecoin Lending tests /////
    /////////////////////////////////////
    // onlyShareTokenLane cases skip LayerBank: aToken is not IShareToken. Index-1 share math is
    // test/ai-generated/unit/layerbank/. Interest tests below still run on the layerbank lane.
    function testDepositedStablecoinIsLent() external onlyShareTokenLane {
        // Check initial balances
        uint256 ltStablecoinBalanceBeforeDeposit = stablecoin.balanceOf(address(shareToken));
        
        super.depositStablecoin();
        
        // Check if stablecoin has been transferred from the handler to the shares
        uint256 ltStablecoinBalanceAfterDeposit = stablecoin.balanceOf(address(shareToken));
        
        // Check that the stablecoin handler has 0 balance (all stablecoin was sent to shares)
        assertEq(stablecoin.balanceOf(address(stablecoinHandler)), 0, "Stablecoin balance in handler should be 0");
        
        // Check that the correct amount was added to the shares
        assertEq(ltStablecoinBalanceAfterDeposit - ltStablecoinBalanceBeforeDeposit, AMOUNT_TO_DEPOSIT, "Incorrect amount deposited in shares");
    }

    function testStablecoinDepositIncreasesSharesBalance() external onlyShareTokenLane {
        uint256 prevSharesBalance = stablecoinHandler.getUserShares(USER);
        super.depositStablecoin();
        uint256 postSharesBalance = stablecoinHandler.getUserShares(USER);

        uint256 exchangeRate = s_routeIndex == TROPYKUS_INDEX 
            ? shareToken.exchangeRateCurrent() 
            : shareToken.tokenPrice();

        // Check that the actual shares (the one used by the stablecoin handler) has the correct balance
        assertApproxEqRel(
            shareToken.balanceOf(address(stablecoinHandler)),
            2 * AMOUNT_TO_DEPOSIT * 1e18 / exchangeRate,
            1 // Allow a maximum difference of 1e-18%
        );

        assertEq(postSharesBalance - prevSharesBalance, AMOUNT_TO_DEPOSIT * 1e18 / exchangeRate);
    }

    function testStablecoinWithdrawalBurnsShares() external onlyShareTokenLane {
        uint256 prevSharesBalance = stablecoinHandler.getUserShares(USER);
        super.withdrawStablecoin();
        uint256 postSharesBalance = stablecoinHandler.getUserShares(USER);
        uint256 exchangeRate =
            s_routeIndex == TROPYKUS_INDEX ? shareToken.exchangeRateCurrent() : shareToken.tokenPrice();
        
        assertApproxEqAbs(
            shareToken.balanceOf(address(stablecoinHandler)),
            0,
            100 // Allow a maximum difference of 100e-18%
        );
        assertApproxEqAbs(
            prevSharesBalance - postSharesBalance,
            AMOUNT_TO_DEPOSIT * 1e18 / exchangeRate,
            100 // Allow a maximum difference of 100e-18%
        );
    }

    function testRbtcPurchaseBurnsShares() external onlyShareTokenLane {
        uint256 prevSharesBalance = stablecoinHandler.getUserShares(USER);
        super.makeSinglePurchase();
        uint256 postSharesBalance = stablecoinHandler.getUserShares(USER);
        uint256 startingExchangeRate = SHARE_TOKEN_STARTING_EXCHANGE_RATE;

        // On fork tests we need to simulate some operation on Tropykus so that the exchange rate gets updated
        if (block.chainid != ANVIL_CHAIN_ID) {
            startingExchangeRate = s_routeIndex == TROPYKUS_INDEX
                ? shareToken.exchangeRateCurrent()
                : shareToken.tokenPrice();
            updateExchangeRate(1 days);
        }
        uint256 exchangeRate =
            s_routeIndex == TROPYKUS_INDEX ? shareToken.exchangeRateCurrent() : shareToken.tokenPrice();

        assertApproxEqRel(
            shareToken.balanceOf(address(stablecoinHandler)),
            (AMOUNT_TO_DEPOSIT * 1e18 / startingExchangeRate - AMOUNT_TO_SPEND * 1e18 / exchangeRate),
            0.3e16 // Allow a maximum difference of 0.3%
        );

        assertApproxEqRel(
            prevSharesBalance - postSharesBalance,
            AMOUNT_TO_SPEND * 1e18 / exchangeRate,
            0.3e16 // Allow a maximum difference of 0.3%
        );
    }

    function testSeveralRbtcPurchasesBurnShares() external onlyShareTokenLane {
        // This just for one user, for many users this will get tested in invariant tests
        super.createSeveralDcaSchedules();
        uint256 prevSharesBalance = stablecoinHandler.getUserShares(USER);

        uint256 startingExchangeRate = SHARE_TOKEN_STARTING_EXCHANGE_RATE;
        // On fork tests we need to simulate some operation on Tropykus so that the exchange rate gets updated
        if (block.chainid != ANVIL_CHAIN_ID) {
            startingExchangeRate = s_routeIndex == TROPYKUS_INDEX
                ? shareToken.exchangeRateCurrent()
                : shareToken.tokenPrice();
        }

        super.makeSeveralPurchasesWithSeveralSchedules();
        uint256 postSharesBalance = stablecoinHandler.getUserShares(USER);

        // if (block.chainid != ANVIL_CHAIN_ID) updateExchangeRate(1 days);
        uint256 exchangeRate =
            s_routeIndex == TROPYKUS_INDEX ? shareToken.exchangeRateCurrent() : shareToken.tokenPrice();

        // @notice In this test we don't use assertEq because calculating the exact number on the right hand side would be too much hassle
        // However, we check that the shares spent to redeem stablecoin to make the rBTC purchases is lower than the amount we would have
        // needed if the exchange rate were constant and greater than the amount necessary if all the redemptions had been made at the latest 
        // exchange rate (since as time passes fewer tokens are necessary to redeem each stablecoin)
        assertLt(
            prevSharesBalance - postSharesBalance,
            NUM_OF_SCHEDULES * AMOUNT_TO_SPEND * 1e18 / startingExchangeRate
        );
        assertGt(
            prevSharesBalance - postSharesBalance, 
            NUM_OF_SCHEDULES * AMOUNT_TO_SPEND * 1e18 / exchangeRate
        );

        // @notice Similarly, here we check that the remaining shares balance of the stablecoin Token Handler contract is lower
        // than it would have been if the redemptions had been made at the highest exchange rate but greater than
        // if the redemptions had been made at the starting exchange rate
        assertLt(
            shareToken.balanceOf(address(stablecoinHandler)),
            AMOUNT_TO_DEPOSIT * 1e18 / startingExchangeRate - NUM_OF_SCHEDULES * AMOUNT_TO_SPEND * 1e18 / exchangeRate
        );
        assertGt(
            shareToken.balanceOf(address(stablecoinHandler)),
            AMOUNT_TO_DEPOSIT * 1e18 / startingExchangeRate - NUM_OF_SCHEDULES * AMOUNT_TO_SPEND * 1e18 / startingExchangeRate
        );
    }

    function testRbtcBatchPurchaseBurnsShares() external onlyShareTokenLane {
        // This just for one user, for many users this will get tested in invariant tests
        super.createSeveralDcaSchedules(); // This creates NUM_OF_SCHEDULES schedules with purchaseAmount = AMOUNT_TO_SPEND / NUM_OF_SCHEDULES
        uint256 prevSharesBalance = stablecoinHandler.getUserShares(USER);

        uint256 startingExchangeRate = SHARE_TOKEN_STARTING_EXCHANGE_RATE;
        // On fork tests we need to simulate some operation on Tropykus so that the exchange rate gets updated
        if (block.chainid != ANVIL_CHAIN_ID) {
            startingExchangeRate = s_routeIndex == TROPYKUS_INDEX
                ? shareToken.exchangeRateCurrent()
                : shareToken.tokenPrice();
        }

        super.makeBatchPurchasesOneUser(); // Batched purchases add up to an amount of AMOUNT_TO_SPEND, this function makes two batch purchases
        uint256 postSharesBalance = stablecoinHandler.getUserShares(USER);

        if (block.chainid != ANVIL_CHAIN_ID) updateExchangeRate(1 days);
        uint256 exchangeRate =
            s_routeIndex == TROPYKUS_INDEX ? shareToken.exchangeRateCurrent() : shareToken.tokenPrice();

        assertApproxEqRel( // There will be a slight arithmetic imprecision, so assertEq makes the test fail
            prevSharesBalance - postSharesBalance,
            (AMOUNT_TO_SPEND * 1e18 / startingExchangeRate) + (AMOUNT_TO_SPEND * 1e18 / exchangeRate), // First batch purchase in makeBatchPurchasesOneUser is done with the starting exchange rate, the second after some time has passed
            0.1e16 // Allow a maximum difference of 0.1%
        );

        if (keccak256(abi.encodePacked(swapType)) == keccak256(abi.encodePacked("mocSwaps"))) {
            assertApproxEqRel(
                shareToken.balanceOf(address(stablecoinHandler)),
                AMOUNT_TO_DEPOSIT * 1e18 / startingExchangeRate - (AMOUNT_TO_SPEND * 1e18 / startingExchangeRate)
                    - (AMOUNT_TO_SPEND * 1e18 / exchangeRate),
                0.1e16 // Allow a maximum difference of 0.1%
            );
        } else if (keccak256(abi.encodePacked(swapType)) == keccak256(abi.encodePacked("dexSwaps"))) {
            assertApproxEqRel( // The mock contract that simulates swapping on Uniswap allows for some slippage
                shareToken.balanceOf(address(stablecoinHandler)),
                AMOUNT_TO_DEPOSIT * 1e18 / startingExchangeRate - (AMOUNT_TO_SPEND * 1e18 / startingExchangeRate)
                    - (AMOUNT_TO_SPEND * 1e18 / exchangeRate),
                _maxPurchaseSlippage() // Allow a maximum difference of 0.5%
            );
        }
    }

    function testWithdrawInterest() external onlyLendingLane {
        updateExchangeRate(10 days);

        uint256 withdrawableInterest =
            dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        uint256 userStablecoinBalanceBeforeInterestWithdrawal = stablecoin.balanceOf(USER);
        // assertGt(withdrawableInterest, 0);
        vm.prank(USER);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        vm.expectEmit(true, true, false, false);
        emit TokenLending__InterestWithdrawn(USER, address(stablecoin), withdrawableInterest);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);
        uint256 userStablecoinBalanceAfterInterestWithdrawal = stablecoin.balanceOf(USER);
        console2.log("userStablecoinBalanceAfterInterestWithdrawal:", userStablecoinBalanceAfterInterestWithdrawal);
        // assertEq(userStablecoinBalanceAfterInterestWithdrawal - userStablecoinBalanceBeforeInterestWithdrawal, withdrawableInterest);
        assertApproxEqRel(
            userStablecoinBalanceAfterInterestWithdrawal - userStablecoinBalanceBeforeInterestWithdrawal,
            withdrawableInterest,
            1 // Allow a maximum difference of 1e-18%
        );
        withdrawableInterest = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        if (withdrawableInterest == 1) withdrawableInterest--; // Handle Sovryn's precision loss
        assertEq(withdrawableInterest, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    WITHDRAW-ALL INTEREST ROUTE PAIRS
    //////////////////////////////////////////////////////////////*/

    /// @notice The two arrays are positional pairs, so their lengths must match.
    function testWithdrawAllInterestRevertsOnLengthMismatch() external {
        address[] memory tokens = new address[](2);
        tokens[0] = address(stablecoin);
        tokens[1] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;

        vm.prank(USER);
        vm.expectRevert(IDcaManager.DcaManager__ArraysLengthMismatch.selector);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);
    }

    /// @notice An empty call reverts instead of succeeding silently, matching `batchBuyRbtc`.
    function testWithdrawAllInterestRevertsOnEmptyArrays() external {
        address[] memory tokens = new address[](0);
        uint256[] memory routeIndexes = new uint256[](0);

        vm.prank(USER);
        vm.expectRevert(IDcaManager.DcaManager__EmptyWithdrawalArrays.selector);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);
    }

    /// @notice A pair whose route has no handler is skipped, and the pairs after it still execute.
    function testWithdrawAllInterestSkipsUnregisteredPairAndKeepsGoing() external onlyLendingLane {
        updateExchangeRate(10 days);

        uint256 withdrawableInterest = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        uint256 userBalanceBeforeWithdrawal = stablecoin.balanceOf(USER);

        address[] memory tokens = new address[](2);
        tokens[0] = address(stablecoin);
        tokens[1] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](2);
        routeIndexes[0] = UNREGISTERED_ROUTE_INDEX;
        routeIndexes[1] = s_routeIndex;

        vm.prank(USER);
        vm.expectEmit(true, true, false, false);
        emit TokenLending__InterestWithdrawn(USER, address(stablecoin), withdrawableInterest);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);

        assertApproxEqRel(
            stablecoin.balanceOf(USER) - userBalanceBeforeWithdrawal,
            withdrawableInterest,
            1 // Allow a maximum difference of 1e-18%
        );
    }

    /// @notice Naming the same pair twice pays once: the second pass finds nothing left to withdraw.
    function testWithdrawAllInterestWithDuplicatePairPaysOnce() external onlyLendingLane {
        updateExchangeRate(10 days);

        uint256 withdrawableInterest = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        uint256 userBalanceBeforeWithdrawal = stablecoin.balanceOf(USER);

        address[] memory tokens = new address[](2);
        tokens[0] = address(stablecoin);
        tokens[1] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](2);
        routeIndexes[0] = s_routeIndex;
        routeIndexes[1] = s_routeIndex;

        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, routeIndexes);

        assertApproxEqRel(
            stablecoin.balanceOf(USER) - userBalanceBeforeWithdrawal,
            withdrawableInterest,
            1 // Allow a maximum difference of 1e-18%
        );
        uint256 remainingInterest = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        if (remainingInterest == 1) remainingInterest--; // Handle Sovryn's precision loss
        assertEq(remainingInterest, 0);
    }

    /// @notice Combined withdraw derives the lending route from the validated schedule.
    /// The caller cannot target a different index (the previous fifth argument is gone).
    function testWithdrawTokenAndInterest() external onlyLendingLane {
        vm.warp(block.timestamp + 10 days);

        // On fork tests we need to simulate some operation on Tropykus so that the exchange rate gets updated
        updateExchangeRate(10 days);

        uint256 withdrawableInterest =
            dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        uint256 userStablecoinBalanceBeforeInterestWithdrawal = stablecoin.balanceOf(USER);
        assertGt(withdrawableInterest, 0);

        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        vm.prank(USER);
        dcaManager.withdrawTokenAndInterest(scheduleId, AMOUNT_TO_SPEND);

        uint256 userStablecoinBalanceAfterInterestWithdrawal = stablecoin.balanceOf(USER);
        assertApproxEqRel(
            userStablecoinBalanceAfterInterestWithdrawal - userStablecoinBalanceBeforeInterestWithdrawal,
            withdrawableInterest + AMOUNT_TO_SPEND,
            1 // Allow a maximum difference of 1e-18%
        );

        withdrawableInterest = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        if (withdrawableInterest == 1) withdrawableInterest = 0; // Handle edge case of 1 wei remaining
        assertEq(withdrawableInterest, 0);
    }

    /// @notice Locked principal is the sum of every schedule on that route, not one of them.
    function testInterestLockedPrincipalSumsAllSchedulesOnRoute() external onlyLendingLane {
        super.createSeveralDcaSchedules();
        updateExchangeRate(10 days);

        uint256 interest = dcaManager.getInterestAccrued(USER, address(stablecoin), s_routeIndex);
        assertGt(interest, 0);
        // One missed schedule would treat that principal as yield (~AMOUNT_TO_DEPOSIT / NUM_OF_SCHEDULES).
        assertLt(interest, AMOUNT_TO_DEPOSIT / NUM_OF_SCHEDULES);
    }

    // @notice: This is difficult to test, because the withdrawal amount is adjusted to the balance
    // in the lending protocol, which only happenes in edge cases on mainnet or a live testnet
    // function testWithdrawalAmountAdjustedToBalance() external {
    //     // Add debug logging
    //     console2.log("Initial user shares balance:", stablecoinHandler.getUserShares(USER));

    //     uint256 exchangeRate =
    //         s_routeIndex == TROPYKUS_INDEX ? shareToken.exchangeRateCurrent() : shareToken.tokenPrice();
    //     console2.log("Exchange rate:", exchangeRate);

    //     uint256 stablecoinInLendingProtocol = stablecoinHandler.getUserShares(USER) * exchangeRate / 1e18;
    //     console2.log("Stablecoin in lending protocol:", stablecoinInLendingProtocol);

    //     uint256 attemptedWithdrawalAmount = stablecoinInLendingProtocol + 1;
    //     console2.log("Attempted withdrawal amount:", attemptedWithdrawalAmount);

    //     vm.expectEmit(true, true, true, true);
    //     emit TokenLending__WithdrawalAmountAdjusted(USER, attemptedWithdrawalAmount, stablecoinInLendingProtocol);

    //     vm.prank(USER);
    //     dcaManager.withdrawToken(address(stablecoin), 0, attemptedWithdrawalAmount);

    //     // Verify user received their full balance
    //     assertEq(stablecoin.balanceOf(USER), stablecoinInLendingProtocol);
    //     // Verify shares balance is now 0
    //     assertEq(stablecoinHandler.getUserShares(USER), 0);
    // }
} 