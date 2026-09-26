// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {console2, Vm} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {DcaDappTest} from "test/unit/DcaDappTest.t.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {ITokenLending} from "src/interfaces/ITokenLending.sol";
import {scheduleIdAt} from "test/utils/ScheduleAt.sol";
import "test/Constants.sol";

/**
 * @title R89ReviewCandidatesGas
 * @notice Read-count pins for the redundant reads R89 removed, plus logged figures for its compute-only
 *         changes.
 * @dev Reproduce on every local lane and both profiles, for example:
 *
 *          SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn forge test --match-path test/gas/R89ReviewCandidatesGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy SWAP_TYPE=mocSwaps LENDING_PROTOCOL=sovryn forge test --match-path test/gas/R89ReviewCandidatesGas.t.sol -vv
 *
 *      Uses the lane's script-deployed handler. Local lanes only: it mints mock stablecoin for the extra
 *      buyers. Read counts come from `vm.startStateDiffRecording`, per slot. Each removed warm re-read is
 *      100 gas in Foundry and 200 on Rootstock (ROOTSTOCK-GAS-SCHEDULE.md). The batch figure is a Foundry
 *      same-build regression pin; the `unchecked` arithmetic it includes is compute and carries over 1:1.
 *      To reproduce the pre-R89 counts, run this file against the parent PR's `src/`: every assertion
 *      below that pins a count then fails with the old value.
 */
