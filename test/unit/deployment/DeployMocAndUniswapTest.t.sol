// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeployMocAndUniswap} from "script/DeployMocAndUniswap.s.sol";
import {DcaManager} from "src/DcaManager.sol";
import "test/Constants.sol";

/**
 * @notice Catches the DeployMocAndUniswap ownership footgun that ComparePurchaseMethods
 *         would see on a fork but that suite is excluded from `make check` / `make fork-*`.
 * @dev Requires a lending protocol with MoC + Dex share tokens (sovryn or tropykus). Other
 *      `make check` lanes skip — the script reverts `Unsupported lending protocol` for none/layerbank.
 */
contract DeployMocAndUniswapTest is Test {
    function test_run_setsTokenMinsUnderOwnerBroadcast() public {
        if (block.chainid != ANVIL_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        // Both stacks share STABLECOIN_TYPE; MoC+Sovryn rejects USDRIF/USDT0, and the Dex live map
        // rejects DOC. This harness only works for DOC on a lending lane that has MoC shares.
        if (
            keccak256(abi.encodePacked(vm.envOr("STABLECOIN_TYPE", DOC_STRING)))
                != keccak256(abi.encodePacked(DOC_STRING))
        ) {
            vm.skip(true);
            return;
        }
        string memory protocol = vm.envOr("LENDING_PROTOCOL", TROPYKUS_STRING);
        bytes32 protocolHash = keccak256(abi.encodePacked(protocol));
        if (
            protocolHash != keccak256(abi.encodePacked(SOVRYN_STRING))
                && protocolHash != keccak256(abi.encodePacked(TROPYKUS_STRING))
        ) {
            vm.skip(true);
            return;
        }

        DeployMocAndUniswap deployer = new DeployMocAndUniswap();
        DeployMocAndUniswap.DeployedContracts memory deployed = deployer.run();

        address doc = deployed.helpConfMoc.getStablecoin();
        address dexStable = deployed.helpConfUni.getStablecoin();
        assertEq(deployed.dcaManMoc.getTokenMinPurchaseAmount(doc), MIN_PURCHASE_AMOUNT);
        assertEq(deployed.dcaManUni.getTokenMinPurchaseAmount(dexStable), MIN_PURCHASE_AMOUNT);
        assertEq(deployed.dcaManMoc.owner(), makeAddr(OWNER_STRING));
        assertEq(deployed.dcaManUni.owner(), makeAddr(OWNER_STRING));
        assertEq(address(deployed.dcaManMoc.i_operationsAdmin()), address(deployed.adOpsMoc));
    }
}
