// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {MocHelperConfig} from "./MocHelperConfig.s.sol";
import {LayerBankDocHandlerMoc} from "../src/layerbank/LayerBankDocHandlerMoc.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {DcaManager} from "../src/DcaManager.sol";
import {IOperationsAdmin} from "../src/interfaces/IOperationsAdmin.sol";
import {IPurchaseFees} from "../src/interfaces/IPurchaseFees.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "../test/mocks/MockLayerBank.sol";
import {console} from "forge-std/Test.sol";
import "./Constants.sol";

/**
 * @title DeployLayerBankHandler
 * @notice Add-on deploy for the index-1 LayerBank DOC + MoC handler, same shape as DeployIdleHandler.
 * @dev Local/Anvil deploys Pool/aToken mocks. Live TESTNET/MAINNET (`REAL_DEPLOYMENT=true`) bind
 *      `MocHelperConfig.layerbankAToken` (handler reads Pool from `aToken.POOL()`).
 *      `getEnvironment()` returns FORK for a real RSK RPC unless that env var is set — FORK must
 *      not take the live path (test `feeCollector` / 2% cap would permanently occupy `(DOC, 1)`).
 *      Fork tests use `deployMocksAndHandler` (no broadcast). Occupied `(token, LAYERBANK_INDEX)`
 *      reverts `HandlerAlreadyAssigned` — do not skip. Map: idle=0 / LayerBank=1 / Sovryn=2.
 */
contract DeployLayerBankHandler is DeployBase {
    struct DeployParams {
        address dcaManager;
        address stablecoin;
        address aToken;
        address mocProxy;
        address feeCollector;
        address initialOwner;
    }

    function deployLayerBankDocHandlerMoc(DeployParams memory params) public returns (address) {
        IPurchaseFees.FeeSettings memory feeSettings = IPurchaseFees.FeeSettings({
            minFeeRate: MIN_FEE_RATE, maxFeeRate: getMaxFeeRate(), feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND
        });

        return address(
            new LayerBankDocHandlerMoc(
                params.dcaManager,
                params.stablecoin,
                params.aToken,
                params.feeCollector,
                params.mocProxy,
                feeSettings,
                params.initialOwner
            )
        );
    }

    /**
     * @notice Deploy Pool/aToken mocks and the handler. Used by tests on Anvil and on a fork.
     * @dev Does not `broadcast` or call `assignHandler`. `run()` broadcasts.
     */
    function deployMocksAndHandler(
        address dcaManager,
        address stablecoin,
        address mocProxy,
        address feeCollector,
        address owner
    ) public returns (address handler) {
        MockLayerBankAToken aToken = new MockLayerBankAToken(stablecoin);
        MockLayerBankPool pool = new MockLayerBankPool(aToken);
        aToken.setPool(address(pool));
        handler = deployLayerBankDocHandlerMoc(
            DeployParams({
                dcaManager: dcaManager,
                stablecoin: stablecoin,
                aToken: address(aToken),
                mocProxy: mocProxy,
                feeCollector: feeCollector,
                initialOwner: owner
            })
        );
        return handler;
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

        address layerbankHandler;

        if (environment == Environment.LOCAL) {
            layerbankHandler =
                deployMocksAndHandler(dcaManager, docToken, mocProxy, getFeeCollector(environment), opsAdmin.owner());
        } else if (environment == Environment.TESTNET || environment == Environment.MAINNET) {
            address aToken = networkConfig.layerbankAToken;
            if (aToken == address(0)) {
                revert("LayerBank aToken address is not configured for this network");
            }
            layerbankHandler = deployLayerBankDocHandlerMoc(
                DeployParams({
                    dcaManager: dcaManager,
                    stablecoin: docToken,
                    aToken: aToken,
                    mocProxy: mocProxy,
                    feeCollector: getFeeCollector(environment),
                    initialOwner: opsAdmin.owner()
                })
            );
        } else {
            // FORK: `--broadcast` against a real RPC without REAL_DEPLOYMENT=true.
            revert("DeployLayerBankHandler live path requires REAL_DEPLOYMENT=true");
        }

        console.log("LayerBank DOC handler deployed at:", layerbankHandler);
        _maybeAssign(opsAdmin, docToken, layerbankHandler);

        vm.stopBroadcast();

        return layerbankHandler;
    }

    function _maybeAssign(OperationsAdmin operationsAdmin, address docToken, address layerbankHandler) internal {
        bool isOwner = msg.sender == operationsAdmin.owner();

        if (!isOwner) {
            console.log("Warning: Deployer is not the owner. Cannot register handler.");
            console.log("Please call operationsAdmin.registerRoute + assignHandler as owner with:");
            console.log("stablecoin:", docToken);
            console.log("index:", LAYERBANK_INDEX);
            console.log("handler:", layerbankHandler);
            return;
        }
        if (operationsAdmin.getRouteClass(LAYERBANK_INDEX) == IOperationsAdmin.RouteClass.Unregistered) {
            operationsAdmin.registerRoute(LAYERBANK_INDEX, true);
        }
        operationsAdmin.assignHandler(docToken, LAYERBANK_INDEX, layerbankHandler);
        console.log("LayerBank DOC handler registered with OperationsAdmin at index", LAYERBANK_INDEX);
    }
}
