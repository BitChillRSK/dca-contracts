// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeployBase} from "./DeployBase.s.sol";
import {MocHelperConfig} from "./MocHelperConfig.s.sol";
import {UsdrifHelperConfig} from "./UsdrifHelperConfig.s.sol";
import {DcaManager} from "../src/DcaManager.sol";
import {OperationsAdmin} from "../src/OperationsAdmin.sol";
import {IdleDocHandlerMoc} from "../src/idle/IdleDocHandlerMoc.sol";
import {LayerBankDocHandlerMoc} from "../src/layerbank/LayerBankDocHandlerMoc.sol";
import {SovrynDocHandlerMoc} from "../src/sovryn/SovrynDocHandlerMoc.sol";
import {IdleErc20HandlerDex} from "../src/idle/IdleErc20HandlerDex.sol";
import {LayerBankErc20HandlerDex} from "../src/layerbank/LayerBankErc20HandlerDex.sol";
import {IPurchaseUniswap} from "../src/interfaces/IPurchaseUniswap.sol";
import {IFeeHandler} from "../src/interfaces/IFeeHandler.sol";
import {IWRBTC} from "../src/interfaces/IWRBTC.sol";
import {IUniswapV3SwapRouter} from "../src/interfaces/IUniswapV3SwapRouter.sol";
import {ICoinPairPrice} from "../src/interfaces/ICoinPairPrice.sol";
import {console} from "forge-std/Test.sol";
import "./Constants.sol";

/**
 * @title DeployFinal
 * @notice Canonical one-shot live deployment of the full production stack on one
 *         `OperationsAdmin` / one `DcaManager`.
 * @dev Seven handlers: DOC idle / LayerBank / Sovryn (MoC) plus USDRIF and USDT0
 *      idle / LayerBank (Uniswap). Fail-closed: missing addresses, zero owner /
 *      collector / swapper, wrong environment, or an incomplete map revert rather
 *      than warn-and-continue. `DeployMocSwaps` / `DeployDexSwaps` and the add-ons
 *      remain for local/fork lanes and incremental add-ons; they are not the
 *      production cutover path. Does not broadcast from an agent session.
 *
 *      Env: `REAL_DEPLOYMENT=true`, `INITIAL_SWAPPER=<non-zero address>`.
 *      Profile: `FOUNDRY_PROFILE=deploy`. Mainnet only for the complete map —
 *      Rootstock testnet lacks LayerBank aTokens for this set, so a live
 *      testnet run of this script reverts on the incomplete-map check.
 *
 *      Config is copied into storage for the duration of `deployStack` so the
 *      `[profile.deploy]` via-IR pipeline does not hit Yul stack-too-deep on the
 *      large memory struct.
 */
