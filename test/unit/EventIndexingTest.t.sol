// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Vm} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {ITokenLending} from "src/interfaces/ITokenLending.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import "../../script/Constants.sol";

/**
 * @title EventIndexingTest
 * @notice ABI-freeze coverage: every scalar address and `scheduleId` is indexed, and nothing else is; lending share
 *         transitions replay to `getUserShares`; a non-zero purchase fee emits `FeeTransferred`.
 */
contract EventIndexingTest is DcaDappTest {
    event TokenLending__UserSharesUpdated(address indexed user, uint256 previousShares, uint256 newShares);
    event FeeHandler__FeeTransferred(address indexed token, address indexed collector, uint256 amount);

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
        assertEq(replayed, ITokenLending(address(stablecoinHandler)).getUserShares(USER));
        assertGt(replayed, 0);
        _assertFirstPartyIndexing(logs);
    }

    function testIdleDepositDoesNotEmitUserSharesUpdated() external {
        if (isLendingLane) {
            return;
        }
        vm.recordLogs();
        depositStablecoin();
        bytes32 sig = TokenLending__UserSharesUpdated.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != sig, "idle handler emitted UserSharesUpdated");
        }
    }

    function testPurchaseEmitsFeeTransferred() external {
        address collector = IFeeHandler(address(stablecoinHandler)).getFeeCollectorAddress();
        uint256 collectorBefore = stablecoin.balanceOf(collector);

        vm.recordLogs();
        makeSinglePurchase();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 feeAmount = _feeTransferredAmount(logs);
        assertGt(feeAmount, 0, "purchase with a positive fee rate must emit FeeTransferred");
        assertEq(stablecoin.balanceOf(collector) - collectorBefore, feeAmount);
        _assertFirstPartyIndexing(logs);
    }

    function testSchedulePauseSetIndexesUserAndScheduleIdOnly() external {
        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.prank(USER);
        vm.recordLogs();
        dcaManager.setSchedulePaused(address(stablecoin), SCHEDULE_INDEX, scheduleId, true);

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
        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.recordLogs();
        depositStablecoin();
        vm.startPrank(USER);
        dcaManager.updatePurchaseAmount(address(stablecoin), SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND);
        dcaManager.updatePurchasePeriod(address(stablecoin), SCHEDULE_INDEX, scheduleId, MIN_PURCHASE_PERIOD);
        dcaManager.setSchedulePaused(address(stablecoin), SCHEDULE_INDEX, scheduleId, true);
        dcaManager.setSchedulePaused(address(stablecoin), SCHEDULE_INDEX, scheduleId, false);
        vm.stopPrank();
        makeSinglePurchase();
        vm.prank(USER);
        dcaManager.withdrawRbtcFromTokenHandler(address(stablecoin), s_routeIndex);
        vm.prank(USER);
        dcaManager.deleteDcaSchedule(address(stablecoin), SCHEDULE_INDEX, scheduleId);
        _assertFirstPartyIndexing(vm.getRecordedLogs());
    }

    function testDcaScheduleDeletedIndexesUserTokenAndScheduleId() external {
        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        vm.prank(USER);
        vm.recordLogs();
        dcaManager.deleteDcaSchedule(address(stablecoin), SCHEDULE_INDEX, scheduleId);

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

    function _feeTransferredAmount(Vm.Log[] memory logs) private pure returns (uint256 amount) {
        bytes32 sig = FeeHandler__FeeTransferred.selector;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            amount = abi.decode(logs[i].data, (uint256));
            found = true;
        }
        require(found, "FeeHandler__FeeTransferred not emitted");
    }

    function _latestUserShares(Vm.Log[] memory logs, address user) private pure returns (uint256 newShares) {
        bytes32 sig = TokenLending__UserSharesUpdated.selector;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != user) continue;
            (, newShares) = abi.decode(logs[i].data, (uint256, uint256));
            found = true;
        }
        require(found, "TokenLending__UserSharesUpdated not emitted");
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
        if (sig == keccak256("DcaManager__DcaScheduleCreated(address,address,uint64,uint256,uint256,uint256,uint256)")) {
            return (true, 3);
        }
        if (sig == keccak256("DcaManager__SchedulePauseSet(address,uint64,bool)")) return (true, 2);
        if (sig == keccak256("DcaManager__DcaScheduleDeleted(address,address,uint64,uint256)")) return (true, 3);
        if (sig == keccak256("DcaManager__MaxSchedulesPerTokenModified(uint256)")) return (true, 0);
        if (sig == keccak256("DcaManager__MinPurchasePeriodModified(uint256)")) return (true, 0);
        if (sig == keccak256("DcaManager__LastPurchaseTimestampUpdated(address,uint64,uint256)")) return (true, 2);
        if (sig == keccak256("DcaManager__DefaultMinPurchaseAmountModified(uint256)")) return (true, 0);
        if (sig == keccak256("DcaManager__TokenMinPurchaseAmountSet(address,uint256)")) return (true, 1);
        if (sig == keccak256("TokenLending__UserSharesUpdated(address,uint256,uint256)")) return (true, 1);
        if (sig == keccak256("TokenLending__SharesRedeemed(address,uint256,uint256)")) return (true, 1);
        if (sig == keccak256("TokenLending__SharesRedeemedBatch(uint256,uint256)")) return (true, 0);
        if (sig == keccak256("TokenLending__InterestWithdrawn(address,address,uint256)")) return (true, 2);
        if (sig == keccak256("TokenLending__WithdrawalAmountAdjusted(address,uint256,uint256)")) return (true, 1);
        if (sig == keccak256("TokenLending__AmountToRedeemAdjusted(address,uint256,uint256,uint256,uint256)")) {
            return (true, 1);
        }
        if (sig == keccak256("TokenHandler__TokenDeposited(address,address,uint256)")) return (true, 2);
        if (sig == keccak256("TokenHandler__TokenWithdrawn(address,address,uint256)")) return (true, 2);
        if (sig == keccak256("PurchaseRbtc__rBtcWithdrawn(address,uint256)")) return (true, 1);
        if (sig == keccak256("PurchaseRbtc__RbtcBought(address,address,uint256,uint64,uint256)")) return (true, 3);
        if (sig == keccak256("PurchaseRbtc__SuccessfulRbtcBatchPurchase(address,uint256,uint256)")) return (true, 1);
        if (sig == keccak256("OperationsAdmin__TokenHandlerAssigned(address,uint256,address)")) return (true, 2);
        if (sig == keccak256("OperationsAdmin__RouteRegistered(uint256,bool)")) return (true, 0);
        if (sig == keccak256("OperationsAdmin__SwapperAdded(address)")) return (true, 1);
        if (sig == keccak256("OperationsAdmin__SwapperRevoked(address)")) return (true, 1);
        if (sig == keccak256("OperationsAdmin__DepositsPauseSet(address,uint256,bool)")) return (true, 1);
        if (sig == keccak256("PurchaseUniswap_PurchasePathAllowedSet(bytes32,bytes,address[],uint24[],bool)")) {
            return (true, 0);
        }
        if (sig == keccak256("FeeHandler__MinFeeRateSet(uint256)")) return (true, 0);
        if (sig == keccak256("FeeHandler__MaxFeeRateSet(uint256)")) return (true, 0);
        if (sig == keccak256("FeeHandler__PurchaseLowerBoundSet(uint256)")) return (true, 0);
        if (sig == keccak256("FeeHandler__PurchaseUpperBoundSet(uint256)")) return (true, 0);
        if (sig == keccak256("FeeHandler__FeeCollectorAddressSet(address)")) return (true, 1);
        if (sig == keccak256("FeeHandler__FeeTransferred(address,address,uint256)")) return (true, 2);
        if (sig == keccak256("PurchaseUniswap_NewPathSet(address[],uint24[],bytes)")) return (true, 0);
        if (sig == keccak256("PurchaseUniswap_AmountOutMinimumPercentUpdated(uint256,uint256)")) return (true, 0);
        if (sig == keccak256("PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(uint256,uint256)")) return (true, 0);
        if (sig == keccak256("PurchaseUniswap_OracleUpdated(address,address)")) return (true, 2);
        if (sig == keccak256("IdleErc20Handler__AmountAdjusted(address,uint256,uint256)")) return (true, 1);
        if (sig == OWNERSHIP_TRANSFERRED) return (true, 2);
        if (sig == OWNERSHIP_TRANSFER_STARTED) return (true, 2);
        return (false, 0);
    }
}
