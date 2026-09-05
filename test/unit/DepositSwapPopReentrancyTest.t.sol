// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DcaManager} from "../../src/DcaManager.sol";
import {OperationsAdmin} from "../../src/OperationsAdmin.sol";
import {TropykusDocHandlerMoc} from "../../src/tropykus-legacy/TropykusDocHandlerMoc.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IFeeHandler} from "../../src/interfaces/IFeeHandler.sol";
import {MockReentrantStablecoin, ITransferFromHook} from "../mocks/MockReentrantStablecoin.sol";
import {MockKdocToken} from "../mocks/MockKdocToken.sol";
import {MockMocProxy} from "../mocks/MockMocProxy.sol";
import "../Constants.sol";
import {reentrantCall} from "../utils/OzRevert.sol";
import {scheduleCount} from "test/utils/ScheduleAt.sol";

contract ReentrantDepositor is ITransferFromHook {
    DcaManager public dca;
    address public token;
    uint64 public deleteId;
    bool public attack;

    constructor(DcaManager dca_, address token_) {
        dca = dca_;
        token = token_;
    }

    function armDelete(uint64 id) external {
        attack = true;
        deleteId = id;
    }

    function onTransferFrom(address, address, uint256) external {
        if (!attack) return;
        attack = false;
        dca.deleteDcaSchedule(token, deleteId);
    }

    function createSchedule(uint256 depositAmount, uint256 purchaseAmount, uint256 period, uint256 lendingIndex)
        external
    {
        dca.createDcaSchedule(token, depositAmount, purchaseAmount, period, lendingIndex);
    }

    function remove(uint64 scheduleId) external {
        dca.deleteDcaSchedule(token, scheduleId);
    }

    function deposit(uint64 scheduleId, uint256 amount) external {
        dca.depositToken(token, scheduleId, amount);
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
    ReentrantDepositor internal user;

    uint256 internal constant DEPOSIT = 100 ether;
    uint256 internal constant EXTRA = 25 ether;

    function setUp() public {
        vm.prank(OWNER);
        operationsAdmin = new OperationsAdmin(OWNER);

        vm.prank(OWNER);
        dcaManager = new DcaManager(
            address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, OWNER
        );

        token = new MockReentrantStablecoin();
        kToken = new MockKdocToken(address(token));
        MockMocProxy mocProxy = new MockMocProxy(address(token));

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(TROPYKUS_INDEX, true);
        vm.stopPrank();

        handler = new TropykusDocHandlerMoc(
            address(dcaManager),
            address(token),
            address(kToken),
            FEE_COLLECTOR,
            address(mocProxy),
            IFeeHandler.FeeSettings({
                minFeeRate: MIN_FEE_RATE,
                maxFeeRate: MAX_FEE_RATE_TEST,
                feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
                feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
            }),
            OWNER
        );

        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(address(token), TROPYKUS_INDEX, address(handler));

        user = new ReentrantDepositor(dcaManager, address(token));
        token.mint(address(user), 10_000 ether);
        vm.prank(address(user));
        token.approve(address(handler), type(uint256).max);
    }

    function test_depositToken_reverts_whenHookDeletesSameIndex() public {
        _createTwoSchedules();
        (uint64[] memory beforeSchedulesIds, IDcaManager.DcaSchedule[] memory beforeSchedules) = dcaManager.getDcaSchedules(address(user), address(token));
        uint64 idA = beforeSchedulesIds[0];

        user.armDelete(idA);
        token.setHook(address(user), true);

        vm.expectRevert(reentrantCall());
        user.deposit(idA, EXTRA);

        (uint64[] memory afterSchedulesIds, IDcaManager.DcaSchedule[] memory afterSchedules) = dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(afterSchedules.length, 2);
        assertEq(afterSchedulesIds[0], beforeSchedulesIds[0]);
        assertEq(afterSchedulesIds[1], beforeSchedulesIds[1]);
        assertEq(afterSchedules[0].tokenBalance, beforeSchedules[0].tokenBalance);
        assertEq(afterSchedules[1].tokenBalance, beforeSchedules[1].tokenBalance);
    }

    function test_depositToken_reverts_whenHookDeletesLastRemainingSchedule() public {
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        (uint64[] memory beforeSchedulesIds, IDcaManager.DcaSchedule[] memory beforeSchedules) = dcaManager.getDcaSchedules(address(user), address(token));
        uint64 idA = beforeSchedulesIds[0];

        user.armDelete(idA);
        token.setHook(address(user), true);

        vm.expectRevert(reentrantCall());
        user.deposit(idA, EXTRA);

        (uint64[] memory afterSchedulesIds, IDcaManager.DcaSchedule[] memory afterSchedules) = dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(afterSchedules.length, 1);
        assertEq(afterSchedulesIds[0], idA);
        assertEq(afterSchedules[0].tokenBalance, beforeSchedules[0].tokenBalance);
    }

    /// @dev create,create,delete,create in one block used to remint the survivor's id.
    function test_createDeleteCreate_mintsUniqueScheduleIds() public {
        (uint64 idB, uint64 idC) = _createDeleteCreateSequence();
        assertTrue(idB != idC);
        (uint64[] memory schedulesIds, IDcaManager.DcaSchedule[] memory schedules) = dcaManager.getDcaSchedules(address(user), address(token));
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
        (uint64[] memory createdIds, IDcaManager.DcaSchedule[] memory created) = dcaManager.getDcaSchedules(address(user), address(token));
        uint64 idA = createdIds[0];
        uint64 idC = createdIds[2];

        user.remove(idA); // C swap-pops into slot 0; B becomes the last element again
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX); // D

        (uint64[] memory liveIds, IDcaManager.DcaSchedule[] memory live) = dcaManager.getDcaSchedules(address(user), address(token));
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
        (uint64[] memory beforeSchedulesIds, IDcaManager.DcaSchedule[] memory beforeSchedules) = dcaManager.getDcaSchedules(address(user), address(token));

        user.armDelete(idB);
        token.setHook(address(user), true);

        // The deposit/delete mutex stops the nested delete before any swap-pop can happen.
        vm.expectRevert(reentrantCall());
        user.deposit(idB, EXTRA);

        (uint64[] memory afterSchedulesIds, IDcaManager.DcaSchedule[] memory afterSchedules) = dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(afterSchedules.length, 2);
        assertEq(afterSchedulesIds[0], beforeSchedulesIds[0]);
        assertEq(afterSchedulesIds[1], beforeSchedulesIds[1]);
        assertEq(afterSchedules[0].tokenBalance, beforeSchedules[0].tokenBalance);
        assertEq(afterSchedules[1].tokenBalance, beforeSchedules[1].tokenBalance);
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
        (uint64[] memory createdIds, IDcaManager.DcaSchedule[] memory created) = dcaManager.getDcaSchedules(address(user), address(token));
        uint64 idA = createdIds[0];
        idB = createdIds[1];
        assertTrue(idA != idB);

        user.remove(idA);
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        (uint64[] memory afterCreateIds, IDcaManager.DcaSchedule[] memory afterCreate) = dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(afterCreate.length, 2);
        assertEq(afterCreateIds[0], idB);
        idC = afterCreateIds[1];
    }
}
