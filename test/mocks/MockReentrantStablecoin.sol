// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

interface ITransferFromHook {
    function onTransferFrom(address from, address to, uint256 amount) external;
}

/// @notice ERC20 whose `transferFrom` can callback the `from` address before moving balances.
/// @dev One-shot: the hook is cleared before the callback so a later `transferFrom` (e.g. kToken mint) does not reenter.
contract MockReentrantStablecoin is ERC20, ERC20Permit {
    address public hookTarget;
    bool public hookEnabled;

    constructor() ERC20("ReentrantStablecoin", "RSTC") ERC20Permit("ReentrantStablecoin") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(address target, bool enabled) external {
        hookTarget = target;
        hookEnabled = enabled;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (hookEnabled && from == hookTarget) {
            hookEnabled = false;
            ITransferFromHook(from).onTransferFrom(from, to, amount);
        }
        return super.transferFrom(from, to, amount);
    }
}
