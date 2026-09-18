// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {PurchaseRbtcHarness} from "test/unit/PurchaseRbtcTest.t.sol";
import {NO_MIN_RBTC_OUT} from "test/utils/BatchBuyOne.sol";

/**
 * @title R77AccumulatedRbtcSentinelGas
 * @notice Prices a cold first credit (slot `0`) against a cold re-credit onto post-withdraw sentinel `1`.
 * @dev Reproduce with:
 *
 *          forge test --match-path test/gas/R77AccumulatedRbtcSentinelGas.t.sol -vv
 *
 *      Warm-up and sentinel establishment run in `setUp`. Each measured credit then starts after
 *      `vm.cool(harness)` so both subject slots are cold, matching a real cross-transaction tick.
 *      (Foundry runs `setUp` in the same transaction as the test; without cooling, the sentinel slot
 *      would stay warm/dirty from `_buy`/`_withdraw` and inflate the gap past the SSTORE delta.)
 *      The paired comparison snapshots the post-setUp state and reverts between the two credits so
 *      shared cold costs cancel.
 *
 *      Expected Foundry/Cancun gap ≈ 17,100 (cold SET − cold RESET). This harness pins
 *      `EXPECTED_COLD_SAVING` at 17,105 as a **Foundry-schedule regression pin**; ±500 absorbs forge
 *      noise. It is not a Rootstock operator saving. On Rootstock the production transfer is
 *      SET 20,000 → RESET 5,000 (−15,000 swapper) against CLEAR−REFUND → RESET (+15,000 user), system
 *      net 0 — see docs/relaunch/ROOTSTOCK-GAS-SCHEDULE.md and R77's Rootstock economics section.
 */
contract R77AccumulatedRbtcSentinelGasTest is Test {
    uint16 internal constant FLAT_FEE_RATE = 100;
    uint256 internal constant RBTC_OUT = 1 ether;
    uint256 internal constant GROSS = 100 ether;
    /// @dev Foundry/Cancun regression pin (cold first − cold re-credit). Not a Rootstock saving.
    uint256 internal constant EXPECTED_COLD_SAVING = 17_105;

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

        // Warm fee/token/path storage every batch touches, then leave buyerSentinel on sentinel `1`.
        _buy(buyerWarmup);
        _withdraw(buyerWarmup);
        _buy(buyerSentinel);
        _withdraw(buyerSentinel);
        assertEq(_rawAccumulatedRbtc(buyerSentinel), 1, "sentinel missing before re-credit");
        assertEq(_rawAccumulatedRbtc(buyerFirst), 0, "first-credit buyer was pre-touched");
    }

    function test_gas_coldFirstCreditOntoZero() public {
        _cool(address(harness));

        uint256 gasBefore = gasleft();
        _buy(buyerFirst);
        uint256 firstCreditGas = gasBefore - gasleft();

        console2.log("COLD first credit onto 0:", firstCreditGas);
        assertEq(harness.getAccumulatedRbtcBalance(buyerFirst), RBTC_OUT);
    }

    function test_gas_coldRecreditOntoSentinel() public {
        _cool(address(harness));

        uint256 gasBefore = gasleft();
        _buy(buyerSentinel);
        uint256 recreditGas = gasBefore - gasleft();

        console2.log("COLD re-credit onto sentinel:", recreditGas);
        assertEq(harness.getAccumulatedRbtcBalance(buyerSentinel), RBTC_OUT);
    }

    function test_gas_coldRecreditSavesAgainstFirstCredit() public {
        uint256 snap = vm.snapshot();

        _cool(address(harness));
        uint256 gasFirst = gasleft();
        _buy(buyerFirst);
        uint256 firstCreditGas = gasFirst - gasleft();

        // Same post-setUp baseline for both credits so shared cold/warm costs cancel.
        vm.revertTo(snap);

        _cool(address(harness));
        uint256 gasRecredit = gasleft();
        _buy(buyerSentinel);
        uint256 recreditGas = gasRecredit - gasleft();

        uint256 saving = firstCreditGas - recreditGas;
        console2.log("COLD first credit onto 0:", firstCreditGas);
        console2.log("COLD re-credit onto sentinel:", recreditGas);
        console2.log("saving (first - re-credit):", saving);

        // Zero→nonzero SSTORE (~20k) versus nonzero→nonzero (~2.9k).
        assertGt(saving, 10_000, "re-credit did not avoid a zero-to-nonzero SSTORE");
        assertLt(saving, 30_000, "saving larger than the SSTORE gap; cooling probably failed");
        assertApproxEqAbs(saving, EXPECTED_COLD_SAVING, 500, "cold saving drifted from the SSTORE gap");
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

    /// @dev Test probe into private `s_usersAccumulatedRbtc` (slot 4 on this harness layout).
    ///      Re-check with `forge inspect PurchaseRbtcHarness storage-layout` if FeeHandler packing moves.
    function _rawAccumulatedRbtc(address user) private view returns (uint256) {
        return uint256(vm.load(address(harness), keccak256(abi.encode(user, uint256(4)))));
    }

    /// @dev forge-std's `Vm` interface on this pin omits `cool`; the cheatcode exists on the binary.
    function _cool(address target) private {
        (bool ok,) = address(uint160(uint256(keccak256("hevm cheat code"))))
            .call(abi.encodeWithSignature("cool(address)", target));
        require(ok, "vm.cool unavailable");
    }
}
