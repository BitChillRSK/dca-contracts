// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DcaManager} from "src/DcaManager.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {IdleDocHandlerMoc} from "src/idle/IdleDocHandlerMoc.sol";
import {TropykusDocHandlerMoc} from "src/tropykus-legacy/TropykusDocHandlerMoc.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import {MockKdocToken} from "test/mocks/MockKdocToken.sol";
import "script/Constants.sol";

/**
 * @title IdleDcaManagerTest
 * @notice DcaManager paths against an idle handler assigned at index 0 with no protocol name.
 */
contract IdleDcaManagerTest is Test {
    uint256 internal constant IDLE_INDEX = 0;

    address internal constant OWNER = address(0x1111);
    address internal constant ADMIN = address(0x2222);
    address internal constant SWAPPER = address(0x3333);
    address internal constant USER = address(0x4444);
    address internal constant FEE_COLLECTOR = address(0x5555);

    DcaManager internal dcaManager;
    OperationsAdmin internal operationsAdmin;
    MockStablecoin internal docToken;
    MockMocProxy internal mocProxy;
    IdleDocHandlerMoc internal handler;

    uint256 internal constant DEPOSIT = 200 ether;
    uint256 internal constant PURCHASE = 50 ether;

    function setUp() public {
        vm.prank(OWNER);
        operationsAdmin = new OperationsAdmin();

        vm.prank(OWNER);
        dcaManager = new DcaManager(
            address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT
        );

        docToken = new MockStablecoin(address(this));
        mocProxy = new MockMocProxy(address(docToken));
        vm.deal(address(mocProxy), 100 ether);

        vm.prank(OWNER);
        operationsAdmin.setAdminRole(ADMIN);
        vm.prank(ADMIN);
        operationsAdmin.setSwapperRole(SWAPPER);

        handler = new IdleDocHandlerMoc(
            address(dcaManager),
            address(docToken),
            FEE_COLLECTOR,
            address(mocProxy),
            IFeeHandler.FeeSettings({
                minFeeRate: MIN_FEE_RATE,
                maxFeeRate: MAX_FEE_RATE_TEST,
                feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
                feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
            })
        );

        vm.prank(ADMIN);
        operationsAdmin.assignOrUpdateTokenHandler(address(docToken), IDLE_INDEX, address(handler));

        vm.prank(address(handler));
        docToken.approve(address(mocProxy), type(uint256).max);

        docToken.mint(USER, 10_000 ether);
        vm.prank(USER);
        docToken.approve(address(handler), type(uint256).max);
    }

    function test_createDcaSchedule_atIndexZero_depositsIdleDoc() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, IDLE_INDEX);

        IDcaManager.DcaDetails memory schedule = dcaManager.getDcaSchedules(USER, address(docToken))[0];
        assertEq(schedule.lendingProtocolIndex, IDLE_INDEX);
        assertEq(schedule.tokenBalance, DEPOSIT);
        assertEq(handler.getUsersIdleTokenBalance(USER), DEPOSIT);
        assertEq(docToken.balanceOf(address(handler)), DEPOSIT);
        assertEq(bytes(operationsAdmin.getLendingProtocolName(IDLE_INDEX)).length, 0);
    }

    function test_buyAndWithdraw_spendIdleDoc() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, IDLE_INDEX);
        bytes32 scheduleId = dcaManager.getScheduleId(USER, address(docToken), 0);

        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(docToken), 0, scheduleId);

        assertGt(dcaManager.getAccumulatedRbtcBalance(USER, address(docToken), IDLE_INDEX), 0);
        assertEq(handler.getUsersIdleTokenBalance(USER), DEPOSIT - PURCHASE);
        assertEq(dcaManager.getScheduleTokenBalance(USER, address(docToken), 0), DEPOSIT - PURCHASE);

        uint256 userDocBefore = docToken.balanceOf(USER);
        vm.prank(USER);
        dcaManager.withdrawToken(address(docToken), 0, scheduleId, DEPOSIT - PURCHASE);

        assertEq(docToken.balanceOf(USER), userDocBefore + DEPOSIT - PURCHASE);
        assertEq(handler.getUsersIdleTokenBalance(USER), 0);
        assertEq(dcaManager.getScheduleTokenBalance(USER, address(docToken), 0), 0);

        uint256 userRbtcBefore = USER.balance;
        vm.prank(USER);
        dcaManager.withdrawRbtcFromTokenHandler(address(docToken), IDLE_INDEX);
        assertGt(USER.balance, userRbtcBefore);
        assertEq(dcaManager.getAccumulatedRbtcBalance(USER, address(docToken), IDLE_INDEX), 0);
    }

    function test_interestCalls_atIndexZero_revert() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, IDLE_INDEX);
        bytes32 scheduleId = dcaManager.getScheduleId(USER, address(docToken), 0);

        bytes memory encodedRevert =
            abi.encodeWithSelector(IDcaManager.DcaManager__TokenDoesNotYieldInterest.selector, address(docToken));

        vm.expectRevert(encodedRevert);
        dcaManager.getInterestAccrued(USER, address(docToken), IDLE_INDEX);

        vm.prank(USER);
        vm.expectRevert(encodedRevert);
        dcaManager.getMyInterestAccrued(address(docToken), IDLE_INDEX);

        address[] memory tokens = new address[](1);
        tokens[0] = address(docToken);
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = IDLE_INDEX;
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, indexes);

        vm.prank(USER);
        vm.expectRevert(encodedRevert);
        dcaManager.withdrawTokenAndInterest(address(docToken), 0, scheduleId, MIN_PURCHASE_AMOUNT, IDLE_INDEX);
    }

    function test_withdrawAllAccumulatedInterest_skipsIdleAndWithdrawsLending() public {
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, IDLE_INDEX);

        vm.prank(ADMIN);
        operationsAdmin.addOrUpdateLendingProtocol(TROPYKUS_STRING, TROPYKUS_INDEX);

        MockKdocToken kDoc = new MockKdocToken(address(docToken));
        docToken.mint(address(kDoc), 100_000 ether);
        TropykusDocHandlerMoc tropykusHandler = new TropykusDocHandlerMoc(
            address(dcaManager),
            address(docToken),
            address(kDoc),
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
        operationsAdmin.assignOrUpdateTokenHandler(address(docToken), TROPYKUS_INDEX, address(tropykusHandler));
        vm.prank(USER);
        docToken.approve(address(tropykusHandler), type(uint256).max);
        vm.prank(USER);
        dcaManager.createDcaSchedule(address(docToken), DEPOSIT, PURCHASE, MIN_PURCHASE_PERIOD, TROPYKUS_INDEX);

        address[] memory tokens = new address[](1);
        tokens[0] = address(docToken);
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = IDLE_INDEX;
        indexes[1] = TROPYKUS_INDEX;
        vm.prank(USER);
        dcaManager.withdrawAllAccumulatedInterest(tokens, indexes);
    }
}
