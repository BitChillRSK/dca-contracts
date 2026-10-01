// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {UsdrifHelperConfig} from "./UsdrifHelperConfig.s.sol";
import {LayerBankHandlerDex} from "../src/layerbank/LayerBankHandlerDex.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {DcaManager} from "../src/DcaManager.sol";
import {IOperationsAdmin} from "../src/interfaces/IOperationsAdmin.sol";
import {IPurchaseUniswap} from "../src/interfaces/IPurchaseUniswap.sol";
import {IPurchaseFees} from "../src/interfaces/IPurchaseFees.sol";
import {IWRBTC} from "../src/interfaces/IWRBTC.sol";
import {IUniswapV3SwapRouter} from "../src/interfaces/IUniswapV3SwapRouter.sol";
import {ICoinPairPrice} from "../src/interfaces/ICoinPairPrice.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "../test/mocks/MockLayerBank.sol";
import {console} from "forge-std/Test.sol";
import "./Constants.sol";

/**
 * @title DeployUsdrifHandler
 * @notice Dex-stable add-on: one `LayerBankHandlerDex` keyed off `STABLECOIN_TYPE` (USDRIF or USDT0).
 * @dev Replaces the Tropykus USDRIF arm. Live TESTNET/MAINNET (`REAL_DEPLOYMENT=true`) bind the
 *      looked-up LayerBank aToken. `getEnvironment()` returns FORK for a real RSK RPC unless that
 *      env var is set — FORK must not take the live path (test `feeCollector` / 2% cap would
 *      permanently occupy `(token, LAYERBANK_INDEX)`). Occupied `(token, LAYERBANK_INDEX)` reverts
 *      `HandlerAlreadyAssigned` — do not skip. USDT0 live path uses 6-decimal fee bounds and
 *      `setTokenMinPurchaseAmount`. Mainnet add-on: the Foundry EOA is not the Safe, so `run()`
 *      deploys then returns without assigning. The constructor already allowlists the initial path.
 *      The Safe must read `getSwapPath()` and confirm the intended route, then `assignHandler`
 *      **and** `setTokenMinPurchaseAmount` (USDRIF `25 ether`, USDT0 `25e6`). There is no
 *      protocol-wide default min. See README "Ownership after deploy".
 */
