// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {UsdrifHelperConfig} from "./UsdrifHelperConfig.s.sol";
import {TropykusErc20HandlerDex} from "../src/tropykus-legacy/TropykusErc20HandlerDex.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {DcaManager} from "../src/DcaManager.sol";
import {IPurchaseUniswap} from "../src/interfaces/IPurchaseUniswap.sol";
import {IFeeHandler} from "../src/interfaces/IFeeHandler.sol";
import {IWRBTC} from "../src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "../src/interfaces/ICoinPairPrice.sol";
import {console} from "forge-std/Test.sol";
import "./Constants.sol";


contract DeployUsdrifHandler is DeployBase {
    // Struct to group deployment parameters to avoid stack too deep errors
    struct DeployParams {
        address dcaManagerAddress;
        address tokenAddress;
        address shareTokenAddress;
        IPurchaseUniswap.UniswapSettings uniswapSettings;
        address feeCollector;
        IFeeHandler.FeeSettings feeSettings;
        uint256 amountOutMinimumPercent;
        uint256 amountOutMinimumSafetyCheck;
        address initialOwner;
    }

    function run(UsdrifHelperConfig existingConfig) external returns (address) {
        // Use the provided config or create a new one if not provided
        UsdrifHelperConfig helperConfig = existingConfig != UsdrifHelperConfig(address(0)) 
            ? existingConfig 
            : new UsdrifHelperConfig();
        
        UsdrifHelperConfig.NetworkConfig memory networkConfig = helperConfig.getNetworkConfig();
        
        // Validate addresses
        if (networkConfig.operationsAdminAddress == address(0) || networkConfig.dcaManagerAddress == address(0)) {
            revert("OperationsAdmin and DcaManager addresses must be set in UsdrifHelperConfig");
        }
        
        console.log("OperationsAdmin address:", networkConfig.operationsAdminAddress);
        console.log("DcaManager address:", networkConfig.dcaManagerAddress);

        OperationsAdmin operationsAdmin = OperationsAdmin(networkConfig.operationsAdminAddress);
        _requireNoPendingOwner(operationsAdmin);
        _requireNoPendingOwner(DcaManager(networkConfig.dcaManagerAddress));
        
        vm.startBroadcast();
        
        // Get fee collector address
        address feeCollector = getFeeCollector(environment);
        
        // Set up Uniswap settings
        IPurchaseUniswap.UniswapSettings memory uniswapSettings = IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(networkConfig.wrbtcTokenAddress),
            swapRouter02: ISwapRouter02(networkConfig.swapRouter02Address),
            swapIntermediateTokens: networkConfig.swapIntermediateTokens,
            swapPoolFeeRates: networkConfig.swapPoolFeeRates,
            mocOracle: ICoinPairPrice(networkConfig.mocOracleAddress)
        });
        
        // Set up fee settings
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: getMaxFeeRate(),
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });
        
        // Set up deployment parameters
        DeployParams memory params = DeployParams({
            dcaManagerAddress: networkConfig.dcaManagerAddress,
            tokenAddress: networkConfig.usdrifTokenAddress,
            shareTokenAddress: networkConfig.kUsdrifTokenAddress,
            uniswapSettings: uniswapSettings,
            feeCollector: feeCollector,
            feeSettings: feeSettings,
            amountOutMinimumPercent: networkConfig.amountOutMinimumPercent,
            amountOutMinimumSafetyCheck: networkConfig.amountOutMinimumSafetyCheck,
            initialOwner: operationsAdmin.owner()
        });
        
        // Deploy the USDRIF handler
        TropykusErc20HandlerDex usdrifHandler = new TropykusErc20HandlerDex(
            params.dcaManagerAddress,
            params.tokenAddress,
            params.shareTokenAddress,
            params.uniswapSettings,
            params.feeCollector,
            params.feeSettings,
            params.amountOutMinimumPercent,
            params.amountOutMinimumSafetyCheck,
            params.initialOwner
        );
        
        console.log("USDRIF handler deployed at:", address(usdrifHandler));
        
        if (msg.sender != operationsAdmin.owner()) {
            console.log("Warning: Deployer is not the owner. Cannot register handler.");
            console.log("Please call operationsAdmin.assignTokenHandler() as owner with:");
            console.log("tokenAddress:", networkConfig.usdrifTokenAddress);
            console.log("index:", TROPYKUS_INDEX);
            console.log("handlerAddress:", address(usdrifHandler));
        } else {
            // Occupied `(token, TROPYKUS_INDEX)` reverts `HandlerAlreadyAssigned` — do not skip.
            operationsAdmin.assignTokenHandler(
                networkConfig.usdrifTokenAddress,
                TROPYKUS_INDEX,
                address(usdrifHandler)
            );

            console.log("USDRIF handler registered with OperationsAdmin using Tropykus index", TROPYKUS_INDEX);
        }

        console.log("Handler owner:", params.initialOwner);
        
        vm.stopBroadcast();
        
        return address(usdrifHandler);
    }
}
