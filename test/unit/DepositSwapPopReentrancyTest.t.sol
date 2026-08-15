// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DcaManager} from "../../src/DcaManager.sol";
import {OperationsAdmin} from "../../src/OperationsAdmin.sol";
import {TropykusDocHandlerMoc} from "../../src/TropykusDocHandlerMoc.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IFeeHandler} from "../../src/interfaces/IFeeHandler.sol";
import {MockReentrantStablecoin, ITransferFromHook} from "../mocks/MockReentrantStablecoin.sol";
import {MockKdocToken} from "../mocks/MockKdocToken.sol";
import {MockMocProxy} from "../mocks/MockMocProxy.sol";
import "../../script/Constants.sol";

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

    function deposit(uint256 scheduleIndex, bytes32 scheduleId, uint256 amount) external {
        dca.depositToken(token, scheduleIndex, scheduleId, amount);
    }

    function update(uint256 scheduleIndex, bytes32 scheduleId, uint256 depositAmount) external {
        dca.updateDcaSchedule(token, scheduleIndex, scheduleId, depositAmount, 0, 0);
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
        operationsAdmin = new OperationsAdmin();

        vm.prank(OWNER);
        dcaManager = new DcaManager(
            address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT
        );

        token = new MockReentrantStablecoin();
        kToken = new MockKdocToken(address(token));
        MockMocProxy mocProxy = new MockMocProxy(address(token));

        vm.prank(OWNER);
        operationsAdmin.setAdminRole(ADMIN);
        vm.prank(ADMIN);
        operationsAdmin.addOrUpdateLendingProtocol("Tropykus", TROPYKUS_INDEX);

        handler = new TropykusDocHandlerMoc(
            address(dcaManager),
            address(token),
            address(kToken),
            MIN_PURCHASE_AMOUNT,
            FEE_COLLECTOR,
            address(mocProxy),
            IFeeHandler.FeeSettings({
                minFeeRate: MIN_FEE_RATE,
                maxFeeRate: MAX_FEE_RATE_TEST,
                feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
                feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
            }),
            EXCHANGE_RATE_DECIMALS
        );

        vm.prank(ADMIN);
        operationsAdmin.assignOrUpdateTokenHandler(address(token), TROPYKUS_INDEX, address(handler));

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

        vm.expectRevert(IDcaManager.DcaManager__ScheduleIdAndIndexMismatch.selector);
        user.deposit(0, idA, EXTRA);

        IDcaManager.DcaDetails[] memory afterSchedules = dcaManager.getDcaSchedules(address(user), address(token));
        assertEq(afterSchedules.length, 2);
        assertEq(afterSchedules[0].scheduleId, beforeSchedules[0].scheduleId);
        assertEq(afterSchedules[1].scheduleId, beforeSchedules[1].scheduleId);
        assertEq(afterSchedules[0].tokenBalance, beforeSchedules[0].tokenBalance);
        assertEq(afterSchedules[1].tokenBalance, beforeSchedules[1].tokenBalance);
    }

    function test_updateDcaSchedule_reverts_whenHookDeletesSameIndex() public {
        _createTwoSchedules();
        IDcaManager.DcaDetails[] memory beforeSchedules = dcaManager.getDcaSchedules(address(user), address(token));
        bytes32 idA = beforeSchedules[0].scheduleId;

        user.armDelete(0, idA);
        token.setHook(address(user), true);

        vm.expectRevert(IDcaManager.DcaManager__ScheduleIdAndIndexMismatch.selector);
        user.update(0, idA, EXTRA);

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
}
