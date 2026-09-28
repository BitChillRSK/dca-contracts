// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseDeploymentTest} from "./BaseDeploymentTest.t.sol";
import {DeployUsdrifHandler} from "../../../script/DeployUsdrifHandler.s.sol";
import {UsdrifHelperConfig} from "../../../script/UsdrifHelperConfig.s.sol";
import {LayerBankHandlerDex} from "../../../src/layerbank/LayerBankHandlerDex.sol";
import {IPurchaseUniswap} from "../../../src/interfaces/IPurchaseUniswap.sol";
import {IPurchaseFees} from "../../../src/interfaces/IPurchaseFees.sol";
import {IWRBTC} from "../../../src/interfaces/IWRBTC.sol";
import {IUniswapV3SwapRouter} from "../../../src/interfaces/IUniswapV3SwapRouter.sol";
import {ICoinPairPrice} from "../../../src/interfaces/ICoinPairPrice.sol";
import {IOperationsAdmin} from "../../../src/interfaces/IOperationsAdmin.sol";
import {IPurchaseRbtc} from "../../../src/interfaces/IPurchaseRbtc.sol";
import {MockStablecoin} from "../../mocks/MockStablecoin.sol";
import {batchBuyOne} from "../../utils/BatchBuyOne.sol";
import {console} from "forge-std/Test.sol";
import "../../Constants.sol";
import {scheduleIdAt} from "test/utils/ScheduleAt.sol";

