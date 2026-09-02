// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseDeploymentTest} from "./BaseDeploymentTest.t.sol";
import {DeployUsdrifHandler} from "../../../script/DeployUsdrifHandler.s.sol";
import {UsdrifHelperConfig} from "../../../script/UsdrifHelperConfig.s.sol";
import {LayerBankErc20HandlerDex} from "../../../src/layerbank/LayerBankErc20HandlerDex.sol";
import {IPurchaseUniswap} from "../../../src/interfaces/IPurchaseUniswap.sol";
import {IFeeHandler} from "../../../src/interfaces/IFeeHandler.sol";
import {IWRBTC} from "../../../src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "../../../src/interfaces/ICoinPairPrice.sol";
import {IOperationsAdmin} from "../../../src/interfaces/IOperationsAdmin.sol";
import {console} from "forge-std/Test.sol";
import "../../Constants.sol";

contract NewHandlerDeploymentTest is BaseDeploymentTest {
    address public usdrifHandlerAddress;
    LayerBankErc20HandlerDex public usdrifHandler;
    UsdrifHelperConfig public usdrifHelperConfig;
    
    function setUp() public override {
        // Parent deploys MoC DOC. Skip on USDRIF/USDT0 lanes (vm.skip in the parent does not stop this setUp).
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DEFAULT_STABLECOIN);
        if (keccak256(abi.encodePacked(coinType)) != keccak256(abi.encodePacked("DOC"))) {
            vm.skip(true);
            return;
        }
        super.setUp();
        
        usdrifHelperConfig = new UsdrifHelperConfig();
        usdrifHelperConfig.updateProtocolAddresses(address(operationsAdmin), address(dcaManager));
        
        UsdrifHelperConfig.NetworkConfig memory config = usdrifHelperConfig.getNetworkConfig();
        IPurchaseUniswap.UniswapSettings memory uniswapSettings = IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(config.wrbtcTokenAddress),
            swapRouter02: ISwapRouter02(config.swapRouter02Address),
            swapIntermediateTokens: config.swapIntermediateTokens,
            swapPoolFeeRates: config.swapPoolFeeRates,
            mocOracle: ICoinPairPrice(config.mocOracleAddress)
        });

        DeployUsdrifHandler usdrifDeployer = new DeployUsdrifHandler();
        console.log("USDRIF handler deployer:", address(usdrifDeployer));

        IFeeHandler.FeeSettings memory feeSettings = usdrifDeployer.feeSettingsForToken(false);
        usdrifHandlerAddress = usdrifDeployer.deployMocksAndHandler(
            DeployUsdrifHandler.DeployParams({
                dcaManagerAddress: address(dcaManager),
                tokenAddress: config.usdrifTokenAddress,
                aTokenAddress: address(0),
                uniswapSettings: uniswapSettings,
                feeCollector: makeAddr(FEE_COLLECTOR_STRING),
                feeSettings: feeSettings,
                amountOutMinimumPercent: config.amountOutMinimumPercent,
                amountOutMinimumSafetyCheck: config.amountOutMinimumSafetyCheck,
                initialOwner: operationsAdmin.owner()
            })
        );
        usdrifHandler = LayerBankErc20HandlerDex(payable(usdrifHandlerAddress));

        vm.startPrank(OWNER);
        if (operationsAdmin.getRouteClass(LAYERBANK_INDEX) == IOperationsAdmin.RouteClass.Unregistered) {
            operationsAdmin.registerRoute(LAYERBANK_INDEX, true);
        }
        operationsAdmin.assignTokenHandler(config.usdrifTokenAddress, LAYERBANK_INDEX, usdrifHandlerAddress);
        vm.stopPrank();
    }
    
    function testUsdrifHandlerDeployment() public {
        assertNotEq(usdrifHandlerAddress, address(0), "USDRIF handler not deployed");
        
        assertEq(usdrifHandler.i_dcaManager(), address(dcaManager), "USDRIF handler doesn't reference DcaManager");
        assertNotEq(address(usdrifHandler.i_aToken()), address(0), "LayerBank aToken not set");
        assertEq(
            usdrifHandler.i_aToken().UNDERLYING_ASSET_ADDRESS(),
            usdrifHelperConfig.getNetworkConfig().usdrifTokenAddress,
            "aToken underlying must be USDRIF"
        );
        
        assertEq(usdrifHandler.owner(), makeAddr(OWNER_STRING), "USDRIF handler owner not set correctly");
        assertEq(usdrifHandler.pendingOwner(), address(0), "USDRIF handler pending owner must be zero after deploy");
        
        UsdrifHelperConfig.NetworkConfig memory config = usdrifHelperConfig.getNetworkConfig();
        address registeredHandler = operationsAdmin.getTokenHandler(config.usdrifTokenAddress, LAYERBANK_INDEX);
        assertEq(registeredHandler, usdrifHandlerAddress, "USDRIF handler not registered in OperationsAdmin");
        assertTrue(operationsAdmin.isLendingRoute(LAYERBANK_INDEX));
        assertTrue(
            IPurchaseUniswap(usdrifHandlerAddress).isPurchasePathAllowed(keccak256(usdrifHandler.getSwapPath())),
            "constructor path is allowlisted at construction"
        );
    }

    function test_run_revertsOnForkWithoutRealDeployment() public {
        if (block.chainid == ANVIL_CHAIN_ID) vm.skip(true);
        DeployUsdrifHandler deployer = new DeployUsdrifHandler();
        vm.expectRevert(bytes("DeployUsdrifHandler live path requires REAL_DEPLOYMENT=true"));
        deployer.run(usdrifHelperConfig);
    }

    function test_run_deploysOnAnvil() public {
        if (block.chainid != ANVIL_CHAIN_ID) vm.skip(true);
        address deployed = new DeployUsdrifHandler().run(usdrifHelperConfig);
        assertNotEq(deployed, address(0));
        assertEq(LayerBankErc20HandlerDex(payable(deployed)).owner(), makeAddr(OWNER_STRING));
        assertEq(LayerBankErc20HandlerDex(payable(deployed)).pendingOwner(), address(0));
    }
}
