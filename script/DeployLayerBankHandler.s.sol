// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {MocHelperConfig} from "./MocHelperConfig.s.sol";
import {LayerBankDocHandlerMoc} from "../src/layerbank/LayerBankDocHandlerMoc.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {IFeeHandler} from "../src/interfaces/IFeeHandler.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockLToken, MockLayerBankCore} from "../test/mocks/MockLayerBank.sol";
import {console} from "forge-std/Test.sol";
import "./Constants.sol";

/**
 * @title DeployLayerBankHandler
 * @notice Add-on deploy for the index-1 LayerBank DOC + MoC handler, same shape as DeployIdleHandler.
 * @dev Local and fork tests deploy Core/lToken mocks. Live lDOC addresses and DeployMocSwaps
 *      registration are PR 16. Index 1 currently belongs to Tropykus on the shared admin;
 *      dedicated tests may overwrite it.
 */
contract DeployLayerBankHandler is DeployBase {
    uint256 public constant LAYERBANK_INDEX = 1;
    string public constant LAYERBANK_STRING = "layerbank";

    struct DeployParams {
        address dcaManager;
        address tokenAddress;
        address lToken;
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
                params.lToken,
                params.feeCollector,
                params.mocProxy,
                feeSettings,
                EXCHANGE_RATE_DECIMALS
            )
        );
    }

    function run(MocHelperConfig existingConfig, address operationsAdminAddress, address dcaManagerAddress)
        external
        returns (address)
    {
        if (environment == Environment.TESTNET || environment == Environment.MAINNET) {
            revert("Live LayerBank lDOC addresses are PR 16");
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

        MockLToken lToken = new MockLToken(docTokenAddress);
        MockLayerBankCore core = new MockLayerBankCore(lToken);
        lToken.setCore(address(core));
        console.log("Mock lToken:", address(lToken));
        console.log("Mock Core:", address(core));

        DeployParams memory params = DeployParams({
            dcaManager: dcaManagerAddress,
            tokenAddress: docTokenAddress,
            lToken: address(lToken),
            mocProxy: mocProxyAddress,
            feeCollector: getFeeCollector(environment)
        });

        address layerbankHandler = deployLayerBankDocHandlerMoc(params);
        console.log("LayerBank DOC handler deployed at:", layerbankHandler);

        OperationsAdmin operationsAdmin = OperationsAdmin(operationsAdminAddress);
        bool isAdmin = operationsAdmin.hasRole(keccak256("ADMIN"), msg.sender);

        if (!isAdmin) {
            console.log("Warning: Deployer is not an admin. Cannot register handler.");
            console.log("Please call operationsAdmin.addOrUpdateLendingProtocol + assignOrUpdateTokenHandler with:");
            console.log("tokenAddress:", docTokenAddress);
            console.log("index:", LAYERBANK_INDEX);
            console.log("handlerAddress:", layerbankHandler);
        } else {
            operationsAdmin.addOrUpdateLendingProtocol(LAYERBANK_STRING, LAYERBANK_INDEX);
            operationsAdmin.assignOrUpdateTokenHandler(docTokenAddress, LAYERBANK_INDEX, layerbankHandler);
            console.log("LayerBank DOC handler registered with OperationsAdmin at index", LAYERBANK_INDEX);
        }

        address currentOwner = operationsAdmin.owner();
        Ownable(layerbankHandler).transferOwnership(currentOwner);
        console.log("Handler ownership transferred to:", currentOwner);

        vm.stopBroadcast();

        return layerbankHandler;
    }
}
