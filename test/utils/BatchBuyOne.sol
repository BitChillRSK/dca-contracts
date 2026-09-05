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
 *      R64 made a row a bare `scheduleId`, keyed by the batch's own token, and dropped both the
 *      per-row buyer and the per-row amount: the manager reads from the schedule who is buying and
 *      what it spends, so there is nothing else to pass.
 */
function batchBuyOne(IDcaManager dcaManager, address token, uint64 scheduleId, uint256 routeIndex) {
    batchBuyOne(dcaManager, token, scheduleId, routeIndex, NO_MIN_RBTC_OUT);
}

/**
 * @notice `batchBuyOne` with an explicit caller minimum (R51).
 */
function batchBuyOne(
    IDcaManager dcaManager,
    address token,
    uint64 scheduleId,
    uint256 routeIndex,
    uint256 minRbtcOut
) {
    uint64[] memory scheduleIds = new uint64[](1);
    scheduleIds[0] = scheduleId;
    dcaManager.batchBuyRbtc(toBatch(scheduleIds, token, routeIndex, minRbtcOut));
}

/**
 * @notice Pack the parallel arrays `DcaManager.batchBuyRbtc` used to take into one `Batch`.
 * @dev Leaves `minRbtcOut` at `NO_MIN_RBTC_OUT`, which is the pre-R51 behavior every caller of this
 *      arity was written against. Use the five-argument form to exercise the caller minimum.
 */
function toBatch(uint64[] memory scheduleIds, address token, uint256 routeIndex)
    pure
    returns (IDcaManager.Batch memory batch)
{
    return toBatch(scheduleIds, token, routeIndex, NO_MIN_RBTC_OUT);
}

/**
 * @notice `toBatch` with an explicit per-batch minimum rBTC output (R51).
 */
function toBatch(uint64[] memory scheduleIds, address token, uint256 routeIndex, uint256 minRbtcOut)
    pure
    returns (IDcaManager.Batch memory batch)
{
    batch.scheduleIds = scheduleIds;
    batch.token = token;
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
