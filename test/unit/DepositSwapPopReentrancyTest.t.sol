// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {DcaManager} from "../../src/DcaManager.sol";
import {OperationsAdmin} from "../../src/OperationsAdmin.sol";
import {TropykusDocHandlerMoc} from "../../src/tropykus-legacy/TropykusDocHandlerMoc.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IPurchaseFees} from "../../src/interfaces/IPurchaseFees.sol";
import {MockReentrantStablecoin, ITransferHook} from "../mocks/MockReentrantStablecoin.sol";
import {MockKdocToken} from "../mocks/MockKdocToken.sol";
import {MockMocProxy} from "../mocks/MockMocProxy.sol";
import "../Constants.sol";
import {reentrantCall} from "../utils/OzRevert.sol";
import {scheduleCount} from "test/utils/ScheduleAt.sol";
import {toBatch} from "test/utils/BatchBuyOne.sol";

contract ReentrantDepositor is ITransferHook {
    DcaManager public dca;
    address public token;
    uint64 public deleteId;
    bool public attack;
    uint64 public buyId;
    bool public buy;

    constructor(DcaManager dca_, address token_) {
        dca = dca_;
        token = token_;
    }

    function armDelete(uint64 id) external {
        attack = true;
        deleteId = id;
    }

    /// @dev Buy `id` from inside the next hooked transfer. Only reaches the manager if this contract is a swapper.
    function armBuy(uint64 id) external {
        buy = true;
        buyId = id;
    }

    function onTransferFrom(address, address, uint256) external {
        _buyIfArmed();
        if (!attack) return;
        attack = false;
        dca.deleteDcaSchedule(token, deleteId, type(uint256).max);
    }

    function onTransferReceived(address, uint256) external {
        _buyIfArmed();
    }

    function createSchedule(uint256 depositAmount, uint256 purchaseAmount, uint256 period, uint256 lendingIndex)
        external
    {
        dca.createDcaSchedule(token, depositAmount, purchaseAmount, period, lendingIndex);
    }

    function remove(uint64 scheduleId) external {
        (uint64[] memory ids,) = dca.getDcaSchedules(address(this), token);
        uint256 index;
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == scheduleId) index = i;
        }
        dca.deleteDcaSchedule(token, scheduleId, index);
    }

    function withdraw(uint64 scheduleId, uint256 amount) external {
        dca.withdrawToken(token, scheduleId, amount);
    }

    function deposit(uint64 scheduleId, uint256 amount) external {
        dca.depositToken(token, scheduleId, amount);
    }

    function _buyIfArmed() private {
        if (!buy) return;
        buy = false;
        uint64[] memory ids = new uint64[](1);
        ids[0] = buyId;
        dca.batchBuyRbtc(toBatch(ids, token, TROPYKUS_INDEX));
    }
}

