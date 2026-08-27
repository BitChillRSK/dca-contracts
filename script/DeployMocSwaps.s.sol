//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {MocHelperConfig} from "./MocHelperConfig.s.sol";
import {DcaManager} from "../src/DcaManager.sol";
import {TropykusDocHandlerMoc} from "../src/tropykus-legacy/TropykusDocHandlerMoc.sol";
import {SovrynDocHandlerMoc} from "../src/sovryn/SovrynDocHandlerMoc.sol";
import {IdleDocHandlerMoc} from "../src/idle/IdleDocHandlerMoc.sol";
import {LayerBankDocHandlerMoc} from "../src/layerbank/LayerBankDocHandlerMoc.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {ICoinPairPrice} from "../src/interfaces/ICoinPairPrice.sol";
import {IFeeHandler} from "../src/interfaces/IFeeHandler.sol";
import {console} from "forge-std/Test.sol";
import "./Constants.sol";


contract DeployMocSwaps is DeployBase {
    // Struct to group deployment parameters to avoid stack too deep errors
    struct DeployParams {
        Protocol protocol;
        address dcaManager;
        address tokenAddress;
        address shareToken;
        address mocProxy;
        address feeCollector;
    }

    function deployDocHandlerMoc(DeployParams memory params) public returns (address) {
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: getMaxFeeRate(),
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        if (params.protocol == Protocol.NONE) {
            return address(
                new IdleDocHandlerMoc(
                    params.dcaManager,
                    params.tokenAddress,
                    params.feeCollector,
                    params.mocProxy,
                    feeSettings,
                    adminAddresses[environment]
                )
            );
        }
        if (params.protocol == Protocol.LAYERBANK) {
            return address(
                new LayerBankDocHandlerMoc(
                    params.dcaManager,
                    params.tokenAddress,
                    params.shareToken,
                    params.feeCollector,
                    params.mocProxy,
                    feeSettings,
                    adminAddresses[environment]
                )
            );
        }
        if (params.protocol == Protocol.TROPYKUS) {
            return address(
                new TropykusDocHandlerMoc(
                    params.dcaManager,
                    params.tokenAddress,
                    params.shareToken,
                    params.feeCollector,
                    params.mocProxy,
                    feeSettings,
                    adminAddresses[environment]
                )
            );
        }
        if (params.protocol == Protocol.SOVRYN) {
            return address(
                new SovrynDocHandlerMoc(
                    params.dcaManager,
                    params.tokenAddress,
                    params.shareToken,
                    params.feeCollector,
                    params.mocProxy,
                    feeSettings,
                    adminAddresses[environment]
                )
            );
        }
        revert("Invalid lending protocol");
    }

    function run() external returns (OperationsAdmin, address, DcaManager, MocHelperConfig) {
        console.log("==== DeployMocSwaps.run() called ====");
        console.log("LENDING_PROTOCOL (env var):", vm.envString("LENDING_PROTOCOL"));
        console.log("STABLECOIN_TYPE (env var):", vm.envString("STABLECOIN_TYPE"));

        MocHelperConfig helperConfig = new MocHelperConfig();
        MocHelperConfig.NetworkConfig memory networkConfig = helperConfig.getActiveNetworkConfig();

        string memory stablecoinType;
        try vm.envString("STABLECOIN_TYPE") returns (string memory coinType) {
            stablecoinType = coinType;
        } catch {
            stablecoinType = DEFAULT_STABLECOIN;
        }

        console.log("Using stablecoin type:", stablecoinType);

        address docTokenAddress = helperConfig.getStablecoinAddress();
        console.log("DOC token address:", docTokenAddress);

        address mocProxyAddress = networkConfig.mocProxyAddress;
        console.log("MoC Proxy address:", mocProxyAddress);

        bool isSovryn = protocol == Protocol.SOVRYN;
        bool isUSDRIF = keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked("USDRIF"));

        if (isSovryn && isUSDRIF) {
            revert("USDRIF is not supported by Sovryn");
        }

        vm.startBroadcast();

        address owner = adminAddresses[environment];
        OperationsAdmin operationsAdmin = new OperationsAdmin(owner);
        DcaManager dcaManager = new DcaManager(
            address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, owner
        );
        address feeCollector = getFeeCollector(environment);
        address docHandlerMocAddress;

        // For local or fork environments, deploy only the selected protocol's handler
        if (environment == Environment.LOCAL || environment == Environment.FORK) {
            console.log("Deploying single handler for local/fork environment");

            address shareTokenAddress;
            if (protocol != Protocol.NONE) {
                shareTokenAddress = helperConfig.getShareTokenAddress();
                if (shareTokenAddress == address(0)) {
                    revert("Share token not available for the selected combination");
                }
                console.log("Share token address:", shareTokenAddress);
            }

            DeployParams memory params = DeployParams({
                protocol: protocol,
                dcaManager: address(dcaManager),
                tokenAddress: docTokenAddress,
                shareToken: shareTokenAddress,
                mocProxy: mocProxyAddress,
                feeCollector: feeCollector
            });

            docHandlerMocAddress = deployDocHandlerMoc(params);
        }
        // Live networks: production map is idle=0, LayerBank=1, Sovryn=2. Tropykus is not registered.
        else if (environment == Environment.TESTNET || environment == Environment.MAINNET) {
            if (protocol == Protocol.TROPYKUS) {
                revert("Tropykus is not on the production MoC map");
            }

            console.log("Deploying production handlers (idle / LayerBank / Sovryn)");

            // Owner is already `adminAddresses[environment]`. `registerRoute` / `assignTokenHandler`
            // in this transaction therefore require the broadcaster to be that address.
            operationsAdmin.registerRoute(LAYERBANK_INDEX, true);
            operationsAdmin.registerRoute(SOVRYN_INDEX, true);

            address idleHandler = deployDocHandlerMoc(
                DeployParams({
                    protocol: Protocol.NONE,
                    dcaManager: address(dcaManager),
                    tokenAddress: docTokenAddress,
                    shareToken: address(0),
                    mocProxy: mocProxyAddress,
                    feeCollector: feeCollector
                })
            );
            console.log("Idle handler deployed at:", idleHandler);
            operationsAdmin.assignTokenHandler(docTokenAddress, IDLE_INDEX, idleHandler);
            if (protocol == Protocol.NONE) {
                docHandlerMocAddress = idleHandler;
            }

            address layerbankAToken = networkConfig.layerbankATokenAddress;
            if (layerbankAToken == address(0)) {
                if (protocol == Protocol.LAYERBANK) {
                    revert("LayerBank aToken not available on this network");
                }
                console.log(
                    "Warning: LayerBank aToken not available; index 1 is now immutable Lending with no handler"
                );
            } else {
                address layerbankHandler = deployDocHandlerMoc(
                    DeployParams({
                        protocol: Protocol.LAYERBANK,
                        dcaManager: address(dcaManager),
                        tokenAddress: docTokenAddress,
                        shareToken: layerbankAToken,
                        mocProxy: mocProxyAddress,
                        feeCollector: feeCollector
                    })
                );
                console.log("LayerBank handler deployed at:", layerbankHandler);
                operationsAdmin.assignTokenHandler(docTokenAddress, LAYERBANK_INDEX, layerbankHandler);
                if (protocol == Protocol.LAYERBANK) {
                    docHandlerMocAddress = layerbankHandler;
                }
            }

            if (!isUSDRIF) {
                address sovrynShareToken = networkConfig.iSusdAddress;
                if (sovrynShareToken == address(0)) {
                    if (protocol == Protocol.SOVRYN) {
                        revert("Sovryn shares not available for this stablecoin");
                    }
                    console.log("Warning: Sovryn shares not available for this stablecoin");
                } else {
                    address sovrynHandler = deployDocHandlerMoc(
                        DeployParams({
                            protocol: Protocol.SOVRYN,
                            dcaManager: address(dcaManager),
                            tokenAddress: docTokenAddress,
                            shareToken: sovrynShareToken,
                            mocProxy: mocProxyAddress,
                            feeCollector: feeCollector
                        })
                    );
                    console.log("Sovryn handler deployed at:", sovrynHandler);
                    operationsAdmin.assignTokenHandler(docTokenAddress, SOVRYN_INDEX, sovrynHandler);
                    if (protocol == Protocol.SOVRYN) {
                        docHandlerMocAddress = sovrynHandler;
                    }
                }
            } else {
                console.log("Skipping Sovryn handler deployment for USDRIF as it's not supported");
            }
        }

        if (docHandlerMocAddress == address(0)) {
            revert("Selected protocol handler was not deployed");
        }

        vm.stopBroadcast();

        return (operationsAdmin, docHandlerMocAddress, dcaManager, helperConfig);
    }
}
