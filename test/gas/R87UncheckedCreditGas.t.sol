// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {PurchaseRbtcHarness} from "test/unit/PurchaseRbtcTest.t.sol";
import {NO_MIN_RBTC_OUT} from "test/utils/BatchBuyOne.sol";

/**
 * @title R87UncheckedCreditGas
 * @notice Pins that `_creditRbtc`'s unchecked add still credits correctly; logs Foundry gas.
 * @dev Reproduce:
 *
 *          forge test --match-path test/gas/R87UncheckedCreditGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R87UncheckedCreditGas.t.sol -vv
 *
 *      The overflow check itself is ~45 Foundry gas; Rootstock compute is in that ballpark. The
 *      accepted bound is Rootstock native supply (~2^85 wei) << uint256.
 */
contract R87UncheckedCreditGasTest is Test {
    uint16 internal constant FLAT_FEE_RATE = 100;
    uint256 internal constant RBTC_OUT = 1 ether;
    uint256 internal constant GROSS = 100 ether;

    address internal buyer = address(0xA11CE);
    MockStablecoin internal token;
    PurchaseRbtcHarness internal harness;

    function setUp() public {
        token = new MockStablecoin(address(this));
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: FLAT_FEE_RATE,
            maxFeeRate: FLAT_FEE_RATE,
            feePurchaseLowerBound: 1000 ether,
            feePurchaseUpperBound: 100_000 ether
        });
        harness = new PurchaseRbtcHarness(address(this), address(token), address(0xFEE), feeSettings, address(this));
        token.mint(address(harness), 1_000_000 ether);
        harness.setRbtcOut(RBTC_OUT);
        vm.deal(address(harness), 20 * RBTC_OUT);
    }

    function test_gas_uncheckedCreditStillAccumulates() public {
        address[] memory buyers = new address[](1);
        buyers[0] = buyer;
        uint64[] memory scheduleIds = new uint64[](1);
        scheduleIds[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = GROSS;

        uint256 gasBefore = gasleft();
        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Foundry gas length-1 batch with unchecked credit:", gasUsed);
        assertEq(harness.getAccumulatedRbtcBalance(buyer), RBTC_OUT);

        harness.batchBuyRbtc(buyers, scheduleIds, amounts, NO_MIN_RBTC_OUT);
        assertEq(harness.getAccumulatedRbtcBalance(buyer), 2 * RBTC_OUT);
    }
}
