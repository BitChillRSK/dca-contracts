// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";

// A schedule id no test schedule can hold: ids are the creation nonce, handed out from 1 upwards
// (R50), so the top of the range is free for "this id belongs to no schedule" assertions.
uint64 constant UNUSED_SCHEDULE_ID = type(uint64).max;

// The caller minimum that reproduces pre-R51 behavior: the handler's own floor is the only bound.
uint256 constant NO_MIN_RBTC_OUT_RATE = 0;

/**
 * @notice Pack one `Batch.rows` element (R66): schedule id in the high 64 bits, the swapper's expected
 *         `purchaseAmount` in the low 96 bits.
 * @dev Every helper in this file is `pure`: none of them read `dcaManager`, on purpose. A row's
 *      `expectedPurchaseAmount` is what the swapper knew when it composed the batch, which a test must
 *      state explicitly (a constant, a value it already holds from an earlier read, or the deliberately
 *      stale amount a front-running test wants to name) rather than have a helper re-fetch it live. A
 *      re-fetching helper would also make an external `view` call before the real purchase call, which
 *      silently steals a single-shot `vm.prank` / `vm.expectRevert` a caller armed for the purchase
 *      itself — build the `Batch` first, then arm the cheatcode, then call `batchBuyRbtc` directly.
 */
function packBatchRow(uint64 scheduleId, uint96 expectedPurchaseAmount) pure returns (bytes32) {
    return bytes32((uint256(scheduleId) << 96) | uint256(expectedPurchaseAmount));
}

/**
 * @notice Build the length-1 `Batch` that replaced the removed single-schedule `DcaManager.buyRbtc`
 *         (R39), naming the row's expected purchase amount explicitly (R66).
 */
function batchOf(address token, uint64 scheduleId, uint96 expectedPurchaseAmount, uint256 routeIndex)
    pure
    returns (IDcaManager.Batch memory)
{
    return batchOf(token, scheduleId, expectedPurchaseAmount, routeIndex, NO_MIN_RBTC_OUT_RATE);
}

/**
 * @notice `batchOf` with an explicit caller minimum rate (R51, reinterpreted as a rate by R66).
 */
function batchOf(
    address token,
    uint64 scheduleId,
    uint96 expectedPurchaseAmount,
    uint256 routeIndex,
    uint256 minRbtcOutRate
) pure returns (IDcaManager.Batch memory) {
    bytes32[] memory rows = new bytes32[](1);
    rows[0] = packBatchRow(scheduleId, expectedPurchaseAmount);
    return toBatch(rows, token, routeIndex, minRbtcOutRate);
}

/**
 * @notice Pack the parallel arrays `DcaManager.batchBuyRbtc` used to take into one `Batch`.
 * @dev Leaves `minRbtcOutRate` at `NO_MIN_RBTC_OUT_RATE`, which is the pre-R51 behavior every caller of
 *      this arity was written against. Use the four-argument form to exercise the caller minimum.
 */
function toBatch(bytes32[] memory rows, address token, uint256 routeIndex)
    pure
    returns (IDcaManager.Batch memory batch)
{
    return toBatch(rows, token, routeIndex, NO_MIN_RBTC_OUT_RATE);
}

/**
 * @notice `toBatch` with an explicit per-batch minimum rBTC output rate (R51, R66).
 */
function toBatch(bytes32[] memory rows, address token, uint256 routeIndex, uint256 minRbtcOutRate)
    pure
    returns (IDcaManager.Batch memory batch)
{
    batch.rows = rows;
    batch.token = token;
    batch.routeIndex = routeIndex;
    batch.minRbtcOutRate = minRbtcOutRate;
}

/**
 * @notice Pack a `Batch.rows` array from parallel id/expected-amount arrays.
 */
function packRows(uint64[] memory scheduleIds, uint96[] memory expectedPurchaseAmounts)
    pure
    returns (bytes32[] memory rows)
{
    uint256 numOfRows = scheduleIds.length;
    rows = new bytes32[](numOfRows);
    for (uint256 i; i < numOfRows; ++i) {
        rows[i] = packBatchRow(scheduleIds[i], expectedPurchaseAmounts[i]);
    }
}

/**
 * @notice Handler-level counterpart: the length-1 batch that replaced `PurchaseRbtc.buyRbtc`.
 */
function handlerBatchBuyOne(IPurchaseRbtc handler, address buyer, uint64 scheduleId, uint256 purchaseAmount) {
    handlerBatchBuyOne(handler, buyer, scheduleId, purchaseAmount, NO_MIN_RBTC_OUT_RATE);
}

/**
 * @notice `handlerBatchBuyOne` with an explicit caller minimum rate (R51, R66).
 */
function handlerBatchBuyOne(
    IPurchaseRbtc handler,
    address buyer,
    uint64 scheduleId,
    uint256 purchaseAmount,
    uint256 minRbtcOutRate
) {
    address[] memory buyers = new address[](1);
    uint64[] memory scheduleIds = new uint64[](1);
    uint256[] memory purchaseAmounts = new uint256[](1);
    buyers[0] = buyer;
    scheduleIds[0] = scheduleId;
    purchaseAmounts[0] = purchaseAmount;
    handler.batchBuyRbtc(buyers, scheduleIds, purchaseAmounts, minRbtcOutRate);
}
