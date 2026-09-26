// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {FeeHandlerHarness} from "../../mocks/FeeHandlerHarness.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IFeeHandler} from "../../../src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "../../mocks/MockStablecoin.sol";

contract FeeHandlerTest is Test {
    FeeHandlerHarness feeHandler;

    address constant FEE_COLLECTOR = address(0xBEEF);

    // Default settings used across tests
    uint16 constant MIN_FEE_RATE = 100; // 1%
    uint16 constant MAX_FEE_RATE = 200; // 2%
    uint16 constant FEE_RATE_CAP = 500;
    uint256 constant BPS_DENOMINATOR = 10_000;
    uint112 constant LOWER_BOUND = 100 ether; // below this gets max fee
    uint112 constant UPPER_BOUND = 1000 ether; // above this gets min fee

    // Events
    event FeeHandler__MinFeeRateSet(uint256 minFeeRate);
    event FeeHandler__MaxFeeRateSet(uint256 maxFeeRate);
    event FeeHandler__PurchaseLowerBoundSet(uint256 feePurchaseLowerBound);
    event FeeHandler__PurchaseUpperBoundSet(uint256 feePurchaseUpperBound);
    event FeeHandler__FeeCollectorAddressSet(address indexed feeCollector);
    event Transfer(address indexed from, address indexed to, uint256 value);

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
        uint256 expectedFee = purchaseAmount * MAX_FEE_RATE / BPS_DENOMINATOR;
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateFee_aboveUpperBound() public {
        uint256 purchaseAmount = 2000 ether; // above upper bound
        uint256 expectedFee = purchaseAmount * MIN_FEE_RATE / BPS_DENOMINATOR;
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateFee_interpolated() public {
        uint256 purchaseAmount = 550 ether; // middle of bounds
        // Expected interpolated rate: 200 - ((550-100)/(1000-100)) * (200-100) = 200 - 50 = 150
        uint256 expectedRate = 150;
        uint256 expectedFee = purchaseAmount * expectedRate / BPS_DENOMINATOR;
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateFee_atLowerBound() public {
        uint256 purchaseAmount = LOWER_BOUND;
        uint256 expectedFee = purchaseAmount * MAX_FEE_RATE / BPS_DENOMINATOR;
        uint256 actualFee = feeHandler.exposedCalculateFee(purchaseAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateFee_atUpperBound() public {
        uint256 purchaseAmount = UPPER_BOUND;
        uint256 expectedFee = purchaseAmount * MIN_FEE_RATE / BPS_DENOMINATOR;
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

    function test_calculateFeeAndNetAmounts_flatMatchesSequentialIncludingRounding() public {
        uint16 flatRate = 137;
        feeHandler.testSetFeeRateParams(flatRate, flatRate, LOWER_BOUND, UPPER_BOUND);

        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 1;
        amounts[1] = 72;
        amounts[2] = 9_999;
        amounts[3] = 10_000;
        amounts[4] = 550 ether;

        (uint256 aggregatedFee, uint256[] memory netAmounts, uint256 totalNet) =
            feeHandler.exposedCalculateFeeAndNetAmounts(amounts);

        uint256 expectedAggregatedFee;
        uint256 expectedTotalNet;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 expectedFee = amounts[i] * flatRate / BPS_DENOMINATOR;
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

    function test_transferFee_transfersWhenNonZero() public {
        MockStablecoin token = new MockStablecoin(address(this));
        uint256 fee = 1 ether;
        token.mint(address(feeHandler), fee);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(feeHandler), FEE_COLLECTOR, fee);
        feeHandler.exposedTransferFee(token, fee);
        assertEq(token.balanceOf(FEE_COLLECTOR), fee);
    }

    function test_transferFee_zeroDoesNotTransfer() public {
        MockStablecoin token = new MockStablecoin(address(this));
        token.mint(address(feeHandler), 1 ether);
        uint256 collectorBefore = token.balanceOf(FEE_COLLECTOR);
        vm.recordLogs();
        feeHandler.exposedTransferFee(token, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = Transfer.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            if (logs[i].emitter != address(token)) continue;
            revert("Transfer emitted for a zero fee");
        }
        assertEq(token.balanceOf(FEE_COLLECTOR), collectorBefore);
        assertEq(token.balanceOf(address(feeHandler)), 1 ether);
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
            
            uint256 rate1 = fee1 * BPS_DENOMINATOR / amounts[i];
            uint256 rate2 = fee2 * BPS_DENOMINATOR / amounts[i + 1];
            
            assertGe(rate1, rate2, "Fee rate should decrease or stay equal with higher amounts");
        }
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE PACKING
    //////////////////////////////////////////////////////////////*/

    /// @dev The five logical fee fields live in two slots. Ownable2Step owns slots 0 and 1, the
    ///      collector occupies slot 2, and all four settings fill slot 3 exactly.
    function test_feeSettingsOccupyTwoSlots() public {
        uint256 collectorSlot = uint256(vm.load(address(feeHandler), bytes32(uint256(2))));
        assertEq(address(uint160(collectorSlot)), FEE_COLLECTOR, "slot 2 does not hold the collector");
        assertEq(collectorSlot >> 160, 0, "settings spilled into the collector slot");

        uint256 settingsSlot = uint256(vm.load(address(feeHandler), bytes32(uint256(3))));
        assertEq(uint112(settingsSlot), LOWER_BOUND, "lower bound is not first in slot 3");
        assertEq(uint112(settingsSlot >> 112), UPPER_BOUND, "upper bound does not follow lower bound");
        assertEq(uint16(settingsSlot >> 224), MIN_FEE_RATE, "minFeeRate does not follow the bounds");
        assertEq(uint16(settingsSlot >> 240), MAX_FEE_RATE, "maxFeeRate does not finish slot 3");

        assertEq(uint256(vm.load(address(feeHandler), bytes32(uint256(4)))), 0, "fee state spilled into a third slot");
    }

    function test_setFeeRateParams_castsIntoThePackedWidths() public {
        uint256 newLower = 200 ether;
        uint256 newUpper = 2000 ether;
        feeHandler.setFeeRateParams(150, 300, newLower, newUpper);

        IFeeHandler.FeeSettings memory settings = feeHandler.getFeeSettings();
        assertEq(settings.minFeeRate, 150);
        assertEq(settings.maxFeeRate, 300);
        assertEq(settings.feePurchaseLowerBound, newLower);
        assertEq(settings.feePurchaseUpperBound, newUpper);

        uint256 collectorSlot = uint256(vm.load(address(feeHandler), bytes32(uint256(2))));
        assertEq(address(uint160(collectorSlot)), FEE_COLLECTOR, "writing settings disturbed the collector");
    }

    function test_setFeeRateParams_revertsOnUncastableRate() public {
        uint256 overflowing = uint256(type(uint16).max) + 1;
        // The cap check fires first: nothing above 500 can reach the uint16 write.
        vm.expectRevert(IFeeHandler.FeeHandler__MaxFeeRateExceedsCap.selector);
        feeHandler.setFeeRateParams(MIN_FEE_RATE, overflowing, LOWER_BOUND, UPPER_BOUND);
    }

    function test_setFeeRateParams_revertsOnUncastableBound() public {
        uint256 overflowing = uint256(type(uint112).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 112, overflowing)
        );
        feeHandler.setFeeRateParams(MIN_FEE_RATE, MAX_FEE_RATE, LOWER_BOUND, overflowing);
    }
}