contract DeployFinal is DeployBase {
    error DeployFinal__NotALivePath();
    error DeployFinal__ZeroAddress(string field);
    error DeployFinal__IncompleteMap(string field);
    error DeployFinal__UnsupportedChain();

    struct FinalStack {
        OperationsAdmin operationsAdmin;
        DcaManager dcaManager;
        address docIdle;
        address docLayerBank;
        address docSovryn;
        address usdrifIdle;
        address usdrifLayerBank;
        address usdt0Idle;
        address usdt0LayerBank;
        address initialSwapper;
    }

    struct FinalNetworkConfig {
        address doc;
        address mocProxy;
        address docLayerBankAToken;
        address docSovrynShares;
        address usdrif;
        address usdrifLayerBankAToken;
        address usdt0;
        address usdt0LayerBankAToken;
        address wrbtc;
        address swapRouter02;
        address mocOracle;
        address[] usdrifIntermediateTokens;
        uint24[] usdrifPoolFeeRates;
        /// @dev A second USDRIF path approved at deploy, so the swapper can activate whichever pays more.
        ///      Empty fee rates skip it.
        address[] usdrifAltIntermediateTokens;
        uint24[] usdrifAltPoolFeeRates;
        address[] usdt0IntermediateTokens;
        uint24[] usdt0PoolFeeRates;
        uint256 amountOutMinimumPercent;
        uint256 amountOutMinimumSafetyCheck;
        address feeCollector;
        address initialSwapper;
    }

    FinalNetworkConfig private s_cfg;
    FinalStack private s_stack;

    /// @notice Live entry: load mainnet addresses, require `INITIAL_SWAPPER`, deploy the stack.
    function run() external returns (FinalStack memory stack) {
        if (!_isLiveEnvironment()) revert DeployFinal__NotALivePath();
        if (block.chainid != RSK_MAINNET_CHAIN_ID) revert DeployFinal__UnsupportedChain();
        return deployStack(_mainnetConfig());
    }

    /// @notice Core deploy used by `run()` and by Anvil tests that supply mock addresses.
    function deployStack(FinalNetworkConfig memory config) public returns (FinalStack memory) {
        _storeConfig(config);
        _requireCompleteConfig();

        _beginLiveAwareBroadcast(msg.sender);

        address owner = deployOwner;
        OperationsAdmin operationsAdmin = new OperationsAdmin(owner);
        DcaManager dcaManager =
            new DcaManager(address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, owner);

        dcaManager.setTokenMinPurchaseAmount(s_cfg.doc, MIN_PURCHASE_AMOUNT);
        dcaManager.setTokenMinPurchaseAmount(s_cfg.usdrif, MIN_PURCHASE_AMOUNT);
        dcaManager.setTokenMinPurchaseAmount(s_cfg.usdt0, USDT0_MIN_PURCHASE_AMOUNT);

        operationsAdmin.registerRoute(LAYERBANK_INDEX, true);
        operationsAdmin.registerRoute(SOVRYN_INDEX, true);
        operationsAdmin.addSwapper(s_cfg.initialSwapper);

        s_stack.operationsAdmin = operationsAdmin;
        s_stack.dcaManager = dcaManager;
        s_stack.initialSwapper = s_cfg.initialSwapper;
        s_stack.docIdle = _newDocIdle(address(dcaManager), owner);
        s_stack.docLayerBank = _newDocLayerBank(address(dcaManager), owner);
        s_stack.docSovryn = _newDocSovryn(address(dcaManager), owner);
        s_stack.usdrifIdle = _newDexIdle(address(dcaManager), owner, false);
        s_stack.usdrifLayerBank = _newDexLayerBank(address(dcaManager), owner, false);
        s_stack.usdt0Idle = _newDexIdle(address(dcaManager), owner, true);
        s_stack.usdt0LayerBank = _newDexLayerBank(address(dcaManager), owner, true);

        _allowUsdrifAltPath(s_stack.usdrifIdle);
        _allowUsdrifAltPath(s_stack.usdrifLayerBank);

        operationsAdmin.assignTokenHandler(s_cfg.doc, IDLE_INDEX, s_stack.docIdle);
        operationsAdmin.assignTokenHandler(s_cfg.doc, LAYERBANK_INDEX, s_stack.docLayerBank);
        operationsAdmin.assignTokenHandler(s_cfg.doc, SOVRYN_INDEX, s_stack.docSovryn);
        operationsAdmin.assignTokenHandler(s_cfg.usdrif, IDLE_INDEX, s_stack.usdrifIdle);
        operationsAdmin.assignTokenHandler(s_cfg.usdrif, LAYERBANK_INDEX, s_stack.usdrifLayerBank);
        operationsAdmin.assignTokenHandler(s_cfg.usdt0, IDLE_INDEX, s_stack.usdt0Idle);
        operationsAdmin.assignTokenHandler(s_cfg.usdt0, LAYERBANK_INDEX, s_stack.usdt0LayerBank);

        _proposeFinalOwner(address(operationsAdmin));
        _proposeFinalOwner(address(dcaManager));
        _proposeFinalOwner(s_stack.docIdle);
        _proposeFinalOwner(s_stack.docLayerBank);
        _proposeFinalOwner(s_stack.docSovryn);
        _proposeFinalOwner(s_stack.usdrifIdle);
        _proposeFinalOwner(s_stack.usdrifLayerBank);
        _proposeFinalOwner(s_stack.usdt0Idle);
        _proposeFinalOwner(s_stack.usdt0LayerBank);

        vm.stopBroadcast();
        _logStack();
        return s_stack;
    }

    function _storeConfig(FinalNetworkConfig memory config) private {
        s_cfg.doc = config.doc;
        s_cfg.mocProxy = config.mocProxy;
        s_cfg.docLayerBankAToken = config.docLayerBankAToken;
        s_cfg.docSovrynShares = config.docSovrynShares;
        s_cfg.usdrif = config.usdrif;
        s_cfg.usdrifLayerBankAToken = config.usdrifLayerBankAToken;
        s_cfg.usdt0 = config.usdt0;
        s_cfg.usdt0LayerBankAToken = config.usdt0LayerBankAToken;
        s_cfg.wrbtc = config.wrbtc;
        s_cfg.swapRouter02 = config.swapRouter02;
        s_cfg.mocOracle = config.mocOracle;
        s_cfg.usdrifIntermediateTokens = config.usdrifIntermediateTokens;
        s_cfg.usdrifPoolFeeRates = config.usdrifPoolFeeRates;
        s_cfg.usdrifAltIntermediateTokens = config.usdrifAltIntermediateTokens;
        s_cfg.usdrifAltPoolFeeRates = config.usdrifAltPoolFeeRates;
        s_cfg.usdt0IntermediateTokens = config.usdt0IntermediateTokens;
        s_cfg.usdt0PoolFeeRates = config.usdt0PoolFeeRates;
        s_cfg.amountOutMinimumPercent = config.amountOutMinimumPercent;
        s_cfg.amountOutMinimumSafetyCheck = config.amountOutMinimumSafetyCheck;
        s_cfg.feeCollector = config.feeCollector;
        s_cfg.initialSwapper = config.initialSwapper;
    }

    function _newDocIdle(address dcaManager, address owner) private returns (address) {
        return address(
            new IdleDocHandlerMoc(
                dcaManager, s_cfg.doc, s_cfg.feeCollector, s_cfg.mocProxy, _docFeeSettings(), owner
            )
        );
    }

    function _newDocLayerBank(address dcaManager, address owner) private returns (address) {
        return address(
            new LayerBankDocHandlerMoc(
                dcaManager,
                s_cfg.doc,
                s_cfg.docLayerBankAToken,
                s_cfg.feeCollector,
                s_cfg.mocProxy,
                _docFeeSettings(),
                owner
            )
        );
    }

    function _newDocSovryn(address dcaManager, address owner) private returns (address) {
        return address(
            new SovrynDocHandlerMoc(
                dcaManager,
                s_cfg.doc,
                s_cfg.docSovrynShares,
                s_cfg.feeCollector,
                s_cfg.mocProxy,
                _docFeeSettings(),
                owner
            )
        );
    }

    function _newDexIdle(address dcaManager, address owner, bool isUsdt0) private returns (address) {
        return address(
            new IdleErc20HandlerDex(
                dcaManager,
                isUsdt0 ? s_cfg.usdt0 : s_cfg.usdrif,
                _uniswapSettings(isUsdt0),
                s_cfg.feeCollector,
                isUsdt0 ? _usdt0FeeSettings() : _docFeeSettings(),
                s_cfg.amountOutMinimumPercent,
                s_cfg.amountOutMinimumSafetyCheck,
                owner
            )
        );
    }

    function _newDexLayerBank(address dcaManager, address owner, bool isUsdt0) private returns (address) {
        return address(
            new LayerBankErc20HandlerDex(
                dcaManager,
                isUsdt0 ? s_cfg.usdt0 : s_cfg.usdrif,
                isUsdt0 ? s_cfg.usdt0LayerBankAToken : s_cfg.usdrifLayerBankAToken,
                _uniswapSettings(isUsdt0),
                s_cfg.feeCollector,
                isUsdt0 ? _usdt0FeeSettings() : _docFeeSettings(),
                s_cfg.amountOutMinimumPercent,
                s_cfg.amountOutMinimumSafetyCheck,
                owner
            )
        );
    }

    /// @dev Runs while the broadcaster still owns the handler: afterwards only the Safe can approve a path.
    function _allowUsdrifAltPath(address handler) private {
        if (s_cfg.usdrifAltPoolFeeRates.length == 0) return;
        IPurchaseUniswap(handler).setPurchasePathAllowed(
            s_cfg.usdrifAltIntermediateTokens, s_cfg.usdrifAltPoolFeeRates, true
        );
    }

    function _docFeeSettings() private view returns (IFeeHandler.FeeSettings memory) {
        return IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: getMaxFeeRate(),
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });
    }

    function _usdt0FeeSettings() private view returns (IFeeHandler.FeeSettings memory) {
        return IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: getMaxFeeRate(),
            feePurchaseLowerBound: USDT0_FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: USDT0_FEE_PURCHASE_UPPER_BOUND
        });
    }

    function _uniswapSettings(bool isUsdt0) private view returns (IPurchaseUniswap.UniswapSettings memory) {
        return IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(s_cfg.wrbtc),
            swapRouter02: IUniswapV3SwapRouter(s_cfg.swapRouter02),
            swapIntermediateTokens: isUsdt0 ? s_cfg.usdt0IntermediateTokens : s_cfg.usdrifIntermediateTokens,
            swapPoolFeeRates: isUsdt0 ? s_cfg.usdt0PoolFeeRates : s_cfg.usdrifPoolFeeRates,
            mocOracle: ICoinPairPrice(s_cfg.mocOracle)
        });
    }

    function _mainnetConfig() internal view returns (FinalNetworkConfig memory config) {
        MocHelperConfig.NetworkConfig memory moc = _mocMainnet();
        UsdrifHelperConfig.NetworkConfig memory dex = _usdrifMainnet();

        address[] memory usdt0Intermediate = new address[](0);
        uint24[] memory usdt0Fees = new uint24[](1);
        usdt0Fees[0] = 3000;

        // USDRIF -0.05%-> 6-decimal USDT -0.30%-> WRBTC. Its USDRIF pool is thin: it can pay more than the
        // default USDT0 hop on small batches, and cannot fill large ones.
        address[] memory usdrifAltIntermediate = new address[](1);
        usdrifAltIntermediate[0] = 0xAf368c91793CB22739386DFCbBb2F1A9e4bCBeBf;
        uint24[] memory usdrifAltFees = new uint24[](2);
        usdrifAltFees[0] = 500;
        usdrifAltFees[1] = 3000;

        config = FinalNetworkConfig({
            doc: moc.docTokenAddress,
            mocProxy: moc.mocProxyAddress,
            docLayerBankAToken: moc.layerbankATokenAddress,
            docSovrynShares: moc.iSusdAddress,
            usdrif: dex.usdrifTokenAddress,
            usdrifLayerBankAToken: dex.layerbankUsdrifATokenAddress,
            usdt0: dex.usdt0TokenAddress,
            usdt0LayerBankAToken: dex.layerbankUsdt0ATokenAddress,
            wrbtc: dex.wrbtcTokenAddress,
            swapRouter02: dex.swapRouter02Address,
            mocOracle: dex.mocOracleAddress,
            usdrifIntermediateTokens: dex.swapIntermediateTokens,
            usdrifPoolFeeRates: dex.swapPoolFeeRates,
            usdrifAltIntermediateTokens: usdrifAltIntermediate,
            usdrifAltPoolFeeRates: usdrifAltFees,
            usdt0IntermediateTokens: usdt0Intermediate,
            usdt0PoolFeeRates: usdt0Fees,
            amountOutMinimumPercent: DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            amountOutMinimumSafetyCheck: DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            feeCollector: getFeeCollector(environment),
            initialSwapper: vm.envAddress("INITIAL_SWAPPER")
        });
    }

    function _mocMainnet() private pure returns (MocHelperConfig.NetworkConfig memory) {
        return MocHelperConfig.NetworkConfig({
            docTokenAddress: 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db,
            kDocAddress: 0x544Eb90e766B405134b3B3F62b6b4C23Fcd5fDa2,
            iSusdAddress: 0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1,
            layerbankATokenAddress: 0x3F04280C66314b78E9712A41BF8C1A214460cAa2,
            mocProxyAddress: 0xf773B590aF754D597770937Fa8ea7AbDf2668370
        });
    }

    function _usdrifMainnet() private pure returns (UsdrifHelperConfig.NetworkConfig memory config) {
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = USDT0_MAINNET; // USDRIF -0.05%-> USDT0 -0.30%-> WRBTC
        uint24[] memory poolFeeRates = new uint24[](2);
        poolFeeRates[0] = 500;
        poolFeeRates[1] = 3000;

        config = UsdrifHelperConfig.NetworkConfig({
            usdrifTokenAddress: 0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37,
            usdt0TokenAddress: USDT0_MAINNET,
            layerbankUsdrifATokenAddress: LAYERBANK_USDRIF_ATOKEN,
            layerbankUsdt0ATokenAddress: LAYERBANK_USDT0_ATOKEN,
            wrbtcTokenAddress: 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d,
            swapRouter02Address: 0x0B14ff67f0014046b4b99057Aec4509640b3947A,
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracleAddress: 0xe2927A0620b82A66D67F678FC9b826B0E01B1bFD,
            operationsAdminAddress: address(0),
            dcaManagerAddress: address(0),
            amountOutMinimumPercent: DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            amountOutMinimumSafetyCheck: DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK
        });
    }

    function _requireCompleteConfig() private view {
        if (s_cfg.doc == address(0)) revert DeployFinal__ZeroAddress("doc");
        if (s_cfg.mocProxy == address(0)) revert DeployFinal__ZeroAddress("mocProxy");
        if (s_cfg.docLayerBankAToken == address(0)) revert DeployFinal__IncompleteMap("docLayerBankAToken");
        if (s_cfg.docSovrynShares == address(0)) revert DeployFinal__IncompleteMap("docSovrynShares");
        if (s_cfg.usdrif == address(0)) revert DeployFinal__ZeroAddress("usdrif");
        if (s_cfg.usdrifLayerBankAToken == address(0)) revert DeployFinal__IncompleteMap("usdrifLayerBankAToken");
        if (s_cfg.usdt0 == address(0)) revert DeployFinal__ZeroAddress("usdt0");
        if (s_cfg.usdt0LayerBankAToken == address(0)) revert DeployFinal__IncompleteMap("usdt0LayerBankAToken");
        if (s_cfg.wrbtc == address(0)) revert DeployFinal__ZeroAddress("wrbtc");
        if (s_cfg.swapRouter02 == address(0)) revert DeployFinal__ZeroAddress("swapRouter02");
        if (s_cfg.mocOracle == address(0)) revert DeployFinal__ZeroAddress("mocOracle");
        if (s_cfg.feeCollector == address(0)) revert DeployFinal__ZeroAddress("feeCollector");
        if (s_cfg.initialSwapper == address(0)) revert DeployFinal__ZeroAddress("initialSwapper");
        if (s_cfg.usdrifPoolFeeRates.length == 0) revert DeployFinal__IncompleteMap("usdrifPoolFeeRates");
        if (s_cfg.usdt0PoolFeeRates.length == 0) revert DeployFinal__IncompleteMap("usdt0PoolFeeRates");
        if (s_cfg.amountOutMinimumPercent == 0) revert DeployFinal__ZeroAddress("amountOutMinimumPercent");
        if (s_cfg.amountOutMinimumSafetyCheck == 0) revert DeployFinal__ZeroAddress("amountOutMinimumSafetyCheck");
    }

    function _logStack() private view {
        console.log("==== DeployFinal stack ====");
        console.log("OperationsAdmin:", address(s_stack.operationsAdmin));
        console.log("DcaManager:", address(s_stack.dcaManager));
        console.log("DOC idle:", s_stack.docIdle);
        console.log("DOC LayerBank:", s_stack.docLayerBank);
        console.log("DOC Sovryn:", s_stack.docSovryn);
        console.log("USDRIF idle:", s_stack.usdrifIdle);
        console.log("USDRIF LayerBank:", s_stack.usdrifLayerBank);
        console.log("USDT0 idle:", s_stack.usdt0Idle);
        console.log("USDT0 LayerBank:", s_stack.usdt0LayerBank);
        console.log("Initial swapper:", s_stack.initialSwapper);
        console.log("Fee collector:", s_cfg.feeCollector);
    }
}
