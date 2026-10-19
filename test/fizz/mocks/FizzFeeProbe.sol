// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseFees} from "src/PurchaseFees.sol";

/**
 * @title FizzFeeProbe
 * @notice Exposes `PurchaseFees._calculateFeeAndNetWeights` so the fee curve can be checked against
 *         docs/PURCHASE_FEES.md without running a purchase (H4, SP-76/77).
 * @dev Owner is the FuzzTester (`admin`), so `probe_feeCurve` calls `setFeeRateParams` directly.
 */
contract FizzFeeProbe is PurchaseFees {
    constructor(address feeCollector, FeeSettings memory feeSettings, address initialOwner)
        PurchaseFees(feeCollector, feeSettings, initialOwner)
    {}

    function calc(uint256[] memory purchaseAmounts)
        external
        view
        returns (uint256 totalFee, uint256[] memory netWeights, uint256 purchaseAmountsSum)
    {
        return _calculateFeeAndNetWeights(purchaseAmounts);
    }
}
