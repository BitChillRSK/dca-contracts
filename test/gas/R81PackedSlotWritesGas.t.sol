// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {DcaManager} from "src/DcaManager.sol";
import {FeeHandler} from "src/FeeHandler.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {StubPurchaseHandler} from "./StubPurchaseHandler.sol";

contract R81FeeHandlerHarness is FeeHandler {
    constructor(IFeeHandler.FeeSettings memory feeSettings) FeeHandler(address(0xFEE), feeSettings, msg.sender) {}
}

/**
 * @title R81PackedSlotWritesGas
 * @notice Counts storage writes per packed slot on the three paths that used to store one word
 *         several times.
 * @dev Reproduce on both profiles:
 *
 *          forge test --match-path test/gas/R81PackedSlotWritesGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R81PackedSlotWritesGas.t.sol -vv
 *
 *      `vm.stopAndReturnStateDiff` records each `SSTORE` (`isWrite`), which is the count Rootstock
 *      prices at 5,000 a repeat. Foundry's own gas is logged as a Cancun regression figure; it is
 *      not the production saving.
 *
 *      Measured on this file, both profiles: each purchase row stores schedule slot 0 once, for a
 *      first anchor and a later one. `createDcaSchedule` stores slots 0 and 1 once each.
 *      `setFeeRateParams` stores the fee word once when any field changes, and not at all when
 *      nothing changes. Events fire only for the fields that changed.
 */
