// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseDeploymentTest} from "./BaseDeploymentTest.t.sol";
import {DeployLayerBankHandler} from "../../../script/DeployLayerBankHandler.s.sol";
import {LayerBankDocHandlerMoc} from "../../../src/layerbank/LayerBankDocHandlerMoc.sol";
import {IOperationsAdmin} from "../../../src/interfaces/IOperationsAdmin.sol";
import {console} from "forge-std/Test.sol";
import "../../Constants.sol";

contract LayerBankHandlerDeploymentTest is BaseDeploymentTest {
    uint256 internal constant LAYERBANK_INDEX = 1;

    address public layerbankHandlerAddress;
    LayerBankDocHandlerMoc public layerbankHandler;

    function setUp() public override {
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DEFAULT_STABLECOIN);
        if (keccak256(abi.encodePacked(coinType)) != keccak256(abi.encodePacked("DOC"))) {
            vm.skip(true);
            return;
        }
        super.setUp();

        DeployLayerBankHandler layerbankDeployer = new DeployLayerBankHandler();
        console.log("LayerBank handler deployer:", address(layerbankDeployer));

        address docTokenAddress = helperConfig.getStablecoinAddress();
        layerbankHandlerAddress = layerbankDeployer.deployMocksAndHandler(
            address(dcaManager),
            docTokenAddress,
            helperConfig.getActiveNetworkConfig().mocProxyAddress,
            makeAddr(FEE_COLLECTOR_STRING),
            operationsAdmin.owner()
        );
        layerbankHandler = LayerBankDocHandlerMoc(payable(layerbankHandlerAddress));

        vm.startPrank(OWNER);
        if (operationsAdmin.getRouteClass(LAYERBANK_INDEX) == IOperationsAdmin.RouteClass.Unregistered) {
            operationsAdmin.registerRoute(LAYERBANK_INDEX, true);
        }
        operationsAdmin.assignTokenHandler(docTokenAddress, LAYERBANK_INDEX, layerbankHandlerAddress);
        vm.stopPrank();
    }

    function testLayerBankHandlerDeployment() public {
        assertNotEq(layerbankHandlerAddress, address(0), "LayerBank handler not deployed");

        assertEq(layerbankHandler.i_dcaManager(), address(dcaManager), "LayerBank handler doesn't reference DcaManager");
        assertEq(address(layerbankHandler.i_stableToken()), helperConfig.getStablecoinAddress(), "LayerBank handler DOC mismatch");
        assertNotEq(address(layerbankHandler.i_aToken()), address(0), "LayerBank aToken not set");
        assertNotEq(address(layerbankHandler.i_pool()), address(0), "LayerBank Pool not set");
        assertEq(layerbankHandler.i_aToken().POOL(), address(layerbankHandler.i_pool()), "aToken.POOL must match handler Pool");
        assertEq(
            layerbankHandler.i_aToken().UNDERLYING_ASSET_ADDRESS(),
            helperConfig.getStablecoinAddress(),
            "aToken underlying must be DOC"
        );
        assertEq(layerbankHandler.owner(), makeAddr(OWNER_STRING), "LayerBank handler owner not set correctly");

        address registeredHandler = operationsAdmin.getTokenHandler(helperConfig.getStablecoinAddress(), LAYERBANK_INDEX);
        assertEq(registeredHandler, layerbankHandlerAddress, "LayerBank handler not registered in OperationsAdmin");
        assertTrue(operationsAdmin.isLendingRoute(LAYERBANK_INDEX));
        assertEq(layerbankHandler.EXCHANGE_RATE_DECIMALS(), 1e27);
    }

    function test_run_revertsWhenNotLocal() public {
        if (block.chainid == ANVIL_CHAIN_ID) vm.skip(true);
        DeployLayerBankHandler deployer = new DeployLayerBankHandler();
        vm.expectRevert(bytes("Live LayerBank Pool/aToken addresses are PR 16"));
        deployer.run(helperConfig, address(operationsAdmin), address(dcaManager));
    }

    function test_run_deploysOnAnvil() public {
        if (block.chainid != ANVIL_CHAIN_ID) vm.skip(true);
        address deployed =
            new DeployLayerBankHandler().run(helperConfig, address(operationsAdmin), address(dcaManager));
        assertNotEq(deployed, address(0));
        assertEq(LayerBankDocHandlerMoc(payable(deployed)).owner(), makeAddr(OWNER_STRING));
    }
}
