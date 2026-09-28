// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {MocHelperConfig} from "./MocHelperConfig.s.sol";
import {IdleDocHandlerMoc} from "../src/idle/IdleDocHandlerMoc.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {DcaManager} from "../src/DcaManager.sol";
import {IPurchaseFees} from "../src/interfaces/IPurchaseFees.sol";
import {console} from "forge-std/Test.sol";
import "./Constants.sol";

/**
 * @title DeployIdleHandler
 * @notice Add-on deploy for the index-0 idle DOC + MoC handler, same shape as DeployUsdrifHandler.
 * @dev Does not change DeployMocSwaps or the lending-index map. Pass the MocHelperConfig from
 *      DeployMocSwaps so local/fork tests share the same DOC and MoC mocks.
 */
contract DeployIdleHandler is DeployBase {
    struct DeployParams {
        address dcaManager;
        address stablecoin;
        address mocProxy;
        address feeCollector;
        address initialOwner;
    }

    function deployIdleDocHandlerMoc(DeployParams memory params) public returns (address) {
        IPurchaseFees.FeeSettings memory feeSettings = IPurchaseFees.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: getMaxFeeRate(),
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        return address(
            new IdleDocHandlerMoc(
                params.dcaManager,
                params.stablecoin,
                params.feeCollector,
                params.mocProxy,
                feeSettings,
                params.initialOwner
            )
        );
    }

    function run(MocHelperConfig existingConfig, address operationsAdmin, address dcaManager)
        external
        returns (address)
    {
        MocHelperConfig helperConfig = address(existingConfig) != address(0) ? existingConfig : new MocHelperConfig();

        if (operationsAdmin == address(0) || dcaManager == address(0)) {
            revert("OperationsAdmin and DcaManager addresses must be set");
        }

        MocHelperConfig.NetworkConfig memory networkConfig = helperConfig.getActiveNetworkConfig();
        address docToken = helperConfig.getStablecoin();
        address mocProxy = networkConfig.mocProxy;

        console.log("OperationsAdmin address:", operationsAdmin);
        console.log("DcaManager address:", dcaManager);
        console.log("DOC token address:", docToken);
        console.log("MoC Proxy address:", mocProxy);

        OperationsAdmin opsAdmin = OperationsAdmin(operationsAdmin);
        _requireNoPendingOwner(opsAdmin);
        _requireNoPendingOwner(DcaManager(dcaManager));

        vm.startBroadcast();

        DeployParams memory params = DeployParams({
            dcaManager: dcaManager,
            stablecoin: docToken,
            mocProxy: mocProxy,
            feeCollector: getFeeCollector(environment),
            initialOwner: opsAdmin.owner()
        });

        address idleHandler = deployIdleDocHandlerMoc(params);
        console.log("Idle DOC handler deployed at:", idleHandler);

        if (msg.sender != opsAdmin.owner()) {
            console.log("Warning: Deployer is not the owner. Cannot register handler.");
            console.log("Please call operationsAdmin.assignHandler() as owner with:");
            console.log("stablecoin:", docToken);
            console.log("index: 0");
            console.log("handler:", idleHandler);
        } else {
            // Occupied `(token, IDLE_INDEX)` reverts `HandlerAlreadyAssigned` — do not skip.
            opsAdmin.assignHandler(docToken, IDLE_INDEX, idleHandler);
            console.log("Idle DOC handler registered with OperationsAdmin at index", IDLE_INDEX);
        }

        console.log("Handler owner:", params.initialOwner);

        vm.stopBroadcast();

        return idleHandler;
    }
}
