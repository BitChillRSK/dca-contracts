// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {DcaManager} from "src/DcaManager.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {StubPurchaseHandler} from "./StubPurchaseHandler.sol";
import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {ITokenLending} from "src/interfaces/ITokenLending.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";

/**
 * @title R94DcaManagerStoreBeforePullGas
 * @notice Pins schedule / settings read counts for the store-before-pull edits.
 * @dev Reproduce on both profiles:
 *
 *          forge test --match-path test/gas/R94DcaManagerStoreBeforePullGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R94DcaManagerStoreBeforePullGas.t.sol -vv
 *
 *      Read counts come from `vm.startStateDiffRecording`. A removed warm re-read is 100 Foundry /
 *      200 Rootstock. Create under deploy is the one pin that drops a counted read (settings slot
 *      2 → 1). Deposit store-before-pull was measured and reverted (reads stayed at 2). Top-up hoist
 *      is kept; its counted reads stay at 2 on both profiles, so this suite does not claim that
 *      200 Rootstock figure.
 */
contract R94DcaManagerStoreBeforePullGasTest is Test {
    uint256 private constant MIN_PURCHASE_PERIOD = 1 days;
    uint256 private constant MAX_SCHEDULES_PER_TOKEN = 10;
    uint256 private constant MIN_PURCHASE_AMOUNT = 1e18;
    uint256 private constant DEPOSIT_AMOUNT = 100e18;
    uint256 private constant PURCHASE_AMOUNT = 10e18;
    uint256 private constant PURCHASE_PERIOD = 1 days;
    uint256 private constant IDLE_ROUTE = 0;
    uint256 private constant LENDING_ROUTE = 1;
    /// @dev `s_dcaSchedules` base slot. Re-check with `forge inspect DcaManager storage-layout`.
    uint256 private constant SCHEDULES_SLOT = 2;
    /// @dev `s_protocolSettings` slot.
    uint256 private constant PROTOCOL_SETTINGS_SLOT = 4;
    uint256 private constant ACCRUED_INTEREST = 50e18;

    address private s_token;
    OperationsAdmin private s_operationsAdmin;
    DcaManager private s_manager;

    function setUp() public {
        vm.warp(1_700_000_000);
        s_token = makeAddr("token");

        s_operationsAdmin = new OperationsAdmin(address(this));
        s_manager =
            new DcaManager(address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, address(this));
        s_manager.setTokenMinPurchaseAmount(s_token, MIN_PURCHASE_AMOUNT);
        s_operationsAdmin.assignTokenHandler(s_token, IDLE_ROUTE, address(new StubPurchaseHandler(s_token)));

        s_operationsAdmin.registerRoute(LENDING_ROUTE, true);
        s_operationsAdmin.assignTokenHandler(
            s_token, LENDING_ROUTE, address(new StubLendingHandler(s_token, ACCRUED_INTEREST))
        );
    }

    function test_deposit_scheduleSlot0ReadCount() public {
        address buyer = makeAddr("deposit-buyer");
        vm.prank(buyer);
        s_manager.createDcaSchedule(s_token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, IDLE_ROUTE);
        uint64 scheduleId = 1;
        (bytes32 slot0,) = _scheduleSlots(s_token, scheduleId);

        vm.startStateDiffRecording();
        vm.prank(buyer);
        s_manager.depositToken(s_token, scheduleId, DEPOSIT_AMOUNT);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 reads = _readCount(accesses, address(s_manager), slot0);
        console2.log("R94 deposit schedule slot0 reads", reads);
        // Call-then-credit: balance + route, then the packed store's RMW after the pull. Legacy
        // codegen counts that RMW as a third read (3); deploy (`via_ir`) keeps it at 2. Store-before-
        // pull was 2 on both profiles but saved nothing under deploy, so it was reverted.
        if (_isDeployProfile()) {
            assertEq(reads, 2, "deposit schedule slot 0 read count drifted under deploy");
        } else {
            assertEq(reads, 3, "deposit schedule slot 0 read count drifted on default");
        }
        assertEq(s_manager.getDcaSchedule(s_token, scheduleId).tokenBalance, DEPOSIT_AMOUNT * 2);
    }

    function test_create_protocolSettingsReadCount() public {
        address buyer = makeAddr("create-buyer");

        vm.startStateDiffRecording();
        vm.prank(buyer);
        s_manager.createDcaSchedule(s_token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, IDLE_ROUTE);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 reads = _readCount(accesses, address(s_manager), bytes32(PROTOCOL_SETTINGS_SLOT));
        console2.log("R94 create protocol-settings reads", reads);
        // Deploy (`via_ir`) merges the load with the early nonce store (1). Legacy codegen still
        // records the store's RMW as a second read (2). One removed warm re-read under deploy is
        // 100 Foundry / 200 Rootstock.
        if (_isDeployProfile()) {
            assertEq(reads, 1, "create must read protocol settings once under deploy");
        } else {
            assertEq(reads, 2, "create protocol-settings read count drifted on default");
        }
        assertEq(s_manager.getSchedulesCreatedCount(), 1);
    }

    function test_topUp_scheduleSlot1ReadCount() public {
        address buyer = makeAddr("topup-buyer");
        vm.prank(buyer);
        s_manager.createDcaSchedule(s_token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, LENDING_ROUTE);
        uint64 scheduleId = 1;
        (, bytes32 slot1) = _scheduleSlots(s_token, scheduleId);

        vm.startStateDiffRecording();
        vm.prank(buyer);
        s_manager.topUpFromInterest(s_token, scheduleId, PURCHASE_AMOUNT);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 reads = _readCount(accesses, address(s_manager), slot1);
        console2.log("R94 top-up schedule slot1 reads", reads);
        // Owner check + purchaseAmount stay two counted reads under both profiles; keep the hoist,
        // do not claim the 200 Rootstock gas.
        assertEq(reads, 2, "top-up schedule slot 1 read count drifted");
        assertEq(s_manager.getDcaSchedule(s_token, scheduleId).tokenBalance, DEPOSIT_AMOUNT + PURCHASE_AMOUNT);
    }

    /// @dev `deploy` is the only `via_ir` profile (foundry.toml); every other profile is legacy codegen.
    function _isDeployProfile() private view returns (bool) {
        return keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default")))) == keccak256("deploy");
    }

    function _scheduleSlots(address token, uint64 scheduleId) private pure returns (bytes32 slot0, bytes32 slot1) {
        bytes32 tokenBase = keccak256(abi.encode(token, SCHEDULES_SLOT));
        slot0 = keccak256(abi.encode(uint256(scheduleId), tokenBase));
        slot1 = bytes32(uint256(slot0) + 1);
    }

    function _readCount(Vm.AccountAccess[] memory accesses, address account, bytes32 slot)
        private
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != account) continue;
            Vm.StorageAccess[] memory storageAccesses = accesses[i].storageAccesses;
            for (uint256 j; j < storageAccesses.length; ++j) {
                if (storageAccesses[j].slot == slot && !storageAccesses[j].isWrite) {
                    unchecked {
                        ++count;
                    }
                }
            }
        }
    }
}

