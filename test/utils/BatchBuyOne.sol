// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";

// A schedule id no test schedule can hold: ids are the creation nonce, handed out from 1 upwards
// (R50), so the top of the range is free for "this id belongs to no schedule" assertions.
uint64 constant UNUSED_SCHEDULE_ID = type(uint64).max;

// The caller minimum that reproduces pre-R51 behavior: the handler's own floor is the only bound.
uint256 constant NO_MIN_RBTC_OUT = 0;

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
    uint64 scheduleId,
    uint256 purchaseAmount,
    uint256 routeIndex
) {
    batchBuyOne(dcaManager, buyer, token, scheduleIndex, scheduleId, purchaseAmount, routeIndex, NO_MIN_RBTC_OUT);
}

/**
 * @notice `batchBuyOne` with an explicit caller minimum (R51).
 */
function batchBuyOne(
    IDcaManager dcaManager,
    address buyer,
    address token,
    uint256 scheduleIndex,
    uint64 scheduleId,
    uint256 purchaseAmount,
    uint256 routeIndex,
    uint256 minRbtcOut
) {
    address[] memory buyers = new address[](1);
    uint256[] memory scheduleIndexes = new uint256[](1);
    uint64[] memory scheduleIds = new uint64[](1);
    uint256[] memory purchaseAmounts = new uint256[](1);
    buyers[0] = buyer;
    scheduleIndexes[0] = scheduleIndex;
    scheduleIds[0] = scheduleId;
    purchaseAmounts[0] = purchaseAmount;
    dcaManager.batchBuyRbtc(
        toBatch(buyers, token, scheduleIndexes, scheduleIds, purchaseAmounts, routeIndex, minRbtcOut)
    );
}

/**
 * @notice Pack the parallel arrays `DcaManager.batchBuyRbtc` used to take into one `Batch`.
 * @dev Leaves `minRbtcOut` at `NO_MIN_RBTC_OUT`, which is the pre-R51 behavior every caller of this
 *      arity was written against. Use the eight-argument form to exercise the caller minimum.
 */
function toBatch(
    address[] memory buyers,
    address token,
    uint256[] memory scheduleIndexes,
    uint64[] memory scheduleIds,
    uint256[] memory purchaseAmounts,
    uint256 routeIndex
) pure returns (IDcaManager.Batch memory batch) {
    return toBatch(buyers, token, scheduleIndexes, scheduleIds, purchaseAmounts, routeIndex, NO_MIN_RBTC_OUT);
}

/**
 * @notice `toBatch` with an explicit per-batch minimum rBTC output (R51).
 */
function toBatch(
    address[] memory buyers,
    address token,
    uint256[] memory scheduleIndexes,
    uint64[] memory scheduleIds,
    uint256[] memory purchaseAmounts,
    uint256 routeIndex,
    uint256 minRbtcOut
) pure returns (IDcaManager.Batch memory batch) {
    batch.buyers = buyers;
    batch.token = token;
    batch.scheduleIndexes = scheduleIndexes;
    batch.scheduleIds = scheduleIds;
    batch.purchaseAmounts = purchaseAmounts;
    batch.routeIndex = routeIndex;
    batch.minRbtcOut = minRbtcOut;
}

/**
 * @notice Handler-level counterpart: the length-1 batch that replaced `PurchaseRbtc.buyRbtc`.
 */
function handlerBatchBuyOne(IPurchaseRbtc handler, address buyer, uint64 scheduleId, uint256 purchaseAmount) {
    handlerBatchBuyOne(handler, buyer, scheduleId, purchaseAmount, NO_MIN_RBTC_OUT);
}

/**
 * @notice `handlerBatchBuyOne` with an explicit caller minimum (R51).
 */
function handlerBatchBuyOne(
    IPurchaseRbtc handler,
    address buyer,
    uint64 scheduleId,
    uint256 purchaseAmount,
    uint256 minRbtcOut
) {
    address[] memory buyers = new address[](1);
    uint64[] memory scheduleIds = new uint64[](1);
    uint256[] memory purchaseAmounts = new uint256[](1);
    buyers[0] = buyer;
    scheduleIds[0] = scheduleId;
    purchaseAmounts[0] = purchaseAmount;
    handler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts, minRbtcOut);
}
