// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {MockStablecoin} from "./MockStablecoin.sol";

/**
 * @notice A `MockStablecoin` whose `decimals()` is chosen at deploy time.
 * @dev Exists so the Dex min-out math can be exercised against the shape of a 6-decimal stablecoin
 *      (USDT0) as well as the 18-decimal ones (DOC, USDRIF) the rest of the suite uses.
 */
contract MockStablecoinWithDecimals is MockStablecoin {
    uint8 private immutable i_decimals;

    constructor(address initialOwner, uint8 tokenDecimals) MockStablecoin(initialOwner) {
        i_decimals = tokenDecimals;
    }

    function decimals() public view override returns (uint8) {
        return i_decimals;
    }
}
