// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice ERC20 that takes a fee on `transfer` and `transferFrom`. Recipient gets `amount - fee`.
/// @dev Models a fee-on-transfer stablecoin. DOC/USDRIF are not FOT; this is for deposit-accounting tests.
contract MockFeeOnTransferStablecoin is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public constant BPS_DIVISOR = 10_000;

    uint256 public feeBps;
    address public feeRecipient;

    constructor() ERC20("FeeOnTransferStablecoin", "FOT") ERC20Permit("FeeOnTransferStablecoin") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeBps(uint256 feeBps_) external {
        require(feeBps_ <= BPS_DIVISOR, "Fee above 100%");
        feeBps = feeBps_;
    }

    function setFeeRecipient(address feeRecipient_) external {
        feeRecipient = feeRecipient_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transferWithFee(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        _transferWithFee(from, to, amount);
        return true;
    }

    function _transferWithFee(address from, address to, uint256 amount) private {
        uint256 fee = amount * feeBps / BPS_DIVISOR;
        _transfer(from, to, amount - fee);
        if (fee > 0) {
            if (feeRecipient == address(0)) _burn(from, fee);
            else _transfer(from, feeRecipient, fee);
        }
    }
}
