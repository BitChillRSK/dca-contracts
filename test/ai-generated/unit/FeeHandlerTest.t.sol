// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {FeeHandlerHarness} from "../../mocks/FeeHandlerHarness.sol";
import {IFeeHandler} from "../../../src/interfaces/IFeeHandler.sol";

contract FeeHandlerTest is Test {
    FeeHandlerHarness feeHandler;

    // Default settings used across tests
    uint256 constant MIN_FEE_RATE = 100; // 1%
    uint256 constant MAX_FEE_RATE = 200; // 2%
    uint256 constant LOWER_BOUND = 100 ether; // below this gets max fee
    uint256 constant UPPER_BOUND = 1000 ether; // above this gets min fee

    // Events
    event FeeHandler__MinFeeRateSet(uint256 indexed minFeeRate);
    event FeeHandler__MaxFeeRateSet(uint256 indexed maxFeeRate);
    event FeeHandler__PurchaseLowerBoundSet(uint256 indexed feePurchaseLowerBound);
    event FeeHandler__PurchaseUpperBoundSet(uint256 indexed feePurchaseUpperBound);

    function setUp() public {
        IFeeHandler.FeeSettings memory settings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE,
            feePurchaseLowerBound: LOWER_BOUND,
            feePurchaseUpperBound: UPPER_BOUND
        });
        feeHandler = new FeeHandlerHarness(settings);
    }

    function test_constructor_reverts_invalidRates() public {
        IFeeHandler.FeeSettings memory settings = IFeeHandler.FeeSettings({
            minFeeRate: 300,
            maxFeeRate: 200,
            feePurchaseLowerBound: LOWER_BOUND,
            feePurchaseUpperBound: UPPER_BOUND
        });

        vm.expectRevert(IFeeHandler.FeeHandler__MinFeeRateCannotBeHigherThanMax.selector);
        new FeeHandlerHarness(settings);
    }

    function test_constructor_reverts_invalidBounds() public {
        IFeeHandler.FeeSettings memory settings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE,
            feePurchaseLowerBound: UPPER_BOUND,
            feePurchaseUpperBound: LOWER_BOUND
        });

        vm.expectRevert(IFeeHandler.FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound.selector);
        new FeeHandlerHarness(settings);
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

        assertEq(feeHandler.getMinFeeRate(), newMin, "Min fee rate not set");
        assertEq(feeHandler.getMaxFeeRate(), newMax, "Max fee rate not set");
        assertEq(feeHandler.getFeePurchaseLowerBound(), newLower, "Lower bound not set");
        assertEq(feeHandler.getFeePurchaseUpperBound(), newUpper, "Upper bound not set");
    }

    function test_setMinFeeRate_success() public {
        uint256 newMin = 130;
        vm.expectEmit(true, true, true, true);
        emit FeeHandler__MinFeeRateSet(newMin);
        feeHandler.setMinFeeRate(newMin);
        assertEq(feeHandler.getMinFeeRate(), newMin, "Min fee rate not set");
    }

    function test_setMaxFeeRate_success() public {
        uint256 newMax = 300;
        vm.expectEmit(true, true, true, true);
        emit FeeHandler__MaxFeeRateSet(newMax);
        feeHandler.setMaxFeeRate(newMax);
        assertEq(feeHandler.getMaxFeeRate(), newMax, "Max fee rate not set");
    }

    function test_setPurchaseLowerBound_success() public {
        uint256 newLower = 250 ether;
        vm.expectEmit(true, true, true, true);
        emit FeeHandler__PurchaseLowerBoundSet(newLower);
        feeHandler.setPurchaseLowerBound(newLower);
        assertEq(feeHandler.getFeePurchaseLowerBound(), newLower, "Lower bound not set");
    }

    function test_setPurchaseUpperBound_success() public {
        uint256 newUpper = 2000 ether;
        vm.expectEmit(true, true, true, true);
        emit FeeHandler__PurchaseUpperBoundSet(newUpper);
        feeHandler.setPurchaseUpperBound(newUpper);
        assertEq(feeHandler.getFeePurchaseUpperBound(), newUpper, "Upper bound not set");
    }

    function test_setFeeRateParams_raisesMinAboveOldMax() public {
        uint256 newMin = 250;
        uint256 newMax = 400;

        feeHandler.setFeeRateParams(newMin, newMax, LOWER_BOUND, UPPER_BOUND);

        assertEq(feeHandler.getMinFeeRate(), newMin);
        assertEq(feeHandler.getMaxFeeRate(), newMax);
        assertEq(feeHandler.getFeePurchaseLowerBound(), LOWER_BOUND);
        assertEq(feeHandler.getFeePurchaseUpperBound(), UPPER_BOUND);
    }

    function test_setFeeRateParams_raisesBothBoundsAboveOldUpper() public {
        uint256 newLower = 2000 ether;
        uint256 newUpper = 5000 ether;

        feeHandler.setFeeRateParams(MIN_FEE_RATE, MAX_FEE_RATE, newLower, newUpper);

        assertEq(feeHandler.getFeePurchaseLowerBound(), newLower);
        assertEq(feeHandler.getFeePurchaseUpperBound(), newUpper);
    }

    function test_setPurchaseLowerBound_reverts_whenGteUpper() public {
        vm.expectRevert(IFeeHandler.FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound.selector);
        feeHandler.setPurchaseLowerBound(UPPER_BOUND);

        vm.expectRevert(IFeeHandler.FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound.selector);
        feeHandler.setPurchaseLowerBound(UPPER_BOUND + 1);
    }

    function test_setPurchaseUpperBound_reverts_whenLteLower() public {
        vm.expectRevert(IFeeHandler.FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound.selector);
        feeHandler.setPurchaseUpperBound(LOWER_BOUND);

        vm.expectRevert(IFeeHandler.FeeHandler__FeeLowerBoundMustBeLowerThanUpperBound.selector);
        feeHandler.setPurchaseUpperBound(LOWER_BOUND - 1);
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
