// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseDeploymentTest} from "./BaseDeploymentTest.t.sol";
import {DeployIdleHandler} from "../../../script/DeployIdleHandler.s.sol";
import {IOperationsAdmin} from "../../../src/interfaces/IOperationsAdmin.sol";
import {IdleDocHandlerMoc} from "../../../src/idle/IdleDocHandlerMoc.sol";
import {console} from "forge-std/Test.sol";
import "../../Constants.sol";

contract IdleHandlerDeploymentTest is BaseDeploymentTest {
    IdleDocHandlerMoc public idleHandler;

    function setUp() public override {
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DOC_STRING);
        if (keccak256(abi.encodePacked(coinType)) != keccak256(abi.encodePacked(DOC_STRING))) {
            vm.skip(true);
            return;
        }
        super.setUp();

        DeployIdleHandler idleDeployer = new DeployIdleHandler();
        console.log("Idle handler deployer:", address(idleDeployer));

        idleHandler =
            IdleDocHandlerMoc(payable(idleDeployer.run(helperConfig, address(operationsAdmin), address(dcaManager))));
        address docToken = helperConfig.getStablecoin();

        if (operationsAdmin.getHandler(docToken, IDLE_INDEX) == address(0)) {
            vm.prank(OWNER);
            operationsAdmin.assignHandler(docToken, IDLE_INDEX, address(idleHandler));
        }
    }

    function testIdleHandlerDeployment() public {
        assertNotEq(address(idleHandler), address(0), "Idle handler not deployed");

        assertEq(idleHandler.i_dcaManager(), address(dcaManager), "Idle handler doesn't reference DcaManager");
        assertEq(address(idleHandler.i_stablecoin()), helperConfig.getStablecoin(), "Idle handler DOC mismatch");
        assertEq(idleHandler.owner(), makeAddr(OWNER_STRING), "Idle handler owner not set correctly");
        assertEq(idleHandler.pendingOwner(), address(0), "Idle handler pending owner must be zero after deploy");

        address registeredHandler = operationsAdmin.getHandler(helperConfig.getStablecoin(), IDLE_INDEX);
        assertEq(registeredHandler, address(idleHandler), "Idle handler not registered in OperationsAdmin");
        assertEq(
            uint256(operationsAdmin.getRouteClass(IDLE_INDEX)),
            uint256(IOperationsAdmin.RouteClass.Idle),
            "Index 0 must be idle"
        );
    }
}
