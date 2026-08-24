// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {HandlerTestHarness} from "../HandlerTestHarness.t.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {LayerBankErc20Handler} from "src/layerbank/LayerBankErc20Handler.sol";
import {MockLToken, MockLayerBankCore} from "test/mocks/MockLayerBank.sol";
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

    MockLToken public lToken;
    MockLayerBankCore public core;
    LayerBankTestHandler public layerbankHandler;

    function deployHandler() internal override returns (ITokenHandler) {
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        layerbankHandler = new LayerBankTestHandler(
            address(dcaManager), address(stablecoin), address(lToken), FEE_COLLECTOR, feeSettings
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

    function getLendingToken() internal view override returns (IERC20) {
        return IERC20(address(lToken));
    }

    function setupHandlerSpecifics() internal override {
        lToken = new MockLToken(address(stablecoin));
        core = new MockLayerBankCore(lToken);
        lToken.setCore(address(core));
        stablecoin.mint(address(lToken), 1000000 ether);
    }

    function test_layerbank_constructor_revertsIfCoreUnset() public {
        MockLToken unset = new MockLToken(address(stablecoin));
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        vm.expectRevert(LayerBankErc20Handler.LayerBankErc20Handler__CoreNotSet.selector);
        new LayerBankTestHandler(address(dcaManager), address(stablecoin), address(unset), FEE_COLLECTOR, feeSettings);
    }

    function test_layerbank_constructor_revertsIfUnderlyingMismatch() public {
        MockStablecoin other = new MockStablecoin(address(this));
        MockLToken mismatch = new MockLToken(address(other));
        MockLayerBankCore mismatchCore = new MockLayerBankCore(mismatch);
        mismatch.setCore(address(mismatchCore));

        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        vm.expectRevert(LayerBankErc20Handler.LayerBankErc20Handler__UnderlyingMismatch.selector);
        new LayerBankTestHandler(
            address(dcaManager), address(stablecoin), address(mismatch), FEE_COLLECTOR, feeSettings
        );
    }

    function test_layerbank_lTokenMinting() public {
        uint256 initialLTokenBalance = lToken.balanceOf(address(handler));

        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        uint256 finalLTokenBalance = lToken.balanceOf(address(handler));
        assertGt(finalLTokenBalance, initialLTokenBalance);
        assertEq(layerbankHandler.getUsersLendingTokenBalance(USER), finalLTokenBalance - initialLTokenBalance);
        assertEq(stablecoin.balanceOf(address(handler)), 0);
    }

    function test_layerbank_supplyReturnIsIgnored() public {
        core.setSupplyReturnOverride(0, true);

        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        uint256 credited = layerbankHandler.getUsersLendingTokenBalance(USER);
        assertGt(credited, 0);
        assertEq(credited, lToken.balanceOf(address(handler)));
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
        assertEq(layerbankHandler.getUsersLendingTokenBalance(USER), 0);
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
        lToken.setForceZeroMint(true);

        vm.prank(address(dcaManager));
        vm.expectRevert(ITokenLending.TokenLending__LendingProtocolDepositFailed.selector);
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        assertEq(layerbankHandler.getUsersLendingTokenBalance(USER), 0);
        assertEq(lToken.balanceOf(address(handler)), 0);
    }

    function test_layerbank_zeroPayoutRedeemReverts() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        uint256 lTokenBalanceBefore = layerbankHandler.getUsersLendingTokenBalance(USER);
        uint256 userBalanceBefore = stablecoin.balanceOf(USER);

        lToken.setSilentZeroPayout(true);

        vm.prank(address(dcaManager));
        vm.expectRevert(
            abi.encodeWithSelector(ITokenLending.TokenLending__ZeroStablecoinReceived.selector, WITHDRAWAL_AMOUNT)
        );
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);

        assertEq(stablecoin.balanceOf(USER), userBalanceBefore);
        assertEq(layerbankHandler.getUsersLendingTokenBalance(USER), lTokenBalanceBefore);
    }

    /**
     * @notice Live LayerBank cannot produce a partial payout: Market._redeem requires
     *         `getCash() >= uAmountIn` and reverts rather than under-paying. `setPayoutCap`
     *         is deliberately more permissive so AGENTS.md invariant 1 (balance-delta cash)
     *         has coverage. Do not "fix" the mock to match live behavior.
     */
    function test_layerbank_withdrawPaysMeasuredShortfall() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);

        uint256 shortfall = WITHDRAWAL_AMOUNT / 2;
        lToken.setPayoutCap(shortfall, true);

        uint256 userBalanceBefore = stablecoin.balanceOf(USER);
        uint256 sharesBefore = layerbankHandler.getUsersLendingTokenBalance(USER);

        vm.prank(address(dcaManager));
        handler.withdrawToken(USER, WITHDRAWAL_AMOUNT);

        assertEq(stablecoin.balanceOf(USER) - userBalanceBefore, shortfall);
        assertLt(layerbankHandler.getUsersLendingTokenBalance(USER), sharesBefore);
    }

    function test_layerbank_zeroPayoutInterestWithdrawalReverts() public {
        vm.prank(address(dcaManager));
        handler.depositToken(USER, DEPOSIT_AMOUNT);
        vm.warp(block.timestamp + 365 days);

        uint256 lTokenBalanceBefore = layerbankHandler.getUsersLendingTokenBalance(USER);
        uint256 userBalanceBefore = stablecoin.balanceOf(USER);

        lToken.setSilentZeroPayout(true);

        vm.prank(address(dcaManager));
        vm.expectRevert();
        layerbankHandler.withdrawInterest(USER, DEPOSIT_AMOUNT / 2);

        assertEq(stablecoin.balanceOf(USER), userBalanceBefore);
        assertEq(layerbankHandler.getUsersLendingTokenBalance(USER), lTokenBalanceBefore);
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
        uint256 available = layerbankHandler.getUsersLendingTokenBalance(user1);
        uint256 exchangeRate = lToken.exchangeRate();
        uint256 totalLtokenToRepay =
            Math.mulDiv(excessiveAmount, EXCHANGE_RATE_DECIMALS, exchangeRate, Math.Rounding.Up);
        uint256 requested = Math.mulDiv(totalLtokenToRepay, amounts[0], excessiveAmount, Math.Rounding.Up);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenLending.TokenLending__InsufficientLendingTokenBalance.selector, user1, requested, available
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

        uint256 lTokenBalanceBefore = layerbankHandler.getUsersLendingTokenBalance(user1);

        lToken.setSilentZeroPayout(true);

        vm.expectRevert(
            abi.encodeWithSelector(ITokenLending.TokenLending__ZeroStablecoinReceived.selector, amounts[0])
        );
        layerbankHandler.testBatchRetrieveStablecoin(users, amounts, amounts[0]);

        assertEq(layerbankHandler.getUsersLendingTokenBalance(user1), lTokenBalanceBefore);
    }
}

contract LayerBankTestHandler is LayerBankErc20Handler {
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address lTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings
    )
        LayerBankErc20Handler(
            dcaManagerAddress, stableTokenAddress, lTokenAddress, feeCollector, feeSettings, EXCHANGE_RATE_DECIMALS
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
