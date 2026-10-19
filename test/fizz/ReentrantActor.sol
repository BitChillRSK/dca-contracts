// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {Actor} from "./Actor.sol";

/// @notice An actor whose `receive()` can re-enter a configured target when it is paid native rBTC.
/// @dev Deployed as `actors[2]` (H7). With `mode == 0` (the default) it behaves exactly like `Actor`.
///      `adv_claimLiveness` arms it with `arm(...)` before a claim and calls `disarm()` after.
///      The counters live here because this contract cannot write the FuzzTester's ghosts.
contract ReentrantActor is Actor {
    /// @notice 0 = inert; any other value re-enters once per payment (no nested re-entry).
    uint8 public mode;
    address public target;
    bytes public reentryData;
    bool public inReentry;
    /// @notice Re-entry calls attempted / that did not revert, since deployment.
    uint256 public attempts;
    uint256 public successes;
    /// @notice Revert data of the last failed re-entry (empty after a success).
    bytes public lastRevertData;

    constructor() payable {}

    function arm(uint8 newMode, address newTarget, bytes calldata data) external {
        mode = newMode;
        target = newTarget;
        reentryData = data;
    }

    function disarm() external {
        mode = 0;
    }

    receive() external payable override {
        if (mode == 0 || inReentry) return;
        inReentry = true;
        attempts++;
        (bool ok, bytes memory ret) = target.call(reentryData);
        if (ok) {
            successes++;
            delete lastRevertData;
        } else {
            lastRevertData = ret;
        }
        inReentry = false;
    }
}
