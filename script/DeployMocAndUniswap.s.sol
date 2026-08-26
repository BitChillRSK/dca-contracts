// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {DeployBase} from "./DeployBase.s.sol";
import {DeployMocSwaps} from "./DeployMocSwaps.s.sol";
import {DeployDexSwaps} from "./DeployDexSwaps.s.sol";
import {MocHelperConfig} from "./MocHelperConfig.s.sol";
import {DexHelperConfig} from "./DexHelperConfig.s.sol";
import {DcaManager} from "../src/DcaManager.sol";
import {IPurchaseUniswap} from "../src/interfaces/IPurchaseUniswap.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {IWRBTC} from "../src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "../src/interfaces/ICoinPairPrice.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {console} from "forge-std/Test.sol";
import "./Constants.sol";

contract DeployMocAndUniswap is DeployBase {
    // Define a struct to hold all deployment results
    struct DeployedContracts {
        // MoC contracts
        OperationsAdmin adOpsMoc;
        address handlerMoc;
        DcaManager dcaManMoc;
        MocHelperConfig helpConfMoc;
        
        // Uniswap contracts
        OperationsAdmin adOpsUni;
        address handlerUni;
        DcaManager dcaManUni;
        DexHelperConfig helpConfUni;
    }
    
    // Struct for DeployDexSwaps parameters to avoid stack too deep errors
    struct DexDeployParams {
        Protocol protocol;
        address dcaManager;
        address tokenAddress;
        address shareToken;
        IPurchaseUniswap.UniswapSettings uniswapSettings;
        address feeCollector;
        uint256 amountOutMinimumPercent;
        uint256 amountOutMinimumSafetyCheck;
    }
    
    string stablecoinType;
    
    constructor() {
        // Initialize stablecoin type from environment or use default
        try vm.envString("STABLECOIN_TYPE") returns (string memory coinType) {
            stablecoinType = coinType;
        } catch {
            stablecoinType = DEFAULT_STABLECOIN;
        }
    }
    
    // Split the deployment into smaller functions to avoid stack too deep errors
    function deployMocContracts() 
        private 
        returns (
            OperationsAdmin adOpsMoc,
            address handlerMoc,
            DcaManager dcaManMoc,
            MocHelperConfig helpConfMoc
        ) 
    {
        helpConfMoc = new MocHelperConfig();
        MocHelperConfig.NetworkConfig memory networkConfig = helpConfMoc.getActiveNetworkConfig();
        
        vm.startBroadcast();
        // Deploy admin operations and DCA manager
        adOpsMoc = new OperationsAdmin();
        dcaManMoc = new DcaManager(address(adOpsMoc), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT);
        
        // Get fee collector address
        address feeCollector = getFeeCollector(environment);
        
        // Get token addresses from network config
        address docTokenAddress = networkConfig.docTokenAddress;
        address mocProxy = networkConfig.mocProxyAddress;
        
        // Select the appropriate shares based on protocol
        address shareToken;
        
        if (protocol == Protocol.TROPYKUS) {
            shareToken = networkConfig.kDocAddress;
        } else if (protocol == Protocol.SOVRYN) {
            // Check if this stablecoin is supported by Sovryn
            bool isUSDRIF = keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked("USDRIF"));
            if (isUSDRIF) {
                revert("USDRIF is not supported by Sovryn");
            }
            shareToken = networkConfig.iSusdAddress;
        } else {
            revert("Unsupported lending protocol");
        }

        vm.stopBroadcast();

        // Deploy MoC handler
        DeployMocSwaps deployMocSwapContracts = new DeployMocSwaps();
        
        // Create a DeployParams struct to pass to deployDocHandlerMoc
        DeployMocSwaps.DeployParams memory params = DeployMocSwaps.DeployParams({
            protocol: protocol,
            dcaManager: address(dcaManMoc),
            tokenAddress: docTokenAddress,
            shareToken: shareToken,
            mocProxy: mocProxy,
            feeCollector: feeCollector
        });
        
        handlerMoc = deployMocSwapContracts.deployDocHandlerMoc(params);
        console.log("MoC handler deployed at:", handlerMoc);
        
        // Get owner address based on environment
        address owner = adminAddresses[environment];
        
        vm.startBroadcast();

        // Transfer ownership of contracts
        adOpsMoc.transferOwnership(owner);
        dcaManMoc.transferOwnership(owner);
        Ownable(handlerMoc).transferOwnership(owner);
        
        vm.stopBroadcast();
    }
    
    function deployUniswapContracts() 
        private 
        returns (
            OperationsAdmin adOpsUni,
            address handlerUni,
            DcaManager dcaManUni,
            DexHelperConfig helpConfUni
        ) 
    {
        helpConfUni = new DexHelperConfig();
        DexHelperConfig.NetworkConfig memory networkConfig = helpConfUni.getActiveNetworkConfig();
        
        vm.startBroadcast();
        // Deploy admin operations and DCA manager
        adOpsUni = new OperationsAdmin();
        dcaManUni = new DcaManager(address(adOpsUni), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT);
        
        // Get fee collector address
        address feeCollector = getFeeCollector(environment);
        
        // Get token addresses from network config
        address stablecoinAddress = networkConfig.stablecoinAddress;
        
        // Select the appropriate shares based on protocol
        address shareToken;
        
        if (protocol == Protocol.TROPYKUS) {
            shareToken = networkConfig.tropykusShareToken;
        } else if (protocol == Protocol.SOVRYN) {
            // Check if this stablecoin is supported by Sovryn
            bool isUSDRIF = keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked("USDRIF"));
            if (isUSDRIF) {
                revert("USDRIF is not supported by Sovryn");
            }
            shareToken = networkConfig.sovrynShareToken;
        } else {
            revert("Unsupported lending protocol");
        }
        
        // Create Uniswap settings from the network config
        IPurchaseUniswap.UniswapSettings memory uniswapSettings = IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(networkConfig.wrbtcTokenAddress),
            swapRouter02: ISwapRouter02(networkConfig.swapRouter02Address),
            swapIntermediateTokens: networkConfig.swapIntermediateTokens,
            swapPoolFeeRates: networkConfig.swapPoolFeeRates,
            mocOracle: ICoinPairPrice(networkConfig.mocOracleAddress)
        });
        
        vm.stopBroadcast();

        // Create deployment parameters struct
        DexDeployParams memory params = DexDeployParams({
            protocol: protocol,
            dcaManager: address(dcaManUni),
            tokenAddress: stablecoinAddress,
            shareToken: shareToken,
            uniswapSettings: uniswapSettings,
            feeCollector: feeCollector,
            amountOutMinimumPercent: networkConfig.amountOutMinimumPercent,
            amountOutMinimumSafetyCheck: networkConfig.amountOutMinimumSafetyCheck
        });

        // Deploy Uniswap handler
        DeployDexSwaps deployDexSwapContracts = new DeployDexSwaps();
        handlerUni = deployDexSwapContracts.deployDocHandlerDex(
            DeployDexSwaps.DeployParams({
                protocol: params.protocol,
                dcaManager: params.dcaManager,
                tokenAddress: params.tokenAddress,
                shareToken: params.shareToken,
                uniswapSettings: params.uniswapSettings,
                feeCollector: params.feeCollector,
                amountOutMinimumPercent: params.amountOutMinimumPercent,
                amountOutMinimumSafetyCheck: params.amountOutMinimumSafetyCheck
            })
        );
        console.log("Uniswap handler deployed at:", handlerUni);
        
        // Get owner address based on environment
        address owner = adminAddresses[environment];
        
        vm.startBroadcast();

        // Transfer ownership of contracts
        adOpsUni.transferOwnership(owner);
        dcaManUni.transferOwnership(owner);
        Ownable(handlerUni).transferOwnership(owner);
        
        vm.stopBroadcast();
    }

    function run()
        external
        returns (DeployedContracts memory contracts)
    {
        console.log("Deploying both MoC and Uniswap handlers for comparison");
        console.log("Using stablecoin type:", stablecoinType);
        
        // Deploy MoC contracts
        (contracts.adOpsMoc, contracts.handlerMoc, contracts.dcaManMoc, contracts.helpConfMoc) = deployMocContracts();
        
        // Deploy Uniswap contracts
        (contracts.adOpsUni, contracts.handlerUni, contracts.dcaManUni, contracts.helpConfUni) = deployUniswapContracts();
        
        return contracts;
    }
}
