// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {HandlerTestHarness} from "../HandlerTestHarness.t.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {LayerBankErc20Handler} from "src/layerbank/LayerBankErc20Handler.sol";
import {ILayerBankErc20Handler} from "src/layerbank/ILayerBankErc20Handler.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "test/mocks/MockLayerBank.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenLending} from "src/interfaces/ITokenLending.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "script/Constants.sol";

/**
 * @title LayerBankErc20HandlerTest
 * @notice Unit tests for LayerBankErc20Handler using the shared handler harness.
 */
contract LayerBankErc20HandlerTest is HandlerTestHarness {
    uint256 internal constant LAYERBANK_INDEX = 1;

    MockLayerBankAToken public aToken;
    MockLayerBankPool public pool;
    LayerBankTestHandler public layerbankHandler;

    function deployHandler() internal override returns (ITokenHandler) {
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        layerbankHandler = new LayerBankTestHandler(
            address(dcaManager), address(stablecoin), address(aToken), FEE_COLLECTOR, feeSettings
        );

        return ITokenHandler(address(layerbankHandler));
    }

    function getLendingProtocolIndex() internal pure override returns (uint256) {
        return LAYERBANK_INDEX;
    }

    function isDexHandler() internal pure override returns (bool) {
        return false;
    }

    function isLendingHandler() internal pure override returns (bool) {
        return true;
    }

    function getShareToken() internal view override returns (IERC20) {
        return IERC20(address(aToken));
    }

    /// @dev LayerBank's share is the scaled balance; `balanceOf` rebases and is not comparable.
    function handlerShareBalance() internal view override returns (uint256) {
        return aToken.scaledBalanceOf(address(handler));
    }

    function setupHandlerSpecifics() internal override {
        aToken = new MockLayerBankAToken(address(stablecoin));
        pool = new MockLayerBankPool(aToken);
        aToken.setPool(address(pool));
        stablecoin.mint(address(aToken), 1000000 ether);
    }

    function test_layerbank_constructor_revertsIfPoolUnset() public {
        MockLayerBankAToken unset = new MockLayerBankAToken(address(stablecoin));
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        vm.expectRevert(ILayerBankErc20Handler.LayerBankErc20Handler__PoolNotSet.selector);
        new LayerBankTestHandler(address(dcaManager), address(stablecoin), address(unset), FEE_COLLECTOR, feeSettings);
    }

    function test_layerbank_constructor_revertsIfUnderlyingMismatch() public {
        MockStablecoin other = new MockStablecoin(address(this));
        MockLayerBankAToken mismatch = new MockLayerBankAToken(address(other));
        MockLayerBankPool mismatchPool = new MockLayerBankPool(mismatch);
        mismatch.setPool(address(mismatchPool));

        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        vm.expectRevert(ILayerBankErc20Handler.LayerBankErc20Handler__UnderlyingMismatch.selector);
        new LayerBankTestHandler(
            address(dcaManager), address(stablecoin), address(mismatch), FEE_COLLECTOR, feeSettings
        );
    }

    function test_layerbank_aTokenMinting() public {
        uint256 initialScaled = aToken.scaledBalanceOf(address(handler));

        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        uint256 finalScaled = aToken.scaledBalanceOf(address(handler));
        assertGt(finalScaled, initialScaled);
        assertEq(layerbankHandler.getUserShares(USER), finalScaled - initialScaled);
        assertEq(stablecoin.balanceOf(address(handler)), 0);
    }

    function test_layerbank_creditsScaledDeltaNotComputedAmount() public {
        uint256 overrideScaled = 42 ether;
        aToken.setMintOverride(overrideScaled, true);

        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        uint256 credited = layerbankHandler.getUserShares(USER);
        assertEq(credited, overrideScaled);
        assertEq(credited, aToken.scaledBalanceOf(address(handler)));
    }

    function test_layerbank_storesScaledSharesNotRebasingBalance() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        uint256 scaledAtDeposit = aToken.scaledBalanceOf(address(handler));
        assertEq(layerbankHandler.getUserShares(USER), scaledAtDeposit);
        assertEq(aToken.balanceOf(address(handler)), scaledAtDeposit); // index == RAY at t0

        vm.warp(block.timestamp + 365 days);

        assertEq(aToken.scaledBalanceOf(address(handler)), scaledAtDeposit);
        assertEq(layerbankHandler.getUserShares(USER), scaledAtDeposit);
        assertGt(aToken.balanceOf(address(handler)), scaledAtDeposit);
    }

    /**
     * @notice LayerBank is the one adapter that cannot be share-exact: Aave has no share-sized
     *         withdraw, so the count the base booked out is converted to underlying and Aave burns
     *         `amount.rayDiv(index)` back out of it.
     * @dev What keeps that burn at or below the book debit is that the withdraw amount is *derived*
     *      from the debited count and floors on the way out, so the round trip can only shrink. This
     *      pins that direction: it fails if LayerBank goes back to passing the caller's requested
     *      underlying straight through, where Aave sizes the burn off its own index instead.
     */
    function test_layerbank_bookDebitNeverBelowScaledBurn() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + 365 days);

        uint256 bookBefore = layerbankHandler.getUserShares(USER);
        uint256 scaledBefore = aToken.scaledBalanceOf(address(handler));

        vm.prank(address(dcaManager));
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);

        uint256 bookDebit = bookBefore - layerbankHandler.getUserShares(USER);
        assertGt(bookDebit, 0);
        assertGe(bookDebit, scaledBefore - aToken.scaledBalanceOf(address(handler)));
        assertLe(layerbankHandler.getUserShares(USER), aToken.scaledBalanceOf(address(handler)));
    }

    function test_layerbank_exchangeRateEffect() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        vm.warp(block.timestamp + 365 days);

        vm.prank(address(dcaManager));
        uint256 accruedInterest = layerbankHandler.getAccruedInterest(USER, DEPOSIT_AMOUNT);
        assertGt(accruedInterest, 0);
    }

    function test_layerbank_redemption_adjustsForAvailableBalance() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        uint256 userBalanceBeforeWithdraw = stablecoin.balanceOf(USER);

        vm.prank(address(dcaManager));
        handler.withdrawToken(USER, DEPOSIT_AMOUNT * 2);

        uint256 actualWithdrawn = stablecoin.balanceOf(USER) - userBalanceBeforeWithdraw;
        assertLe(actualWithdrawn, DEPOSIT_AMOUNT);
        assertEq(layerbankHandler.getUserShares(USER), 0);
    }

    function test_layerbank_interestWithdrawal() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        vm.warp(block.timestamp + 365 days);

        uint256 userBalanceBeforeInterestWithdraw = stablecoin.balanceOf(USER);

        vm.prank(address(dcaManager));
        layerbankHandler.withdrawInterest(USER, DEPOSIT_AMOUNT);

        assertGt(stablecoin.balanceOf(USER), userBalanceBeforeInterestWithdraw);
    }

    function test_layerbank_interestWithdrawal_noInterestScenario() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        uint256 userBalanceBefore = stablecoin.balanceOf(USER);

        vm.prank(address(dcaManager));
        layerbankHandler.withdrawInterest(USER, DEPOSIT_AMOUNT);

        assertEq(stablecoin.balanceOf(USER), userBalanceBefore);
    }

    function test_layerbank_mintFailureHandling() public {
        // Hop-1 insufficient balance (same as the Tropykus/Sovryn twin). The zero-mint guard is
        // `test_layerbank_zeroMintReverts`.
        uint256 currentBalance = stablecoin.balanceOf(USER);
        if (currentBalance > 0) {
            vm.prank(USER);
            stablecoin.transfer(address(0x999), currentBalance);
        }

        stablecoin.mint(USER, DEPOSIT_AMOUNT / 2);

        vm.prank(address(dcaManager));
        vm.expectRevert();
        handler.depositToken(USER, DEPOSIT_AMOUNT);
    }

    function test_layerbank_zeroMintReverts() public {
        aToken.setForceZeroMint(true);

        vm.prank(address(dcaManager));
        vm.expectRevert(ITokenLending.TokenLending__LendingProtocolDepositFailed.selector);
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        assertEq(layerbankHandler.getUserShares(USER), 0);
        assertEq(aToken.scaledBalanceOf(address(handler)), 0);
    }

    function test_layerbank_zeroPayoutRedeemReverts() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        uint256 aTokenBalanceBefore = layerbankHandler.getUserShares(USER);
        uint256 userBalanceBefore = stablecoin.balanceOf(USER);

        aToken.setSilentZeroPayout(true);
        pool.setWithdrawReturnOverride(WITHDRAWAL_AMOUNT, true);

        vm.prank(address(dcaManager));
        vm.expectRevert(
            abi.encodeWithSelector(ITokenLending.TokenLending__ZeroStablecoinReceived.selector, WITHDRAWAL_AMOUNT)
        );
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);

        assertEq(stablecoin.balanceOf(USER), userBalanceBefore);
        assertEq(layerbankHandler.getUserShares(USER), aTokenBalanceBefore);
    }

    /**
     * @notice Live Aave `withdraw` transfers underlying from the aToken and reverts on
     *         insufficient cash rather than under-paying. `setPayoutCap` is deliberately
     *         more permissive so AGENTS.md invariant 1 (balance-delta cash) has coverage.
     *         Do not "fix" the mock to match live behavior.
     */
    function test_layerbank_withdrawPaysMeasuredShortfall() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        uint256 shortfall = WITHDRAWAL_AMOUNT / 2;
        aToken.setPayoutCap(shortfall, true);
        pool.setWithdrawReturnOverride(WITHDRAWAL_AMOUNT, true);

        uint256 userBalanceBefore = stablecoin.balanceOf(USER);
        uint256 sharesBefore = layerbankHandler.getUserShares(USER);

        vm.prank(address(dcaManager));
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);

        assertEq(stablecoin.balanceOf(USER) - userBalanceBefore, shortfall);
        assertLt(layerbankHandler.getUserShares(USER), sharesBefore);
    }

    function test_layerbank_zeroPayoutInterestWithdrawalReverts() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + 365 days);

        uint256 aTokenBalanceBefore = layerbankHandler.getUserShares(USER);
        uint256 userBalanceBefore = stablecoin.balanceOf(USER);

        aToken.setSilentZeroPayout(true);

        vm.prank(address(dcaManager));
        vm.expectRevert();
        layerbankHandler.withdrawInterest(USER, DEPOSIT_AMOUNT / 2);

        assertEq(stablecoin.balanceOf(USER), userBalanceBefore);
        assertEq(layerbankHandler.getUserShares(USER), aTokenBalanceBefore);
    }

    function test_layerbank_batchRetrieveStablecoin_exceedsBalance_reverts() public {
        address user1 = makeAddr("user1");
        address[] memory users = new address[](1);
        users[0] = user1;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = DEPOSIT_AMOUNT;

        stablecoin.mint(user1, DEPOSIT_AMOUNT);
        vm.prank(user1);
        stablecoin.approve(address(layerbankHandler), type(uint256).max);

        vm.prank(address(dcaManager));
        handler.depositToken(user1, DEPOSIT_AMOUNT / 10);

        uint256 excessiveAmount = DEPOSIT_AMOUNT * 2;
        uint256 available = layerbankHandler.getUserShares(user1);
        uint256 exchangeRate = aToken.getNormalizedIncome();
        uint256 totalAtokenToRedeem =
            Math.mulDiv(excessiveAmount, aToken.RAY(), exchangeRate, Math.Rounding.Up);
        uint256 requested = Math.mulDiv(totalAtokenToRedeem, amounts[0], excessiveAmount, Math.Rounding.Up);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenLending.TokenLending__InsufficientShares.selector, user1, requested, available
            )
        );
        layerbankHandler.testBatchRetrieveStablecoin(users, amounts, excessiveAmount);
    }

    function test_layerbank_batchRetrieveStablecoin_zeroPayout_reverts() public {
        address user1 = makeAddr("user1");
        address[] memory users = new address[](1);
        users[0] = user1;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = DEPOSIT_AMOUNT / 2;

        stablecoin.mint(user1, DEPOSIT_AMOUNT);
        vm.prank(user1);
        stablecoin.approve(address(layerbankHandler), type(uint256).max);

        vm.prank(address(dcaManager));
        handler.depositToken(user1, DEPOSIT_AMOUNT);

        uint256 aTokenBalanceBefore = layerbankHandler.getUserShares(user1);

        aToken.setSilentZeroPayout(true);

        vm.expectRevert(
            abi.encodeWithSelector(ITokenLending.TokenLending__ZeroStablecoinReceived.selector, amounts[0])
        );
        layerbankHandler.testBatchRetrieveStablecoin(users, amounts, amounts[0]);

        assertEq(layerbankHandler.getUserShares(user1), aTokenBalanceBefore);
    }
}

contract LayerBankTestHandler is LayerBankErc20Handler {
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address aTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings
    )
        LayerBankErc20Handler(
            dcaManagerAddress,
            stableTokenAddress,
            aTokenAddress,
            feeCollector,
            feeSettings
        )
    {}

    function buyRbtc(address, bytes32, uint256) external pure returns (uint256) {
        return 0;
    }

    function testBatchRetrieveStablecoin(
        address[] memory users,
        uint256[] memory purchaseAmounts,
        uint256 totalStablecoinAmount
    ) external returns (uint256) {
        return _batchRetrieveStablecoin(users, purchaseAmounts, totalStablecoinAmount);
    }
}
