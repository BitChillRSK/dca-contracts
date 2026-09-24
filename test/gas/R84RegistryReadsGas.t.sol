// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {DcaManager} from "src/DcaManager.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {ITokenLending} from "src/interfaces/ITokenLending.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {StubPurchaseHandler} from "./StubPurchaseHandler.sol";

/**
 * @notice Lending-route handler stub that moves no tokens and reports a fixed accrued interest.
 * @dev Records the last caller-facing call so a test can prove principal and interest reached the
 *      same handler. Answers `ITokenLending` so `OperationsAdmin` accepts it on a lending route.
 */
contract StubLendingHandler is IERC165, ITokenHandler, ITokenLending, IPurchaseRbtc {
    uint256 public constant ACCRUED_INTEREST = 100e18;
    uint256 public principalWithdrawals;
    uint256 public interestWithdrawals;

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITokenHandler).interfaceId || interfaceId == type(ITokenLending).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function depositToken(address, uint256) external override {}

    function withdrawToken(address, uint256 amount) external override returns (uint256) {
        ++principalWithdrawals;
        return amount;
    }

    function withdrawInterest(address, uint256) external override {
        ++interestWithdrawals;
    }

    function getAccruedInterest(address, uint256) external pure override returns (uint256) {
        return ACCRUED_INTEREST;
    }

    function getUserShares(address) external pure override returns (uint256) {
        return 0;
    }

    function quoteAccruedInterest(address, uint256) external pure override returns (uint256) {
        return ACCRUED_INTEREST;
    }

    function batchBuyRbtc(address[] memory, uint64[] memory, uint256[] memory, uint256) external override {}

    function withdrawAccumulatedRbtc(address) external override {}

    function getAccumulatedRbtcBalance(address) external pure override returns (uint256) {
        return 0;
    }
}

/**
 * @title R84RegistryReadsGas
 * @notice Counts `OperationsAdmin` calls per user path, so no path asks the registry the same
 *         question about one route twice.
 * @dev Reproduce on both profiles:
 *
 *          forge test --match-path test/gas/R84RegistryReadsGas.t.sol -vv
 *          FOUNDRY_PROFILE=deploy forge test --match-path test/gas/R84RegistryReadsGas.t.sol -vv
 *
 *      `vm.stopAndReturnStateDiff` records one `StaticCall` access per registry call. Rootstock has no
 *      EIP-2929 for account access, so each repeat call into `OperationsAdmin` costs a flat 700 plus
 *      200 for the `SLOAD` behind it, where Foundry prices it warm at 100 + 100. The Foundry gas
 *      logged here is a Cancun regression figure; the Rootstock saving is derived in the R84 spec.
 */
