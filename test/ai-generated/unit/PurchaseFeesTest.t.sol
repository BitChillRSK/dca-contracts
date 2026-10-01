// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {PurchaseFeesHarness} from "../../mocks/PurchaseFeesHarness.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPurchaseFees} from "../../../src/interfaces/IPurchaseFees.sol";

contract PurchaseFeesTest is Test {
    PurchaseFeesHarness feeHandler;

    address constant FEE_COLLECTOR = address(0xBEEF);

    // Default settings used across tests
    uint16 constant MIN_FEE_RATE = 100; // 1%
    uint16 constant MAX_FEE_RATE = 200; // 2%
    uint16 constant FEE_RATE_CAP = 500;
    uint256 constant BPS_DENOMINATOR = 10_000;
    uint112 constant LOWER_BOUND = 100 ether; // below this gets max fee

    // Events
    event PurchaseFees__MinFeeRateSet(uint256 minFeeRate);
    event PurchaseFees__MaxFeeRateSet(uint256 maxFeeRate);
    event PurchaseFees__PurchaseLowerBoundSet(uint256 feePurchaseLowerBound);
    event PurchaseFees__FeeCollectorAddressSet(address indexed feeCollector);

    function setUp() public {
        IPurchaseFees.FeeSettings memory settings = IPurchaseFees.FeeSettings({
            minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE, feePurchaseLowerBound: LOWER_BOUND
        });
        feeHandler = new PurchaseFeesHarness(FEE_COLLECTOR, settings, address(this));
    }

    function test_constructor_reverts_invalidRates() public {
        IPurchaseFees.FeeSettings memory settings =
            IPurchaseFees.FeeSettings({minFeeRate: 300, maxFeeRate: 200, feePurchaseLowerBound: LOWER_BOUND});

        vm.expectRevert(IPurchaseFees.PurchaseFees__MinFeeRateCannotBeHigherThanMax.selector);
        new PurchaseFeesHarness(FEE_COLLECTOR, settings, address(this));
    }

    function test_constructor_reverts_zeroFeeCollector() public {
        IPurchaseFees.FeeSettings memory settings = IPurchaseFees.FeeSettings({
            minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE, feePurchaseLowerBound: LOWER_BOUND
        });

        vm.expectRevert(IPurchaseFees.PurchaseFees__InvalidFeeCollector.selector);
        new PurchaseFeesHarness(address(0), settings, address(this));
    }

    function test_constructor_reverts_maxFeeRateAboveCap() public {
        IPurchaseFees.FeeSettings memory settings = IPurchaseFees.FeeSettings({
            minFeeRate: MIN_FEE_RATE, maxFeeRate: FEE_RATE_CAP + 1, feePurchaseLowerBound: LOWER_BOUND
        });

        vm.expectRevert(IPurchaseFees.PurchaseFees__MaxFeeRateExceedsCap.selector);
        new PurchaseFeesHarness(FEE_COLLECTOR, settings, address(this));
    }

    function test_calculateFee_belowLowerBound() public {
        uint256 purchaseAmount = 50 ether; // below lower bound
        uint256 expectedFee = purchaseAmount * MAX_FEE_RATE / BPS_DENOMINATOR;
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateFee_largePurchase() public {
        uint256 purchaseAmount = 2000 ether;
        uint256 expectedFee = _referenceFee(purchaseAmount, MIN_FEE_RATE, MAX_FEE_RATE, LOWER_BOUND);
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateFee_interpolated() public {
        uint256 purchaseAmount = 550 ether;
        uint256 expectedFee = _referenceFee(purchaseAmount, MIN_FEE_RATE, MAX_FEE_RATE, LOWER_BOUND);
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateFee_atLowerBound() public {
        uint256 purchaseAmount = LOWER_BOUND;
        uint256 expectedFee = purchaseAmount * MAX_FEE_RATE / BPS_DENOMINATOR;
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateFee_asymptoticMinimum() public {
        uint256 purchaseAmount = 1000 ether;
        uint256 expectedFee = _referenceFee(purchaseAmount, MIN_FEE_RATE, MAX_FEE_RATE, LOWER_BOUND);
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_setFeeRateParams_reverts_invalidRates() public {
        vm.expectRevert(IPurchaseFees.PurchaseFees__MinFeeRateCannotBeHigherThanMax.selector);
        feeHandler.setFeeRateParams(300, 200, LOWER_BOUND); // min > max
    }

    function test_setFeeRateParams_success() public {
        uint256 newMin = 120;
        uint256 newMax = 250;
        uint256 newLower = 200 ether;

        // Should not revert
        feeHandler.setFeeRateParams(newMin, newMax, newLower);

        IPurchaseFees.FeeSettings memory settings = feeHandler.getFeeSettings();
        assertEq(settings.minFeeRate, newMin, "Min fee rate not set");
        assertEq(settings.maxFeeRate, newMax, "Max fee rate not set");
        assertEq(settings.feePurchaseLowerBound, newLower, "Lower bound not set");
    }

    function test_setFeeRateParams_raisesMinAboveOldMax() public {
        uint256 newMin = 250;
        uint256 newMax = 400;

        feeHandler.setFeeRateParams(newMin, newMax, LOWER_BOUND);

        IPurchaseFees.FeeSettings memory settings = feeHandler.getFeeSettings();
        assertEq(settings.minFeeRate, newMin);
        assertEq(settings.maxFeeRate, newMax);
        assertEq(settings.feePurchaseLowerBound, LOWER_BOUND);
    }

    function test_setFeeRateParams_updatesLowerBound() public {
        uint256 newLower = 2000 ether;

        feeHandler.setFeeRateParams(MIN_FEE_RATE, MAX_FEE_RATE, newLower);

        IPurchaseFees.FeeSettings memory settings = feeHandler.getFeeSettings();
        assertEq(settings.feePurchaseLowerBound, newLower);
    }

    function test_calculateFee_flatMinEqualsMax() public {
        uint16 flatRate = 100;
        feeHandler.testSetMinFeeRate(flatRate);
        feeHandler.testSetMaxFeeRate(flatRate);

        uint256 below = 50 ether;
        uint256 mid = 550 ether;
        uint256 above = 2000 ether;
        assertEq(feeHandler.exposedCalculateFee(below), below * flatRate / BPS_DENOMINATOR);
        assertEq(feeHandler.exposedCalculateFee(mid), mid * flatRate / BPS_DENOMINATOR);
        assertEq(feeHandler.exposedCalculateFee(above), above * flatRate / BPS_DENOMINATOR);
    }

    function test_calculateFeeAndNetWeights_matchesSequentialCalculateFee() public {
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 50 ether;
        amounts[1] = LOWER_BOUND;
        amounts[2] = 550 ether;
        amounts[3] = 2000 ether;

        (uint256 totalFee, uint256[] memory netAmounts, uint256 purchaseAmountsSum) =
            feeHandler.exposedCalculateFeeAndNetWeights(amounts);

        uint256 expectedTotalFee;
        uint256 expectedPurchaseAmountsSum;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 expectedFee = feeHandler.exposedCalculateFee(amounts[i]);
            expectedTotalFee += expectedFee;
            expectedPurchaseAmountsSum += amounts[i];
            assertEq(netAmounts[i], amounts[i] - expectedFee);
        }
        assertEq(totalFee, expectedTotalFee);
        assertEq(purchaseAmountsSum, expectedPurchaseAmountsSum);
    }

    function test_calculateFeeAndNetWeights_flatMatchesSequentialIncludingRounding() public {
        uint16 flatRate = 137;
        feeHandler.testSetFeeRateParams(flatRate, flatRate, LOWER_BOUND);

        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 1;
        amounts[1] = 72;
        amounts[2] = 9_999;
        amounts[3] = 10_000;
        amounts[4] = 550 ether;

        (uint256 totalFee, uint256[] memory netAmounts, uint256 purchaseAmountsSum) =
            feeHandler.exposedCalculateFeeAndNetWeights(amounts);

        uint256 expectedTotalFee;
        uint256 expectedPurchaseAmountsSum;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 expectedFee = amounts[i] * flatRate / BPS_DENOMINATOR;
            expectedTotalFee += expectedFee;
            expectedPurchaseAmountsSum += amounts[i];
            assertEq(netAmounts[i], amounts[i] - expectedFee);
        }
        assertEq(totalFee, expectedTotalFee);
        assertEq(purchaseAmountsSum, expectedPurchaseAmountsSum);
    }

    function test_setFeeRateParams_reverts_aboveCap() public {
        vm.expectRevert(IPurchaseFees.PurchaseFees__MaxFeeRateExceedsCap.selector);
        feeHandler.setFeeRateParams(MIN_FEE_RATE, FEE_RATE_CAP + 1, LOWER_BOUND);
    }

    function test_setFeeRateParams_atCap_success() public {
        feeHandler.setFeeRateParams(MIN_FEE_RATE, FEE_RATE_CAP, LOWER_BOUND);
        assertEq(feeHandler.getFeeSettings().maxFeeRate, FEE_RATE_CAP);
    }

    function test_setFeeCollector_reverts_zero() public {
        vm.expectRevert(IPurchaseFees.PurchaseFees__InvalidFeeCollector.selector);
        feeHandler.setFeeCollector(address(0));
    }

    function test_setFeeCollector_success() public {
        address newCollector = address(0xCAFE);
        vm.expectEmit(true, true, true, true);
        emit PurchaseFees__FeeCollectorAddressSet(newCollector);
        feeHandler.setFeeCollector(newCollector);
        assertEq(feeHandler.getFeeCollector(), newCollector);
    }

    function test_getFeeSettings_returnsStoredBand() public {
        IPurchaseFees.FeeSettings memory settings = feeHandler.getFeeSettings();
        assertEq(settings.minFeeRate, MIN_FEE_RATE);
        assertEq(settings.maxFeeRate, MAX_FEE_RATE);
        assertEq(settings.feePurchaseLowerBound, LOWER_BOUND);
    }

    // Test to ensure monotonicity: higher purchase amounts should have lower or equal fee rates
    function test_feeMonotonicity() public {
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 50 ether; // below lower bound
        amounts[1] = 100 ether; // at lower bound
        amounts[2] = 550 ether; // middle
        amounts[3] = 1000 ether;
        amounts[4] = 2000 ether;

        for (uint256 i = 0; i < amounts.length - 1; i++) {
            uint256 fee1 = feeHandler.exposedCalculateFee(amounts[i]);
            uint256 fee2 = feeHandler.exposedCalculateFee(amounts[i + 1]);

            uint256 rate1 = fee1 * BPS_DENOMINATOR / amounts[i];
            uint256 rate2 = fee2 * BPS_DENOMINATOR / amounts[i + 1];

            assertGe(rate1, rate2, "Fee rate should decrease or stay equal with higher amounts");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        UNCHECKED ARITHMETIC BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// @dev The fee multiplication and both loop sums run unchecked, bounded by uint96 purchase amounts and
    ///      the 500 bps cap. Drive a long batch at those bounds, flat and across the variable curve,
    ///      and compare every output with full-width arithmetic.
    function test_calculateFeeAndNetWeights_uint96RowsAtCapMatchFullWidth() public {
        uint256 rows = 256;
        uint256[] memory amounts = new uint256[](rows);
        uint256 step = uint256(type(uint96).max) / rows;
        for (uint256 i; i < rows; ++i) {
            amounts[i] = uint256(type(uint96).max) - i * step;
        }

        feeHandler.testSetFeeRateParams(FEE_RATE_CAP, FEE_RATE_CAP, 1);
        _assertFeesMatchFullWidth(amounts, FEE_RATE_CAP, FEE_RATE_CAP, 1);

        uint112 lower = uint112(step);
        feeHandler.testSetFeeRateParams(0, FEE_RATE_CAP, lower);
        _assertFeesMatchFullWidth(amounts, 0, FEE_RATE_CAP, lower);
    }

    function _assertFeesMatchFullWidth(uint256[] memory amounts, uint256 minRate, uint256 maxRate, uint256 lower)
        private
    {
        (uint256 totalFee, uint256[] memory nets, uint256 purchaseAmountsSum) =
            feeHandler.exposedCalculateFeeAndNetWeights(amounts);
        uint256 expectedFees;
        uint256 expectedPurchaseAmountsSum;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = amounts[i];
            uint256 fee = _referenceFee(amount, minRate, maxRate, lower);
            assertEq(nets[i], amount - fee, "row net");
            expectedFees += fee;
            expectedPurchaseAmountsSum += amount;
        }
        assertEq(totalFee, expectedFees, "total fee");
        assertEq(purchaseAmountsSum, expectedPurchaseAmountsSum, "purchaseAmountsSum");
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE PACKING
    //////////////////////////////////////////////////////////////*/

    /// @dev The four logical fee fields live in two slots. Ownable2Step owns slots 0 and 1, the
    ///      collector occupies slot 2, and all three settings fit in slot 3.
    function test_feeSettingsOccupyTwoSlots() public {
        uint256 collectorSlot = uint256(vm.load(address(feeHandler), bytes32(uint256(2))));
        assertEq(address(uint160(collectorSlot)), FEE_COLLECTOR, "slot 2 does not hold the collector");
        assertEq(collectorSlot >> 160, 0, "settings spilled into the collector slot");

        uint256 settingsSlot = uint256(vm.load(address(feeHandler), bytes32(uint256(3))));
        assertEq(uint112(settingsSlot), LOWER_BOUND, "lower bound is not first in slot 3");
        assertEq(settingsSlot >> 144, 0, "unexpected bits above settings");
        assertEq(uint16(settingsSlot >> 112), MIN_FEE_RATE, "minFeeRate does not follow the bounds");
        assertEq(uint16(settingsSlot >> 128), MAX_FEE_RATE, "maxFeeRate does not finish slot 3");

        assertEq(uint256(vm.load(address(feeHandler), bytes32(uint256(4)))), 0, "fee state spilled into a third slot");
    }

    function test_setFeeRateParams_castsIntoThePackedWidths() public {
        uint256 newLower = 200 ether;
        feeHandler.setFeeRateParams(150, 300, newLower);

        IPurchaseFees.FeeSettings memory settings = feeHandler.getFeeSettings();
        assertEq(settings.minFeeRate, 150);
        assertEq(settings.maxFeeRate, 300);
        assertEq(settings.feePurchaseLowerBound, newLower);

        uint256 collectorSlot = uint256(vm.load(address(feeHandler), bytes32(uint256(2))));
        assertEq(address(uint160(collectorSlot)), FEE_COLLECTOR, "writing settings disturbed the collector");
    }

    function test_setFeeRateParams_revertsOnUncastableRate() public {
        uint256 overflowing = uint256(type(uint16).max) + 1;
        // The cap check fires first: nothing above 500 can reach the uint16 write.
        vm.expectRevert(IPurchaseFees.PurchaseFees__MaxFeeRateExceedsCap.selector);
        feeHandler.setFeeRateParams(MIN_FEE_RATE, overflowing, LOWER_BOUND);
    }

    function test_setFeeRateParams_revertsOnUncastableBound() public {
        uint256 overflowing = uint256(type(uint112).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 112, overflowing));
        feeHandler.setFeeRateParams(MIN_FEE_RATE, MAX_FEE_RATE, overflowing);
    }

    // Independent form: start from the maximum-rate fee and subtract the exact discount.
    // Ceil the discount in the numerator before dividing by BPS; this equals one final floor.
    function _referenceFee(uint256 x, uint256 minRate, uint256 maxRate, uint256 lower) private pure returns (uint256) {
        if (x <= lower) return x * maxRate / BPS_DENOMINATOR;
        uint256 discountNumerator = (maxRate - minRate) * (x - lower) * (x - lower);
        uint256 discount = discountNumerator / x + (discountNumerator % x == 0 ? 0 : 1);
        return (maxRate * x - discount) / BPS_DENOMINATOR;
    }

    function test_regression_feeNeverDipsAtFormerUpperBound() public {
        feeHandler.setFeeRateParams(50, 100, 100 ether);
        // Old interpolation charged 5.04 at 900 but only 5 at 1000.
        uint256 previous = feeHandler.exposedCalculateFee(850 ether);
        for (uint256 x = 851 ether; x <= 1050 ether; x += 1 ether) {
            uint256 current = feeHandler.exposedCalculateFee(x);
            assertGe(current, previous);
            previous = current;
        }
        // Old whole-bps step at 118 also reduced the absolute fee.
        assertGe(feeHandler.exposedCalculateFee(118 ether), feeHandler.exposedCalculateFee(118 ether - 1));
    }

    function test_referenceValues_sixAndEighteenDecimals() public {
        for (uint256 decimals = 6; decimals <= 18; decimals += 12) {
            uint256 unit = 10 ** decimals;
            feeHandler.setFeeRateParams(10, 100, 250 * unit);
            assertEq(feeHandler.exposedCalculateFee(100 * unit), unit);
            assertEq(feeHandler.exposedCalculateFee(500 * unit), 3875 * unit / 1000);
            assertEq(feeHandler.exposedCalculateFee(1000 * unit), 49375 * unit / 10000);
            assertEq(feeHandler.exposedCalculateFee(10000 * unit), 1444375 * unit / 100000);
            feeHandler.setFeeRateParams(10, 100, 100 * unit);
            assertEq(feeHandler.exposedCalculateFee(500 * unit), 212 * unit / 100);
            assertEq(feeHandler.exposedCalculateFee(1000 * unit), 271 * unit / 100);
        }
    }

    function test_zeroRatesAndExtremeBounds() public {
        uint256 maxAmount = type(uint96).max;
        feeHandler.setFeeRateParams(0, 0, 0);
        assertEq(feeHandler.exposedCalculateFee(maxAmount), 0);
        assertEq(feeHandler.exposedCalculateFee(0), 0);
        feeHandler.setFeeRateParams(10, 500, 0);
        assertEq(feeHandler.exposedCalculateFee(maxAmount), maxAmount * 10 / 10000);
        feeHandler.setFeeRateParams(0, 500, type(uint112).max);
        assertEq(feeHandler.exposedCalculateFee(maxAmount), maxAmount * 500 / 10000);
        feeHandler.setFeeRateParams(0, 500, maxAmount - 1);
        assertEq(feeHandler.exposedCalculateFee(maxAmount), _referenceFee(maxAmount, 0, 500, maxAmount - 1));
    }

    function test_setFeeRateParams_emitsChangedFieldsOnly() public {
        vm.expectEmit(false, false, false, true);
        emit PurchaseFees__MinFeeRateSet(10);
        vm.expectEmit(false, false, false, true);
        emit PurchaseFees__MaxFeeRateSet(100);
        vm.expectEmit(false, false, false, true);
        emit PurchaseFees__PurchaseLowerBoundSet(250 ether);
        feeHandler.setFeeRateParams(10, 100, 250 ether);
        vm.recordLogs();
        feeHandler.setFeeRateParams(10, 100, 250 ether);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testFuzz_monotoneFeesAndNetAmounts(uint96 a, uint96 b, uint112 lower, uint16 minSeed, uint16 maxSeed)
        public
    {
        uint256 maxRate = bound(maxSeed, 0, 500);
        uint256 minRate = bound(minSeed, 0, maxRate);
        feeHandler.setFeeRateParams(minRate, maxRate, lower);
        uint256 x = a < b ? a : b;
        uint256 y = a < b ? b : a;
        _assertOrdered(x, y, minRate, maxRate, lower);
        if (x < type(uint96).max) _assertOrdered(x, x + 1, minRate, maxRate, lower);
        // Exercise the curved branch even when the fuzzed uint112 bound exceeds all uint96 amounts.
        uint256 reachableLower = bound(uint256(lower), 0, type(uint96).max - 1);
        feeHandler.setFeeRateParams(minRate, maxRate, reachableLower);
        _assertOrdered(reachableLower, reachableLower + 1, minRate, maxRate, reachableLower);
        if (reachableLower > 0) _assertOrdered(reachableLower - 1, reachableLower, minRate, maxRate, reachableLower);
        _assertOrdered(x, y, minRate, maxRate, reachableLower);
    }

    function _assertOrdered(uint256 x, uint256 y, uint256 minRate, uint256 maxRate, uint256 lower) private {
        uint256 fx = feeHandler.exposedCalculateFee(x);
        uint256 fy = feeHandler.exposedCalculateFee(y);
        assertGe(fy, fx, "absolute fee decreased");
        assertGe(y - fy, x - fx, "net purchase decreased");
        assertEq(fx, _referenceFee(x, minRate, maxRate, lower));
        assertEq(fy, _referenceFee(y, minRate, maxRate, lower));
        assertGe(fx, x * minRate / 10000);
        assertLe(fx, x * maxRate / 10000);
        assertGe(fy, y * minRate / 10000);
        assertLe(fy, y * maxRate / 10000);
        // Actual rates may differ from the smooth rate by less than one token base unit per fee.
        assertLe(fy * x, (fx + 1) * y, "rate increased beyond final-rounding tolerance");
    }
}
