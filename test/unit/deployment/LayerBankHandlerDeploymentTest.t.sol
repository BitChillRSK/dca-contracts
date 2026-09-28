// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseDeploymentTest} from "./BaseDeploymentTest.t.sol";
import {DeployLayerBankHandler} from "../../../script/DeployLayerBankHandler.s.sol";
import {LayerBankDocHandlerMoc} from "../../../src/layerbank/LayerBankDocHandlerMoc.sol";
import {IOperationsAdmin} from "../../../src/interfaces/IOperationsAdmin.sol";
import {console} from "forge-std/Test.sol";
import "../../Constants.sol";

contract LayerBankHandlerDeploymentTest is BaseDeploymentTest {
    LayerBankDocHandlerMoc public layerbankHandler;

    function setUp() public override {
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DOC_STRING);
        if (keccak256(abi.encodePacked(coinType)) != keccak256(abi.encodePacked(DOC_STRING))) {
            vm.skip(true);
            return;
        }
        super.setUp();

        address docToken = helperConfig.getStablecoin();
        if (operationsAdmin.getHandler(docToken, LAYERBANK_INDEX) != address(0)) {
            layerbankHandler = LayerBankDocHandlerMoc(payable(operationsAdmin.getHandler(docToken, LAYERBANK_INDEX)));
            return;
        }

        DeployLayerBankHandler layerbankDeployer = new DeployLayerBankHandler();
        console.log("LayerBank handler deployer:", address(layerbankDeployer));

        layerbankHandler = LayerBankDocHandlerMoc(
            payable(layerbankDeployer.deployMocksAndHandler(
                    address(dcaManager),
                    docToken,
                    helperConfig.getActiveNetworkConfig().mocProxy,
                    makeAddr(FEE_COLLECTOR_STRING),
                    operationsAdmin.owner()
                ))
        );

        vm.startPrank(OWNER);
        if (operationsAdmin.getRouteClass(LAYERBANK_INDEX) == IOperationsAdmin.RouteClass.Unregistered) {
            operationsAdmin.registerRoute(LAYERBANK_INDEX, true);
        }
        operationsAdmin.assignHandler(docToken, LAYERBANK_INDEX, address(layerbankHandler));
        vm.stopPrank();
    }

    function testLayerBankHandlerDeployment() public {
        assertNotEq(address(layerbankHandler), address(0), "LayerBank handler not deployed");

        assertEq(layerbankHandler.i_dcaManager(), address(dcaManager), "LayerBank handler doesn't reference DcaManager");
        assertEq(
            address(layerbankHandler.i_stablecoin()), helperConfig.getStablecoin(), "LayerBank handler DOC mismatch"
        );
        assertNotEq(address(layerbankHandler.i_aToken()), address(0), "LayerBank aToken not set");
        assertNotEq(address(layerbankHandler.i_pool()), address(0), "LayerBank Pool not set");
        assertEq(
            layerbankHandler.i_aToken().POOL(),
            address(layerbankHandler.i_pool()),
            "aToken.POOL must match handler Pool"
        );
        assertEq(
            layerbankHandler.i_aToken().UNDERLYING_ASSET_ADDRESS(),
            helperConfig.getStablecoin(),
            "aToken underlying must be DOC"
        );
        assertEq(layerbankHandler.owner(), makeAddr(OWNER_STRING), "LayerBank handler owner not set correctly");
        assertEq(
            layerbankHandler.pendingOwner(), address(0), "LayerBank handler pending owner must be zero after deploy"
        );

        address registeredHandler = operationsAdmin.getHandler(helperConfig.getStablecoin(), LAYERBANK_INDEX);
        assertEq(registeredHandler, address(layerbankHandler), "LayerBank handler not registered in OperationsAdmin");
        assertEq(uint256(operationsAdmin.getRouteClass(LAYERBANK_INDEX)), uint256(IOperationsAdmin.RouteClass.Lending));
        assertEq(layerbankHandler.EXCHANGE_RATE_DECIMALS(), 1e27);
    }

    function test_run_revertsOnForkWithoutRealDeployment() public {
        if (block.chainid == ANVIL_CHAIN_ID) vm.skip(true);
        DeployLayerBankHandler deployer = new DeployLayerBankHandler();
        vm.expectRevert(bytes("DeployLayerBankHandler live path requires REAL_DEPLOYMENT=true"));
        deployer.run(helperConfig, address(operationsAdmin), address(dcaManager));
    }

    function test_run_deploysOnAnvil() public {
        if (block.chainid != ANVIL_CHAIN_ID) vm.skip(true);
        address deployed = new DeployLayerBankHandler().run(helperConfig, address(operationsAdmin), address(dcaManager));
        assertNotEq(deployed, address(0));
        assertEq(LayerBankDocHandlerMoc(payable(deployed)).owner(), makeAddr(OWNER_STRING));
        assertEq(LayerBankDocHandlerMoc(payable(deployed)).pendingOwner(), address(0));
    }
}
