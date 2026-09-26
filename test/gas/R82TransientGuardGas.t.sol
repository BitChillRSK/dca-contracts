// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {DcaManager} from "src/DcaManager.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {reentrantCall} from "../utils/OzRevert.sol";

/// @notice Idle-route handler whose `depositToken` re-enters a second guarded `DcaManager` function once.
/// @dev Records the inner revert data instead of bubbling it, so the test can pin the exact refusal and
///      still see the outer guarded call complete.
contract ReenteringDepositHandler is IERC165, ITokenHandler, IPurchaseRbtc {
    DcaManager private immutable i_manager;
    /// @dev Reported so `OperationsAdmin.assignTokenHandler` can check it against the assigned token.
    address public immutable i_stableToken;
    address private s_token;
    uint64 private s_scheduleId;
    bool private s_armed;
    bytes public s_innerRevert;

    constructor(DcaManager manager, address stableToken) {
        i_manager = manager;
        i_stableToken = stableToken;
    }

    function arm(address token, uint64 scheduleId) external {
        s_token = token;
        s_scheduleId = scheduleId;
        s_armed = true;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITokenHandler).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function depositToken(address, uint256) external override {
        if (!s_armed) return;
        s_armed = false;
        try i_manager.updatePurchaseAmount(s_token, s_scheduleId, 2e18) {
            s_innerRevert = "";
        } catch (bytes memory reason) {
            s_innerRevert = reason;
        }
    }

    function withdrawToken(address, uint256 amount) external pure override returns (uint256) {
        return amount;
    }

    function batchBuyRbtc(address[] calldata, uint64[] calldata, uint256[] calldata, uint256) external override {}

    function withdrawAccumulatedRbtc(address) external override {}

    function getAccumulatedRbtcBalance(address) external pure override returns (uint256) {
        return 0;
    }
}

/**
 * @title R82TransientGuardGas
 * @notice Pins that `DcaManager`'s reentrancy guard lives in transient storage and still refuses re-entry.
 * @dev Reproduce on both profiles:
 *
 *          forge test --match-path test/gas/R82TransientGuardGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R82TransientGuardGas.t.sol -vv
 *
 *      OZ's storage and transient guards share one ERC-7201 slot id. `vm.stopAndReturnStateDiff`
 *      records `SLOAD`/`SSTORE` only, so a guarded call that touches that id in persistent storage is
 *      the storage guard (Rootstock: `SLOAD` 200 + two `RESET`s of 5,000). The transient guard's
 *      `TLOAD`/`TSTORE` (100 each on Rootstock since RSKIP-446) never appears. Foundry's own gas is
 *      logged as a Cancun regression figure; it is not the production saving.
 */
contract R82TransientGuardGasTest is Test {
    /// @dev keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~0xff
    bytes32 private constant GUARD_SLOT = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    uint256 private constant MIN_PURCHASE_PERIOD = 1 days;
    uint256 private constant MAX_SCHEDULES_PER_TOKEN = 10;
    uint256 private constant MIN_PURCHASE_AMOUNT = 1e18;
    uint256 private constant DEPOSIT_AMOUNT = 1000e18;
    uint256 private constant PURCHASE_AMOUNT = 10e18;
    uint256 private constant PURCHASE_PERIOD = 1 days;
    uint256 private constant ROUTE_INDEX = 0;

    address private s_token;
    address private s_buyer;
    DcaManager private s_manager;
    ReenteringDepositHandler private s_handler;

    function setUp() public {
        s_token = makeAddr("token");
        s_buyer = makeAddr("buyer");

        OperationsAdmin operationsAdmin = new OperationsAdmin(address(this));
        s_manager = new DcaManager(address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, address(this));
        s_manager.setTokenMinPurchaseAmount(s_token, MIN_PURCHASE_AMOUNT);
        s_handler = new ReenteringDepositHandler(s_manager, s_token);
        operationsAdmin.assignTokenHandler(s_token, ROUTE_INDEX, address(s_handler));

        vm.prank(s_buyer);
        s_manager.createDcaSchedule(s_token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
    }

    function test_deploy_leavesGuardSlotEmpty() public {
        assertEq(vm.load(address(s_manager), GUARD_SLOT), bytes32(0), "constructor wrote the guard slot");
    }

    function test_guardedCalls_neverTouchGuardSlotInStorage() public {
        uint64 scheduleId = uint64(s_manager.getSchedulesCreatedCount());

        uint256 snap = vm.snapshot();
        uint256 gasBefore = gasleft();
        vm.prank(s_buyer);
        s_manager.depositToken(s_token, scheduleId, DEPOSIT_AMOUNT);
        uint256 depositGas = gasBefore - gasleft();
        vm.revertTo(snap);

        vm.startStateDiffRecording();
        vm.prank(s_buyer);
        s_manager.depositToken(s_token, scheduleId, DEPOSIT_AMOUNT);
        vm.prank(s_buyer);
        s_manager.updatePurchaseAmount(s_token, scheduleId, 2 * PURCHASE_AMOUNT);
        vm.prank(s_buyer);
        s_manager.setSchedulePaused(s_token, scheduleId, true);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        console2.log("R82 depositToken gas (Cancun)", depositGas);
        assertEq(_guardSlotAccesses(accesses), 0, "guarded call touched the guard slot in storage");
        assertEq(vm.load(address(s_manager), GUARD_SLOT), bytes32(0));

        // The three calls ran back to back in one transaction, so each one released the transient lock.
        assertEq(s_manager.getDcaSchedule(s_token, scheduleId).purchaseAmount, 2 * PURCHASE_AMOUNT);
        assertTrue(s_manager.getDcaSchedule(s_token, scheduleId).paused);
    }

    function test_reentryIntoSecondGuardedFunction_reverts() public {
        uint64 scheduleId = uint64(s_manager.getSchedulesCreatedCount());
        s_handler.arm(s_token, scheduleId);

        vm.prank(s_buyer);
        s_manager.depositToken(s_token, scheduleId, DEPOSIT_AMOUNT);

        assertEq(s_handler.s_innerRevert(), reentrantCall(), "re-entry was not refused by the guard");
        assertEq(s_manager.getDcaSchedule(s_token, scheduleId).purchaseAmount, PURCHASE_AMOUNT);
        assertEq(s_manager.getDcaSchedule(s_token, scheduleId).tokenBalance, 2 * DEPOSIT_AMOUNT);
    }

    function _guardSlotAccesses(Vm.AccountAccess[] memory accesses) private view returns (uint256 count) {
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != address(s_manager)) continue;
            Vm.StorageAccess[] memory storageAccesses = accesses[i].storageAccesses;
            for (uint256 j; j < storageAccesses.length; ++j) {
                if (storageAccesses[j].slot == GUARD_SLOT) ++count;
            }
        }
    }
}