contract R81PackedSlotWritesGasTest is Test {
    uint256 private constant MIN_PURCHASE_PERIOD = 1 days;
    uint256 private constant MAX_SCHEDULES_PER_TOKEN = 10;
    uint256 private constant MIN_PURCHASE_AMOUNT = 1e18;
    uint256 private constant DEPOSIT_AMOUNT = 1000e18;
    uint256 private constant PURCHASE_AMOUNT = 10e18;
    uint256 private constant PURCHASE_PERIOD = 1 days;
    uint256 private constant ROUTE_INDEX = 0;
    /// @dev `s_dcaSchedules` base slot. Re-check with `forge inspect DcaManager storage-layout`.
    uint256 private constant SCHEDULES_SLOT = 2;
    /// @dev Packed fee word on `R81FeeHandlerHarness` (owner, pending owner, collector, then the word).
    ///      Re-check with `forge inspect R81FeeHandlerHarness storage-layout`.
    uint256 private constant FEE_WORD_SLOT = 3;

    address private s_swapper;
    address private s_token;
    OperationsAdmin private s_operationsAdmin;
    DcaManager private s_manager;
    R81FeeHandlerHarness private s_feeHandler;

    function setUp() public {
        vm.warp(1_700_000_000);
        s_swapper = makeAddr("swapper");
        s_token = makeAddr("token");

        s_operationsAdmin = new OperationsAdmin(address(this));
        s_operationsAdmin.addSwapper(s_swapper);
        s_manager = new DcaManager(address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, address(this));
        s_manager.setTokenMinPurchaseAmount(s_token, MIN_PURCHASE_AMOUNT);
        s_operationsAdmin.assignTokenHandler(s_token, ROUTE_INDEX, address(new StubPurchaseHandler()));

        for (uint256 i; i < 5; ++i) {
            _create(makeAddr(string(abi.encodePacked("buyer", vm.toString(i)))));
        }

        s_feeHandler = new R81FeeHandlerHarness(
            IFeeHandler.FeeSettings({
                minFeeRate: 100,
                maxFeeRate: 100,
                feePurchaseLowerBound: 1000 ether,
                feePurchaseUpperBound: 100_000 ether
            })
        );
    }

    function test_purchase_oneRow_firstAnchor_writesSlot0Once() public {
        _assertPurchaseSlot0Writes(1, false);
    }

    function test_purchase_fiveRows_firstAnchor_writesSlot0Once() public {
        _assertPurchaseSlot0Writes(5, false);
    }

    function test_purchase_oneRow_laterAnchor_writesSlot0Once() public {
        _assertPurchaseSlot0Writes(1, true);
    }

    function test_purchase_fiveRows_laterAnchor_writesSlot0Once() public {
        _assertPurchaseSlot0Writes(5, true);
    }

    function test_create_writesEachScheduleSlotFewerTimesThanTheStructLiteral() public {
        address buyer = makeAddr("create-buyer");
        uint64 scheduleId = uint64(s_manager.getSchedulesCreatedCount() + 1);
        (bytes32 slot0, bytes32 slot1) = _scheduleSlots(s_token, scheduleId);

        uint256 snap = vm.snapshot();
        uint256 gasBefore = gasleft();
        vm.prank(buyer);
        s_manager.createDcaSchedule(s_token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        uint256 gasUsed = gasBefore - gasleft();
        vm.revertTo(snap);

        vm.startStateDiffRecording();
        vm.prank(buyer);
        s_manager.createDcaSchedule(s_token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 slot0Writes = _writeCount(accesses, address(s_manager), slot0);
        uint256 slot1Writes = _writeCount(accesses, address(s_manager), slot1);
        console2.log("R81 create slot0 writes", slot0Writes);
        console2.log("R81 create slot1 writes", slot1Writes);
        console2.log("R81 create gas", gasUsed);

        // Exact on both profiles. The struct literal was 5+2 (default) and 5+1 (deploy). An upper
        // bound would let a deploy regression from 1+1 back to 2+1 pass.
        assertEq(slot0Writes, 1, "slot 0 was not stored once");
        assertEq(slot1Writes, 1, "slot 1 was not stored once");
        assertEq(_readCount(accesses, address(s_manager), slot0), 1, "slot 0 was read more than once");
        assertEq(_readCount(accesses, address(s_manager), slot1), 0, "slot 1 was read");

        IDcaManager.DcaSchedule memory schedule = s_manager.getDcaSchedule(s_token, scheduleId);
        assertEq(schedule.tokenBalance, DEPOSIT_AMOUNT);
        assertEq(schedule.cadenceAnchor, 0);
        assertFalse(schedule.paused);
        assertEq(schedule.purchasePeriod, PURCHASE_PERIOD);
        assertEq(schedule.routeIndex, ROUTE_INDEX);
        assertEq(schedule.user, buyer);
        assertEq(schedule.purchaseAmount, PURCHASE_AMOUNT);
    }

    function test_setFeeRateParams_allFourFields_writesTheFeeWordOnce() public {
        uint256 newMin = 50;
        uint256 newMax = 200;
        uint256 newLower = 100 ether;
        uint256 newUpper = 5000 ether;

        vm.expectEmit(address(s_feeHandler));
        emit IFeeHandler.FeeHandler__MinFeeRateSet(newMin);
        vm.expectEmit(address(s_feeHandler));
        emit IFeeHandler.FeeHandler__MaxFeeRateSet(newMax);
        vm.expectEmit(address(s_feeHandler));
        emit IFeeHandler.FeeHandler__PurchaseLowerBoundSet(newLower);
        vm.expectEmit(address(s_feeHandler));
        emit IFeeHandler.FeeHandler__PurchaseUpperBoundSet(newUpper);

        uint256 snap = vm.snapshot();
        uint256 gasBefore = gasleft();
        s_feeHandler.setFeeRateParams(newMin, newMax, newLower, newUpper);
        uint256 gasUsed = gasBefore - gasleft();
        vm.revertTo(snap);

        vm.startStateDiffRecording();
        s_feeHandler.setFeeRateParams(newMin, newMax, newLower, newUpper);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 writes = _writeCount(accesses, address(s_feeHandler), bytes32(FEE_WORD_SLOT));
        console2.log("R81 fee word writes", writes);
        console2.log("R81 fee gas", gasUsed);
        assertEq(writes, 1, "changing all four fee fields stored the word more than once");

        IFeeHandler.FeeSettings memory settings = s_feeHandler.getFeeSettings();
        assertEq(settings.minFeeRate, newMin);
        assertEq(settings.maxFeeRate, newMax);
        assertEq(settings.feePurchaseLowerBound, newLower);
        assertEq(settings.feePurchaseUpperBound, newUpper);
    }

    function test_setFeeRateParams_partialChange_emitsOnlyChangedFieldsAndWritesOnce() public {
        uint256 newMin = 50;
        uint256 newUpper = 5000 ether;

        vm.recordLogs();
        vm.startStateDiffRecording();
        s_feeHandler.setFeeRateParams(newMin, 100, 1000 ether, newUpper);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        assertEq(_writeCount(accesses, address(s_feeHandler), bytes32(FEE_WORD_SLOT)), 1);
        assertEq(logs.length, 2, "unchanged fee fields emitted");
        assertEq(logs[0].topics[0], keccak256("FeeHandler__MinFeeRateSet(uint256)"));
        assertEq(logs[1].topics[0], keccak256("FeeHandler__PurchaseUpperBoundSet(uint256)"));
        assertEq(abi.decode(logs[0].data, (uint256)), newMin);
        assertEq(abi.decode(logs[1].data, (uint256)), newUpper);

        IFeeHandler.FeeSettings memory settings = s_feeHandler.getFeeSettings();
        assertEq(settings.minFeeRate, newMin);
        assertEq(settings.maxFeeRate, 100);
        assertEq(settings.feePurchaseLowerBound, 1000 ether);
        assertEq(settings.feePurchaseUpperBound, newUpper);
    }

    function test_setFeeRateParams_unchanged_emitsNothingAndDoesNotWrite() public {
        vm.recordLogs();
        vm.startStateDiffRecording();
        s_feeHandler.setFeeRateParams(100, 100, 1000 ether, 100_000 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        assertEq(_writeCount(accesses, address(s_feeHandler), bytes32(FEE_WORD_SLOT)), 0);
        assertEq(logs.length, 0, "an unchanged fee update emitted");
    }

    function _assertPurchaseSlot0Writes(uint256 rows, bool laterPurchase) private {
        uint64[] memory scheduleIds = _scheduleIds(rows);
        if (laterPurchase) {
            _buy(scheduleIds);
            vm.warp(block.timestamp + PURCHASE_PERIOD);
        }

        uint256 snap = vm.snapshot();
        uint256 gasBefore = gasleft();
        _buy(scheduleIds);
        uint256 gasUsed = gasBefore - gasleft();
        vm.revertTo(snap);

        vm.startStateDiffRecording();
        _buy(scheduleIds);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        console2.log(laterPurchase ? "R81 later purchase rows" : "R81 first purchase rows", rows);
        console2.log("R81 purchase gas", gasUsed);

        for (uint256 i; i < rows; ++i) {
            (bytes32 slot0,) = _scheduleSlots(s_token, scheduleIds[i]);
            uint256 writes = _writeCount(accesses, address(s_manager), slot0);
            assertEq(writes, 1, "schedule slot 0 was not stored exactly once");

            IDcaManager.DcaSchedule memory schedule = s_manager.getDcaSchedule(s_token, scheduleIds[i]);
            uint256 purchases = laterPurchase ? 2 : 1;
            assertEq(schedule.tokenBalance, DEPOSIT_AMOUNT - PURCHASE_AMOUNT * purchases);
            assertGt(schedule.cadenceAnchor, 0);
            if (!laterPurchase) {
                assertEq(schedule.cadenceAnchor, _dayStart(block.timestamp));
            }
        }
    }

    function _create(address buyer) private {
        vm.prank(buyer);
        s_manager.createDcaSchedule(s_token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, ROUTE_INDEX);
    }

    function _scheduleIds(uint256 rows) private pure returns (uint64[] memory scheduleIds) {
        scheduleIds = new uint64[](rows);
        for (uint256 i; i < rows; ++i) {
            scheduleIds[i] = uint64(i + 1);
        }
    }

    function _buy(uint64[] memory scheduleIds) private {
        vm.prank(s_swapper);
        s_manager.batchBuyRbtc(
            IDcaManager.Batch({
                scheduleIds: scheduleIds, token: s_token, routeIndex: ROUTE_INDEX, minRbtcOut: 0
            })
        );
    }

    function _scheduleSlots(address token, uint64 scheduleId) private pure returns (bytes32 slot0, bytes32 slot1) {
        bytes32 tokenBase = keccak256(abi.encode(token, SCHEDULES_SLOT));
        slot0 = keccak256(abi.encode(uint256(scheduleId), tokenBase));
        slot1 = bytes32(uint256(slot0) + 1);
    }

    function _writeCount(Vm.AccountAccess[] memory accesses, address account, bytes32 slot)
        private
        pure
        returns (uint256 count)
    {
        return _accessCount(accesses, account, slot, true);
    }

    function _readCount(Vm.AccountAccess[] memory accesses, address account, bytes32 slot)
        private
        pure
        returns (uint256 count)
    {
        return _accessCount(accesses, account, slot, false);
    }

    function _accessCount(Vm.AccountAccess[] memory accesses, address account, bytes32 slot, bool writes)
        private
        pure
        returns (uint256 count)
    {
        uint256 n = accesses.length;
        for (uint256 i; i < n; ++i) {
            Vm.StorageAccess[] memory storageAccesses = accesses[i].storageAccesses;
            uint256 m = storageAccesses.length;
            for (uint256 j; j < m; ++j) {
                Vm.StorageAccess memory access = storageAccesses[j];
                if (access.account == account && access.slot == slot && access.isWrite == writes && !access.reverted) {
                    ++count;
                }
            }
        }
    }

    function _dayStart(uint256 timestamp) private pure returns (uint256) {
        return timestamp - (timestamp % 1 days);
    }
}