contract R84RegistryReadsGasTest is Test {
    uint256 private constant MIN_PURCHASE_PERIOD = 1 days;
    uint256 private constant MAX_SCHEDULES_PER_TOKEN = 10;
    uint256 private constant MIN_PURCHASE_AMOUNT = 1e18;
    uint256 private constant DEPOSIT_AMOUNT = 1000e18;
    uint256 private constant PURCHASE_AMOUNT = 10e18;
    uint256 private constant PURCHASE_PERIOD = 1 days;
    uint256 private constant IDLE_ROUTE = 0;
    uint256 private constant LENDING_ROUTE = 1;
    uint256 private constant UNASSIGNED_ROUTE = 2;

    address private s_token;
    address private s_buyer;
    OperationsAdmin private s_operationsAdmin;
    DcaManager private s_manager;
    StubLendingHandler private s_lendingHandler;
    uint64 private s_lendingScheduleId;

    function setUp() public {
        s_token = makeAddr("token");
        s_buyer = makeAddr("buyer");

        s_operationsAdmin = new OperationsAdmin(address(this));
        s_operationsAdmin.registerRoute(LENDING_ROUTE, true);
        s_manager = new DcaManager(address(s_operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, address(this));
        s_manager.setTokenMinPurchaseAmount(s_token, MIN_PURCHASE_AMOUNT);
        s_lendingHandler = new StubLendingHandler();
        s_operationsAdmin.assignTokenHandler(s_token, LENDING_ROUTE, address(s_lendingHandler));
        s_operationsAdmin.assignTokenHandler(s_token, IDLE_ROUTE, address(new StubPurchaseHandler()));

        vm.startPrank(s_buyer);
        s_manager.createDcaSchedule(s_token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, LENDING_ROUTE);
        s_lendingScheduleId = uint64(s_manager.getSchedulesCreatedCount());
        s_manager.createDcaSchedule(s_token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, IDLE_ROUTE);
        vm.stopPrank();
    }

    function test_createDcaSchedule_callsRegistryOnce() public {
        bytes memory data = abi.encodeCall(
            DcaManager.createDcaSchedule, (s_token, DEPOSIT_AMOUNT, PURCHASE_AMOUNT, PURCHASE_PERIOD, LENDING_ROUTE)
        );
        assertEq(_measure("createDcaSchedule", data), 1);
    }

    function test_depositToken_callsRegistryOnce() public {
        bytes memory data = abi.encodeCall(DcaManager.depositToken, (s_token, s_lendingScheduleId, DEPOSIT_AMOUNT));
        assertEq(_measure("depositToken", data), 1);
    }

    function test_topUpFromInterest_callsRegistryOnce() public {
        bytes memory data = abi.encodeCall(DcaManager.topUpFromInterest, (s_token, s_lendingScheduleId, PURCHASE_AMOUNT));
        assertEq(_measure("topUpFromInterest", data), 1);
    }

    function test_withdrawAllAccumulatedInterest_callsRegistryOncePerPair() public {
        assertEq(_measure("withdrawAllAccumulatedInterest, one pair", _withdrawAllInterestCall(1)), 1);
        assertEq(s_lendingHandler.interestWithdrawals(), 1);
    }

    function test_withdrawAllAccumulatedInterest_mixedPairs_callsRegistryOncePerPair() public {
        // Lending, idle, and unassigned: each pair is asked about once, and only the lending one pays.
        assertEq(_measure("withdrawAllAccumulatedInterest, three pairs", _withdrawAllInterestCall(3)), 3);
        assertEq(s_lendingHandler.interestWithdrawals(), 1);
    }

    function test_withdrawTokenAndInterest_callsRegistryTwice_sameHandler() public {
        bytes memory data =
            abi.encodeCall(DcaManager.withdrawTokenAndInterest, (s_token, s_lendingScheduleId, PURCHASE_AMOUNT));
        // One handler lookup and one route-class lookup.
        assertEq(_measure("withdrawTokenAndInterest", data), 2);
        assertEq(s_lendingHandler.principalWithdrawals(), 1, "principal did not reach the lending handler");
        assertEq(s_lendingHandler.interestWithdrawals(), 1, "interest did not reach the lending handler");
    }

    /// @dev Runs `data` from the buyer twice from one snapshot: once for Foundry gas, once recorded.
    ///      Leaves the recorded run's state in place so callers can assert on its effects.
    function _measure(string memory label, bytes memory data) private returns (uint256 registryCalls) {
        uint256 snap = vm.snapshot();
        _warmRegistry();
        vm.prank(s_buyer);
        uint256 gasBefore = gasleft();
        (bool ok,) = address(s_manager).call(data);
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(ok, label);
        vm.revertTo(snap);

        _warmRegistry();
        vm.startStateDiffRecording();
        vm.prank(s_buyer);
        (ok,) = address(s_manager).call(data);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertTrue(ok, label);

        uint256 registryReads;
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != address(s_operationsAdmin)) continue;
            if (accesses[i].kind != VmSafe.AccountAccessKind.StaticCall) continue;
            ++registryCalls;
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                if (!accesses[i].storageAccesses[j].isWrite) ++registryReads;
            }
        }
        console2.log(label);
        console2.log("  Foundry gas (Cancun, call incl. overhead)", gasUsed);
        console2.log("  OperationsAdmin calls", registryCalls);
        console2.log("  OperationsAdmin SLOADs", registryReads);
    }

    /// @dev Warms `OperationsAdmin` and every registry slot any path here reads, through getters that
    ///      predate `getRouteInfo`. Cancun then prices each registry call and read the same way on
    ///      both sides of the change (100 + 100), so the logged delta converts to Rootstock by
    ///      repricing only the calls and reads that were added or removed. Without this, a read that
    ///      is cold in the test but a flat 200 on Rootstock would dominate the Cancun delta.
    function _warmRegistry() private view {
        for (uint256 route; route <= UNASSIGNED_ROUTE; ++route) {
            s_operationsAdmin.getTokenHandler(s_token, route);
            s_operationsAdmin.getRouteClass(route);
        }
    }

    function _withdrawAllInterestCall(uint256 numOfPairs) private view returns (bytes memory) {
        address[] memory tokens = new address[](numOfPairs);
        uint256[] memory routeIndexes = new uint256[](numOfPairs);
        uint256[3] memory routes = [LENDING_ROUTE, IDLE_ROUTE, UNASSIGNED_ROUTE];
        for (uint256 i; i < numOfPairs; ++i) {
            tokens[i] = s_token;
            routeIndexes[i] = routes[i];
        }
        return abi.encodeCall(DcaManager.withdrawAllAccumulatedInterest, (tokens, routeIndexes));
    }
}