/// @notice Swap-pop coverage: hook deletes the *same* scheduleIndex being deposited into.
contract DepositSwapPopReentrancyTest is Test {
    address internal constant OWNER = address(0x1111);
    address internal constant ADMIN = address(0x2222);
    address internal constant FEE_COLLECTOR = address(0x5555);

    DcaManager internal dcaManager;
    OperationsAdmin internal operationsAdmin;
    MockReentrantStablecoin internal token;
    MockKdocToken internal kToken;
    TropykusDocHandlerMoc internal handler;
    MockMocProxy internal mocProxy;
    ReentrantDepositor internal user;

    uint256 internal constant DEPOSIT = 100 ether;
    uint256 internal constant EXTRA = 25 ether;

    function setUp() public {
        vm.prank(OWNER);
        operationsAdmin = new OperationsAdmin(OWNER);

        vm.prank(OWNER);
        dcaManager = new DcaManager(address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, OWNER);

        token = new MockReentrantStablecoin();
        vm.prank(OWNER);
        dcaManager.setTokenMinPurchaseAmount(address(token), MIN_PURCHASE_AMOUNT);
        kToken = new MockKdocToken(address(token));
        mocProxy = new MockMocProxy(address(token));
        vm.deal(address(mocProxy), 100 ether);

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(TROPYKUS_INDEX, true);
        vm.stopPrank();

        handler = new TropykusDocHandlerMoc(
            address(dcaManager),
            address(token),
            address(kToken),
            FEE_COLLECTOR,
            address(mocProxy),
            IPurchaseFees.FeeSettings({
                minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE_TEST, feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND
            }),
            OWNER
        );

        vm.prank(OWNER);
        operationsAdmin.assignHandler(address(token), TROPYKUS_INDEX, address(handler));

        user = new ReentrantDepositor(dcaManager, address(token));
        token.mint(address(user), 10_000 ether);
        vm.prank(address(user));
        token.approve(address(handler), type(uint256).max);
    }

    function test_depositToken_reverts_whenHookDeletesSameIndex() public {
        _createTwoSchedules();
        (uint64[] memory beforeSchedulesIds, IDcaManager.DcaSchedule[] memory beforeSchedules) =
            dcaManager.getDcaSchedules(address(user), address(token));
        uint64 idA = beforeSchedulesIds[0];

        user.armDelete(idA);
        token.setHook(address(user), true);

        vm.expectRevert(reentrantCall());
        user.deposit(idA, EXTRA);

        (uint64[] memory afterSchedulesIds, IDcaManager.DcaSchedule[] memory afterSchedules) =
            dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(afterSchedules.length, 2);
        assertEq(afterSchedulesIds[0], beforeSchedulesIds[0]);
        assertEq(afterSchedulesIds[1], beforeSchedulesIds[1]);
        assertEq(afterSchedules[0].tokenBalance, beforeSchedules[0].tokenBalance);
        assertEq(afterSchedules[1].tokenBalance, beforeSchedules[1].tokenBalance);
    }

    function test_depositToken_reverts_whenHookDeletesLastRemainingSchedule() public {
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        (uint64[] memory beforeSchedulesIds, IDcaManager.DcaSchedule[] memory beforeSchedules) =
            dcaManager.getDcaSchedules(address(user), address(token));
        uint64 idA = beforeSchedulesIds[0];

        user.armDelete(idA);
        token.setHook(address(user), true);

        vm.expectRevert(reentrantCall());
        user.deposit(idA, EXTRA);

        (uint64[] memory afterSchedulesIds, IDcaManager.DcaSchedule[] memory afterSchedules) =
            dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(afterSchedules.length, 1);
        assertEq(afterSchedulesIds[0], idA);
        assertEq(afterSchedules[0].tokenBalance, beforeSchedules[0].tokenBalance);
    }

    /**
     * @dev A purchase is not `nonReentrant`, so a pull that calls back into an allowlisted swapper can buy
     *      the schedule being funded. The deposit credit is stored and logged before the pull, so that
     *      purchase debits the new balance and logs after it. Storing after the pull overwrote the debit;
     *      logging after it left a stale balance as the schedule's last event.
     */
    function test_depositToken_purchaseFromPullCallback_keepsItsDebit() public {
        uint64 idA = _createScheduleAndArmBuy();

        vm.recordLogs();
        user.deposit(idA, EXTRA);

        assertFalse(user.buy(), "the pull did not call back");
        uint256 stored = _tokenBalance();
        assertEq(stored, DEPOSIT + EXTRA - MIN_PURCHASE_AMOUNT, "the purchase debit was lost");
        assertGt(handler.getAccumulatedRbtcBalance(address(user)), 0, "the callback purchase was not credited");
        _assertBalanceEvents(idA, DEPOSIT + EXTRA, stored);
    }

    /// @dev Same callback during the withdrawal payout: the debit is logged before the handler call, so the
    ///      purchase's balance event is the last one.
    function test_withdrawToken_purchaseFromPayoutCallback_logsTheStoredBalanceLast() public {
        uint64 idA = _createScheduleAndArmBuy();

        vm.recordLogs();
        user.withdraw(idA, EXTRA);

        assertFalse(user.buy(), "the payout did not call back");
        uint256 stored = _tokenBalance();
        assertEq(stored, DEPOSIT - EXTRA - MIN_PURCHASE_AMOUNT, "the purchase debit was lost");
        _assertBalanceEvents(idA, DEPOSIT - EXTRA, stored);
    }

    /// @dev create,create,delete,create in one block used to remint the survivor's id.
    function test_createDeleteCreate_mintsUniqueScheduleIds() public {
        (uint64 idB, uint64 idC) = _createDeleteCreateSequence();
        assertTrue(idB != idC);
        (uint64[] memory schedulesIds, IDcaManager.DcaSchedule[] memory schedules) =
            dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(schedules.length, 2);
        assertTrue(schedulesIds[0] != schedulesIds[1]);
    }

    /// @dev Regression: deriving ids from array state let swap-pop rewind the chain.
    /// create A,B,C then delete index 0 moves C into slot 0 and makes B last again,
    /// so a chained derivation reproduced idC while C was still live.
    function test_swapPopRewind_doesNotRemintLiveScheduleId() public {
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX); // A
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX); // B
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX); // C
        (uint64[] memory createdIds, IDcaManager.DcaSchedule[] memory created) =
            dcaManager.getDcaSchedules(address(user), address(token));
        uint64 idA = createdIds[0];
        uint64 idC = createdIds[2];

        user.remove(idA); // C swap-pops into slot 0; B becomes the last element again
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX); // D

        (uint64[] memory liveIds, IDcaManager.DcaSchedule[] memory live) =
            dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(live.length, 3);
        assertEq(liveIds[0], idC); // C is still live in slot 0
        assertTrue(liveIds[2] != idC); // D must not reuse it
        for (uint256 i; i < live.length; ++i) {
            for (uint256 j = i + 1; j < live.length; ++j) {
                assertTrue(liveIds[i] != liveIds[j]);
            }
        }
    }

    function test_depositToken_reverts_whenHookDeletesReusedSlot() public {
        (uint64 idB,) = _createDeleteCreateSequence();
        (uint64[] memory beforeSchedulesIds, IDcaManager.DcaSchedule[] memory beforeSchedules) =
            dcaManager.getDcaSchedules(address(user), address(token));

        user.armDelete(idB);
        token.setHook(address(user), true);

        // The deposit/delete mutex stops the nested delete before any swap-pop can happen.
        vm.expectRevert(reentrantCall());
        user.deposit(idB, EXTRA);

        (uint64[] memory afterSchedulesIds, IDcaManager.DcaSchedule[] memory afterSchedules) =
            dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(afterSchedules.length, 2);
        assertEq(afterSchedulesIds[0], beforeSchedulesIds[0]);
        assertEq(afterSchedulesIds[1], beforeSchedulesIds[1]);
        assertEq(afterSchedules[0].tokenBalance, beforeSchedules[0].tokenBalance);
        assertEq(afterSchedules[1].tokenBalance, beforeSchedules[1].tokenBalance);
    }

    /// @dev One schedule owned by `user`, which is made a swapper and set to buy it from the next hooked transfer.
    function _createScheduleAndArmBuy() private returns (uint64 id) {
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        (uint64[] memory ids,) = dcaManager.getDcaSchedules(address(user), address(token));
        id = ids[0];

        vm.prank(OWNER);
        operationsAdmin.addSwapper(address(user));
        // Live MoC burns DOC without an allowance; the mock pulls it.
        vm.prank(address(handler));
        token.approve(address(mocProxy), type(uint256).max);
        user.armBuy(id);
        token.setHook(address(user), true);
    }

    function _tokenBalance() private view returns (uint256) {
        (, IDcaManager.DcaSchedule[] memory schedules) = dcaManager.getDcaSchedules(address(user), address(token));
        return schedules[0].tokenBalance;
    }

    /// @dev The schedule's recorded `TokenBalanceUpdated` amounts are the user call's, then the purchase's.
    function _assertBalanceEvents(uint64 scheduleId, uint256 userCallBalance, uint256 storedBalance) private {
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        uint256[] memory amounts = new uint256[](logs.length);
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(dcaManager)
                    && logs[i].topics[0] == IDcaManager.DcaManager__TokenBalanceUpdated.selector
                    && logs[i].topics[2] == bytes32(uint256(scheduleId))
            ) {
                amounts[count++] = abi.decode(logs[i].data, (uint256));
            }
        }
        assertEq(count, 2, "expected the user call's and the purchase's balance events");
        assertEq(amounts[0], userCallBalance, "the user call must log its balance first");
        assertEq(amounts[1], storedBalance, "the last balance event must be the stored balance");
    }

    function _createTwoSchedules() private {
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        vm.warp(block.timestamp + 1);
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        assertEq(scheduleCount(dcaManager, address(user), address(token)), 2);
    }

    /// @dev Create A,B then delete A and create C in the same timestamp.
    function _createDeleteCreateSequence() private returns (uint64 idB, uint64 idC) {
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        (uint64[] memory createdIds, IDcaManager.DcaSchedule[] memory created) =
            dcaManager.getDcaSchedules(address(user), address(token));
        uint64 idA = createdIds[0];
        idB = createdIds[1];
        assertTrue(idA != idB);

        user.remove(idA);
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        (uint64[] memory afterCreateIds, IDcaManager.DcaSchedule[] memory afterCreate) =
            dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(afterCreate.length, 2);
        assertEq(afterCreateIds[0], idB);
        idC = afterCreateIds[1];
    }
}
