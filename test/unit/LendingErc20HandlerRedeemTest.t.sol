// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {LendingErc20Handler} from "src/LendingErc20Handler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {ITokenLending} from "src/interfaces/ITokenLending.sol";
import {MockStablecoin} from "../mocks/MockStablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../script/Constants.sol";

/**
 * @title LendingErc20HandlerRedeemTest
 * @notice Base-level regressions for `_redeemShares`: the per-user share clamp (R21) and the
 *         positive-share zero-payout revert (PR 63 review; R15 dust stays deferred).
 */
contract LendingErc20HandlerRedeemTest is Test {
    event TokenLending__AmountToRedeemAdjusted(
        address indexed user,
        uint256 indexed originalSharesAmount,
        uint256 indexed adjustedSharesAmount,
        uint256 originalStablecoinAmount,
        uint256 adjustedStablecoinAmount
    );
    event TokenLending__SharesRedeemed(
        address indexed user, uint256 indexed underlyingAmount, uint256 indexed sharesAmountRedeemed
    );

    uint256 internal constant RATE_SCALE = 1e18;
    uint256 internal constant USER_A_DEPOSIT = 100 ether;
    uint256 internal constant USER_B_DEPOSIT = 50 ether;
    uint256 internal constant OVERSTATED_REQUEST = 1000 ether;

    LendingErc20HandlerHarness internal harness;
    MockStablecoin internal stablecoin;
    address internal userA = address(0xA11CE);
    address internal userB = address(0xB0B);

    function setUp() public {
        stablecoin = new MockStablecoin(address(this));
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });
        // dcaManager = this, so tests can call onlyDcaManager entry points directly
        harness = new LendingErc20HandlerHarness(address(this), address(stablecoin), address(0xFEE), feeSettings);

        stablecoin.mint(userA, USER_A_DEPOSIT);
        stablecoin.mint(userB, USER_B_DEPOSIT);
        vm.prank(userA);
        stablecoin.approve(address(harness), type(uint256).max);
        vm.prank(userB);
        stablecoin.approve(address(harness), type(uint256).max);
    }

    function test_redeemShares_clampsToTheUsersOwnBook() public {
        harness.depositToken(userA, USER_A_DEPOSIT);
        harness.depositToken(userB, USER_B_DEPOSIT);

        uint256 userAShares = harness.getUserShares(userA);
        uint256 userBShares = harness.getUserShares(userB);
        uint256 requestedShares = _stablecoinToSharesUp(OVERSTATED_REQUEST, RATE_SCALE);
        uint256 adjustedStablecoin = userAShares * RATE_SCALE / RATE_SCALE;

        assertGt(requestedShares, userAShares);

        vm.expectEmit(true, true, true, true, address(harness));
        emit TokenLending__AmountToRedeemAdjusted(
            userA, requestedShares, userAShares, OVERSTATED_REQUEST, adjustedStablecoin
        );

        uint256 received = harness.redeemShares(userA, OVERSTATED_REQUEST);

        assertEq(received, adjustedStablecoin);
        assertGt(received, 0);
        assertEq(harness.getUserShares(userA), 0);
        assertEq(harness.getUserShares(userB), userBShares);
    }

    function test_redeemShares_zeroSharesIsANoOp() public {
        harness.depositToken(userA, USER_A_DEPOSIT);
        uint256 sharesBefore = harness.getUserShares(userA);
        uint256 protocolSharesBefore = harness.protocolShares();

        vm.recordLogs();
        uint256 received = harness.redeemShares(userA, 0);

        assertEq(received, 0);
        assertEq(harness.protocolRedeemCalls(), 0);
        assertEq(harness.getUserShares(userA), sharesBefore);
        assertEq(harness.protocolShares(), protocolSharesBefore);
        _assertNoSharesRedeemedEvent();
    }

    function test_redeemShares_dustSharesThatPayZeroRevertAndRollBack() public {
        // 1 share at rate 1 / 1e18 floors to 0 wei of stablecoin
        harness.setExchangeRate(1);
        harness.creditShares(userA, 1);
        harness.setPayOut(false);

        uint256 bookBefore = harness.getUserShares(userA);
        uint256 protocolBefore = harness.protocolShares();
        assertEq(bookBefore, 1);
        assertEq(bookBefore * 1 / RATE_SCALE, 0);

        vm.expectRevert(abi.encodeWithSelector(ITokenLending.TokenLending__ZeroStablecoinReceived.selector, 0));
        harness.redeemShares(userA, 1);

        assertEq(harness.getUserShares(userA), bookBefore);
        assertEq(harness.protocolShares(), protocolBefore);
    }

    function _stablecoinToSharesUp(uint256 amount, uint256 rate) private pure returns (uint256) {
        return (amount * RATE_SCALE + rate - 1) / rate;
    }

    function _assertNoSharesRedeemedEvent() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sharesRedeemedTopic = TokenLending__SharesRedeemed.selector;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != sharesRedeemedTopic, "SharesRedeemed emitted on a zero-share no-op");
        }
    }
}

/**
 * @notice Minimal LendingErc20Handler: 1:1 mint at the current rate, optional silent-zero redeem.
 * @dev `dcaManager` is the test contract. Protocol shares live on this mock so a reverted redeem
 *      can be shown to leave both the book and the protocol-side count unchanged.
 */
contract LendingErc20HandlerHarness is LendingErc20Handler {
    using SafeERC20 for IERC20;

    uint256 public exchangeRate = 1e18;
    bool public payOut = true;
    uint256 public protocolRedeemCalls;
    uint256 public protocolShares;

    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings
    ) LendingErc20Handler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, 1e18) {}

    function setExchangeRate(uint256 rate) external {
        exchangeRate = rate;
    }

    function setPayOut(bool shouldPay) external {
        payOut = shouldPay;
    }

    function creditShares(address user, uint256 shares) external {
        s_shares[user] += shares;
        protocolShares += shares;
    }

    function redeemShares(address user, uint256 stablecoinAmount) external returns (uint256) {
        return _redeemShares(user, stablecoinAmount, _exchangeRate());
    }

    function _exchangeRate() internal view override returns (uint256) {
        return exchangeRate;
    }

    function _viewExchangeRate() internal view override returns (uint256) {
        return exchangeRate;
    }

    function _lendingSpender() internal view override returns (address) {
        return address(this);
    }

    function _protocolDeposit(uint256 stablecoinAmount) internal override returns (uint256 mintedShares) {
        mintedShares = _stablecoinToShares(stablecoinAmount, exchangeRate);
        protocolShares += mintedShares;
        i_stableToken.safeTransfer(address(1), stablecoinAmount);
    }

    function _protocolRedeem(uint256 sharesAmount, uint256 rate) internal override {
        protocolRedeemCalls++;
        protocolShares -= sharesAmount;
        if (!payOut) return;
        uint256 amount = _sharesToStablecoin(sharesAmount, rate);
        if (amount > 0) {
            MockStablecoin(address(i_stableToken)).mint(address(this), amount);
        }
    }
}
