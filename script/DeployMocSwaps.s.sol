//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {MocHelperConfig} from "./MocHelperConfig.s.sol";
import {DcaManager} from "../src/DcaManager.sol";
import {TropykusDocHandlerMoc} from "../src/TropykusDocHandlerMoc.sol";
import {SovrynDocHandlerMoc} from "../src/SovrynDocHandlerMoc.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {ICoinPairPrice} from "../src/interfaces/ICoinPairPrice.sol";
import {IFeeHandler} from "../src/interfaces/IFeeHandler.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {console} from "forge-std/Test.sol";
import "./Constants.sol";


contract DeployMocSwaps is DeployBase {
    // Struct to group deployment parameters to avoid stack too deep errors
    struct DeployParams {
        Protocol protocol;
        address dcaManager;
        address tokenAddress;
        address lendingToken;
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

        if (params.protocol == Protocol.TROPYKUS) {
            return address(
                new TropykusDocHandlerMoc(
                    params.dcaManager, 
                    params.tokenAddress, 
                    params.lendingToken, 
                    MIN_PURCHASE_AMOUNT, 
                    params.feeCollector, 
                    params.mocProxy, 
                    feeSettings,
                    EXCHANGE_RATE_DECIMALS
                )
            );
        } else {
            return address(
                new SovrynDocHandlerMoc(
                    params.dcaManager, 
                    params.tokenAddress, 
                    params.lendingToken, 
                    MIN_PURCHASE_AMOUNT, 
                    params.feeCollector, 
                    params.mocProxy, 
                    feeSettings,
                    EXCHANGE_RATE_DECIMALS
                )
            );
        }
    }

    function run() external returns (OperationsAdmin, address, DcaManager, MocHelperConfig) {
        console.log("==== DeployMocSwaps.run() called ====");
        console.log("LENDING_PROTOCOL (env var):", vm.envString("LENDING_PROTOCOL"));
        console.log("STABLECOIN_TYPE (env var):", vm.envString("STABLECOIN_TYPE"));
        
        // Lots of debugging here
        try vm.envString("LENDING_PROTOCOL") returns (string memory lendingProtocolFromEnv) {
            console.log("Got LENDING_PROTOCOL from env:", lendingProtocolFromEnv);
        } catch {
            console.log("Failed to get LENDING_PROTOCOL from env");
        }
        
        try vm.envString("STABLECOIN_TYPE") returns (string memory stablecoinTypeFromEnv) {
            console.log("Got STABLECOIN_TYPE from env:", stablecoinTypeFromEnv);
        } catch {
            console.log("Failed to get STABLECOIN_TYPE from env");
        }

        // Initialize MocHelperConfig which reads the STABLECOIN_TYPE env var
        MocHelperConfig helperConfig = new MocHelperConfig();
        MocHelperConfig.NetworkConfig memory networkConfig = helperConfig.getActiveNetworkConfig();

        // Get stablecoin type (or use default if not specified)
        string memory stablecoinType;
        try vm.envString("STABLECOIN_TYPE") returns (string memory coinType) {
            stablecoinType = coinType;
        } catch {
            stablecoinType = DEFAULT_STABLECOIN;
        }
        
        console.log("Using stablecoin type:", stablecoinType);
        
        // Get the DOC token address
        address docTokenAddress = helperConfig.getStablecoinAddress();
        console.log("DOC token address:", docTokenAddress);
        
        address mocProxyAddress = networkConfig.mocProxyAddress;
        console.log("MoC Proxy address:", mocProxyAddress);

        // Check if stablecoin is supported by the selected protocol
        bool isSovryn = protocol == Protocol.SOVRYN;
        bool isUSDRIF = keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked("USDRIF"));
        
        if (isSovryn && isUSDRIF) {
            revert("USDRIF is not supported by Sovryn");
        }

        vm.startBroadcast();

        OperationsAdmin operationsAdmin = new OperationsAdmin();
        DcaManager dcaManager = new DcaManager(address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT);
        address feeCollector = getFeeCollector(environment);
        address docHandlerMocAddress;

        // For local or fork environments, deploy only the selected protocol's handler
        if (environment == Environment.LOCAL || environment == Environment.FORK) {
            console.log("Deploying single handler for local/fork environment");
            
            // Get the appropriate lending token address based on protocol
            address lendingTokenAddress = helperConfig.getLendingTokenAddress();
            if (lendingTokenAddress == address(0)) {
                revert("Lending token not available for the selected combination");
            }
            
            console.log("Lending token address:", lendingTokenAddress);
            
            DeployParams memory params = DeployParams({
                protocol: protocol,
                dcaManager: address(dcaManager),
                tokenAddress: docTokenAddress,
                lendingToken: lendingTokenAddress,
                mocProxy: mocProxyAddress,
                feeCollector: feeCollector
            });
            
            docHandlerMocAddress = deployDocHandlerMoc(params);

            address owner = adminAddresses[environment];
            operationsAdmin.transferOwnership(owner);
            dcaManager.transferOwnership(owner);
            Ownable(docHandlerMocAddress).transferOwnership(owner);
        }
        // For live networks (testnet/mainnet), deploy handlers for both lending protocols
        else if (environment == Environment.TESTNET || environment == Environment.MAINNET) {
            console.log("Deploying handlers for lending protocols for live network");

            // First register the lending protocols
            operationsAdmin.setAdminRole(tx.origin);
            operationsAdmin.addOrUpdateLendingProtocol(TROPYKUS_STRING, TROPYKUS_INDEX); // index 1
            operationsAdmin.addOrUpdateLendingProtocol(SOVRYN_STRING, SOVRYN_INDEX); // index 2

            // Deploy Tropykus handler if there's a valid lending token
            address tropykusLendingToken = networkConfig.kDocAddress;
            
            if (tropykusLendingToken == address(0)) {
                console.log("Warning: Tropykus lending token not available for this stablecoin");
            } else {
                // Deploy Tropykus handler
                DeployParams memory tropykusParams = DeployParams({
                    protocol: Protocol.TROPYKUS,
                    dcaManager: address(dcaManager),
                    tokenAddress: docTokenAddress,
                    lendingToken: tropykusLendingToken,
                    mocProxy: mocProxyAddress,
                    feeCollector: feeCollector
                });
                
                address tropykusHandler = deployDocHandlerMoc(tropykusParams);
                console.log("Tropykus handler deployed at:", tropykusHandler);
                
                // Assign the Tropykus handler
                operationsAdmin.assignOrUpdateTokenHandler(docTokenAddress, TROPYKUS_INDEX, tropykusHandler);
                
                // If we're deploying for Tropykus, set this as our return handler
                if (protocol == Protocol.TROPYKUS) {
                    docHandlerMocAddress = tropykusHandler;
                }
            }

            // Only deploy Sovryn handler if the stablecoin is supported
            if (!isUSDRIF) {
                // Get Sovryn lending token address
                address sovrynLendingToken = networkConfig.iSusdAddress;
                
                if (sovrynLendingToken == address(0)) {
                    console.log("Warning: Sovryn lending token not available for this stablecoin");
                } else {
                    // Deploy Sovryn handler
                    DeployParams memory sovrynParams = DeployParams({
                        protocol: Protocol.SOVRYN,
                        dcaManager: address(dcaManager),
                        tokenAddress: docTokenAddress,
                        lendingToken: sovrynLendingToken,
                        mocProxy: mocProxyAddress,
                        feeCollector: feeCollector
                    });
                    
                    address sovrynHandler = deployDocHandlerMoc(sovrynParams);
                    console.log("Sovryn handler deployed at:", sovrynHandler);
                    
                    // Assign the Sovryn handler
                    operationsAdmin.assignOrUpdateTokenHandler(docTokenAddress, SOVRYN_INDEX, sovrynHandler);
                    
                    // If we're deploying for Sovryn, set this as our return handler
                    if (protocol == Protocol.SOVRYN) {
                        docHandlerMocAddress = sovrynHandler;
                    }
                }
            } else {
                console.log("Skipping Sovryn handler deployment for USDRIF as it's not supported");
            }

            if (environment == Environment.TESTNET) {
                operationsAdmin.setAdminRole(adminAddresses[Environment.TESTNET]);
            }
        }

        vm.stopBroadcast();

        return (operationsAdmin, docHandlerMocAddress, dcaManager, helperConfig);
    }
}
