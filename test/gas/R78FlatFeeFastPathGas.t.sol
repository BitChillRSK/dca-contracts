// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {FeeHandler} from "src/FeeHandler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";

contract R78OptimizedFeeHandlerGasHarness is FeeHandler {
    constructor(IFeeHandler.FeeSettings memory feeSettings) FeeHandler(address(0xFEE), feeSettings, msg.sender) {}

    function measure(uint256[] calldata purchaseAmounts)
        external
        view
        returns (uint256 gasUsed, uint256 aggregatedFee, uint256 totalAmountToSpend, bytes32 netAmountsHash)
    {
        uint256[] memory amounts = purchaseAmounts;
        uint256[] memory netAmounts;
        uint256 gasBefore = gasleft();
        (aggregatedFee, netAmounts, totalAmountToSpend) = _calculateFeeAndNetAmounts(amounts);
        gasUsed = gasBefore - gasleft();
        netAmountsHash = keccak256(abi.encode(netAmounts));
    }
}

contract R78BaselineFeeHandlerGasHarness is FeeHandler {
    constructor(IFeeHandler.FeeSettings memory feeSettings) FeeHandler(address(0xFEE), feeSettings, msg.sender) {}

    function measure(uint256[] calldata purchaseAmounts)
        external
        view
        returns (uint256 gasUsed, uint256 aggregatedFee, uint256 totalAmountToSpend, bytes32 netAmountsHash)
    {
        uint256[] memory amounts = purchaseAmounts;
        uint256[] memory netAmounts;
        uint256 gasBefore = gasleft();
        (aggregatedFee, netAmounts, totalAmountToSpend) = _baselineCalculateFeeAndNetAmounts(amounts);
        gasUsed = gasBefore - gasleft();
        netAmountsHash = keccak256(abi.encode(netAmounts));
    }

    /// @dev The generic loop mirrors the private production curve against the same packed settings
    ///      layout. Its separate harness keeps reference code from changing optimized code generation.
    function _baselineCalculateFeeAndNetAmounts(uint256[] memory purchaseAmounts)
        private
        view
        returns (uint256 aggregatedFee, uint256[] memory netAmountsToSpend, uint256 totalAmountToSpend)
    {
        uint256 len = purchaseAmounts.length;
        netAmountsToSpend = new uint256[](len);
        FeeSettings memory feeSettings = FeeSettings({
            minFeeRate: s_minFeeRate,
            maxFeeRate: s_maxFeeRate,
            feePurchaseLowerBound: s_feePurchaseLowerBound,
            feePurchaseUpperBound: s_feePurchaseUpperBound
        });

        for (uint256 i; i < len; ++i) {
            uint256 amount = purchaseAmounts[i];
            uint256 fee = _baselineCalculateVariableFee(
                amount,
                feeSettings.minFeeRate,
                feeSettings.maxFeeRate,
                feeSettings.feePurchaseLowerBound,
                feeSettings.feePurchaseUpperBound
            );
            aggregatedFee += fee;
            uint256 net;
            unchecked {
                net = amount - fee;
            }
            netAmountsToSpend[i] = net;
            totalAmountToSpend += net;
        }
    }

    /// @dev Test-only reference copy because the production curve is deliberately private.
    function _baselineCalculateVariableFee(
        uint256 purchaseAmount,
        uint256 minFeeRate,
        uint256 maxFeeRate,
        uint256 feePurchaseLowerBound,
        uint256 feePurchaseUpperBound
    ) private pure returns (uint256) {
        if (purchaseAmount >= feePurchaseUpperBound) {
            return _baselineCalculateFeeAtRate(purchaseAmount, minFeeRate);
        }

        if (purchaseAmount <= feePurchaseLowerBound) {
            return _baselineCalculateFeeAtRate(purchaseAmount, maxFeeRate);
        }

        uint256 feeRate;
        unchecked {
            feeRate = maxFeeRate
                - ((purchaseAmount - feePurchaseLowerBound)
                    * (maxFeeRate - minFeeRate))
                    / (feePurchaseUpperBound - feePurchaseLowerBound);
        }
        return _baselineCalculateFeeAtRate(purchaseAmount, feeRate);
    }

    function _baselineCalculateFeeAtRate(uint256 amount, uint256 feeRate) private pure returns (uint256) {
        return amount * feeRate / BPS_DENOMINATOR;
    }
}

/**
 * @title R78FlatFeeFastPathGas
 * @notice Compares the generic fee loop with the flat-fee batch fast path in the same build.
 * @dev Reproduce with both:
 *
 *          forge test --match-path test/gas/R78FlatFeeFastPathGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R78FlatFeeFastPathGas.t.sol -vv
 *
 *      Both variants load the same one-word settings layout. Their delta contains only compute and
 *      memory work, whose pricing is the same on Foundry / Cancun and Rootstock.
 */
