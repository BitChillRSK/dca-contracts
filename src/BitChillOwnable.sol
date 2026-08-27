// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title BitChillOwnable
 * @notice Shared governance policy: two-step ownership transfer, direct initial owner, no renounce.
 * @dev OpenZeppelin `Ownable` already rejects `address(0)` at construction. Future transfers
 *      go through `Ownable2Step` (`transferOwnership` proposes, `acceptOwnership` completes).
 *      Renouncing would freeze owner-only configuration with no recovery.
 */
abstract contract BitChillOwnable is Ownable2Step {
    error BitChillOwnable__OwnershipCannotBeRenounced();

    constructor(address initialOwner) Ownable(initialOwner) {}

    /**
     * @notice Ownership cannot be renounced.
     */
    function renounceOwnership() public pure override {
        revert BitChillOwnable__OwnershipCannotBeRenounced();
    }
}