/**
 * @notice Minimal lending stub so `topUpFromInterest` can call `getAccruedInterest` without a venue.
 */
contract StubLendingHandler is IERC165, ITokenHandler, ITokenLending, IPurchaseRbtc {
    IERC20 public immutable i_stableToken;
    uint256 public immutable i_accruedInterest;

    constructor(address stableToken, uint256 accruedInterest) {
        i_stableToken = IERC20(stableToken);
        i_accruedInterest = accruedInterest;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITokenHandler).interfaceId || interfaceId == type(ITokenLending).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function depositToken(address, uint256) external override {}

    function withdrawToken(address, uint256 amount) external pure override returns (uint256) {
        return amount;
    }

    function batchBuyRbtc(address[] calldata, uint64[] calldata, uint256[] calldata, uint256) external override {}

    function withdrawAccumulatedRbtc(address) external override {}

    function getAccumulatedRbtcBalance(address) external pure override returns (uint256) {
        return 0;
    }

    function withdrawInterest(address, uint256) external override {}

    function getAccruedInterest(address, uint256) external view override returns (uint256) {
        return i_accruedInterest;
    }

    function restoreLendingApproval() external override {}

    function getUserShares(address) external pure override returns (uint256) {
        return 0;
    }

    function quoteAccruedInterest(address, uint256) external view override returns (uint256) {
        return i_accruedInterest;
    }
}