contract R89ReviewCandidatesGasTest is DcaDappTest {
    using stdStorage for StdStorage;

    uint256 private constant ROWS = 10;
    /// @dev `s_scheduleIds` and `s_protocolSettings` in DcaManager (`forge inspect DcaManager storageLayout`).
    uint256 private constant SCHEDULE_IDS_SLOT = 3;
    uint256 private constant PROTOCOL_SETTINGS_SLOT = 4;
    /// @dev `s_routeClass` in OperationsAdmin (`forge inspect OperationsAdmin storageLayout`).
    uint256 private constant ROUTE_CLASS_SLOT = 3;

    address[] private s_buyers;

    function setUp() public override {
        super.setUp();
        if (block.chainid != ANVIL_CHAIN_ID) {
            vm.skip(true);
            return;
        }
        s_buyers.push(USER);
        for (uint256 i = 1; i < ROWS; ++i) {
            address buyer = makeAddr(string.concat("r89Buyer", vm.toString(i)));
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

    /*//////////////////////////////////////////////////////////////
                          ITEM 1: _lockedPrincipal
    //////////////////////////////////////////////////////////////*/

    /// @dev Ten schedules pack into three id words. The loop used to re-read the length and the id's word
    ///      on every iteration (1 + 2 × 10 = 21 reads). The memory copy reads the length once; `via_ir`
    ///      then reads each packed word once (3), while legacy codegen still reads one word per id (10).
    function test_lockedPrincipal_readsEachIdWordOnce() public {
        if (!operationsAdmin.isLendingRoute(s_routeIndex)) vm.skip(true);
        _fillUserSchedules(MAX_SCHEDULES_PER_TOKEN);
        updateExchangeRate(180 days);

        address[] memory tokens = new address[](1);
        uint256[] memory routes = new uint256[](1);
        tokens[0] = address(stablecoin);
        routes[0] = s_routeIndex;

        vm.startStateDiffRecording();
        vm.prank(USER);
        uint256 gasBefore = gasleft();
        dcaManager.withdrawAllAccumulatedInterest(tokens, routes);
        uint256 gasUsed = gasBefore - gasleft();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        bytes32 lengthSlot = keccak256(abi.encode(address(stablecoin), keccak256(abi.encode(USER, SCHEDULE_IDS_SLOT))));
        uint256 dataStart = uint256(keccak256(abi.encode(lengthSlot)));
        uint256 lengthReads = _reads(accesses, address(dcaManager), lengthSlot);
        uint256 wordReads;
        for (uint256 w; w < 3; ++w) {
            wordReads += _reads(accesses, address(dcaManager), bytes32(dataStart + w));
        }
        console2.log("withdrawAllAccumulatedInterest, 10 schedules: gas", gasUsed);
        console2.log("  id-array length reads", lengthReads);
        console2.log("  id-array word reads (3 words)", wordReads);

        assertEq(lengthReads, 1, "id-array length re-read");
        assertEq(wordReads, _viaIr() ? 3 : MAX_SCHEDULES_PER_TOKEN, "id word re-read");
    }

    /*//////////////////////////////////////////////////////////////
                          ITEM 2: _redeemShares
    //////////////////////////////////////////////////////////////*/

    /// @dev One handler call, one read of the user's booked shares (was two).
    function test_withdrawToken_readsBookedSharesOnce() public {
        if (!operationsAdmin.isLendingRoute(s_routeIndex)) vm.skip(true);
        bytes32 sharesSlot = _userSharesSlot(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);

        vm.startStateDiffRecording();
        vm.prank(USER);
        uint256 gasBefore = gasleft();
        dcaManager.withdrawToken(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
        uint256 gasUsed = gasBefore - gasleft();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 sharesReads = _reads(accesses, address(stablecoinHandler), sharesSlot);
        console2.log("withdrawToken (lending): gas", gasUsed);
        console2.log("  booked-shares reads", sharesReads);
        assertEq(sharesReads, 1, "booked shares re-read");
    }

    /// @dev Two handler calls (principal, then interest), one read each (was two each).
    function test_withdrawTokenAndInterest_readsBookedSharesOncePerCall() public {
        if (!operationsAdmin.isLendingRoute(s_routeIndex)) vm.skip(true);
        updateExchangeRate(180 days);
        bytes32 sharesSlot = _userSharesSlot(USER);
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);

        vm.startStateDiffRecording();
        vm.prank(USER);
        uint256 gasBefore = gasleft();
        dcaManager.withdrawTokenAndInterest(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
        uint256 gasUsed = gasBefore - gasleft();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 sharesReads = _reads(accesses, address(stablecoinHandler), sharesSlot);
        console2.log("withdrawTokenAndInterest (lending): gas", gasUsed);
        console2.log("  booked-shares reads", sharesReads);
        assertEq(sharesReads, 2, "booked shares re-read");
    }

    /*//////////////////////////////////////////////////////////////
                      ITEM 3: _validatePurchasePeriod
    //////////////////////////////////////////////////////////////*/

    /// @dev Creation loads the settings word once and rewrites it for the nonce; the period check no
    ///      longer adds a read of its own.
    function test_createDcaSchedule_readsSettingsWordWithoutTheValidatorsExtraRead() public {
        address buyer = makeAddr("r89Creator");
        stablecoin.mint(buyer, AMOUNT_TO_DEPOSIT);
        vm.prank(buyer);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);

        vm.startStateDiffRecording();
        vm.prank(buyer);
        uint256 gasBefore = gasleft();
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        uint256 gasUsed = gasBefore - gasleft();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 settingsReads = _reads(accesses, address(dcaManager), bytes32(PROTOCOL_SETTINGS_SLOT));
        console2.log("createDcaSchedule: gas", gasUsed);
        console2.log("  settings-word reads", settingsReads);
        assertEq(settingsReads, 2, "settings word re-read");
    }

    /*//////////////////////////////////////////////////////////////
                    ITEM 4: purchase-path arithmetic
    //////////////////////////////////////////////////////////////*/

    /// @dev Logged figure only: the `unchecked` saving is compute, so it shows as a lower total here and
    ///      carries over to Rootstock unchanged.
    function test_batchBuyRbtc_tenRows() public {
        uint64[] memory scheduleIds = new uint64[](ROWS);
        for (uint256 i; i < ROWS; ++i) {
            scheduleIds[i] = scheduleIdAt(dcaManager, s_buyers[i], address(stablecoin), 0);
        }
        IDcaManager.Batch memory batch = IDcaManager.Batch({
            scheduleIds: scheduleIds, token: address(stablecoin), routeIndex: s_routeIndex, minRbtcOut: 0
        });

        vm.prank(SWAPPER);
        uint256 gasBefore = gasleft();
        dcaManager.batchBuyRbtc(batch);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("batchBuyRbtc, 10 rows: gas", gasUsed);
    }

    /*//////////////////////////////////////////////////////////////
                      ITEM 11: assignTokenHandler
    //////////////////////////////////////////////////////////////*/

    /// @dev One read of the route's class (was two: the registration check and the lending/idle split).
    ///      A fresh registry takes the lane's real handler, so the pin runs on every lane.
    function test_assignTokenHandler_readsRouteClassOnce() public {
        OperationsAdmin registry = new OperationsAdmin(address(this));
        if (s_routeIndex != IDLE_INDEX) {
            registry.registerRoute(s_routeIndex, operationsAdmin.isLendingRoute(s_routeIndex));
        }

        vm.startStateDiffRecording();
        uint256 gasBefore = gasleft();
        registry.assignTokenHandler(address(stablecoin), s_routeIndex, address(stablecoinHandler));
        uint256 gasUsed = gasBefore - gasleft();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        bytes32 routeClassSlot = keccak256(abi.encode(s_routeIndex, ROUTE_CLASS_SLOT));
        uint256 routeClassReads = _reads(accesses, address(registry), routeClassSlot);
        console2.log("assignTokenHandler: gas", gasUsed);
        console2.log("  route-class reads", routeClassReads);
        assertEq(routeClassReads, 1, "route class re-read");
    }

    /*//////////////////////////////////////////////////////////////
                        ITEM 12: widening adds
    //////////////////////////////////////////////////////////////*/

    /// @dev Logged figure only, like the batch. `createDcaSchedule`'s figure above includes the nonce add.
    function test_activateProtectedPurchaseWindow() public {
        vm.prank(SWAPPER);
        uint256 gasBefore = gasleft();
        dcaManager.activateProtectedPurchaseWindow();
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("activateProtectedPurchaseWindow: gas", gasUsed);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Top USER up to `count` schedules on the lane's route, each with the standard shape.
    function _fillUserSchedules(uint256 count) private {
        uint256 missing = count - 1;
        stablecoin.mint(USER, AMOUNT_TO_DEPOSIT * missing);
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT * missing);
        for (uint256 i; i < missing; ++i) {
            dcaManager.createDcaSchedule(
                address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
            );
        }
        vm.stopPrank();
    }

    /// @dev Found through the public getter, so the pin does not depend on each leaf's storage layout.
    function _userSharesSlot(address user) private returns (bytes32) {
        return bytes32(
            stdstore.target(address(stablecoinHandler)).sig(ITokenLending.getUserShares.selector).with_key(user).find()
        );
    }

    /// @dev `deploy` is the only `via_ir` profile (foundry.toml); every other profile is legacy codegen.
    function _viaIr() private view returns (bool) {
        return keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default")))) == keccak256("deploy");
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
