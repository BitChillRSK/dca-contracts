// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DeployMocSwaps} from "../../../script/DeployMocSwaps.s.sol";
import {OperationsAdmin} from "../../../src/OperationsAdmin.sol";
import {DcaManager} from "../../../src/DcaManager.sol";
import {TropykusDocHandlerMoc} from "../../../src/tropykus-legacy/TropykusDocHandlerMoc.sol";
import {SovrynDocHandlerMoc} from "../../../src/sovryn/SovrynDocHandlerMoc.sol";
import {MocHelperConfig} from "../../../script/MocHelperConfig.s.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BitChillOwnable} from "../../../src/BitChillOwnable.sol";
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
        // REAL_DEPLOYMENT is local-only. Do not write LENDING_PROTOCOL: vm.setEnv is process-wide
        // and would force every later suite in this forge run onto tropykus (R24).
        vm.setEnv("REAL_DEPLOYMENT", "false");

        // This suite always deploys DeployMocSwaps (DOC). Skip on USDRIF lanes rather than
        // setEnv STABLECOIN_TYPE — that would poison DcaDappTest the same way LENDING_PROTOCOL did.
        string memory coinType = vm.envOr("STABLECOIN_TYPE", DEFAULT_STABLECOIN);
        if (keccak256(abi.encodePacked(coinType)) != keccak256(abi.encodePacked("DOC"))) {
            vm.skip(true);
            return;
        }

        DeployMocSwaps deployer = new DeployMocSwaps();
        (operationsAdmin, docHandlerMocAddress, dcaManager, helperConfig) = deployer.run();

        string memory lendingProtocol = vm.envString("LENDING_PROTOCOL");
        if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(SOVRYN_STRING))) {
            sovrynHandler = SovrynDocHandlerMoc(payable(docHandlerMocAddress));
        } else if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(TROPYKUS_STRING))) {
            tropykusHandler = TropykusDocHandlerMoc(payable(docHandlerMocAddress));
        }

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(LAYERBANK_INDEX, true);
        operationsAdmin.registerRoute(SOVRYN_INDEX, true);
        operationsAdmin.registerRoute(TROPYKUS_INDEX, true);
        vm.stopPrank();
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
        assertEq(operationsAdmin.pendingOwner(), address(0), "OperationsAdmin pending owner must be zero after deploy");
        assertEq(dcaManager.owner(), makeAddr(OWNER_STRING), "DcaManager owner not set correctly");
        assertEq(dcaManager.pendingOwner(), address(0), "DcaManager pending owner must be zero after deploy");
        
        // Verify DcaManager reference in handler
        string memory lendingProtocol = vm.envString("LENDING_PROTOCOL");
        if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(TROPYKUS_STRING))) {
            assertEq(tropykusHandler.i_dcaManager(), address(dcaManager), "TropykusHandler doesn't reference DcaManager");
            assertEq(TropykusDocHandlerMoc(payable(docHandlerMocAddress)).owner(), makeAddr(OWNER_STRING), "Handler owner not set correctly");
            assertEq(TropykusDocHandlerMoc(payable(docHandlerMocAddress)).pendingOwner(), address(0), "Handler pending owner must be zero after deploy");
        } else if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(SOVRYN_STRING))) {
            assertEq(sovrynHandler.i_dcaManager(), address(dcaManager), "SovrynHandler doesn't reference DcaManager");
            assertEq(SovrynDocHandlerMoc(payable(docHandlerMocAddress)).owner(), makeAddr(OWNER_STRING), "Handler owner not set correctly");
            assertEq(SovrynDocHandlerMoc(payable(docHandlerMocAddress)).pendingOwner(), address(0), "Handler pending owner must be zero after deploy");
        } else {
            assertEq(Ownable(docHandlerMocAddress).owner(), makeAddr(OWNER_STRING), "Handler owner not set correctly");
            assertEq(
                BitChillOwnable(docHandlerMocAddress).pendingOwner(),
                address(0),
                "Handler pending owner must be zero after deploy"
            );
        }
    }
}