contract R78FlatFeeFastPathGasTest is Test {
    uint16 internal constant FLAT_FEE_RATE = 100;

    R78OptimizedFeeHandlerGasHarness internal optimizedHarness;
    R78OptimizedFeeHandlerGasHarness internal variableOptimizedHarness;
    R78BaselineFeeHandlerGasHarness internal baselineHarness;
    R78BaselineFeeHandlerGasHarness internal variableBaselineHarness;

    function setUp() public {
        IFeeHandler.FeeSettings memory settings = IFeeHandler.FeeSettings({
            minFeeRate: FLAT_FEE_RATE,
            maxFeeRate: FLAT_FEE_RATE,
            feePurchaseLowerBound: 1000 ether,
            feePurchaseUpperBound: 100_000 ether
        });
        optimizedHarness = new R78OptimizedFeeHandlerGasHarness(settings);
        baselineHarness = new R78BaselineFeeHandlerGasHarness(settings);

        settings.minFeeRate = 100;
        settings.maxFeeRate = 200;
        settings.feePurchaseLowerBound = 100 ether;
        settings.feePurchaseUpperBound = 1000 ether;
        variableOptimizedHarness = new R78OptimizedFeeHandlerGasHarness(settings);
        variableBaselineHarness = new R78BaselineFeeHandlerGasHarness(settings);
    }

    function test_gas_flatOneRowFastPath() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;
        _assertSaving(amounts, "one-row");
    }

    function test_gas_flatFiveRowFastPath() public {
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 1;
        amounts[1] = 9_999;
        amounts[2] = 50 ether;
        amounts[3] = 550 ether;
        amounts[4] = 2000 ether;
        _assertSaving(amounts, "five-row");
    }

    function test_gas_flatHundredRowFastPath() public {
        uint256[] memory amounts = new uint256[](100);
        for (uint256 i; i < amounts.length; ++i) {
            amounts[i] = (i + 1) * 1 ether;
        }
        _assertSaving(amounts, "hundred-row");
    }

    function test_gas_variableOneRowFullCurve() public {
        _logVariableGas(1, "variable one-row full curve");
    }

    function test_gas_variableFiveRowsFullCurve() public {
        _logVariableGas(5, "variable five-row full curve");
    }

    function test_gas_variableHundredRowsFullCurve() public {
        _logVariableGas(100, "variable hundred-row full curve");
    }

    function testFuzz_optimizedMatchesBaseline(uint96[5] memory fuzzedAmounts) public {
        uint256[] memory amounts = new uint256[](fuzzedAmounts.length);
        for (uint256 i; i < fuzzedAmounts.length; ++i) {
            amounts[i] = bound(uint256(fuzzedAmounts[i]), 1, 2000 ether);
        }

        _assertEquivalent(baselineHarness, optimizedHarness, amounts);
        _assertEquivalent(variableBaselineHarness, variableOptimizedHarness, amounts);
    }

    function _assertSaving(uint256[] memory amounts, string memory label) private {
        _cool(address(baselineHarness));
        (uint256 baselineGas, uint256 baselineFee, uint256 baselineNet, bytes32 baselineHash) =
            baselineHarness.measure(amounts);

        _cool(address(optimizedHarness));
        (uint256 optimizedGas, uint256 optimizedFee, uint256 optimizedNet, bytes32 optimizedHash) =
            optimizedHarness.measure(amounts);

        assertEq(optimizedFee, baselineFee, "aggregated fee changed");
        assertEq(optimizedNet, baselineNet, "aggregated net changed");
        assertEq(optimizedHash, baselineHash, "per-row net amounts changed");

        uint256 saving = baselineGas - optimizedGas;
        console2.log(label);
        console2.log("generic fee loop:", baselineGas);
        console2.log("R78 flat-fee fast path:", optimizedGas);
        console2.log("saving:", saving);
        assertGt(saving, 100, "fast path did not save compute");
        assertLt(saving, 50_000, "saving exceeded the intended fee-loop scope");
    }

    function _assertEquivalent(
        R78BaselineFeeHandlerGasHarness baseline,
        R78OptimizedFeeHandlerGasHarness optimized,
        uint256[] memory amounts
    ) private {
        (, uint256 baselineFee, uint256 baselineNet, bytes32 baselineHash) = baseline.measure(amounts);
        (, uint256 optimizedFee, uint256 optimizedNet, bytes32 optimizedHash) = optimized.measure(amounts);

        assertEq(optimizedFee, baselineFee, "aggregated fee changed");
        assertEq(optimizedNet, baselineNet, "aggregated net changed");
        assertEq(optimizedHash, baselineHash, "per-row net amounts changed");
    }

    function _logVariableGas(uint256 rows, string memory label) private {
        uint256[] memory amounts = new uint256[](rows);
        for (uint256 i; i < rows; ++i) {
            amounts[i] = 550 ether;
        }

        _cool(address(variableOptimizedHarness));
        (uint256 gasUsed,,,) = variableOptimizedHarness.measure(amounts);
        console2.log(label);
        console2.log("stack-scalar loop:", gasUsed);
    }

    /// @dev forge-std's `Vm` interface on this pin omits `cool`; the cheatcode exists on the binary.
    function _cool(address target) private {
        (bool ok,) = address(uint160(uint256(keccak256("hevm cheat code"))))
            .call(abi.encodeWithSignature("cool(address)", target));
        require(ok, "vm.cool unavailable");
    }
}
