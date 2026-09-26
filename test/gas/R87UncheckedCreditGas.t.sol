// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";

/**
 * @title R87UncheckedCreditGas
 * @notice Old-vs-new accumulated-rBTC encoding add: checked baseline vs production `unchecked`.
 * @dev Reproduce:
 *
 *          forge test --match-path test/gas/R87UncheckedCreditGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R87UncheckedCreditGas.t.sol -vv
 *
 *      Isolates the add inside `_creditRbtc` (live encoding `claimable + 1`). Warm re-credit onto a
 *      nonzero slot is the production case. Foundry saving is tens of gas; Rootstock compute for the
 *      same arithmetic is in that ballpark. The overflow bound is Rootstock native supply (~2^85 wei).
 */
contract R87UncheckedCreditGasTest is Test {
    uint256 internal constant AMOUNT = 1 ether;
    address internal constant BUYER = address(0xA11CE);

    CheckedCreditHarness internal checked;
    UncheckedCreditHarness internal uncheckedAdd;

    function setUp() public {
        checked = new CheckedCreditHarness();
        uncheckedAdd = new UncheckedCreditHarness();
        // Warm both slots onto a live encoding so the measured call is nonzero→nonzero.
        checked.credit(BUYER, AMOUNT);
        uncheckedAdd.credit(BUYER, AMOUNT);
    }

    function test_gas_uncheckedCreditSavesOverflowCheck() public {
        uint256 snap = vm.snapshot();

        uint256 gasUncheckedBefore = gasleft();
        uncheckedAdd.credit(BUYER, AMOUNT);
        uint256 gasUnchecked = gasUncheckedBefore - gasleft();
        assertEq(uncheckedAdd.raw(BUYER), 1 + 2 * AMOUNT, "unchecked encoding");

        vm.revertTo(snap);

        uint256 gasCheckedBefore = gasleft();
        checked.credit(BUYER, AMOUNT);
        uint256 gasChecked = gasCheckedBefore - gasleft();
        assertEq(checked.raw(BUYER), 1 + 2 * AMOUNT, "checked encoding");

        uint256 saving = gasChecked - gasUnchecked;
        console2.log("Foundry gas checked credit add:", gasChecked);
        console2.log("Foundry gas unchecked credit add:", gasUnchecked);
        console2.log("Foundry saving:", saving);
        assertGt(gasChecked, gasUnchecked, "checked add should cost more");
        assertLt(saving, 200, "saving larger than an overflow check; harness drifted");
        // ~45 was the decision estimate; via-IR can shrink the checked path further.
        assertApproxEqAbs(saving, 45, 50, "unchecked-add Foundry saving drifted");
        assertGt(saving, 0);
    }
}

/// @dev Pre-removal shape: checked add on `(stored == 0 ? 1 : stored) + amount`.
contract CheckedCreditHarness {
    mapping(address => uint256) private s_usersAccumulatedRbtc;

    function credit(address buyer, uint256 amount) external {
        uint256 stored = s_usersAccumulatedRbtc[buyer];
        s_usersAccumulatedRbtc[buyer] = (stored == 0 ? 1 : stored) + amount;
    }

    function raw(address buyer) external view returns (uint256) {
        return s_usersAccumulatedRbtc[buyer];
    }
}

/// @dev Production shape after R87.
contract UncheckedCreditHarness {
    mapping(address => uint256) private s_usersAccumulatedRbtc;

    function credit(address buyer, uint256 amount) external {
        uint256 stored = s_usersAccumulatedRbtc[buyer];
        unchecked {
            s_usersAccumulatedRbtc[buyer] = (stored == 0 ? 1 : stored) + amount;
        }
    }

    function raw(address buyer) external view returns (uint256) {
        return s_usersAccumulatedRbtc[buyer];
    }
}
