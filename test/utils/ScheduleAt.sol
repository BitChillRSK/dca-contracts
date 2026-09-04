// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDcaManager} from "src/interfaces/IDcaManager.sol";

/**
 * @notice One schedule by its position in an owner's list for a token.
 * @dev R64 made `scheduleId` the only way to address a schedule, so `DcaManager` no longer exposes a
 *      by-position read. Tests that were written against positions keep using them through this helper
 *      rather than being rewritten to carry ids: what they are asserting is the schedule's contents,
 *      not how it was reached. Reverts on an out-of-range position, which is what the removed
 *      `getDcaSchedule(user, token, index)` did.
 */
function scheduleAt(IDcaManager dcaManager, address user, address token, uint256 scheduleIndex)
    view
    returns (IDcaManager.DcaSchedule memory)
{
    return dcaManager.getDcaSchedules(user, token)[scheduleIndex];
}

/**
 * @notice The id of the schedule at a position in an owner's list for a token.
 */
function scheduleIdAt(IDcaManager dcaManager, address user, address token, uint256 scheduleIndex)
    view
    returns (uint64)
{
    return scheduleAt(dcaManager, user, token, scheduleIndex).scheduleId;
}
