// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {FeeHandlerHarness} from "../../mocks/FeeHandlerHarness.sol";
import {IFeeHandler} from "../../../src/interfaces/IFeeHandler.sol";

contract FeeHandlerTest is Test {
    FeeHandlerHarness feeHandler;

    address constant FEE_COLLECTOR = address(0xBEEF);

    // Default settings used across tests
    uint256 constant MIN_FEE_RATE = 100; // 1%
    uint256 constant MAX_FEE_RATE = 200; // 2%
    uint256 constant FEE_RATE_CAP = 500;
    uint256 constant LOWER_BOUND = 100 ether; // below this gets max fee
    uint256 constant UPPER_BOUND = 1000 ether; // above this gets min fee

    // Events
    event FeeHandler__MinFeeRateSet(uint256 indexed minFeeRate);
    event FeeHandler__MaxFeeRateSet(uint256 indexed maxFeeRate);
    event FeeHandler__PurchaseLowerBoundSet(uint256 indexed feePurchaseLowerBound);
    event FeeHandler__PurchaseUpperBoundSet(uint256 indexed feePurchaseUpperBound);
    event FeeHandler__FeeCollectorAddressSet(address indexed feeCollector);

    function setUp() public {
        IFeeHandler.FeeSettings memory settings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE,
            feePurchaseLowerBound: LOWER_BOUND,
            feePurchaseUpperBound: UPPER_BOUND
        });
        feeHandler = new FeeHandlerHarness(FEE_COLLECTOR, settings, address(this));
    }

    function test_constructor_reverts_invalidRates() public {
        IFeeHandler.FeeSettings memory settings = IFeeHandler.FeeSettings({
            minFeeRate: 300,
            maxFeeRate: 200,
            feePurchaseLowerBound: LOWER_BOUND,
            feePurchaseUpperBound: UPPER_BOUND
        });

        vm.expectRevert(IFeeHandler.FeeHandler__MinFeeRateCannotBeHigherThanMax.selector);
        new FeeHandlerHarness(FEE_COLLECTOR, settings, address(this));
    }

    function test_constructor_reverts_invalidBounds() public {
        IFeeHandler.FeeSettings memory settings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE,
            feePurchaseLowerBound: UPPER_BOUND,
            feePurchaseUpperBound: LOWER_BOUND
        });

        vm.expectRevert(IFeeHandler.FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound.selector);
        new FeeHandlerHarness(FEE_COLLECTOR, settings, address(this));
    }

    function test_constructor_reverts_zeroFeeCollector() public {
        IFeeHandler.FeeSettings memory settings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE,
            feePurchaseLowerBound: LOWER_BOUND,
            feePurchaseUpperBound: UPPER_BOUND
        });

        vm.expectRevert(IFeeHandler.FeeHandler__InvalidFeeCollector.selector);
        new FeeHandlerHarness(address(0), settings, address(this));
    }

    function test_constructor_reverts_maxFeeRateAboveCap() public {
        IFeeHandler.FeeSettings memory settings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: FEE_RATE_CAP + 1,
            feePurchaseLowerBound: LOWER_BOUND,
            feePurchaseUpperBound: UPPER_BOUND
        });

        vm.expectRevert(IFeeHandler.FeeHandler__MaxFeeRateExceedsCap.selector);
        new FeeHandlerHarness(FEE_COLLECTOR, settings, address(this));
    }

    function test_calculateFee_belowLowerBound() public {
        uint256 purchaseAmount = 50 ether; // below lower bound
        uint256 expectedFee = purchaseAmount * MAX_FEE_RATE / 10_000;
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateFee_aboveUpperBound() public {
        uint256 purchaseAmount = 2000 ether; // above upper bound
        uint256 expectedFee = purchaseAmount * MIN_FEE_RATE / 10_000;
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateFee_interpolated() public {
        uint256 purchaseAmount = 550 ether; // middle of bounds
        // Expected interpolated rate: 200 - ((550-100)/(1000-100)) * (200-100) = 200 - 50 = 150
        uint256 expectedRate = 150;
        uint256 expectedFee = purchaseAmount * expectedRate / 10_000;
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateFee_atLowerBound() public {
        uint256 purchaseAmount = LOWER_BOUND;
        uint256 expectedFee = purchaseAmount * MAX_FEE_RATE / 10_000;
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateFee_atUpperBound() public {
        uint256 purchaseAmount = UPPER_BOUND;
        uint256 expectedFee = purchaseAmount * MIN_FEE_RATE / 10_000;
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_setFeeRateParams_reverts_invalidRates() public {
        vm.expectRevert(IFeeHandler.FeeHandler__MinFeeRateCannotBeHigherThanMax.selector);
        feeHandler.setFeeRateParams(300, 200, LOWER_BOUND, UPPER_BOUND); // min > max
    }

    function test_setFeeRateParams_reverts_invalidBounds() public {
        vm.expectRevert(IFeeHandler.FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound.selector);
        feeHandler.setFeeRateParams(MIN_FEE_RATE, MAX_FEE_RATE, 1000 ether, 500 ether); // lower > upper
    }

    function test_setFeeRateParams_success() public {
        uint256 newMin = 120;
        uint256 newMax = 250;
        uint256 newLower = 200 ether;
        uint256 newUpper = 1500 ether;

        // Should not revert
        feeHandler.setFeeRateParams(newMin, newMax, newLower, newUpper);

        IFeeHandler.FeeSettings memory settings = feeHandler.getFeeSettings();
        assertEq(settings.minFeeRate, newMin, "Min fee rate not set");
        assertEq(settings.maxFeeRate, newMax, "Max fee rate not set");
        assertEq(settings.feePurchaseLowerBound, newLower, "Lower bound not set");
        assertEq(settings.feePurchaseUpperBound, newUpper, "Upper bound not set");
    }

    function test_setFeeRateParams_raisesMinAboveOldMax() public {
        uint256 newMin = 250;
        uint256 newMax = 400;

        feeHandler.setFeeRateParams(newMin, newMax, LOWER_BOUND, UPPER_BOUND);

        IFeeHandler.FeeSettings memory settings = feeHandler.getFeeSettings();
        assertEq(settings.minFeeRate, newMin);
        assertEq(settings.maxFeeRate, newMax);
        assertEq(settings.feePurchaseLowerBound, LOWER_BOUND);
        assertEq(settings.feePurchaseUpperBound, UPPER_BOUND);
    }

    function test_setFeeRateParams_raisesBothBoundsAboveOldUpper() public {
        uint256 newLower = 2000 ether;
        uint256 newUpper = 5000 ether;

        feeHandler.setFeeRateParams(MIN_FEE_RATE, MAX_FEE_RATE, newLower, newUpper);

        IFeeHandler.FeeSettings memory settings = feeHandler.getFeeSettings();
        assertEq(settings.feePurchaseLowerBound, newLower);
        assertEq(settings.feePurchaseUpperBound, newUpper);
    }

    function test_setFeeRateParams_reverts_whenLowerGteUpper() public {
        vm.expectRevert(IFeeHandler.FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound.selector);
        feeHandler.setFeeRateParams(MIN_FEE_RATE, MAX_FEE_RATE, UPPER_BOUND, UPPER_BOUND);

        vm.expectRevert(IFeeHandler.FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound.selector);
        feeHandler.setFeeRateParams(MIN_FEE_RATE, MAX_FEE_RATE, UPPER_BOUND + 1, UPPER_BOUND);
    }

    function test_setFeeRateParams_reverts_whenUpperLteLower() public {
        vm.expectRevert(IFeeHandler.FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound.selector);
        feeHandler.setFeeRateParams(MIN_FEE_RATE, MAX_FEE_RATE, LOWER_BOUND, LOWER_BOUND);

        vm.expectRevert(IFeeHandler.FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound.selector);
        feeHandler.setFeeRateParams(MIN_FEE_RATE, MAX_FEE_RATE, LOWER_BOUND, LOWER_BOUND - 1);
    }

    function test_calculateFee_flatMinEqualsMax() public {
        uint256 flatRate = 100;
        feeHandler.testSetMinFeeRate(flatRate);
        feeHandler.testSetMaxFeeRate(flatRate);

        uint256 below = 50 ether;
        uint256 mid = 550 ether;
        uint256 above = 2000 ether;
        assertEq(feeHandler.exposedCalculateFee(below), below * flatRate / 10_000);
        assertEq(feeHandler.exposedCalculateFee(mid), mid * flatRate / 10_000);
        assertEq(feeHandler.exposedCalculateFee(above), above * flatRate / 10_000);
    }

    function test_calculateFeeAndNetAmounts_matchesSequentialCalculateFee() public {
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 50 ether;
        amounts[1] = LOWER_BOUND;
        amounts[2] = 550 ether;
        amounts[3] = 2000 ether;

        (uint256 aggregatedFee, uint256[] memory netAmounts, uint256 totalNet) =
            feeHandler.exposedCalculateFeeAndNetAmounts(amounts);

        uint256 expectedAggregatedFee;
        uint256 expectedTotalNet;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 expectedFee = feeHandler.exposedCalculateFee(amounts[i]);
            expectedAggregatedFee += expectedFee;
            expectedTotalNet += amounts[i] - expectedFee;
            assertEq(netAmounts[i], amounts[i] - expectedFee);
        }
        assertEq(aggregatedFee, expectedAggregatedFee);
        assertEq(totalNet, expectedTotalNet);
    }

    function test_setFeeRateParams_reverts_aboveCap() public {
        vm.expectRevert(IFeeHandler.FeeHandler__MaxFeeRateExceedsCap.selector);
        feeHandler.setFeeRateParams(MIN_FEE_RATE, FEE_RATE_CAP + 1, LOWER_BOUND, UPPER_BOUND);
    }

    function test_setFeeRateParams_atCap_success() public {
        feeHandler.setFeeRateParams(MIN_FEE_RATE, FEE_RATE_CAP, LOWER_BOUND, UPPER_BOUND);
        assertEq(feeHandler.getFeeSettings().maxFeeRate, FEE_RATE_CAP);
    }

    function test_setFeeCollectorAddress_reverts_zero() public {
        vm.expectRevert(IFeeHandler.FeeHandler__InvalidFeeCollector.selector);
        feeHandler.setFeeCollectorAddress(address(0));
    }

    function test_setFeeCollectorAddress_success() public {
        address newCollector = address(0xCAFE);
        vm.expectEmit(true, true, true, true);
        emit FeeHandler__FeeCollectorAddressSet(newCollector);
        feeHandler.setFeeCollectorAddress(newCollector);
        assertEq(feeHandler.getFeeCollectorAddress(), newCollector);
    }

    function test_getFeeSettings_returnsStoredBand() public {
        IFeeHandler.FeeSettings memory settings = feeHandler.getFeeSettings();
        assertEq(settings.minFeeRate, MIN_FEE_RATE);
        assertEq(settings.maxFeeRate, MAX_FEE_RATE);
        assertEq(settings.feePurchaseLowerBound, LOWER_BOUND);
        assertEq(settings.feePurchaseUpperBound, UPPER_BOUND);
    }

    // Test to ensure monotonicity: higher purchase amounts should have lower or equal fee rates
    function test_feeMonotonicity() public {
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 50 ether;   // below lower bound
        amounts[1] = 100 ether;  // at lower bound
        amounts[2] = 550 ether;  // middle
        amounts[3] = 1000 ether; // at upper bound
        amounts[4] = 2000 ether; // above upper bound
        
        for (uint256 i = 0; i < amounts.length - 1; i++) {
            uint256 fee1 = feeHandler.exposedCalculateFee(amounts[i]);
            uint256 fee2 = feeHandler.exposedCalculateFee(amounts[i + 1]);
            
            uint256 rate1 = fee1 * 10_000 / amounts[i];
            uint256 rate2 = fee2 * 10_000 / amounts[i + 1];
            
            assertGe(rate1, rate2, "Fee rate should decrease or stay equal with higher amounts");
        }
    }
}
