// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {scheduleCount} from "test/utils/ScheduleAt.sol";

/**
 * @notice One schedule by its position in an owner's list for a token.
 * @dev R64 made `(token, scheduleId)` the only way to address a schedule, so `DcaManager` no longer
 *      exposes a by-position read. Tests that were written against positions keep using them through
 *      this helper rather than being rewritten to carry ids: what they assert is the schedule's
 *      contents, not how it was reached. Reverts on an out-of-range position, which is what the removed
 *      `getDcaSchedule(user, token, index)` did.
 */
function scheduleAt(IDcaManager dcaManager, address user, address token, uint256 scheduleIndex)
    view
    returns (IDcaManager.DcaSchedule memory)
{
    (, IDcaManager.DcaSchedule[] memory schedules) = dcaManager.getDcaSchedules(user, token);
    return schedules[scheduleIndex];
}

/**
 * @notice The id of the schedule at a position in an owner's list for a token.
 * @dev The id is no longer a field of the schedule — it is half of the key that addresses it — so it
 *      comes from the parallel array `getDcaSchedules` returns beside the structs.
 */
function scheduleIdAt(IDcaManager dcaManager, address user, address token, uint256 scheduleIndex)
    view
    returns (uint64)
{
    (uint64[] memory scheduleIds,) = dcaManager.getDcaSchedules(user, token);
    return scheduleIds[scheduleIndex];
}

/**
 * @notice How many schedules an owner holds for a token.
 */
function scheduleCount(IDcaManager dcaManager, address user, address token) view returns (uint256) {
    (uint64[] memory scheduleIds,) = dcaManager.getDcaSchedules(user, token);
    return scheduleIds.length;
}
