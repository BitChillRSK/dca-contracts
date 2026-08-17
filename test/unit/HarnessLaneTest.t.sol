// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import "../../script/Constants.sol";

/**
 * @title HarnessLaneTest
 * @notice R24. `vm.setEnv("LENDING_PROTOCOL", …)` is process-wide. If a suite writes tropykus
 * during `make moc-sovryn`, every later `DcaDappTest` constructs as Tropykus and Sovryn-only
 * tests skip. Makefile sets EXPECTED_LENDING_PROTOCOL to the lane; this file asserts the
 * process env still matches after BaseDeploymentTest and DcaDappTest have run.
 */
contract HarnessLaneTest is DcaDappTest {
    function test_harness_lendingProtocolWasNotOverwritten() public {
        string memory protocol = vm.envString("LENDING_PROTOCOL");
        string memory expected = vm.envOr("EXPECTED_LENDING_PROTOCOL", protocol);
        assertEq(protocol, expected, "LENDING_PROTOCOL was overwritten (vm.setEnv is process-wide)");
    }

    function test_harness_constructedIndexMatchesLane() public {
        string memory protocol = vm.envString("LENDING_PROTOCOL");
        if (keccak256(abi.encodePacked(protocol)) == keccak256(abi.encodePacked(SOVRYN_STRING))) {
            assertEq(s_lendingProtocolIndex, SOVRYN_INDEX, "sovryn lane constructed a tropykus harness");
        } else {
            assertEq(s_lendingProtocolIndex, TROPYKUS_INDEX, "tropykus lane constructed a sovryn harness");
        }
    }
}

/// @dev Asserts the deployment suite did not clobber the lane either. EXPECTED_LENDING_PROTOCOL
/// is set by the Makefile to the same value as LENDING_PROTOCOL.
contract HarnessDeploymentLaneTest is Test {
    function test_harness_deploymentSuiteLeftLendingProtocolAlone() public {
        string memory protocol = vm.envString("LENDING_PROTOCOL");
        string memory expected = vm.envOr("EXPECTED_LENDING_PROTOCOL", protocol);
        assertEq(protocol, expected, "LENDING_PROTOCOL was overwritten (vm.setEnv is process-wide)");
    }
}
