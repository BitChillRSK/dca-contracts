// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {FeeHandler} from "src/FeeHandler.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";

contract R78FeeHandlerGasHarness is FeeHandler {
    constructor(IFeeHandler.FeeSettings memory feeSettings) FeeHandler(address(0xFEE), feeSettings, msg.sender) {}

    function measureOptimized(uint256[] calldata purchaseAmounts)
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

    function measureBaseline(uint256[] calldata purchaseAmounts)
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

    /// @dev The R77 implementation retained here only as a same-build gas baseline.
    function _baselineCalculateFeeAndNetAmounts(uint256[] memory purchaseAmounts)
        private
        view
        returns (uint256 aggregatedFee, uint256[] memory netAmountsToSpend, uint256 totalAmountToSpend)
    {
        uint256 len = purchaseAmounts.length;
        netAmountsToSpend = new uint256[](len);
        FeeSettings memory feeSettings = _feeSettings();

        for (uint256 i; i < len; ++i) {
            uint256 amount = purchaseAmounts[i];
            uint256 fee = _calculateFeeWithParams(amount, feeSettings);
            aggregatedFee += fee;
            uint256 net;
            unchecked {
                net = amount - fee;
            }
            netAmountsToSpend[i] = net;
            totalAmountToSpend += net;
        }
    }
}

/**
 * @title R78FlatFeeFastPathGas
 * @notice Compares R77's generic fee loop with the flat-fee batch fast path in the same build.
 * @dev Reproduce with both:
 *
 *          forge test --match-path test/gas/R78FlatFeeFastPathGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R78FlatFeeFastPathGas.t.sol -vv
 *
 *      Each measurement runs inside a fresh harness call. Cooling the harness before each call makes
 *      the rate and bounds slots cold, matching the first access in a handler purchase transaction.
 */
contract R78FlatFeeFastPathGasTest is Test {
    uint16 internal constant FLAT_FEE_RATE = 100;

    R78FeeHandlerGasHarness internal harness;

    function setUp() public {
        IFeeHandler.FeeSettings memory settings = IFeeHandler.FeeSettings({
            minFeeRate: FLAT_FEE_RATE,
            maxFeeRate: FLAT_FEE_RATE,
            feePurchaseLowerBound: 1000 ether,
            feePurchaseUpperBound: 100_000 ether
        });
        harness = new R78FeeHandlerGasHarness(settings);
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

    function _assertSaving(uint256[] memory amounts, string memory label) private {
        _cool(address(harness));
        (uint256 baselineGas, uint256 baselineFee, uint256 baselineNet, bytes32 baselineHash) =
            harness.measureBaseline(amounts);

        _cool(address(harness));
        (uint256 optimizedGas, uint256 optimizedFee, uint256 optimizedNet, bytes32 optimizedHash) =
            harness.measureOptimized(amounts);

        assertEq(optimizedFee, baselineFee, "aggregated fee changed");
        assertEq(optimizedNet, baselineNet, "aggregated net changed");
        assertEq(optimizedHash, baselineHash, "per-row net amounts changed");

        uint256 saving = baselineGas - optimizedGas;
        console2.log(label);
        console2.log("R77 generic fee loop:", baselineGas);
        console2.log("R78 flat-fee fast path:", optimizedGas);
        console2.log("saving:", saving);
        assertGt(saving, 1_500, "flat path did not materially save a cold storage read");
        assertLt(saving, 10_000, "saving exceeded the intended fee-loop scope");
    }

    /// @dev forge-std's `Vm` interface on this pin omits `cool`; the cheatcode exists on the binary.
    function _cool(address target) private {
        (bool ok,) = address(uint160(uint256(keccak256("hevm cheat code"))))
            .call(abi.encodeWithSignature("cool(address)", target));
        require(ok, "vm.cool unavailable");
    }
}
