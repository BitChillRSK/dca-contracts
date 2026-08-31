// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {console} from "forge-std/Test.sol";

/**
 * @title DeployOptimizerProof
 * @notice One-contract Rootstock testnet CREATE of optimizer-on `OperationsAdmin` (R23-class proof).
 * @dev Not a production deploy. Broadcast only from `TESTNET_OWNER` on chain 31 with
 *      `REAL_DEPLOYMENT=true`. Do not use on mainnet.
 */
contract DeployOptimizerProof is DeployBase {
    function run() external returns (OperationsAdmin admin) {
        _assertLiveBroadcastSender(msg.sender);
        if (environment != Environment.TESTNET) {
            revert("DeployOptimizerProof is testnet-only");
        }

        vm.startBroadcast();
        admin = new OperationsAdmin(msg.sender);
        vm.stopBroadcast();

        console.log("Optimizer-proof OperationsAdmin:", address(admin));
        console.log("owner:", admin.owner());
    }
}
