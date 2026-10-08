// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Vm} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {ILendingHandler} from "src/interfaces/ILendingHandler.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import "../Constants.sol";
import {scheduleIdAt} from "test/utils/ScheduleAt.sol";

/**
 * @title EventIndexingTest
 * @notice ABI-freeze coverage: every scalar address and `scheduleId` is indexed, and nothing else is; lending share
 *         transitions replay to `getUserShares`; a non-zero purchase fee emits `PurchaseFees__FeeCredited`.
 */
contract EventIndexingTest is DcaDappTest {
    event LendingHandler__UserSharesUpdated(address indexed user, uint256 previousShares, uint256 newShares);
    event PurchaseFees__FeeCredited(address indexed collector, uint256 rbtcAmount, uint256 stablecoinAmount);

    bytes32 private constant OWNERSHIP_TRANSFERRED = keccak256("OwnershipTransferred(address,address)");
    bytes32 private constant OWNERSHIP_TRANSFER_STARTED = keccak256("OwnershipTransferStarted(address,address)");

    function setUp() public override {
        super.setUp();
    }

    function testLendingShareEventsReplayToGetter() external onlyLendingLane {
        vm.recordLogs();
        depositStablecoin();
        makeSinglePurchase();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 replayed = _latestUserShares(logs, USER);
        assertEq(replayed, ILendingHandler(address(stablecoinHandler)).getUserShares(USER));
        assertGt(replayed, 0);
        _assertFirstPartyIndexing(logs);
    }

    function testIdleDepositDoesNotEmitUserSharesUpdated() external {
        if (isLendingLane) {
            return;
        }
        vm.recordLogs();
        depositStablecoin();
        bytes32 sig = LendingHandler__UserSharesUpdated.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != sig, "idle handler emitted UserSharesUpdated");
        }
    }

    function testPurchaseFeeEmitsFeeCredited() external {
        address collector = IPurchaseFees(address(stablecoinHandler)).getFeeCollector();
        uint256 creditBefore = IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(collector);
        uint256 collectorAssetBefore = isDexSwaps ? wrbtc.balanceOf(collector) : collector.balance;

        vm.recordLogs();
        makeSinglePurchase();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 rbtcAmount, uint256 stablecoinAmount) = _feeCreditedAmounts(logs, collector);
        assertGt(rbtcAmount, 0, "purchase with a positive fee rate must emit FeeCredited");
        assertGt(stablecoinAmount, 0, "FeeCredited must log the stablecoin share");
        assertEq(
            IPurchaseRbtc(address(stablecoinHandler)).getAccumulatedRbtcBalance(collector) - creditBefore, rbtcAmount
        );
        uint256 collectorAssetAfter = isDexSwaps ? wrbtc.balanceOf(collector) : collector.balance;
        assertEq(collectorAssetAfter, collectorAssetBefore, "the collector is not paid until it withdraws");
        assertEq(stablecoin.balanceOf(collector), 0, "stablecoin fee must not be paid");
        _assertFirstPartyIndexing(logs);
    }

    function testSchedulePauseSetIndexesUserAndScheduleIdOnly() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.prank(USER);
        vm.recordLogs();
        dcaManager.setSchedulePaused(address(stablecoin), scheduleId, true);

        bytes32 sig = keccak256("DcaManager__SchedulePauseSet(address,uint64,bool)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            assertEq(logs[i].topics.length, 3, "SchedulePauseSet must index only user and scheduleId");
            assertEq(address(uint160(uint256(logs[i].topics[1]))), USER);
            assertEq(uint64(uint256(logs[i].topics[2])), scheduleId);
            bool paused = abi.decode(logs[i].data, (bool));
            assertTrue(paused);
            found = true;
        }
        assertTrue(found, "DcaManager__SchedulePauseSet not emitted");
    }

    function testFirstPartyLogsIndexEveryAddressAndScheduleIdOnly() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.recordLogs();
        depositStablecoin();
        vm.startPrank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), scheduleId, AMOUNT_TO_SPEND);
        dcaManager.updatePurchasePeriod(address(stablecoin), scheduleId, MIN_PURCHASE_PERIOD);
        dcaManager.setSchedulePaused(address(stablecoin), scheduleId, true);
        dcaManager.setSchedulePaused(address(stablecoin), scheduleId, false);
        vm.stopPrank();
        makeSinglePurchase();
        address[] memory tokens = new address[](1);
        tokens[0] = address(stablecoin);
        uint256[] memory routeIndexes = new uint256[](1);
        routeIndexes[0] = s_routeIndex;
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedRbtc(tokens, routeIndexes);
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), scheduleId, SCHEDULE_INDEX);
        _assertFirstPartyIndexing(vm.getRecordedLogs());
    }

    function testDcaScheduleDeletedIndexesUserTokenAndScheduleId() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), SCHEDULE_INDEX);
        vm.prank(USER);
        vm.recordLogs();
        dcaManager.deleteDcaSchedule(address(stablecoin), scheduleId, SCHEDULE_INDEX);

        bytes32 sig = keccak256("DcaManager__DcaScheduleDeleted(address,address,uint64,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            assertEq(logs[i].topics.length, 4, "DcaScheduleDeleted must index user, token, and scheduleId");
            assertEq(address(uint160(uint256(logs[i].topics[1]))), USER);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(stablecoin));
            assertEq(uint64(uint256(logs[i].topics[3])), scheduleId);
            abi.decode(logs[i].data, (uint256));
            found = true;
        }
        assertTrue(found, "DcaManager__DcaScheduleDeleted not emitted");
    }

    function _feeCreditedAmounts(Vm.Log[] memory logs, address collector)
        private
        view
        returns (uint256 rbtcAmount, uint256 stablecoinAmount)
    {
        bytes32 sig = PurchaseFees__FeeCredited.selector;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            if (logs[i].emitter != address(stablecoinHandler)) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != collector) continue;
            (rbtcAmount, stablecoinAmount) = abi.decode(logs[i].data, (uint256, uint256));
            found = true;
        }
        require(found, "PurchaseFees__FeeCredited not emitted");
    }

    function _latestUserShares(Vm.Log[] memory logs, address user) private pure returns (uint256 newShares) {
        bytes32 sig = LendingHandler__UserSharesUpdated.selector;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != user) continue;
            (, newShares) = abi.decode(logs[i].data, (uint256, uint256));
            found = true;
        }
        require(found, "LendingHandler__UserSharesUpdated not emitted");
    }

    function _assertFirstPartyIndexing(Vm.Log[] memory logs) private {
        for (uint256 i; i < logs.length; ++i) {
            address emitter = logs[i].emitter;
            if (
                emitter != address(dcaManager) && emitter != address(stablecoinHandler)
                    && emitter != address(operationsAdmin)
            ) {
                continue;
            }
            uint256 extra = logs[i].topics.length - 1;
            (bool known, uint256 expected) = _expectedExtraTopics(logs[i].topics[0]);
            assertTrue(known, "unknown first-party event in the freeze table");
            assertEq(extra, expected, "first-party event indexing does not match address/scheduleId rule");
        }
    }

    /// @dev Extra topics beyond the signature: every scalar `address` and `uint64 scheduleId`, and nothing else.
    function _expectedExtraTopics(bytes32 sig) private pure returns (bool known, uint256 extra) {
        if (sig == keccak256("DcaManager__TokenBalanceUpdated(address,uint64,uint256)")) return (true, 2);
        if (sig == keccak256("DcaManager__PurchaseAmountUpdated(address,uint64,uint256,uint256)")) return (true, 2);
        if (sig == keccak256("DcaManager__PurchasePeriodUpdated(address,uint64,uint256,uint256)")) return (true, 2);
        if (sig == keccak256("DcaManager__DcaScheduleCreated(address,address,uint64,uint256,uint256,uint256,uint256)"))
        {
            return (true, 3);
        }
        if (sig == keccak256("DcaManager__SchedulePauseSet(address,uint64,bool)")) return (true, 2);
        if (sig == keccak256("DcaManager__ProtectedPurchaseWindowActivated(address,uint256)")) return (true, 1);
        if (sig == keccak256("DcaManager__DcaScheduleDeleted(address,address,uint64,uint256)")) return (true, 3);
        if (sig == keccak256("DcaManager__MaxSchedulesPerTokenModified(uint256)")) return (true, 0);
        if (sig == keccak256("DcaManager__MinPurchasePeriodModified(uint256)")) return (true, 0);
        if (sig == keccak256("DcaManager__TokenMinPurchaseAmountSet(address,uint256)")) return (true, 1);
        if (sig == keccak256("LendingHandler__UserSharesUpdated(address,uint256,uint256)")) return (true, 1);
        if (sig == keccak256("LendingHandler__SharesRedeemed(address,uint256,uint256)")) return (true, 1);
        if (sig == keccak256("LendingHandler__SharesRedeemedBatch(uint256,uint256)")) return (true, 0);
        if (sig == keccak256("LendingHandler__InterestWithdrawn(address,address,uint256)")) return (true, 2);
        if (sig == keccak256("LendingHandler__WithdrawalAmountAdjusted(address,uint256,uint256)")) return (true, 1);
        if (sig == keccak256("TokenHandler__TokenDeposited(address,address,uint256)")) return (true, 2);
        if (sig == keccak256("TokenHandler__TokenWithdrawn(address,address,uint256)")) return (true, 2);
        if (sig == keccak256("PurchaseRbtc__rBtcWithdrawn(address,uint256)")) return (true, 1);
        if (sig == keccak256("PurchaseRbtc__RbtcBought(address,address,uint256,uint64,uint256)")) return (true, 3);
        if (sig == keccak256("PurchaseRbtc__SuccessfulRbtcBatchPurchase(address,uint256,uint256)")) return (true, 1);
        if (sig == keccak256("OperationsAdmin__HandlerAssigned(address,uint256,address)")) return (true, 2);
        if (sig == keccak256("OperationsAdmin__RouteRegistered(uint256,bool)")) return (true, 0);
        if (sig == keccak256("OperationsAdmin__SwapperAdded(address)")) return (true, 1);
        if (sig == keccak256("OperationsAdmin__SwapperRevoked(address)")) return (true, 1);
        if (sig == keccak256("OperationsAdmin__DepositsPauseSet(address,uint256,bool)")) return (true, 1);
        if (sig == keccak256("PurchaseUniswap__PurchasePathAllowedSet(bytes32,bytes,address[],uint24[],bool)")) {
            return (true, 0);
        }
        if (sig == keccak256("PurchaseFees__MinFeeRateSet(uint256)")) return (true, 0);
        if (sig == keccak256("PurchaseFees__MaxFeeRateSet(uint256)")) return (true, 0);
        if (sig == keccak256("PurchaseFees__PurchaseLowerBoundSet(uint256)")) return (true, 0);
        if (sig == keccak256("PurchaseFees__FeeCollectorAddressSet(address)")) return (true, 1);
        if (sig == keccak256("PurchaseFees__FeeCredited(address,uint256,uint256)")) return (true, 1);
        if (sig == keccak256("PurchaseUniswap__NewPathSet(address[],uint24[],bytes)")) return (true, 0);
        if (sig == keccak256("PurchaseUniswap__AmountOutMinimumPercentUpdated(uint256,uint256)")) return (true, 0);
        if (sig == keccak256("PurchaseUniswap__AmountOutMinimumSafetyCheckUpdated(uint256,uint256)")) return (true, 0);
        if (sig == keccak256("PurchaseUniswap__OracleUpdated(address,address)")) return (true, 2);
        if (sig == OWNERSHIP_TRANSFERRED) return (true, 2);
        if (sig == OWNERSHIP_TRANSFER_STARTED) return (true, 2);
        return (false, 0);
    }
}
