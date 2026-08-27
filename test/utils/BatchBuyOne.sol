// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";

/**
 * @notice Build the length-1 `batchBuyRbtc` that replaced the removed single-schedule
 *         `DcaManager.buyRbtc` (R39).
 * @dev Free function, so no external call happens between the caller's `vm.prank` and
 *      `batchBuyRbtc`: a prank placed immediately before this helper still applies to the batch.
 */
function batchBuyOne(
    IDcaManager dcaManager,
    address buyer,
    address token,
    uint256 scheduleIndex,
    bytes32 scheduleId,
    uint256 purchaseAmount,
    uint256 routeIndex
) {
    address[] memory buyers = new address[](1);
    uint256[] memory scheduleIndexes = new uint256[](1);
    bytes32[] memory scheduleIds = new bytes32[](1);
    uint256[] memory purchaseAmounts = new uint256[](1);
    buyers[0] = buyer;
    scheduleIndexes[0] = scheduleIndex;
    scheduleIds[0] = scheduleId;
    purchaseAmounts[0] = purchaseAmount;
    dcaManager.batchBuyRbtc(buyers, token, scheduleIndexes, scheduleIds, purchaseAmounts, routeIndex);
}

/**
 * @notice Handler-level counterpart: the length-1 batch that replaced `PurchaseRbtc.buyRbtc`.
 */
function handlerBatchBuyOne(IPurchaseRbtc handler, address buyer, bytes32 scheduleId, uint256 purchaseAmount) {
    address[] memory buyers = new address[](1);
    bytes32[] memory scheduleIds = new bytes32[](1);
    uint256[] memory purchaseAmounts = new uint256[](1);
    buyers[0] = buyer;
    scheduleIds[0] = scheduleId;
    purchaseAmounts[0] = purchaseAmount;
    handler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts);
}
