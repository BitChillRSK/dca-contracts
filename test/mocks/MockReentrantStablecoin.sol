// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

interface ITransferHook {
    function onTransferFrom(address from, address to, uint256 amount) external;
    function onTransferReceived(address from, uint256 amount) external;
}

/**
 * @notice ERC20 that can call back its hook target before moving balances: on `transferFrom` when the
 *         target is the sender, and on `transfer` when it is the recipient.
 * @dev One-shot: the hook is cleared before the callback so a later transfer (e.g. kToken mint) does not reenter.
 */
contract MockReentrantStablecoin is ERC20, ERC20Permit {
    address public hookTarget;
    bool public hookEnabled;

    constructor() ERC20("ReentrantStablecoin", "RSTC") ERC20Permit("ReentrantStablecoin") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev `MockMocProxy` burns the DOC it redeems.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function setHook(address target, bool enabled) external {
        hookTarget = target;
        hookEnabled = enabled;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (hookEnabled && from == hookTarget) {
            hookEnabled = false;
            ITransferHook(from).onTransferFrom(from, to, amount);
        }
        return super.transferFrom(from, to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (hookEnabled && to == hookTarget) {
            hookEnabled = false;
            ITransferHook(to).onTransferReceived(msg.sender, amount);
        }
        return super.transfer(to, amount);
    }
}