contract DeployUsdrifHandler is DeployBase {
    struct DeployParams {
        address dcaManager;
        address stablecoin;
        address aToken;
        IPurchaseUniswap.UniswapSettings uniswapSettings;
        address feeCollector;
        IPurchaseFees.FeeSettings feeSettings;
        uint256 amountOutMinimumPercent;
        uint256 amountOutMinimumSafetyCheck;
        address initialOwner;
    }

    function deployLayerBankHandlerDex(DeployParams memory params) public returns (address) {
        return address(
            new LayerBankHandlerDex(
                params.dcaManager,
                params.stablecoin,
                params.aToken,
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
     * @dev Does not `broadcast` or call `assignHandler`. `run()` broadcasts.
     *      `params.aToken` is ignored; a fresh mock aToken is bound to `params.stablecoin`.
     */
    function deployMocksAndHandler(DeployParams memory params) public returns (address handler) {
        MockLayerBankAToken aToken = new MockLayerBankAToken(params.stablecoin);
        MockLayerBankPool pool = new MockLayerBankPool(aToken);
        aToken.setPool(address(pool));
        params.aToken = address(aToken);
        return deployLayerBankHandlerDex(params);
    }

    /// @notice Live USDT0 uses 6-decimal bounds; Anvil mocks stay 18-decimal so local USDT0 keeps DOC/USDRIF units.
    function feeSettingsForToken(bool isUsdt0Live) public view returns (IPurchaseFees.FeeSettings memory) {
        return IPurchaseFees.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: getMaxFeeRate(),
            feePurchaseLowerBound: isUsdt0Live ? USDT0_FEE_PURCHASE_LOWER_BOUND : FEE_PURCHASE_LOWER_BOUND
        });
    }

    function run(UsdrifHelperConfig existingConfig) external returns (address) {
        UsdrifHelperConfig helperConfig =
            address(existingConfig) != address(0) ? existingConfig : new UsdrifHelperConfig();

        UsdrifHelperConfig.NetworkConfig memory networkConfig = helperConfig.getNetworkConfig();

        if (networkConfig.operationsAdmin == address(0) || networkConfig.dcaManager == address(0)) {
            revert("OperationsAdmin and DcaManager addresses must be set in UsdrifHelperConfig");
        }

        bool isUsdt0 = helperConfig.isUsdt0();
        address stablecoin = helperConfig.getToken();

        console.log("OperationsAdmin address:", networkConfig.operationsAdmin);
        console.log("DcaManager address:", networkConfig.dcaManager);
        console.log("Stablecoin:", isUsdt0 ? USDT0_STRING : USDRIF_STRING);
        console.log("Token address:", stablecoin);

        OperationsAdmin operationsAdmin = OperationsAdmin(networkConfig.operationsAdmin);
        DcaManager dcaManager = DcaManager(networkConfig.dcaManager);
        _requireNoPendingOwner(operationsAdmin);
        _requireNoPendingOwner(dcaManager);

        vm.startBroadcast();

        bool isUsdt0Live = isUsdt0 && _isLiveEnvironment();
        DeployParams memory params = DeployParams({
            dcaManager: networkConfig.dcaManager,
            stablecoin: stablecoin,
            aToken: helperConfig.getAToken(),
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
            if (params.aToken == address(0)) {
                revert("LayerBank aToken address is not configured for this network");
            }
            handler = deployLayerBankHandlerDex(params);
        } else {
            revert("DeployUsdrifHandler live path requires REAL_DEPLOYMENT=true");
        }

        console.log("LayerBank dex handler deployed at:", handler);
        _maybeAssign(operationsAdmin, dcaManager, stablecoin, handler, isUsdt0Live);

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
            wrbtc: IWRBTC(networkConfig.wrbtc),
            swapRouter: IUniswapV3SwapRouter(networkConfig.swapRouter),
            swapIntermediateTokens: intermediates,
            swapPoolFeeRates: fees,
            mocOracle: ICoinPairPrice(networkConfig.mocOracle)
        });
    }

    function _maybeAssign(
        OperationsAdmin operationsAdmin,
        DcaManager dcaManager,
        address stablecoin,
        address handler,
        bool isUsdt0Live
    ) internal {
        bool isOwner = msg.sender == operationsAdmin.owner();

        if (!isOwner) {
            console.log("Warning: Deployer is not the owner. Cannot register handler.");
            console.log("Safe runbook (owner of OperationsAdmin + DcaManager):");
            console.log("1. registerRoute(LAYERBANK_INDEX, true) only if getRouteClass is Unregistered");
            console.log("   (already-registered reverts RouteAlreadyRegistered; skip that call)");
            console.log("2. Read handler.getSwapPath() and verify it exactly matches the intended");
            console.log("   stablecoin / intermediate pools / WRBTC route (constructor already allowlisted it)");
            console.log("3. REQUIRED: dcaManager.setTokenMinPurchaseAmount(token, min)");
            console.log("   USDRIF: 25 ether; USDT0: 25e6. There is no protocol-wide default.");
            console.log("4. assignHandler(token, LAYERBANK_INDEX, handler)");
            console.log("stablecoin:", stablecoin);
            console.log("index:", LAYERBANK_INDEX);
            console.log("handler:", handler);
            console.log("minPurchaseAmount:", isUsdt0Live ? USDT0_MIN_PURCHASE_AMOUNT : MIN_PURCHASE_AMOUNT);
            return;
        }
        if (operationsAdmin.getRouteClass(LAYERBANK_INDEX) == IOperationsAdmin.RouteClass.Unregistered) {
            operationsAdmin.registerRoute(LAYERBANK_INDEX, true);
        }
        uint256 minPurchaseAmount = isUsdt0Live ? USDT0_MIN_PURCHASE_AMOUNT : MIN_PURCHASE_AMOUNT;
        dcaManager.setTokenMinPurchaseAmount(stablecoin, minPurchaseAmount);
        console.log("Token min purchase amount set to", minPurchaseAmount);
        operationsAdmin.assignHandler(stablecoin, LAYERBANK_INDEX, handler);
        console.log("LayerBank dex handler registered with OperationsAdmin at index", LAYERBANK_INDEX);
    }
}
