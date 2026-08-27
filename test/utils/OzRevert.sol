// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @notice Exact OpenZeppelin v5 revert data for the guards this repo relies on (R44).
 * @dev v5 replaced the v4 revert strings ("Ownable: caller is not the owner",
 *      "ReentrancyGuard: reentrant call") with custom errors. These helpers keep the
 *      assertions exact — `OwnableUnauthorizedAccount` carries the rejected caller, so a
 *      test still pins *who* was refused, not merely that something reverted.
 *      Free functions so a `vm.prank` placed next to the assertion is not consumed by a call.
 */
function ownableUnauthorized(address caller) pure returns (bytes memory) {
    return abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
}

function ownableInvalidOwner(address owner) pure returns (bytes memory) {
    return abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, owner);
}

function reentrantCall() pure returns (bytes memory) {
    return abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
}
