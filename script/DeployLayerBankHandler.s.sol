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
 * @dev `run()` is Anvil-only. `DeployBase` reports FORK (not MAINNET) for a real RSK RPC
 *      unless `REAL_DEPLOYMENT=true`, so gating on TESTNET/MAINNET would still broadcast
 *      mocks onto chain 30. Live Pool/aToken addresses and DeployMocSwaps registration are
 *      PR 16. Index 1 currently belongs to Tropykus on the shared admin; dedicated tests
 *      may overwrite it via `deployMocksAndHandler`.
 */
contract DeployLayerBankHandler is DeployBase {
    uint256 public constant LAYERBANK_INDEX = 1;

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
     * @dev Does not `broadcast` or call `assignTokenHandler`. `run()` is the
     *      Anvil-only broadcast entry.
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
        if (environment != Environment.LOCAL) {
            revert("Live LayerBank Pool/aToken addresses are PR 16");
        }

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
        address layerbankHandler = deployMocksAndHandler(
            dcaManagerAddress,
            docTokenAddress,
            mocProxyAddress,
            getFeeCollector(environment),
            operationsAdmin.owner()
        );
        console.log("LayerBank DOC handler deployed at:", layerbankHandler);

        bool isOwner = msg.sender == operationsAdmin.owner();

        if (!isOwner) {
            console.log("Warning: Deployer is not the owner. Cannot register handler.");
            console.log("Please call operationsAdmin.registerRoute + assignTokenHandler as owner with:");
            console.log("tokenAddress:", docTokenAddress);
            console.log("index:", LAYERBANK_INDEX);
            console.log("handlerAddress:", layerbankHandler);
        } else {
            if (operationsAdmin.getRouteClass(LAYERBANK_INDEX) == IOperationsAdmin.RouteClass.Unregistered) {
                operationsAdmin.registerRoute(LAYERBANK_INDEX, true);
            }
            if (operationsAdmin.getTokenHandler(docTokenAddress, LAYERBANK_INDEX) != address(0)) {
                console.log("LayerBank route already has a handler; skipping assignment.");
            } else {
                operationsAdmin.assignTokenHandler(docTokenAddress, LAYERBANK_INDEX, layerbankHandler);
                console.log("LayerBank DOC handler registered with OperationsAdmin at index", LAYERBANK_INDEX);
            }
        }

        vm.stopBroadcast();

        return layerbankHandler;
    }
}
