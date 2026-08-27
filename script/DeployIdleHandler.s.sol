// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {MocHelperConfig} from "./MocHelperConfig.s.sol";
import {IdleDocHandlerMoc} from "../src/idle/IdleDocHandlerMoc.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {IFeeHandler} from "../src/interfaces/IFeeHandler.sol";
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
        address tokenAddress;
        address mocProxy;
        address feeCollector;
        address initialOwner;
    }

    function deployIdleDocHandlerMoc(DeployParams memory params) public returns (address) {
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: getMaxFeeRate(),
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        return address(
            new IdleDocHandlerMoc(
                params.dcaManager,
                params.tokenAddress,
                params.feeCollector,
                params.mocProxy,
                feeSettings,
                params.initialOwner
            )
        );
    }

    function run(MocHelperConfig existingConfig, address operationsAdminAddress, address dcaManagerAddress)
        external
        returns (address)
    {
        MocHelperConfig helperConfig =
            address(existingConfig) != address(0) ? existingConfig : new MocHelperConfig();

        if (operationsAdminAddress == address(0) || dcaManagerAddress == address(0)) {
            revert("OperationsAdmin and DcaManager addresses must be set");
        }

        MocHelperConfig.NetworkConfig memory networkConfig = helperConfig.getActiveNetworkConfig();
        address docTokenAddress = helperConfig.getStablecoinAddress();
        address mocProxyAddress = networkConfig.mocProxyAddress;

        console.log("OperationsAdmin address:", operationsAdminAddress);
        console.log("DcaManager address:", dcaManagerAddress);
        console.log("DOC token address:", docTokenAddress);
        console.log("MoC Proxy address:", mocProxyAddress);

        vm.startBroadcast();

        DeployParams memory params = DeployParams({
            dcaManager: dcaManagerAddress,
            tokenAddress: docTokenAddress,
            mocProxy: mocProxyAddress,
            feeCollector: getFeeCollector(environment),
            initialOwner: OperationsAdmin(operationsAdminAddress).owner()
        });

        address idleHandler = deployIdleDocHandlerMoc(params);
        console.log("Idle DOC handler deployed at:", idleHandler);

        OperationsAdmin operationsAdmin = OperationsAdmin(operationsAdminAddress);
        if (msg.sender != operationsAdmin.owner()) {
            console.log("Warning: Deployer is not the owner. Cannot register handler.");
            console.log("Please call operationsAdmin.assignTokenHandler() as owner with:");
            console.log("tokenAddress:", docTokenAddress);
            console.log("index: 0");
            console.log("handlerAddress:", idleHandler);
        } else {
            // Occupied `(token, IDLE_INDEX)` reverts `HandlerAlreadyAssigned` — do not skip.
            operationsAdmin.assignTokenHandler(docTokenAddress, IDLE_INDEX, idleHandler);
            console.log("Idle DOC handler registered with OperationsAdmin at index", IDLE_INDEX);
        }

        console.log("Handler owner:", params.initialOwner);

        vm.stopBroadcast();

        return idleHandler;
    }
}
