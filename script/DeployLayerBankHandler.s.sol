// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {MocHelperConfig} from "./MocHelperConfig.s.sol";
import {LayerBankDocHandlerMoc} from "../src/layerbank/LayerBankDocHandlerMoc.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {IOperationsAdmin} from "../src/interfaces/IOperationsAdmin.sol";
import {IFeeHandler} from "../src/interfaces/IFeeHandler.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "../test/mocks/MockLayerBank.sol";
import {console} from "forge-std/Test.sol";
import "./Constants.sol";

/**
 * @title DeployLayerBankHandler
 * @notice Add-on deploy for the index-1 LayerBank DOC + MoC handler, same shape as DeployIdleHandler.
 * @dev Local/Anvil deploys Pool/aToken mocks. Fork and live use `MocHelperConfig.layerbankATokenAddress`
 *      (handler reads Pool from `aToken.POOL()`). Occupied `(token, LAYERBANK_INDEX)` reverts
 *      `HandlerAlreadyAssigned` — do not skip. The production map is idle=0 / LayerBank=1 / Sovryn=2.
 */
contract DeployLayerBankHandler is DeployBase {

    struct DeployParams {
        address dcaManager;
        address tokenAddress;
        address aToken;
        address mocProxy;
        address feeCollector;
    }

    function deployLayerBankDocHandlerMoc(DeployParams memory params) public returns (address) {
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: getMaxFeeRate(),
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        return address(
            new LayerBankDocHandlerMoc(
                params.dcaManager,
                params.tokenAddress,
                params.aToken,
                params.feeCollector,
                params.mocProxy,
                feeSettings
            )
        );
    }

    /**
     * @notice Deploy Pool/aToken mocks and the handler. Used by tests on Anvil and on a fork.
     * @dev Does not `broadcast` or call `assignTokenHandler`. `run()` broadcasts.
     */
    function deployMocksAndHandler(
        address dcaManager,
        address tokenAddress,
        address mocProxy,
        address feeCollector,
        address owner
    ) public returns (address handler) {
        MockLayerBankAToken aToken = new MockLayerBankAToken(tokenAddress);
        MockLayerBankPool pool = new MockLayerBankPool(aToken);
        aToken.setPool(address(pool));
        handler = deployLayerBankDocHandlerMoc(
            DeployParams({
                dcaManager: dcaManager,
                tokenAddress: tokenAddress,
                aToken: address(aToken),
                mocProxy: mocProxy,
                feeCollector: feeCollector
            })
        );
        Ownable(handler).transferOwnership(owner);
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

        OperationsAdmin operationsAdmin = OperationsAdmin(operationsAdminAddress);
        address layerbankHandler;

        if (environment == Environment.LOCAL) {
            layerbankHandler = deployMocksAndHandler(
                dcaManagerAddress,
                docTokenAddress,
                mocProxyAddress,
                getFeeCollector(environment),
                operationsAdmin.owner()
            );
        } else {
            address aToken = networkConfig.layerbankATokenAddress;
            if (aToken == address(0)) {
                revert("LayerBank aToken address is not configured for this network");
            }
            layerbankHandler = deployLayerBankDocHandlerMoc(
                DeployParams({
                    dcaManager: dcaManagerAddress,
                    tokenAddress: docTokenAddress,
                    aToken: aToken,
                    mocProxy: mocProxyAddress,
                    feeCollector: getFeeCollector(environment)
                })
            );
            Ownable(layerbankHandler).transferOwnership(operationsAdmin.owner());
        }

        console.log("LayerBank DOC handler deployed at:", layerbankHandler);
        _maybeAssign(operationsAdmin, docTokenAddress, layerbankHandler);

        vm.stopBroadcast();

        return layerbankHandler;
    }

    function _maybeAssign(OperationsAdmin operationsAdmin, address docTokenAddress, address layerbankHandler)
        internal
    {
        bool isOwner = msg.sender == operationsAdmin.owner();

        if (!isOwner) {
            console.log("Warning: Deployer is not the owner. Cannot register handler.");
            console.log("Please call operationsAdmin.registerRoute + assignTokenHandler as owner with:");
            console.log("tokenAddress:", docTokenAddress);
            console.log("index:", LAYERBANK_INDEX);
            console.log("handlerAddress:", layerbankHandler);
            return;
        }
        if (operationsAdmin.getRouteClass(LAYERBANK_INDEX) == IOperationsAdmin.RouteClass.Unregistered) {
            operationsAdmin.registerRoute(LAYERBANK_INDEX, true);
        }
        operationsAdmin.assignTokenHandler(docTokenAddress, LAYERBANK_INDEX, layerbankHandler);
        console.log("LayerBank DOC handler registered with OperationsAdmin at index", LAYERBANK_INDEX);
    }
}
