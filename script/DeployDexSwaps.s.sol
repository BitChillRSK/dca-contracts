// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {DexHelperConfig} from "./DexHelperConfig.s.sol";
import {DcaManager} from "../src/DcaManager.sol";
import {TropykusErc20HandlerDex} from "../src/tropykus-legacy/TropykusErc20HandlerDex.sol";
import {SovrynErc20HandlerDex} from "../src/sovryn/SovrynErc20HandlerDex.sol";
import {IPurchaseUniswap} from "../src/interfaces/IPurchaseUniswap.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {IWRBTC} from "../src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "../src/interfaces/ICoinPairPrice.sol";
import {IFeeHandler} from "../src/interfaces/IFeeHandler.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {console} from "forge-std/Test.sol";
import "./Constants.sol";

contract DeployDexSwaps is DeployBase {
    // Struct to group deployment parameters to avoid stack too deep errors
    struct DeployParams {
        Protocol protocol;
        address dcaManager;
        address tokenAddress;
        address shareToken;
        IPurchaseUniswap.UniswapSettings uniswapSettings;
        address feeCollector;
        uint256 amountOutMinimumPercent;
        uint256 amountOutMinimumSafetyCheck;
    }

    function deployDocHandlerDex(DeployParams memory params) public returns (address) {
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: getMaxFeeRate(),
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        if (params.protocol == Protocol.TROPYKUS) {
            return address(
                new TropykusErc20HandlerDex(
                    params.dcaManager, 
                    params.tokenAddress, 
                    params.shareToken, 
                    params.uniswapSettings, 
                    params.feeCollector, 
                    feeSettings,
                    params.amountOutMinimumPercent,
                    params.amountOutMinimumSafetyCheck,
                    EXCHANGE_RATE_DECIMALS
                )
            );
        } else {
            return address(
                new SovrynErc20HandlerDex(
                    params.dcaManager, 
                    params.tokenAddress, 
                    params.shareToken, 
                    params.uniswapSettings, 
                    params.feeCollector, 
                    feeSettings,
                    params.amountOutMinimumPercent,
                    params.amountOutMinimumSafetyCheck,
                    EXCHANGE_RATE_DECIMALS
                )
            );
        }
    }

    function run() external returns (OperationsAdmin, address, DcaManager, DexHelperConfig) {
        // Initialize DexHelperConfig which reads the STABLECOIN_TYPE env var
        DexHelperConfig helperConfig = new DexHelperConfig();
        DexHelperConfig.NetworkConfig memory networkConfig = helperConfig.getActiveNetworkConfig();

        // Get stablecoin type (or use default if not specified)
        string memory stablecoinType;
        try vm.envString("STABLECOIN_TYPE") returns (string memory coinType) {
            stablecoinType = coinType;
        } catch {
            stablecoinType = DEFAULT_STABLECOIN;
        }
        
        console.log("Using stablecoin type:", stablecoinType);
        bool isUSDRIF = keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked("USDRIF"));
        
        // Get tokens based on current stablecoin type
        address stablecoinAddress = helperConfig.getStablecoinAddress();
        console.log("Stablecoin address:", stablecoinAddress);
        
        // Check if stablecoin is supported by the selected protocol
        bool isSovryn = protocol == Protocol.SOVRYN;
        
        if (isSovryn && isUSDRIF) {
            revert("USDRIF is not supported by Sovryn");
        }

        vm.startBroadcast();

        OperationsAdmin operationsAdmin = new OperationsAdmin();
        DcaManager dcaManager = new DcaManager(address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT);
        address feeCollector = getFeeCollector(environment);
        
        address docHandlerDexAddress;

        IPurchaseUniswap.UniswapSettings memory uniswapSettings = IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(networkConfig.wrbtcTokenAddress),
            swapRouter02: ISwapRouter02(networkConfig.swapRouter02Address),
            swapIntermediateTokens: networkConfig.swapIntermediateTokens,
            swapPoolFeeRates: networkConfig.swapPoolFeeRates,
            mocOracle: ICoinPairPrice(networkConfig.mocOracleAddress)
        });

        // For local or fork environments, deploy only the selected protocol's handler
        if (environment == Environment.LOCAL || environment == Environment.FORK) {
            console.log("Deploying single handler for local/fork environment");
            
            // Get the appropriate shares address based on protocol
            address shareTokenAddress = helperConfig.getShareTokenAddress();
            if (shareTokenAddress == address(0)) {
                revert("Share token not available for the selected combination");
            }
            
            console.log("Share token address:", shareTokenAddress);
            
            DeployParams memory params = DeployParams({
                protocol: protocol,
                dcaManager: address(dcaManager),
                tokenAddress: stablecoinAddress,
                shareToken: shareTokenAddress,
                uniswapSettings: uniswapSettings,
                feeCollector: feeCollector,
                amountOutMinimumPercent: networkConfig.amountOutMinimumPercent,
                amountOutMinimumSafetyCheck: networkConfig.amountOutMinimumSafetyCheck
            });
            
            docHandlerDexAddress = deployDocHandlerDex(params);

            address owner = adminAddresses[environment];
            operationsAdmin.transferOwnership(owner);
            dcaManager.transferOwnership(owner);
            Ownable(docHandlerDexAddress).transferOwnership(owner);
        }
        // For live networks (testnet/mainnet), deploy handlers for both lending protocols
        else if (environment == Environment.TESTNET || environment == Environment.MAINNET) {
            console.log("Deploying handlers for lending protocols for live network");

            // First register the lending protocols
            operationsAdmin.setAdminRole(tx.origin);
            operationsAdmin.addOrUpdateLendingProtocol(TROPYKUS_STRING, TROPYKUS_INDEX); // index 1
            operationsAdmin.addOrUpdateLendingProtocol(SOVRYN_STRING, SOVRYN_INDEX); // index 2

            // Deploy Tropykus handler if there's a valid shares
            address tropykusShareToken = helperConfig.getShareTokenAddress();
            
            if (tropykusShareToken == address(0)) {
                console.log("Warning: Tropykus shares not available for this stablecoin");
            } else {
                // Deploy Tropykus handler
                address tropykusHandler = deployDocHandlerDex(
                    DeployParams({
                        protocol: Protocol.TROPYKUS,
                        dcaManager: address(dcaManager),
                        tokenAddress: stablecoinAddress,
                        shareToken: tropykusShareToken,
                        uniswapSettings: uniswapSettings,
                        feeCollector: feeCollector,
                        amountOutMinimumPercent: networkConfig.amountOutMinimumPercent,
                        amountOutMinimumSafetyCheck: networkConfig.amountOutMinimumSafetyCheck
                    })
                );
                console.log("Tropykus handler deployed at:", tropykusHandler);
                
                // Assign the Tropykus handler to the DCA manager
                operationsAdmin.assignOrUpdateTokenHandler(stablecoinAddress, TROPYKUS_INDEX, tropykusHandler);
                
                // If we're deploying for Tropykus, set this as our main handler
                if (protocol == Protocol.TROPYKUS) {
                    docHandlerDexAddress = tropykusHandler;
                }
            }

            // Only deploy Sovryn handler if the stablecoin is supported by Sovryn
            if (!isUSDRIF) {
                // Get Sovryn shares address
                address sovrynShareToken = helperConfig.getShareTokenAddress();
                
                if (sovrynShareToken == address(0)) {
                    console.log("Warning: Sovryn shares not available for this stablecoin");
                } else {
                    // Deploy Sovryn handler
                    address sovrynHandler = deployDocHandlerDex(
                        DeployParams({
                            protocol: Protocol.SOVRYN,
                            dcaManager: address(dcaManager),
                            tokenAddress: stablecoinAddress,
                            shareToken: sovrynShareToken,
                            uniswapSettings: uniswapSettings,
                            feeCollector: feeCollector,
                            amountOutMinimumPercent: networkConfig.amountOutMinimumPercent,
                            amountOutMinimumSafetyCheck: networkConfig.amountOutMinimumSafetyCheck
                        })
                    );
                    console.log("Sovryn handler deployed at:", sovrynHandler);
                    
                    // Assign the Sovryn handler to the DCA manager
                    operationsAdmin.assignOrUpdateTokenHandler(stablecoinAddress, SOVRYN_INDEX, sovrynHandler);
                    
                    // If we're deploying for Sovryn, set this as our main handler
                    if (protocol == Protocol.SOVRYN) {
                        docHandlerDexAddress = sovrynHandler;
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

        return (operationsAdmin, docHandlerDexAddress, dcaManager, helperConfig);
    }
}
