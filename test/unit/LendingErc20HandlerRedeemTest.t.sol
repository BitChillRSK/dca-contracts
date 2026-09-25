// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {LendingErc20Handler} from "src/LendingErc20Handler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {ITokenLending} from "src/interfaces/ITokenLending.sol";
import {MockStablecoin} from "../mocks/MockStablecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../Constants.sol";

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
        uint256 firstShares = _stablecoinToSharesUp(firstDebit, RATE_SCALE);
        uint256 secondShares = _stablecoinToSharesUp(secondDebit, RATE_SCALE);

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userA;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = firstDebit;
        amounts[1] = secondDebit;

        vm.recordLogs();
        harness.batchRetrieveStablecoin(users, amounts);

        _assertSequentialShareDebits(start, firstShares, secondShares);
        assertEq(harness.getUserShares(userA), start - firstShares - secondShares);
    }

    function test_batchRetrieve_doesNotEmitSharesRedeemed() public {
        harness.depositToken(userA, USER_A_DEPOSIT);
        harness.depositToken(userB, USER_B_DEPOSIT);

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10 ether;
        amounts[1] = 20 ether;

        vm.recordLogs();
        uint256 received = harness.batchRetrieveStablecoin(users, amounts);
        assertGt(received, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sharesRedeemedTopic = TokenLending__SharesRedeemed.selector;
        bytes32 batchTopic = ITokenLending.TokenLending__SharesRedeemedBatch.selector;
        bool sawBatch;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != sharesRedeemedTopic, "SharesRedeemed must not fire on batch");
            if (logs[i].topics[0] == batchTopic) {
                sawBatch = true;
                (uint256 underlyingAmount, uint256 sharesAmountRedeemed) =
                    abi.decode(logs[i].data, (uint256, uint256));
                assertEq(underlyingAmount, received);
                assertEq(
                    sharesAmountRedeemed,
                    _stablecoinToSharesUp(amounts[0], RATE_SCALE) + _stablecoinToSharesUp(amounts[1], RATE_SCALE)
                );
            }
        }
        assertTrue(sawBatch, "SharesRedeemedBatch required");
    }

    function test_batchRetrieve_debitsEqualProtocolBurn() public {
        // Non-round rate so aggregate-then-pro-rata ceilings would have left orphan shares.
        uint256 rate = 1_000_123_456_789_012_345;
        harness.setExchangeRate(rate);
        _fundAndDeposit(userA, 100 ether);
        _fundAndDeposit(userB, 80 ether);

        uint256 sharesABefore = harness.getUserShares(userA);
        uint256 sharesBBefore = harness.getUserShares(userB);
        uint256 protocolBefore = harness.protocolShares();

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 25 ether + 1;
        amounts[1] = 40 ether + 7;

        uint256 expectedBurn =
            _stablecoinToSharesUp(amounts[0], rate) + _stablecoinToSharesUp(amounts[1], rate);
        uint256 received = harness.batchRetrieveStablecoin(users, amounts);

        assertEq(sharesABefore - harness.getUserShares(userA), _stablecoinToSharesUp(amounts[0], rate));
        assertEq(sharesBBefore - harness.getUserShares(userB), _stablecoinToSharesUp(amounts[1], rate));
        assertEq(protocolBefore - harness.protocolShares(), expectedBurn);
        assertEq(received, expectedBurn * rate / RATE_SCALE);
        assertGt(received, 0);
    }

    function test_batchRetrieve_repeatedBuyerDebitsExactRowSum() public {
        uint256 rate = 1_000_123_456_789_012_345;
        harness.setExchangeRate(rate);
        _fundAndDeposit(userA, 200 ether);

        uint256 start = harness.getUserShares(userA);
        uint256 protocolBefore = harness.protocolShares();
        uint256 rowAmount = 33 ether + 1;
        uint256 rowShares = _stablecoinToSharesUp(rowAmount, rate);

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userA;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = rowAmount;
        amounts[1] = rowAmount;

        harness.batchRetrieveStablecoin(users, amounts);

        assertEq(harness.getUserShares(userA), start - rowShares * 2);
        assertEq(protocolBefore - harness.protocolShares(), rowShares * 2);
    }

    function test_batchRetrieve_insufficientSharesRevertsWholeBatch() public {
        harness.depositToken(userA, 10 ether);
        harness.depositToken(userB, USER_B_DEPOSIT);

        uint256 sharesA = harness.getUserShares(userA);
        uint256 sharesB = harness.getUserShares(userB);
        uint256 protocolBefore = harness.protocolShares();

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 25 ether; // more than userA's 10 ether deposit
        amounts[1] = 10 ether;

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenLending.TokenLending__InsufficientShares.selector,
                userA,
                _stablecoinToSharesUp(amounts[0], RATE_SCALE),
                sharesA
            )
        );
        harness.batchRetrieveStablecoin(users, amounts);

        assertEq(harness.getUserShares(userA), sharesA);
        assertEq(harness.getUserShares(userB), sharesB);
        assertEq(harness.protocolShares(), protocolBefore);
        assertEq(harness.protocolRedeemCalls(), 0);
    }

    function _fundAndDeposit(address user, uint256 amount) private {
        stablecoin.mint(user, amount);
        vm.prank(user);
        stablecoin.approve(address(harness), amount);
        harness.depositToken(user, amount);
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
        harness.batchRetrieveStablecoin(users, amounts);

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

    function test_redeemShares_exactShareConsumptionMatchesExternalDelta() public {
        harness.depositToken(userA, USER_A_DEPOSIT);
        uint256 bookBefore = harness.getUserShares(userA);
        uint256 protocolBefore = harness.protocolShares();
        uint256 redeemAmount = 40 ether;
        uint256 expectedDebit = _stablecoinToSharesUp(redeemAmount, RATE_SCALE);

        uint256 received = harness.redeemShares(userA, redeemAmount);

        assertEq(received, redeemAmount);
        assertEq(bookBefore - harness.getUserShares(userA), expectedDebit);
        assertEq(protocolBefore - harness.protocolShares(), expectedDebit);
    }

    function test_redeemShares_partialShareBurnWithPositiveCashRevertsAndRollsBack() public {
        harness.depositToken(userA, USER_A_DEPOSIT);
        harness.setBurnBps(5_000);

        uint256 bookBefore = harness.getUserShares(userA);
        uint256 protocolBefore = harness.protocolShares();
        uint256 stableBefore = stablecoin.balanceOf(address(harness));
        uint256 redeemAmount = 40 ether;
        uint256 intended = _stablecoinToSharesUp(redeemAmount, RATE_SCALE);
        uint256 afterPartial = protocolBefore - intended / 2;

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenLending.TokenLending__ShareConsumptionMismatch.selector,
                intended,
                protocolBefore,
                afterPartial
            )
        );
        harness.redeemShares(userA, redeemAmount);

        assertEq(harness.getUserShares(userA), bookBefore);
        assertEq(harness.protocolShares(), protocolBefore);
        assertEq(stablecoin.balanceOf(address(harness)), stableBefore);
    }

    function test_batchRetrieve_partialShareBurnRevertsAndRollsBack() public {
        harness.depositToken(userA, USER_A_DEPOSIT);
        harness.depositToken(userB, USER_B_DEPOSIT);
        harness.setBurnBps(5_000);

        uint256 sharesA = harness.getUserShares(userA);
        uint256 sharesB = harness.getUserShares(userB);
        uint256 protocolBefore = harness.protocolShares();

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10 ether;
        amounts[1] = 15 ether;

        uint256 intended =
            _stablecoinToSharesUp(amounts[0], RATE_SCALE) + _stablecoinToSharesUp(amounts[1], RATE_SCALE);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenLending.TokenLending__ShareConsumptionMismatch.selector,
                intended,
                protocolBefore,
                protocolBefore - intended / 2
            )
        );
        harness.batchRetrieveStablecoin(users, amounts);

        assertEq(harness.getUserShares(userA), sharesA);
        assertEq(harness.getUserShares(userB), sharesB);
        assertEq(harness.protocolShares(), protocolBefore);
    }

    function test_redeemShares_liquidityShortageRevertsUnchanged() public {
        harness.depositToken(userA, USER_A_DEPOSIT);
        harness.setRevertOnRedeem(true);

        uint256 bookBefore = harness.getUserShares(userA);
        uint256 protocolBefore = harness.protocolShares();

        vm.expectRevert(bytes("Harness: insufficient liquidity"));
        harness.redeemShares(userA, 40 ether);

        assertEq(harness.getUserShares(userA), bookBefore);
        assertEq(harness.protocolShares(), protocolBefore);
        assertEq(harness.protocolRedeemCalls(), 0);
    }

    function test_redeemShares_overBurnHitsNamedMismatch() public {
        harness.depositToken(userA, USER_A_DEPOSIT);
        harness.setOverBurn(true);

        uint256 protocolBefore = harness.protocolShares();
        uint256 redeemAmount = 40 ether;
        uint256 intended = _stablecoinToSharesUp(redeemAmount, RATE_SCALE);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenLending.TokenLending__ShareConsumptionMismatch.selector,
                intended,
                protocolBefore,
                protocolBefore - (intended + 1)
            )
        );
        harness.redeemShares(userA, redeemAmount);

        assertEq(harness.protocolShares(), protocolBefore);
    }

    function test_redeemShares_increasingReceiptBalanceHitsNamedMismatch() public {
        harness.depositToken(userA, USER_A_DEPOSIT);
        harness.setIncreaseBalanceOnRedeem(true);

        uint256 protocolBefore = harness.protocolShares();
        uint256 redeemAmount = 40 ether;
        uint256 intended = _stablecoinToSharesUp(redeemAmount, RATE_SCALE);

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenLending.TokenLending__ShareConsumptionMismatch.selector,
                intended,
                protocolBefore,
                protocolBefore + 1
            )
        );
        harness.redeemShares(userA, redeemAmount);

        assertEq(harness.protocolShares(), protocolBefore);
    }

    function test_withdrawInterest_partialShareBurnRevertsAndRollsBack() public {
        harness.depositToken(userA, USER_A_DEPOSIT);
        // Accrue interest by raising the rate so share-backed value exceeds locked principal.
        harness.setExchangeRate(2e18);
        harness.setBurnBps(5_000);

        uint256 bookBefore = harness.getUserShares(userA);
        uint256 protocolBefore = harness.protocolShares();
        uint256 userStableBefore = stablecoin.balanceOf(userA);

        vm.expectRevert();
        harness.withdrawInterest(userA, USER_A_DEPOSIT);

        assertEq(harness.getUserShares(userA), bookBefore);
        assertEq(harness.protocolShares(), protocolBefore);
        assertEq(stablecoin.balanceOf(userA), userStableBefore);
    }

    /// @dev Gas snapshot for the PR body: 1 / 10 / 200 row batchRetrieve under the harness.
    ///      Warm one call first so cold-storage startup does not dominate the short measurements
    ///      (after dropping per-row `SharesRedeemed`, a cold 1-row call can exceed a warm 10-row).
    function test_gas_batchRetrieve_rowCounts() public {
        _fundAndDeposit(userA, 10_000 ether);
        uint256 rowAmount = 1 ether;
        _batchRows(1, rowAmount);

        uint256 g1 = gasleft();
        _batchRows(1, rowAmount);
        uint256 gas1 = g1 - gasleft();

        uint256 g10 = gasleft();
        _batchRows(10, rowAmount);
        uint256 gas10 = g10 - gasleft();

        uint256 g200 = gasleft();
        _batchRows(200, rowAmount);
        uint256 gas200 = g200 - gasleft();

        // Keep the snapshot observable in `-vv` without asserting absolute numbers (profile-sensitive).
        emit log_named_uint("batchRetrieve gas rows=1", gas1);
        emit log_named_uint("batchRetrieve gas rows=10", gas10);
        emit log_named_uint("batchRetrieve gas rows=200", gas200);
        assertGt(gas10, gas1);
        assertGt(gas200, gas10);
    }

    function _batchRows(uint256 n, uint256 rowAmount) private {
        address[] memory users = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            users[i] = userA;
            amounts[i] = rowAmount;
        }
        harness.batchRetrieveStablecoin(users, amounts);
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
    /// @notice BPS of `sharesAmount` actually burned. BPS_DENOMINATOR = full. Positive cash still paid for the fraction.
    uint256 public burnBps = BPS_DENOMINATOR;
    bool public overBurn;
    bool public increaseBalanceOnRedeem;
    bool public revertOnRedeem;

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

    function setBurnBps(uint256 bps) external {
        burnBps = bps;
    }

    function setOverBurn(bool enabled) external {
        overBurn = enabled;
    }

    function setIncreaseBalanceOnRedeem(bool enabled) external {
        increaseBalanceOnRedeem = enabled;
    }

    function setRevertOnRedeem(bool enabled) external {
        revertOnRedeem = enabled;
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
        uint256[] memory purchaseAmounts
    ) external returns (uint256) {
        return _batchRetrieveStablecoin(users, purchaseAmounts);
    }

    function _viewExchangeRate() internal view override returns (uint256) {
        return exchangeRate;
    }

    function _lendingSpender() internal view override returns (address) {
        return address(this);
    }

    function _receiptSharesBalance() internal override returns (uint256) {
        return protocolShares;
    }

    function _protocolDeposit(uint256 stablecoinAmount) internal override returns (uint256 mintedShares) {
        mintedShares = _stablecoinToShares(stablecoinAmount, exchangeRate);
        protocolShares += mintedShares;
        i_stableToken.safeTransfer(address(1), stablecoinAmount);
    }

    function _protocolRedeem(uint256 sharesAmount, uint256 rate) internal override {
        if (revertOnRedeem) revert("Harness: insufficient liquidity");
        protocolRedeemCalls++;

        uint256 toBurn = sharesAmount;
        if (increaseBalanceOnRedeem) {
            protocolShares += 1;
            toBurn = 0;
        } else if (overBurn) {
            toBurn = sharesAmount + 1;
        } else if (burnBps < BPS_DENOMINATOR) {
            toBurn = sharesAmount * burnBps / BPS_DENOMINATOR;
        }
        if (toBurn > 0) {
            protocolShares -= toBurn;
        }

        if (!payOut) return;
        uint256 amount = toBurn > 0
            ? _sharesToStablecoin(toBurn, rate)
            : _sharesToStablecoin(sharesAmount, rate);
        if (amount > 0) {
            MockStablecoin(address(i_stableToken)).mint(address(this), amount);
        }
    }
}