contract NewHandlerDeploymentTest is BaseDeploymentTest {
    uint256 internal constant DEPOSIT_AMOUNT = 2000 ether;
    uint256 internal constant PURCHASE_AMOUNT = 200 ether;

    LayerBankHandlerDex public usdrifHandler;
    UsdrifHelperConfig public usdrifHelperConfig;

    function setUp() public override {
        // Parent deploys MoC DOC. Skip on USDRIF/USDT0 lanes (vm.skip in the parent does not stop this setUp).
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DOC_STRING);
        if (keccak256(abi.encodePacked(coinType)) != keccak256(abi.encodePacked(DOC_STRING))) {
            vm.skip(true);
            return;
        }
        super.setUp();

        usdrifHelperConfig = new UsdrifHelperConfig();
        usdrifHelperConfig.updateProtocolAddresses(address(operationsAdmin), address(dcaManager));

        UsdrifHelperConfig.NetworkConfig memory config = usdrifHelperConfig.getNetworkConfig();
        IPurchaseUniswap.UniswapSettings memory uniswapSettings = IPurchaseUniswap.UniswapSettings({
            wrbtc: IWRBTC(config.wrbtc),
            swapRouter: IUniswapV3SwapRouter(config.swapRouter),
            swapIntermediateTokens: config.swapIntermediateTokens,
            swapPoolFeeRates: config.swapPoolFeeRates,
            mocOracle: ICoinPairPrice(config.mocOracle)
        });

        DeployUsdrifHandler usdrifDeployer = new DeployUsdrifHandler();
        console.log("USDRIF handler deployer:", address(usdrifDeployer));

        IPurchaseFees.FeeSettings memory feeSettings = usdrifDeployer.feeSettingsForToken(false);
        usdrifHandler = LayerBankHandlerDex(
            payable(usdrifDeployer.deployMocksAndHandler(
                    DeployUsdrifHandler.DeployParams({
                        dcaManager: address(dcaManager),
                        stablecoin: config.usdrifToken,
                        aToken: address(0),
                        uniswapSettings: uniswapSettings,
                        feeCollector: makeAddr(FEE_COLLECTOR_STRING),
                        feeSettings: feeSettings,
                        amountOutMinimumPercent: config.amountOutMinimumPercent,
                        amountOutMinimumSafetyCheck: config.amountOutMinimumSafetyCheck,
                        initialOwner: operationsAdmin.owner()
                    })
                ))
        );

        vm.startPrank(OWNER);
        if (operationsAdmin.getRouteClass(LAYERBANK_INDEX) == IOperationsAdmin.RouteClass.Unregistered) {
            operationsAdmin.registerRoute(LAYERBANK_INDEX, true);
        }
        dcaManager.setTokenMinPurchaseAmount(config.usdrifToken, MIN_PURCHASE_AMOUNT);
        operationsAdmin.assignHandler(config.usdrifToken, LAYERBANK_INDEX, address(usdrifHandler));
        vm.stopPrank();
    }

    function testUsdrifHandlerDeployment() public {
        assertNotEq(address(usdrifHandler), address(0), "USDRIF handler not deployed");

        assertEq(usdrifHandler.i_dcaManager(), address(dcaManager), "USDRIF handler doesn't reference DcaManager");
        assertNotEq(address(usdrifHandler.i_aToken()), address(0), "LayerBank aToken not set");
        assertEq(
            usdrifHandler.i_aToken().UNDERLYING_ASSET_ADDRESS(),
            usdrifHelperConfig.getNetworkConfig().usdrifToken,
            "aToken underlying must be USDRIF"
        );

        assertEq(usdrifHandler.owner(), makeAddr(OWNER_STRING), "USDRIF handler owner not set correctly");
        assertEq(usdrifHandler.pendingOwner(), address(0), "USDRIF handler pending owner must be zero after deploy");

        UsdrifHelperConfig.NetworkConfig memory config = usdrifHelperConfig.getNetworkConfig();
        address registeredHandler = operationsAdmin.getHandler(config.usdrifToken, LAYERBANK_INDEX);
        assertEq(registeredHandler, address(usdrifHandler), "USDRIF handler not registered in OperationsAdmin");
        assertEq(uint256(operationsAdmin.getRouteClass(LAYERBANK_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending));
        assertTrue(
            IPurchaseUniswap(address(usdrifHandler)).isPurchasePathAllowed(keccak256(usdrifHandler.getSwapPath())),
            "constructor path is allowlisted at construction"
        );
    }

    /**
     * @notice A schedule created on the add-on handler must actually be able to buy.
     * @dev The deployment assertions above all hold on a handler whose configured route cannot execute:
     *      they read constructor state and never call `batchBuyRbtc`. R59 made that gap load-bearing —
     *      the purchase now reads each active intermediate token's `balanceOf` on the router, and a
     *      high-level call to a codeless address reverts — so this add-on path needs one real purchase.
     */
    function testUsdrifHandlerPurchasesThroughTheDeployedRoute() public {
        if (block.chainid != ANVIL_CHAIN_ID) vm.skip(true);

        UsdrifHelperConfig.NetworkConfig memory config = usdrifHelperConfig.getNetworkConfig();
        address user = makeAddr(USER_STRING);
        address swapper = makeAddr(SWAPPER_STRING);
        MockStablecoin usdrif = MockStablecoin(config.usdrifToken);

        vm.prank(OWNER);
        operationsAdmin.addSwapper(swapper);
        // The mock router wraps rBTC it holds into WRBTC for the handler, the way a real swap pays out.
        vm.deal(config.swapRouter, 1000 ether);

        usdrif.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        usdrif.approve(address(usdrifHandler), DEPOSIT_AMOUNT);
        dcaManager.createDcaSchedule(
            config.usdrifToken, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, LAYERBANK_INDEX
        );
        vm.stopPrank();

        uint64 scheduleId = scheduleIdAt(dcaManager, user, config.usdrifToken, 0);
        vm.prank(swapper);
        batchBuyOne(dcaManager, config.usdrifToken, scheduleId, LAYERBANK_INDEX);

        assertGt(
            IPurchaseRbtc(address(usdrifHandler)).getAccumulatedRbtcBalance(user),
            0,
            "purchase through the deployed USDRIF route credited no rBTC"
        );
        assertEq(usdrif.balanceOf(address(usdrifHandler)), 0, "a complete fill leaves no stablecoin on the handler");
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
        assertEq(LayerBankHandlerDex(payable(deployed)).owner(), makeAddr(OWNER_STRING));
        assertEq(LayerBankHandlerDex(payable(deployed)).pendingOwner(), address(0));
    }
}
