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
import "../../script/Constants.sol";
import {reentrantCall} from "../utils/OzRevert.sol";

contract ReentrantDepositor is ITransferFromHook {
    DcaManager public dca;
    address public token;
    uint256 public deleteIndex;
    bytes32 public deleteId;
    bool public attack;

    constructor(DcaManager dca_, address token_) {
        dca = dca_;
        token = token_;
    }

    function armDelete(uint256 index, bytes32 id) external {
        attack = true;
        deleteIndex = index;
        deleteId = id;
    }

    function onTransferFrom(address, address, uint256) external {
        if (!attack) return;
        attack = false;
        dca.deleteDcaSchedule(token, deleteIndex, deleteId);
    }

    function createSchedule(uint256 depositAmount, uint256 purchaseAmount, uint256 period, uint256 lendingIndex)
        external
    {
        dca.createDcaSchedule(token, depositAmount, purchaseAmount, period, lendingIndex);
    }

    function remove(uint256 scheduleIndex, bytes32 scheduleId) external {
        dca.deleteDcaSchedule(token, scheduleIndex, scheduleId);
    }

    function deposit(uint256 scheduleIndex, bytes32 scheduleId, uint256 amount) external {
        dca.depositToken(token, scheduleIndex, scheduleId, amount);
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
        IDcaManager.DcaDetails[] memory beforeSchedules = dcaManager.getDcaSchedules(address(user), address(token));
        bytes32 idA = beforeSchedules[0].scheduleId;

        user.armDelete(0, idA);
        token.setHook(address(user), true);

        vm.expectRevert(reentrantCall());
        user.deposit(0, idA, EXTRA);

        IDcaManager.DcaDetails[] memory afterSchedules = dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(afterSchedules.length, 2);
        assertEq(afterSchedules[0].scheduleId, beforeSchedules[0].scheduleId);
        assertEq(afterSchedules[1].scheduleId, beforeSchedules[1].scheduleId);
        assertEq(afterSchedules[0].tokenBalance, beforeSchedules[0].tokenBalance);
        assertEq(afterSchedules[1].tokenBalance, beforeSchedules[1].tokenBalance);
    }

    function test_depositToken_reverts_whenHookDeletesLastRemainingSchedule() public {
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        IDcaManager.DcaDetails[] memory beforeSchedules = dcaManager.getDcaSchedules(address(user), address(token));
        bytes32 idA = beforeSchedules[0].scheduleId;

        user.armDelete(0, idA);
        token.setHook(address(user), true);

        vm.expectRevert(reentrantCall());
        user.deposit(0, idA, EXTRA);

        IDcaManager.DcaDetails[] memory afterSchedules = dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(afterSchedules.length, 1);
        assertEq(afterSchedules[0].scheduleId, idA);
        assertEq(afterSchedules[0].tokenBalance, beforeSchedules[0].tokenBalance);
    }

    /// @dev create,create,delete,create in one block used to remint the survivor's id.
    function test_createDeleteCreate_mintsUniqueScheduleIds() public {
        (bytes32 idB, bytes32 idC) = _createDeleteCreateSequence();
        assertTrue(idB != idC);
        IDcaManager.DcaDetails[] memory schedules = dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(schedules.length, 2);
        assertTrue(schedules[0].scheduleId != schedules[1].scheduleId);
    }

    /// @dev Regression: deriving ids from array state let swap-pop rewind the chain.
    /// create A,B,C then delete index 0 moves C into slot 0 and makes B last again,
    /// so a chained derivation reproduced idC while C was still live.
    function test_swapPopRewind_doesNotRemintLiveScheduleId() public {
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX); // A
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX); // B
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX); // C
        IDcaManager.DcaDetails[] memory created = dcaManager.getDcaSchedules(address(user), address(token));
        bytes32 idA = created[0].scheduleId;
        bytes32 idC = created[2].scheduleId;

        user.remove(0, idA); // C swap-pops into slot 0; B becomes the last element again
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX); // D

        IDcaManager.DcaDetails[] memory live = dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(live.length, 3);
        assertEq(live[0].scheduleId, idC); // C is still live in slot 0
        assertTrue(live[2].scheduleId != idC); // D must not reuse it
        for (uint256 i; i < live.length; ++i) {
            for (uint256 j = i + 1; j < live.length; ++j) {
                assertTrue(live[i].scheduleId != live[j].scheduleId);
            }
        }
    }

    function test_depositToken_reverts_whenHookDeletesReusedSlot() public {
        (bytes32 idB,) = _createDeleteCreateSequence();
        IDcaManager.DcaDetails[] memory beforeSchedules = dcaManager.getDcaSchedules(address(user), address(token));

        user.armDelete(0, idB);
        token.setHook(address(user), true);

        // The deposit/delete mutex stops the nested delete before any swap-pop can happen.
        vm.expectRevert(reentrantCall());
        user.deposit(0, idB, EXTRA);

        IDcaManager.DcaDetails[] memory afterSchedules = dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(afterSchedules.length, 2);
        assertEq(afterSchedules[0].scheduleId, beforeSchedules[0].scheduleId);
        assertEq(afterSchedules[1].scheduleId, beforeSchedules[1].scheduleId);
        assertEq(afterSchedules[0].tokenBalance, beforeSchedules[0].tokenBalance);
        assertEq(afterSchedules[1].tokenBalance, beforeSchedules[1].tokenBalance);
    }

    function _createTwoSchedules() private {
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        vm.warp(block.timestamp + 1);
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        assertEq(dcaManager.getDcaSchedules(address(user), address(token)).length, 2);
    }

    /// @dev Create A,B then delete A and create C in the same timestamp.
    function _createDeleteCreateSequence() private returns (bytes32 idB, bytes32 idC) {
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        IDcaManager.DcaDetails[] memory created = dcaManager.getDcaSchedules(address(user), address(token));
        bytes32 idA = created[0].scheduleId;
        idB = created[1].scheduleId;
        assertTrue(idA != idB);

        user.remove(0, idA);
        user.createSchedule(DEPOSIT, MIN_PURCHASE_AMOUNT, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);
        IDcaManager.DcaDetails[] memory afterCreate = dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(afterCreate.length, 2);
        assertEq(afterCreate[0].scheduleId, idB);
        idC = afterCreate[1].scheduleId;
    }
}
