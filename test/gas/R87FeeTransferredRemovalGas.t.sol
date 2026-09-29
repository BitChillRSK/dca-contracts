// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

/**
 * @title R87FeeTransferredRemovalGas
 * @notice Historical pin for dropping `PurchaseFees__FeeTransferred` while fees were a stablecoin
 *         `Transfer`. R107 re-adds that event (native MoC payments have no ERC-20 log) and pays
 *         rBTC / WRBTC, so the old ERC-20 baseline no longer compiles against production.
 */
contract R87FeeTransferredRemovalGasTest is Test {
    function test_r107SupersedesTheFeeTransferredRemovalPin() public pure {}
}
