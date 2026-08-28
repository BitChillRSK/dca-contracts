// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {SwapperBatcher} from "../src/SwapperBatcher.sol";
import {IDcaManager} from "../src/interfaces/IDcaManager.sol";
import {console} from "forge-std/Test.sol";

/**
 * @title DeploySwapperBatcher
 * @notice Add-on deploy for the swapper batcher. Local/test only in this PR.
 * @dev Does not `addSwapper`. Live allowlisting is ops after deploy: the batcher is `msg.sender`
 *      on `DcaManager.batchBuyRbtc`, so purchases revert `UnauthorizedSwapper` until the owner
 *      calls `OperationsAdmin.addSwapper(batcher)`. Keep the bot EOA on that allowlist as the
 *      per-handler retry path; do not revoke it in the same transaction as this deploy.
 */
contract DeploySwapperBatcher is DeployBase {
    function run(address dcaManagerAddress) external returns (address) {
        if (dcaManagerAddress == address(0) || dcaManagerAddress.code.length == 0) {
            revert("DcaManager address must be a deployed contract");
        }

        address operationsAdminAddress = IDcaManager(dcaManagerAddress).getOperationsAdminAddress();

        console.log("DcaManager address:", dcaManagerAddress);
        console.log("OperationsAdmin address:", operationsAdminAddress);

        vm.startBroadcast();
        SwapperBatcher batcher = new SwapperBatcher(dcaManagerAddress);
        vm.stopBroadcast();

        console.log("SwapperBatcher deployed at:", address(batcher));
        console.log("Ops (do not broadcast from this script):");
        console.log("  operationsAdmin.addSwapper(batcher)");
        console.log("  Keep the bot EOA allowlisted for per-handler retries");

        return address(batcher);
    }
}
