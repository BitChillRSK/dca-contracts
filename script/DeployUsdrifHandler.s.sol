// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {UsdrifHelperConfig} from "./UsdrifHelperConfig.s.sol";
import {LayerBankErc20HandlerDex} from "../src/layerbank/LayerBankErc20HandlerDex.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {DcaManager} from "../src/DcaManager.sol";
import {IOperationsAdmin} from "../src/interfaces/IOperationsAdmin.sol";
import {IPurchaseUniswap} from "../src/interfaces/IPurchaseUniswap.sol";
import {IFeeHandler} from "../src/interfaces/IFeeHandler.sol";
import {IWRBTC} from "../src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "../src/interfaces/ICoinPairPrice.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "../test/mocks/MockLayerBank.sol";
import {console} from "forge-std/Test.sol";
import "./Constants.sol";

/**
 * @title DeployUsdrifHandler
 * @notice Dex-stable add-on: one `LayerBankErc20HandlerDex` keyed off `STABLECOIN_TYPE` (USDRIF or USDT0).
 * @dev Replaces the Tropykus USDRIF arm. Live TESTNET/MAINNET (`REAL_DEPLOYMENT=true`) bind the
 *      looked-up LayerBank aToken. `getEnvironment()` returns FORK for a real RSK RPC unless that
 *      env var is set — FORK must not take the live path (test `feeCollector` / 2% cap would
 *      permanently occupy `(token, LAYERBANK_INDEX)`). Occupied `(token, LAYERBANK_INDEX)` reverts
 *      `HandlerAlreadyAssigned` — do not skip. USDT0 live path uses 6-decimal fee bounds and
 *      `setTokenMinPurchaseAmount`.
 */
