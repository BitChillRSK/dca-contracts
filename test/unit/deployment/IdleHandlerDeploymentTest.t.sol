// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BaseDeploymentTest} from "./BaseDeploymentTest.t.sol";
import {DeployIdleHandler} from "../../../script/DeployIdleHandler.s.sol";
import {IdleDocHandlerMoc} from "../../../src/idle/IdleDocHandlerMoc.sol";
import {console} from "forge-std/Test.sol";
import "../../Constants.sol";

contract IdleHandlerDeploymentTest is BaseDeploymentTest {
    address public idleHandlerAddress;
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

        idleHandlerAddress = idleDeployer.run(helperConfig, address(operationsAdmin), address(dcaManager));
        idleHandler = IdleDocHandlerMoc(payable(idleHandlerAddress));
        address docTokenAddress = helperConfig.getStablecoinAddress();

        if (operationsAdmin.getTokenHandler(docTokenAddress, IDLE_INDEX) == address(0)) {
            vm.prank(OWNER);
            operationsAdmin.assignTokenHandler(docTokenAddress, IDLE_INDEX, idleHandlerAddress);
        }
    }

    function testIdleHandlerDeployment() public {
        assertNotEq(idleHandlerAddress, address(0), "Idle handler not deployed");

        assertEq(idleHandler.i_dcaManager(), address(dcaManager), "Idle handler doesn't reference DcaManager");
        assertEq(address(idleHandler.i_stableToken()), helperConfig.getStablecoinAddress(), "Idle handler DOC mismatch");
        assertEq(idleHandler.owner(), makeAddr(OWNER_STRING), "Idle handler owner not set correctly");
        assertEq(idleHandler.pendingOwner(), address(0), "Idle handler pending owner must be zero after deploy");

        address registeredHandler = operationsAdmin.getTokenHandler(helperConfig.getStablecoinAddress(), IDLE_INDEX);
        assertEq(registeredHandler, idleHandlerAddress, "Idle handler not registered in OperationsAdmin");
        assertFalse(operationsAdmin.isLendingRoute(IDLE_INDEX), "Index 0 must be idle");
    }
}
