// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FeeHandler} from "../../src/FeeHandler.sol";
import {IFeeHandler} from "../../src/interfaces/IFeeHandler.sol";

contract FeeHandlerHarness is FeeHandler {
    constructor(address feeCollector, IFeeHandler.FeeSettings memory settings, address initialOwner)
        FeeHandler(feeCollector, settings, initialOwner)
    {}

    function exposedCalculateFee(uint256 amount) external view returns (uint256) {
        return _calculateFee(amount);
    }

    function exposedCalculateFeeAndNetAmounts(uint256[] memory purchaseAmounts)
        external
        view
        returns (uint256 aggregatedFee, uint256[] memory netAmountsToSpend, uint256 totalAmountToSpend)
    {
        return _calculateFeeAndNetAmounts(purchaseAmounts);
    }

    // Test-only setters without onlyOwner restriction for convenience.
    // Widths match FeeHandler storage, so a caller cannot park a value the real setters could not write.
    function testSetFeeRateParams(uint16 minFee, uint16 maxFee, uint128 lower, uint128 upper) external {
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

    function testSetFeePurchaseLowerBound(uint128 lower) external {
        s_feePurchaseLowerBound = lower;
    }

    function testSetFeePurchaseUpperBound(uint128 upper) external {
        s_feePurchaseUpperBound = upper;
    }
}
