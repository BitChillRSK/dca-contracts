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
        uint256 originalSharesAmount,
        uint256 adjustedSharesAmount,
        uint256 originalStablecoinAmount,
        uint256 adjustedStablecoinAmount
    );
    event TokenLending__SharesRedeemed(
        address indexed user, uint256 underlyingAmount, uint256 sharesAmountRedeemed
    );
    event TokenLending__UserSharesUpdated(address indexed user, uint256 previousShares, uint256 newShares);

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
        harness = new LendingErc20HandlerHarness(address(this), address(stablecoin), address(0xFEE), feeSettings, address(this));

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
        _assertNoShareMutationEvents();
    }

    function test_deposit_emitsUserSharesUpdatedWithMeasuredMint() public {
        uint256 previousShares = harness.getUserShares(userA);
        uint256 expectedShares = _stablecoinToSharesUp(USER_A_DEPOSIT, RATE_SCALE);

        vm.recordLogs();
        harness.depositToken(userA, USER_A_DEPOSIT);

        assertEq(harness.getUserShares(userA), expectedShares);
        _assertLastUserSharesUpdated(userA, previousShares, expectedShares);
    }

    function test_redeemShares_emitsUserSharesUpdated() public {
        harness.depositToken(userA, USER_A_DEPOSIT);
        uint256 previousShares = harness.getUserShares(userA);
        uint256 redeemAmount = 40 ether;
        uint256 sharesToRedeem = _stablecoinToSharesUp(redeemAmount, RATE_SCALE);

        vm.recordLogs();
        uint256 received = harness.redeemShares(userA, redeemAmount);

        assertEq(received, redeemAmount);
        assertEq(harness.getUserShares(userA), previousShares - sharesToRedeem);
        _assertLastUserSharesUpdated(userA, previousShares, previousShares - sharesToRedeem);
    }

    function test_batchRetrieve_repeatedUserEmitsSequentialTransitions() public {
        harness.depositToken(userA, USER_A_DEPOSIT);
        uint256 start = harness.getUserShares(userA);
        uint256 firstDebit = 10 ether;
        uint256 secondDebit = 20 ether;

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userA;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = firstDebit;
        amounts[1] = secondDebit;

        vm.recordLogs();
        harness.batchRetrieveStablecoin(users, amounts, firstDebit + secondDebit);

        _assertSequentialShareDebits(start, firstDebit, secondDebit);
        assertEq(harness.getUserShares(userA), start - firstDebit - secondDebit);
    }

    function test_replayUserSharesUpdatedReconstructsBalances() public {
        vm.recordLogs();
        harness.depositToken(userA, USER_A_DEPOSIT);
        harness.depositToken(userB, USER_B_DEPOSIT);
        harness.redeemShares(userA, 25 ether);

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10 ether;
        amounts[1] = 15 ether;
        harness.batchRetrieveStablecoin(users, amounts, 25 ether);

        (uint256 replayedA, uint256 replayedB) = _replayUserShares(userA, userB);
        assertEq(replayedA, harness.getUserShares(userA));
        assertEq(replayedB, harness.getUserShares(userB));
        assertGt(replayedA, 0);
        assertGt(replayedB, 0);
    }

    function _stablecoinToSharesUp(uint256 amount, uint256 rate) private pure returns (uint256) {
        return (amount * RATE_SCALE + rate - 1) / rate;
    }

    function _assertNoShareMutationEvents() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sharesRedeemedTopic = TokenLending__SharesRedeemed.selector;
        bytes32 sharesUpdatedTopic = TokenLending__UserSharesUpdated.selector;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != sharesRedeemedTopic, "SharesRedeemed emitted on a zero-share no-op");
            assertTrue(logs[i].topics[0] != sharesUpdatedTopic, "UserSharesUpdated emitted on a zero-share no-op");
        }
    }

    function _replayUserShares(address a, address b) private returns (uint256 sharesA, uint256 sharesB) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = TokenLending__UserSharesUpdated.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            address user = address(uint160(uint256(logs[i].topics[1])));
            (, uint256 newShares) = abi.decode(logs[i].data, (uint256, uint256));
            if (user == a) sharesA = newShares;
            else if (user == b) sharesB = newShares;
        }
    }

    function _assertSequentialShareDebits(uint256 start, uint256 firstDebit, uint256 secondDebit) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = TokenLending__UserSharesUpdated.selector;
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            address user = address(uint160(uint256(logs[i].topics[1])));
            (uint256 prev, uint256 next) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(user, userA);
            if (seen == 0) {
                assertEq(prev, start);
                assertEq(next, start - firstDebit);
            } else {
                assertEq(prev, start - firstDebit);
                assertEq(next, start - firstDebit - secondDebit);
            }
            seen++;
        }
        assertEq(seen, 2, "repeated buyer must emit one UserSharesUpdated per debit");
    }

    function _assertLastUserSharesUpdated(address expectedUser, uint256 previousShares, uint256 newShares) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = TokenLending__UserSharesUpdated.selector;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            address user = address(uint160(uint256(logs[i].topics[1])));
            (uint256 prev, uint256 next) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(user, expectedUser);
            assertEq(prev, previousShares);
            assertEq(next, newShares);
            found = true;
        }
        assertTrue(found, "TokenLending__UserSharesUpdated not emitted");
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

    function test_exchangeRate_defaultsToViewExchangeRate() public {
        uint256 viewRate = 2e18;
        harness.setExchangeRate(viewRate);
        harness.depositToken(userA, USER_A_DEPOSIT);

        uint256 expectedShares = _stablecoinToSharesUp(USER_A_DEPOSIT, viewRate);
        assertEq(harness.getUserShares(userA), expectedShares);
        assertEq(harness.getAccruedInterest(userA, USER_A_DEPOSIT), 0);
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
        FeeSettings memory feeSettings,
        address initialOwner
    ) LendingErc20Handler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, 1e18, initialOwner) {}

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

    function batchRetrieveStablecoin(
        address[] memory users,
        uint256[] memory purchaseAmounts,
        uint256 totalStablecoinAmount
    ) external returns (uint256) {
        return _batchRetrieveStablecoin(users, purchaseAmounts, totalStablecoinAmount);
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
