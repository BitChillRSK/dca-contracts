// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FeeHandler} from "../../src/FeeHandler.sol";
import {IFeeHandler} from "../../src/interfaces/IFeeHandler.sol";

contract FeeHandlerHarness is FeeHandler {
    constructor(IFeeHandler.FeeSettings memory settings) FeeHandler(address(0xBEEF), settings) {}

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

    // Test-only setters without onlyOwner restriction for convenience
    function testSetFeeRateParams(uint256 minFee, uint256 maxFee, uint256 lower, uint256 upper) external {
        s_minFeeRate = minFee;
        s_maxFeeRate = maxFee;
        s_feePurchaseLowerBound = lower;
        s_feePurchaseUpperBound = upper;
    }

    function testSetMinFeeRate(uint256 minFee) external {
        s_minFeeRate = minFee;
    }

    function testSetMaxFeeRate(uint256 maxFee) external {
        s_maxFeeRate = maxFee;
    }

    function testSetFeePurchaseLowerBound(uint256 lower) external {
        s_feePurchaseLowerBound = lower;
    }

    function testSetFeePurchaseUpperBound(uint256 upper) external {
        s_feePurchaseUpperBound = upper;
    }
} 