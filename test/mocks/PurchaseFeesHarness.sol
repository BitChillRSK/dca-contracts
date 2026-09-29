// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseFees} from "../../src/PurchaseFees.sol";
import {IPurchaseFees} from "../../src/interfaces/IPurchaseFees.sol";

contract PurchaseFeesHarness is PurchaseFees {
    constructor(address feeCollector, IPurchaseFees.FeeSettings memory settings, address initialOwner)
        PurchaseFees(feeCollector, settings, initialOwner)
    {}

    function exposedCalculateFee(uint256 amount) external view returns (uint256) {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        (uint256 fee,,) = this.exposedCalculateFeeAndNetWeights(amounts);
        return fee;
    }

    function exposedCalculateFeeAndNetWeights(uint256[] calldata purchaseAmounts)
        external
        view
        returns (uint256 totalFeeWeight, uint256[] memory netWeights, uint256 totalNetWeight)
    {
        return _calculateFeeAndNetWeights(purchaseAmounts);
    }

    // Test-only setters without onlyOwner restriction for convenience.
    // Widths match PurchaseFees storage, so a caller cannot park a value the real setters could not write.
    function testSetFeeRateParams(uint16 minFee, uint16 maxFee, uint112 lower, uint112 upper) external {
        s_minFeeRate = minFee;
        s_maxFeeRate = maxFee;
        s_feePurchaseLowerBound = lower;
        s_feePurchaseUpperBound = upper;
    }

    function testSetMinFeeRate(uint16 minFee) external {
        s_minFeeRate = minFee;
    }

    function testSetMaxFeeRate(uint16 maxFee) external {
        s_maxFeeRate = maxFee;
    }

    function testSetFeePurchaseLowerBound(uint112 lower) external {
        s_feePurchaseLowerBound = lower;
    }

    function testSetFeePurchaseUpperBound(uint112 upper) external {
        s_feePurchaseUpperBound = upper;
    }

    function exposedTransferFee(uint256 fee) external {
        _transferFee(fee);
    }
}
