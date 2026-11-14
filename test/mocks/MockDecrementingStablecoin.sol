// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {MockStablecoin} from "./MockStablecoin.sol";

/**
 * @title MockDecrementingStablecoin
 * @notice A stablecoin that decrements even an unbounded allowance on every `transferFrom`.
 * @dev OpenZeppelin's ERC20 treats `type(uint256).max` as infinite and skips the write; DOC and USDT0
 *      do not (measured on mainnet by `StandingApprovalProbe`). This mock is the cheap half of that
 *      split, so the deposit fallback that tops an exhausted allowance back up stays covered.
 */
contract MockDecrementingStablecoin is MockStablecoin {
    constructor(address initialOwner) MockStablecoin(initialOwner) {}

    function _spendAllowance(address owner, address spender, uint256 value) internal override {
        uint256 currentAllowance = allowance(owner, spender);
        require(currentAllowance >= value, "insufficient allowance");
        _approve(owner, spender, currentAllowance - value, false);
    }
}
