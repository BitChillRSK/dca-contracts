// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {DexHelperConfig} from "./DexHelperConfig.s.sol";
import {DcaManager} from "../src/DcaManager.sol";
import {TropykusErc20HandlerDex} from "../src/tropykus-legacy/TropykusErc20HandlerDex.sol";
import {SovrynErc20HandlerDex} from "../src/sovryn/SovrynErc20HandlerDex.sol";
import {LayerBankErc20HandlerDex} from "../src/layerbank/LayerBankErc20HandlerDex.sol";
import {IdleErc20HandlerDex} from "../src/idle/IdleErc20HandlerDex.sol";
import {IPurchaseUniswap} from "../src/interfaces/IPurchaseUniswap.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {IWRBTC} from "../src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "../src/interfaces/ICoinPairPrice.sol";
import {IFeeHandler} from "../src/interfaces/IFeeHandler.sol";
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

    function _isUsdt0(string memory stablecoinType) internal pure returns (bool) {
        return keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked(USDT0_STRING));
    }

    function _isUsdrif(string memory stablecoinType) internal pure returns (bool) {
        return keccak256(abi.encodePacked(stablecoinType)) == keccak256(abi.encodePacked(USDRIF_STRING));
    }

    /// @notice Live USDT0 uses 6-decimal bounds; local/fork mocks stay 18-decimal.
    function feeSettingsForToken(bool isUsdt0Live) public view returns (IFeeHandler.FeeSettings memory) {
        return IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: getMaxFeeRate(),
            feePurchaseLowerBound: isUsdt0Live ? USDT0_FEE_PURCHASE_LOWER_BOUND : FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: isUsdt0Live ? USDT0_FEE_PURCHASE_UPPER_BOUND : FEE_PURCHASE_UPPER_BOUND
        });
    }

    function deployDocHandlerDex(DeployParams memory params) public returns (address) {
        bool isUsdt0Live = _isLiveEnvironment() && _isUsdt0(_stablecoinType());
        IFeeHandler.FeeSettings memory feeSettings = feeSettingsForToken(isUsdt0Live);

        if (params.protocol == Protocol.NONE) {
            return address(
                new IdleErc20HandlerDex(
                    params.dcaManager,
                    params.tokenAddress,
                    params.uniswapSettings,
                    params.feeCollector,
                    feeSettings,
                    params.amountOutMinimumPercent,
                    params.amountOutMinimumSafetyCheck,
                    _initialOwner()
                )
            );
        }
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
                    _initialOwner()
                )
            );
        }
        if (params.protocol == Protocol.SOVRYN) {
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
                    _initialOwner()
                )
            );
        }
        if (params.protocol == Protocol.LAYERBANK) {
            return address(
                new LayerBankErc20HandlerDex(
                    params.dcaManager,
                    params.tokenAddress,
                    params.shareToken,
                    params.uniswapSettings,
                    params.feeCollector,
                    feeSettings,
                    params.amountOutMinimumPercent,
                    params.amountOutMinimumSafetyCheck,
                    _initialOwner()
                )
            );
        }
        revert("Dex path is none/tropykus/sovryn/layerbank");
    }

    function _deployLiveDexHandlers(
        OperationsAdmin operationsAdmin,
        DcaManager dcaManager,
        address stablecoinAddress,
        DexHelperConfig.NetworkConfig memory networkConfig,
        IPurchaseUniswap.UniswapSettings memory uniswapSettings,
        address feeCollector,
        bool isUSDRIF,
        bool isUSDT0
    ) internal returns (address selectedHandler) {
        // Live dex stables are USDRIF / USDT0. Production map: idle=0, LayerBank=1; Sovryn is
        // registered as a lending class but has no handler for these stables. DexHelperConfig's
        // else arm is DOC config, so anything not exactly those two (unset STABLECOIN_TYPE, DOC,
        // or a typo) must revert — DOC buys rBTC through MoC redemption. Tropykus is test-only.
        if (protocol == Protocol.TROPYKUS) {
            revert("Tropykus is not on the production dex map");
        }
        if (!isUSDRIF && !isUSDT0) {
            revert("DOC is not on the production dex map");
        }

        console.log("Deploying production dex handlers (idle / LayerBank)");

        // Owner is the Foundry broadcaster for this transaction so route registration succeeds.
        // Mainnet proposes MAINNET_OWNER (the Safe) after setup. Index 0 is already Idle.
        operationsAdmin.registerRoute(SOVRYN_INDEX, true);
        operationsAdmin.registerRoute(LAYERBANK_INDEX, true);

        address idleHandler = deployDocHandlerDex(
            DeployParams({
                protocol: Protocol.NONE,
                dcaManager: address(dcaManager),
                tokenAddress: stablecoinAddress,
                shareToken: address(0),
                uniswapSettings: uniswapSettings,
                feeCollector: feeCollector,
                amountOutMinimumPercent: networkConfig.amountOutMinimumPercent,
                amountOutMinimumSafetyCheck: networkConfig.amountOutMinimumSafetyCheck
            })
        );
        console.log("Idle dex handler deployed at:", idleHandler);
        operationsAdmin.assignTokenHandler(stablecoinAddress, IDLE_INDEX, idleHandler);
        _proposeFinalOwner(idleHandler);
        if (protocol == Protocol.NONE) {
            selectedHandler = idleHandler;
        }

        address layerbankAToken = networkConfig.layerbankAToken;
        if (layerbankAToken == address(0)) {
            if (protocol == Protocol.LAYERBANK) {
                revert("LayerBank aToken not available on this network");
            }
            console.log("Warning: LayerBank aToken not available for this dex stable");
        } else {
            address layerbankHandler = deployDocHandlerDex(
                DeployParams({
                    protocol: Protocol.LAYERBANK,
                    dcaManager: address(dcaManager),
                    tokenAddress: stablecoinAddress,
                    shareToken: layerbankAToken,
                    uniswapSettings: uniswapSettings,
                    feeCollector: feeCollector,
                    amountOutMinimumPercent: networkConfig.amountOutMinimumPercent,
                    amountOutMinimumSafetyCheck: networkConfig.amountOutMinimumSafetyCheck
                })
            );
            console.log("LayerBank dex handler deployed at:", layerbankHandler);
            operationsAdmin.assignTokenHandler(stablecoinAddress, LAYERBANK_INDEX, layerbankHandler);
            _proposeFinalOwner(layerbankHandler);
            if (protocol == Protocol.LAYERBANK) {
                selectedHandler = layerbankHandler;
            }
        }

        if (isUSDT0) {
            dcaManager.setTokenMinPurchaseAmount(stablecoinAddress, USDT0_MIN_PURCHASE_AMOUNT);
            console.log("USDT0 min purchase amount set to", USDT0_MIN_PURCHASE_AMOUNT);
        }
    }

    function run() external returns (OperationsAdmin, address, DcaManager, DexHelperConfig) {
        _assertLiveBroadcastSender(msg.sender);
        // Initialize DexHelperConfig which reads the STABLECOIN_TYPE env var
        DexHelperConfig helperConfig = new DexHelperConfig();
        DexHelperConfig.NetworkConfig memory networkConfig = helperConfig.getActiveNetworkConfig();

        string memory stablecoinType = _stablecoinType();
        
        console.log("Using stablecoin type:", stablecoinType);
        bool isUSDRIF = _isUsdrif(stablecoinType);
        bool isUSDT0 = _isUsdt0(stablecoinType);
        
        address stablecoinAddress = helperConfig.getStablecoinAddress();
        console.log("Stablecoin address:", stablecoinAddress);
        
        bool isSovryn = protocol == Protocol.SOVRYN;
        
        if (isSovryn && (isUSDRIF || isUSDT0)) {
            revert("Sovryn does not list this stablecoin");
        }

        _beginLiveAwareBroadcast(msg.sender);

        OperationsAdmin operationsAdmin = new OperationsAdmin(deployOwner);
        DcaManager dcaManager = new DcaManager(
            address(operationsAdmin),
            MIN_PURCHASE_PERIOD,
            MAX_SCHEDULES_PER_TOKEN,
            MIN_PURCHASE_AMOUNT,
            deployOwner
        );
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
                tokenAddress: stablecoinAddress,
                shareToken: shareTokenAddress,
                uniswapSettings: uniswapSettings,
                feeCollector: feeCollector,
                amountOutMinimumPercent: networkConfig.amountOutMinimumPercent,
                amountOutMinimumSafetyCheck: networkConfig.amountOutMinimumSafetyCheck
            });

            docHandlerDexAddress = deployDocHandlerDex(params);
        }
        // Live: idle + LayerBank Dex handlers for USDRIF / USDT0 (DOC stays on MoC).
        else if (environment == Environment.TESTNET || environment == Environment.MAINNET) {
            docHandlerDexAddress = _deployLiveDexHandlers(
                operationsAdmin,
                dcaManager,
                stablecoinAddress,
                networkConfig,
                uniswapSettings,
                feeCollector,
                isUSDRIF,
                isUSDT0
            );
        }

        _proposeFinalOwner(address(operationsAdmin));
        _proposeFinalOwner(address(dcaManager));
        _proposeFinalOwner(docHandlerDexAddress);

        vm.stopBroadcast();

        return (operationsAdmin, docHandlerDexAddress, dcaManager, helperConfig);
    }

    function _stablecoinType() internal view returns (string memory stablecoinType) {
        try vm.envString("STABLECOIN_TYPE") returns (string memory coinType) {
            stablecoinType = coinType;
        } catch {
            stablecoinType = DOC_STRING;
        }
    }
}
