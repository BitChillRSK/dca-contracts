// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {DcaManager} from "../../src/DcaManager.sol";

/**
 * @title DeleteDcaSchedule Debug Test
 * @notice This test forks RSK mainnet at block 7911986 to debug a failed deleteDcaSchedule transaction
 * @dev The transaction that failed:
 * - Function: deleteDcaSchedule
 * - Token: 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db
 * - ScheduleIndex: 0
 * - ScheduleId: 0x42eb1494245e848161c4b8047c08158a866cde77f6ab79e0afb67e312180f3a1
 */
contract DeleteDcaScheduleDebugTest is Test {
    
    // RSK Mainnet fork configuration
    uint256 constant RSK_MAINNET_FORK_BLOCK = 7911986;
    string constant RSK_MAINNET_RPC = "RSK_MAINNET_RPC_URL";
    
    address constant DCA_MANAGER_ADDRESS = 0xf7b1B3C7731d5c06c1Fc027c5B8DC4da1bf55C98;
    
    // Test parameters from the failed transaction
    address constant USER_ADDRESS = 0xe976d12aE5E0E8320f84e42faB41f1613d42e9C6;
    address constant TOKEN_ADDRESS = 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db;
    uint256 constant SCHEDULE_INDEX = 0;
    bytes32 constant SCHEDULE_ID = 0x42eb1494245e848161c4b8047c08158a866cde77f6ab79e0afb67e312180f3a1;
    
    function setUp() public {
        // Fork RSK mainnet at the specific block where the transaction failed
        vm.createSelectFork(vm.envString(RSK_MAINNET_RPC), RSK_MAINNET_FORK_BLOCK);
        
        // Impersonate the user
        vm.startPrank(USER_ADDRESS);
    }
    
    function test_ReproduceDeleteDcaScheduleFailure() public {
        console2.log("=== Debugging deleteDcaSchedule Failure ===");
        console2.log("Block number:", block.number);
        console2.log("User address:", USER_ADDRESS);
        console2.log("Token address:", TOKEN_ADDRESS);
        console2.log("Schedule index:", SCHEDULE_INDEX);
        console2.log("Schedule ID:", vm.toString(SCHEDULE_ID));
        
        // Get contract instance
        DcaManager dcaManager = DcaManager(DCA_MANAGER_ADDRESS);
        
        // Check user's schedules first
        try dcaManager.getDcaSchedules(USER_ADDRESS, TOKEN_ADDRESS) returns (DcaManager.DcaDetails[] memory schedules) {
            console2.log("Number of schedules:", schedules.length);
            if (schedules.length > 0) {
                console2.log("Schedule 0 token balance:", schedules[0].tokenBalance);
                console2.log("Schedule 0 schedule ID:", vm.toString(schedules[0].scheduleId));
            }
        } catch {
            console2.log("Failed to get schedules");
        }
        
        // Now attempt to reproduce the exact transaction that failed
        try dcaManager.deleteDcaSchedule(TOKEN_ADDRESS, SCHEDULE_INDEX, SCHEDULE_ID) {
            console2.log("deleteDcaSchedule succeeded (unexpected!)");
        } catch Error(string memory reason) {
            console2.log("deleteDcaSchedule failed with reason:", reason);
        } catch (bytes memory lowLevelData) {
            console2.log("deleteDcaSchedule failed with low-level error");
            console2.logBytes(lowLevelData);
        }
    }
}
