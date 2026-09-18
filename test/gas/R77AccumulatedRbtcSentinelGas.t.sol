// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {PurchaseRbtcHarness} from "test/unit/PurchaseRbtcTest.t.sol";
import {NO_MIN_RBTC_OUT} from "test/utils/BatchBuyOne.sol";

/**
 * @title R77AccumulatedRbtcSentinelGas
 * @notice Prices a cold-style first credit (slot `0`) against a re-credit onto post-withdraw sentinel `1`.
 * @dev Reproduce with:
 *
 *          forge test --match-path test/gas/R77AccumulatedRbtcSentinelGas.t.sol -vv
 *
 *      Shared batch state is warmed first so the delta isolates the per-user rBTC slot SSTORE
 *      (zero→nonzero versus nonzero→nonzero), which is the operator saving on every credit after a
 *      full withdrawal.
 */
contract R77AccumulatedRbtcSentinelGasTest is Test {
    uint16 internal constant FLAT_FEE_RATE = 100;
    uint256 internal constant RBTC_OUT = 1 ether;
    uint256 internal constant GROSS = 100 ether;

    address internal buyerFirst = address(0xA11CE);
    address internal buyerSentinel = address(0xB0B);
    address internal buyerWarmup = address(0xC0FFEE);
    MockStablecoin internal token;
    PurchaseRbtcHarness internal harness;

    function setUp() public {
        token = new MockStablecoin(address(this));
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: FLAT_FEE_RATE,
            maxFeeRate: FLAT_FEE_RATE,
            feePurchaseLowerBound: 1000 ether,
            feePurchaseUpperBound: 100_000 ether
        });
        harness = new PurchaseRbtcHarness(address(this), address(token), address(0xFEE), feeSettings, address(this));
        token.mint(address(harness), 1_000_000 ether);
        harness.setRbtcOut(RBTC_OUT);
        vm.deal(address(harness), 20 * RBTC_OUT);
    }

    function test_gas_firstCreditVsRecreditAfterFullWithdraw() public {
        // Warm fee/token/path storage that every batch touches, unrelated to the sentinel encoding.
        _buy(buyerWarmup);
        _withdraw(buyerWarmup);

        // Establish the post-withdraw sentinel for the re-credit subject without measuring it.
        _buy(buyerSentinel);
        _withdraw(buyerSentinel);
        assertEq(harness.rawAccumulatedRbtc(buyerSentinel), 1, "sentinel missing before re-credit");
        assertEq(harness.rawAccumulatedRbtc(buyerFirst), 0, "first-credit buyer was pre-touched");

        uint256 gasRecredit = gasleft();
        _buy(buyerSentinel);
        uint256 recreditGas = gasRecredit - gasleft();

        uint256 gasFirst = gasleft();
        _buy(buyerFirst);
        uint256 firstCreditGas = gasFirst - gasleft();

        uint256 saving = firstCreditGas - recreditGas;
        console2.log("first credit onto slot 0 gas:", firstCreditGas);
        console2.log("re-credit onto sentinel 1 gas:", recreditGas);
        console2.log("saving (first - re-credit):", saving);

        // Zero→nonzero SSTORE (~20k) versus nonzero→nonzero (~2.9k). Shared path is already warm, so
        // the gap should sit near that difference.
        assertGt(saving, 10_000, "re-credit did not avoid a zero-to-nonzero SSTORE");
        assertLt(saving, 30_000, "saving larger than the SSTORE gap; warm-up probably failed");
        assertLt(recreditGas, firstCreditGas, "re-credit was not cheaper than the first credit");
    }

    function _buy(address buyer) private {
        address[] memory buyers = new address[](1);
        buyers[0] = buyer;
        uint64[] memory scheduleIds = new uint64[](1);
        scheduleIds[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = GROSS;
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);
    }

    function _withdraw(address buyer) private {
        harness.withdrawAccumulatedRbtc(buyer);
    }
}
