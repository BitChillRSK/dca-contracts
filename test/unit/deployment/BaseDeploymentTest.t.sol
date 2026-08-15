// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DeployMocSwaps} from "../../../script/DeployMocSwaps.s.sol";
import {OperationsAdmin} from "../../../src/OperationsAdmin.sol";
import {DcaManager} from "../../../src/DcaManager.sol";
import {TropykusDocHandlerMoc} from "../../../src/TropykusDocHandlerMoc.sol";
import {SovrynDocHandlerMoc} from "../../../src/SovrynDocHandlerMoc.sol";
import {MocHelperConfig} from "../../../script/MocHelperConfig.s.sol";
import "../../Constants.sol";

contract BaseDeploymentTest is Test {
    // Core contracts
    OperationsAdmin public operationsAdmin;
    DcaManager public dcaManager;
    address public docHandlerMocAddress;
    MocHelperConfig public helperConfig;
    address OWNER = makeAddr(OWNER_STRING);
    address ADMIN = makeAddr(ADMIN_STRING);
    
    // For validating the handler type
    TropykusDocHandlerMoc public tropykusHandler;
    SovrynDocHandlerMoc public sovrynHandler;

    function setUp() public virtual {
        // Set up environment variables for deployment
        vm.setEnv("REAL_DEPLOYMENT", "false");
        vm.setEnv("LENDING_PROTOCOL", TROPYKUS_STRING);
        
        // Deploy the core protocol
        DeployMocSwaps deployer = new DeployMocSwaps();
        (operationsAdmin, docHandlerMocAddress, dcaManager, helperConfig) = deployer.run();
        
        // Check which handler type was deployed based on the lending protocol
        string memory lendingProtocol = vm.envString("LENDING_PROTOCOL");
        if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(TROPYKUS_STRING))) {
            tropykusHandler = TropykusDocHandlerMoc(payable(docHandlerMocAddress));
        } else if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(SOVRYN_STRING))) {
            sovrynHandler = SovrynDocHandlerMoc(payable(docHandlerMocAddress));
        }

        // Grant admin role to test contract and register the handler
        vm.prank(OWNER);
        operationsAdmin.setAdminRole(ADMIN);
        vm.prank(ADMIN);
        operationsAdmin.addOrUpdateLendingProtocol(
            TROPYKUS_STRING,
            TROPYKUS_INDEX
        );
    }
    
    function testCoreProtocolDeployment() public {
        // Verify OperationsAdmin deployment
        assertNotEq(address(operationsAdmin), address(0), "OperationsAdmin not deployed");
        
        // Verify DcaManager deployment
        assertNotEq(address(dcaManager), address(0), "DcaManager not deployed");
        
        // Verify DocHandler deployment
        assertNotEq(docHandlerMocAddress, address(0), "DocHandler not deployed");
        
        // Check ownership
        assertEq(operationsAdmin.owner(), makeAddr(OWNER_STRING), "OperationsAdmin owner not set correctly");
        assertEq(dcaManager.owner(), makeAddr(OWNER_STRING), "DcaManager owner not set correctly");
        
        // Verify DcaManager reference in handler
        string memory lendingProtocol = vm.envString("LENDING_PROTOCOL");
        if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(TROPYKUS_STRING))) {
            assertEq(tropykusHandler.i_dcaManager(), address(dcaManager), "TropykusHandler doesn't reference DcaManager");
            assertEq(TropykusDocHandlerMoc(payable(docHandlerMocAddress)).owner(), makeAddr(OWNER_STRING), "Handler owner not set correctly");
        } else {
            assertEq(sovrynHandler.i_dcaManager(), address(dcaManager), "SovrynHandler doesn't reference DcaManager");
            assertEq(SovrynDocHandlerMoc(payable(docHandlerMocAddress)).owner(), makeAddr(OWNER_STRING), "Handler owner not set correctly");
        }
    }
}