contract DeployUsdrifHandler is DeployBase {
    struct DeployParams {
        address dcaManagerAddress;
        address tokenAddress;
        address aTokenAddress;
        IPurchaseUniswap.UniswapSettings uniswapSettings;
        address feeCollector;
        IFeeHandler.FeeSettings feeSettings;
        uint256 amountOutMinimumPercent;
        uint256 amountOutMinimumSafetyCheck;
        address initialOwner;
    }

    function deployLayerBankErc20HandlerDex(DeployParams memory params) public returns (address) {
        return address(
            new LayerBankErc20HandlerDex(
                params.dcaManagerAddress,
                params.tokenAddress,
                params.aTokenAddress,
                params.uniswapSettings,
                params.feeCollector,
                params.feeSettings,
                params.amountOutMinimumPercent,
                params.amountOutMinimumSafetyCheck,
                params.initialOwner
            )
        );
    }

    /**
     * @notice Deploy Pool/aToken mocks and the dex handler. Used by tests on Anvil and on a fork.
     * @dev Does not `broadcast` or call `assignTokenHandler`. `run()` broadcasts.
     *      `params.aTokenAddress` is ignored; a fresh mock aToken is bound to `params.tokenAddress`.
     */
    function deployMocksAndHandler(DeployParams memory params) public returns (address handler) {
        MockLayerBankAToken aToken = new MockLayerBankAToken(params.tokenAddress);
        MockLayerBankPool pool = new MockLayerBankPool(aToken);
        aToken.setPool(address(pool));
        params.aTokenAddress = address(aToken);
        return deployLayerBankErc20HandlerDex(params);
    }

    /// @notice Live USDT0 uses 6-decimal bounds; Anvil mocks stay 18-decimal so local USDT0 keeps DOC/USDRIF units.
    function feeSettingsForToken(bool isUsdt0Live) public view returns (IFeeHandler.FeeSettings memory) {
        return IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: getMaxFeeRate(),
            feePurchaseLowerBound: isUsdt0Live ? USDT0_FEE_PURCHASE_LOWER_BOUND : FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: isUsdt0Live ? USDT0_FEE_PURCHASE_UPPER_BOUND : FEE_PURCHASE_UPPER_BOUND
        });
    }

    function run(UsdrifHelperConfig existingConfig) external returns (address) {
        UsdrifHelperConfig helperConfig = address(existingConfig) != address(0)
            ? existingConfig
            : new UsdrifHelperConfig();

        UsdrifHelperConfig.NetworkConfig memory networkConfig = helperConfig.getNetworkConfig();

        if (networkConfig.operationsAdminAddress == address(0) || networkConfig.dcaManagerAddress == address(0)) {
            revert("OperationsAdmin and DcaManager addresses must be set in UsdrifHelperConfig");
        }

        bool isUsdt0 = helperConfig.isUsdt0();
        address tokenAddress = helperConfig.getTokenAddress();

        console.log("OperationsAdmin address:", networkConfig.operationsAdminAddress);
        console.log("DcaManager address:", networkConfig.dcaManagerAddress);
        console.log("Stablecoin:", isUsdt0 ? USDT0_STRING : USDRIF_STRING);
        console.log("Token address:", tokenAddress);

        OperationsAdmin operationsAdmin = OperationsAdmin(networkConfig.operationsAdminAddress);
        DcaManager dcaManager = DcaManager(networkConfig.dcaManagerAddress);
        _requireNoPendingOwner(operationsAdmin);
        _requireNoPendingOwner(dcaManager);

        vm.startBroadcast();

        bool isUsdt0Live = isUsdt0 && _isLiveEnvironment();
        DeployParams memory params = DeployParams({
            dcaManagerAddress: networkConfig.dcaManagerAddress,
            tokenAddress: tokenAddress,
            aTokenAddress: helperConfig.getATokenAddress(),
            uniswapSettings: _uniswapSettings(networkConfig, isUsdt0),
            feeCollector: getFeeCollector(environment),
            feeSettings: feeSettingsForToken(isUsdt0Live),
            amountOutMinimumPercent: networkConfig.amountOutMinimumPercent,
            amountOutMinimumSafetyCheck: networkConfig.amountOutMinimumSafetyCheck,
            initialOwner: operationsAdmin.owner()
        });

        address handler;
        if (environment == Environment.LOCAL) {
            handler = deployMocksAndHandler(params);
        } else if (environment == Environment.TESTNET || environment == Environment.MAINNET) {
            if (params.aTokenAddress == address(0)) {
                revert("LayerBank aToken address is not configured for this network");
            }
            handler = deployLayerBankErc20HandlerDex(params);
        } else {
            revert("DeployUsdrifHandler live path requires REAL_DEPLOYMENT=true");
        }

        console.log("LayerBank dex handler deployed at:", handler);
        _maybeAssign(operationsAdmin, dcaManager, tokenAddress, handler, isUsdt0Live);

        vm.stopBroadcast();

        return handler;
    }

    function _uniswapSettings(UsdrifHelperConfig.NetworkConfig memory networkConfig, bool isUsdt0)
        internal
        pure
        returns (IPurchaseUniswap.UniswapSettings memory)
    {
        address[] memory intermediates = networkConfig.swapIntermediateTokens;
        uint24[] memory fees = networkConfig.swapPoolFeeRates;
        if (isUsdt0) {
            intermediates = new address[](0);
            fees = new uint24[](1);
            fees[0] = 3000;
        }
        return IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(networkConfig.wrbtcTokenAddress),
            swapRouter02: ISwapRouter02(networkConfig.swapRouter02Address),
            swapIntermediateTokens: intermediates,
            swapPoolFeeRates: fees,
            mocOracle: ICoinPairPrice(networkConfig.mocOracleAddress)
        });
    }

    function _maybeAssign(
        OperationsAdmin operationsAdmin,
        DcaManager dcaManager,
        address tokenAddress,
        address handler,
        bool isUsdt0Live
    ) internal {
        bool isOwner = msg.sender == operationsAdmin.owner();

        if (!isOwner) {
            console.log("Warning: Deployer is not the owner. Cannot register handler.");
            console.log("Please call operationsAdmin.registerRoute + assignTokenHandler as owner with:");
            console.log("tokenAddress:", tokenAddress);
            console.log("index:", LAYERBANK_INDEX);
            console.log("handlerAddress:", handler);
            return;
        }
        if (operationsAdmin.getRouteClass(LAYERBANK_INDEX) == IOperationsAdmin.RouteClass.Unregistered) {
            operationsAdmin.registerRoute(LAYERBANK_INDEX, true);
        }
        operationsAdmin.assignTokenHandler(tokenAddress, LAYERBANK_INDEX, handler);
        console.log("LayerBank dex handler registered with OperationsAdmin at index", LAYERBANK_INDEX);

        if (isUsdt0Live) {
            dcaManager.setTokenMinPurchaseAmount(tokenAddress, USDT0_MIN_PURCHASE_AMOUNT);
            console.log("USDT0 min purchase amount set to", USDT0_MIN_PURCHASE_AMOUNT);
        }
    }
}
