// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {console2, Vm} from "forge-std/Test.sol";
import {DcaDappTest} from "test/unit/DcaDappTest.t.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {scheduleIdAt} from "test/utils/ScheduleAt.sol";
import "test/Constants.sol";

/**
 * @title R90OraclePackingGas
 * @notice Read-count pins for Dex oracle/live-floor packing. Local Dex lanes only.
 * @dev Reproduce:
 *
 *          STABLECOIN_TYPE=USDRIF SWAP_TYPE=dexSwaps LENDING_PROTOCOL=none \
 *            forge test --match-path test/gas/R90OraclePackingGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy STABLECOIN_TYPE=USDRIF SWAP_TYPE=dexSwaps LENDING_PROTOCOL=none \
 *            forge test --match-path test/gas/R90OraclePackingGas.t.sol -vv
 *
 *      Idle: oracle+percent slot 5, safety slot 6. Lending Dex inserts `s_shares` at 4, so those
 *      become 6 and 7. Each removed cold SLOAD is 2,100 Foundry / 200 Rootstock; warm re-reads are
 *      100 Foundry / 200 Rootstock. Quote Rootstock from the read count, not the Cancun cold delta.
 */
contract R90OraclePackingGasTest is DcaDappTest {
    uint256 private constant ROWS = 10;
    uint256 private constant IDLE_ORACLE_SLOT = 5;
    uint256 private constant IDLE_SAFETY_SLOT = 6;
    uint256 private constant LENDING_ORACLE_SLOT = 6;
    uint256 private constant LENDING_SAFETY_SLOT = 7;

    address[] private s_buyers;

    function setUp() public override {
        super.setUp();
        if (block.chainid != ANVIL_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        if (!isDexSwaps) {
            vm.skip(true);
            return;
        }
        s_buyers.push(USER);
        for (uint256 i = 1; i < ROWS; ++i) {
            address buyer = makeAddr(string.concat("r90Buyer", vm.toString(i)));
            stablecoin.mint(buyer, AMOUNT_TO_DEPOSIT);
            vm.startPrank(buyer);
            stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
            dcaManager.createDcaSchedule(
                address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
            );
            vm.stopPrank();
            s_buyers.push(buyer);
        }
    }

    function test_batchBuyRbtc_readsPackedOracleFloorOnce() public {
        uint64[] memory scheduleIds = new uint64[](ROWS);
        for (uint256 i; i < ROWS; ++i) {
            scheduleIds[i] = scheduleIdAt(dcaManager, s_buyers[i], address(stablecoin), 0);
        }
        IDcaManager.Batch memory batch = IDcaManager.Batch({
            scheduleIds: scheduleIds, token: address(stablecoin), routeIndex: s_routeIndex, minRbtcOut: 0
        });

        uint256 oracleSlot = isLendingLane ? LENDING_ORACLE_SLOT : IDLE_ORACLE_SLOT;
        uint256 safetySlot = isLendingLane ? LENDING_SAFETY_SLOT : IDLE_SAFETY_SLOT;

        vm.startStateDiffRecording();
        vm.prank(SWAPPER);
        uint256 gasBefore = gasleft();
        dcaManager.batchBuyRbtc(batch);
        uint256 gasUsed = gasBefore - gasleft();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 oracleReads = _reads(accesses, address(stablecoinHandler), bytes32(oracleSlot));
        uint256 safetyReads = _reads(accesses, address(stablecoinHandler), bytes32(safetySlot));
        console2.log("batchBuyRbtc, 10 rows: gas", gasUsed);
        console2.log("  oracle+percent slot reads", oracleReads);
        console2.log("  safety-slot reads", safetyReads);

        assertEq(oracleReads, 1, "packed oracle+percent word should be read once per batch");
        assertEq(safetyReads, 0, "purchase must not read the safety floor");
    }

    function test_setAmountOutMinimumPercent_readsBothSettingSlots() public {
        uint256 oracleSlot = isLendingLane ? LENDING_ORACLE_SLOT : IDLE_ORACLE_SLOT;
        uint256 safetySlot = isLendingLane ? LENDING_SAFETY_SLOT : IDLE_SAFETY_SLOT;
        uint256 newPercent = DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT * 999 / 1000;

        vm.startStateDiffRecording();
        vm.prank(OWNER);
        uint256 gasBefore = gasleft();
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(newPercent);
        uint256 gasUsed = gasBefore - gasleft();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 oracleReads = _reads(accesses, address(stablecoinHandler), bytes32(oracleSlot));
        uint256 safetyReads = _reads(accesses, address(stablecoinHandler), bytes32(safetySlot));
        console2.log("setAmountOutMinimumPercent: gas", gasUsed);
        console2.log("  oracle+percent slot reads", oracleReads);
        console2.log("  safety-slot reads", safetyReads);

        assertGe(safetyReads, 1, "setter must read the safety floor");
        assertGe(oracleReads, 1, "setter must touch the packed oracle+percent word");
    }

    function test_setAmountOutMinimumSafetyCheck_readsBothSettingSlots() public {
        uint256 oracleSlot = isLendingLane ? LENDING_ORACLE_SLOT : IDLE_ORACLE_SLOT;
        uint256 safetySlot = isLendingLane ? LENDING_SAFETY_SLOT : IDLE_SAFETY_SLOT;
        uint256 newSafety = DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK * 999 / 1000;

        vm.startStateDiffRecording();
        vm.prank(OWNER);
        uint256 gasBefore = gasleft();
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumSafetyCheck(newSafety);
        uint256 gasUsed = gasBefore - gasleft();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 oracleReads = _reads(accesses, address(stablecoinHandler), bytes32(oracleSlot));
        uint256 safetyReads = _reads(accesses, address(stablecoinHandler), bytes32(safetySlot));
        console2.log("setAmountOutMinimumSafetyCheck: gas", gasUsed);
        console2.log("  oracle+percent slot reads", oracleReads);
        console2.log("  safety-slot reads", safetyReads);

        assertGe(oracleReads, 1, "setter must read the live floor beside the oracle");
        assertGe(safetyReads, 1, "setter must touch the safety word");
    }

    function _reads(Vm.AccountAccess[] memory accesses, address account, bytes32 slot)
        private
        pure
        returns (uint256 n)
    {
        for (uint256 i; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory storageAccesses = accesses[i].storageAccesses;
            for (uint256 j; j < storageAccesses.length; ++j) {
                Vm.StorageAccess memory access = storageAccesses[j];
                if (access.account == account && access.slot == slot && !access.isWrite && !access.reverted) ++n;
            }
        }
    }
}
