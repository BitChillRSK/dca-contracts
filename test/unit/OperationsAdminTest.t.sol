//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {OperationsAdmin} from "../../src/OperationsAdmin.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IDcaManagerAccessControl} from "../../src/interfaces/IDcaManagerAccessControl.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {IOperationsAdmin} from "../../src/interfaces/IOperationsAdmin.sol";
import "./TestsHelper.t.sol";

contract OperationsAdminTest is DcaDappTest {
    event OperationsAdmin__SwapperAdded(address indexed swapper);
    event OperationsAdmin__SwapperRevoked(address indexed swapper);
    event OperationsAdmin__RouteRegistered(uint256 indexed index, bool lends);

    uint256 private constant SECOND_IDLE_INDEX = 10;
    uint256 private constant SECOND_LENDING_INDEX = 11;

    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                         ADMIN OPERATIONS TESTS
    //////////////////////////////////////////////////////////////*/
    function testUpdateTokenHandlerMustSupportInterface() external {
        vm.startBroadcast();
        DummyERC165Contract dummyERC165Contract = new DummyERC165Contract();
        vm.stopBroadcast();

        vm.prank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);

        bytes memory encodedRevert = abi.encodeWithSelector(
            IOperationsAdmin.OperationsAdmin__ContractIsNotTokenHandler.selector, address(dummyERC165Contract)
        );

        vm.expectRevert(encodedRevert);
        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(
            address(stablecoin), SECOND_LENDING_INDEX, address(dummyERC165Contract)
        );

        vm.expectRevert();
        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(address(stablecoin), SECOND_LENDING_INDEX, address(dcaManager));
    }

    function testUpdateTokenHandlerFailsIfAddressIsEoa() external {
        address dummyAddress = makeAddr("dummyAddress");
        bytes memory encodedRevert =
            abi.encodeWithSelector(IOperationsAdmin.OperationsAdmin__EoaCannotBeHandler.selector, dummyAddress);
        vm.expectRevert(encodedRevert);
        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(address(stablecoin), s_lendingProtocolIndex, dummyAddress);
    }

    function testAssignTokenHandlerFailsIfRouteUnregistered() external {
        bytes memory encodedRevert =
            abi.encodeWithSelector(IOperationsAdmin.OperationsAdmin__RouteNotRegistered.selector, 3);
        vm.expectRevert(encodedRevert);
        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(address(stablecoin), 3, address(stablecoinHandler));
    }

    function testDuplicateHandlerAssignmentReverts() external {
        bytes memory encodedRevert = abi.encodeWithSelector(
            IOperationsAdmin.OperationsAdmin__HandlerAlreadyAssigned.selector,
            address(stablecoin),
            s_lendingProtocolIndex
        );
        vm.expectRevert(encodedRevert);
        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(address(stablecoin), s_lendingProtocolIndex, address(stablecoinHandler));
    }

    function testOnlyOwnerCanRegisterRoutesAndSwappers() external {
        vm.prank(ADMIN);
        vm.expectRevert("Ownable: caller is not the owner");
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);

        vm.prank(SWAPPER);
        vm.expectRevert("Ownable: caller is not the owner");
        operationsAdmin.addSwapper(address(2));

        vm.prank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        assertTrue(operationsAdmin.isLendingRoute(SECOND_LENDING_INDEX));
    }

    function testOwnerCannotRenounceOwnership() external {
        vm.expectRevert(IOperationsAdmin.OperationsAdmin__OwnershipCannotBeRenounced.selector);
        vm.prank(OWNER);
        operationsAdmin.renounceOwnership();

        vm.expectRevert(IOperationsAdmin.OperationsAdmin__OwnershipCannotBeRenounced.selector);
        vm.prank(USER);
        operationsAdmin.renounceOwnership();

        assertEq(operationsAdmin.owner(), OWNER);
    }

    function testConstructorEmitsIdleRouteRegistered() external {
        vm.expectEmit(true, true, true, true);
        emit OperationsAdmin__RouteRegistered(0, false);
        OperationsAdmin freshAdmin = new OperationsAdmin();
        assertEq(uint256(freshAdmin.getRouteClass(0)), uint256(IOperationsAdmin.RouteClass.Idle));
        assertFalse(freshAdmin.isLendingRoute(0));
    }

    function testAddAndRevokeSwapper() external {
        address extraSwapper = address(2);
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true);
        emit OperationsAdmin__SwapperAdded(extraSwapper);
        operationsAdmin.addSwapper(extraSwapper);
        assertTrue(operationsAdmin.isSwapper(SWAPPER));
        assertTrue(operationsAdmin.isSwapper(extraSwapper));

        vm.expectEmit(true, true, true, true);
        emit OperationsAdmin__SwapperRevoked(SWAPPER);
        vm.prank(OWNER);
        operationsAdmin.revokeSwapper(SWAPPER);
        assertFalse(operationsAdmin.isSwapper(SWAPPER));
        assertTrue(operationsAdmin.isSwapper(extraSwapper));
    }

    function testRevokeSwapperFailsIfNotOwner() external {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert("Ownable: caller is not the owner");
        operationsAdmin.revokeSwapper(SWAPPER);
    }

    function testRevokedSwapperCannotPurchase() external {
        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).scheduleId;
        vm.prank(OWNER);
        operationsAdmin.revokeSwapper(SWAPPER);

        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__UnauthorizedSwapper.selector, SWAPPER));
        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(stablecoin), 0, scheduleId);
    }

    function testReregisteringAnyIndexReverts() external {
        vm.startPrank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IOperationsAdmin.OperationsAdmin__RouteAlreadyRegistered.selector, 0)
        );
        operationsAdmin.registerRoute(0, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__RouteAlreadyRegistered.selector, s_lendingProtocolIndex
            )
        );
        operationsAdmin.registerRoute(s_lendingProtocolIndex, true);
        vm.stopPrank();
    }

    function testIsLendingRouteReadsRecordedClass() external {
        assertFalse(operationsAdmin.isLendingRoute(0));
        assertEq(
            uint256(operationsAdmin.getRouteClass(0)), uint256(IOperationsAdmin.RouteClass.Idle)
        );
        assertTrue(operationsAdmin.isLendingRoute(TROPYKUS_INDEX));
        assertTrue(operationsAdmin.isLendingRoute(SOVRYN_INDEX));
        assertFalse(operationsAdmin.isLendingRoute(999));
        assertEq(
            uint256(operationsAdmin.getRouteClass(999)), uint256(IOperationsAdmin.RouteClass.Unregistered)
        );
    }

    function testRegisterRouteEmitsAndClassifies() external {
        vm.expectEmit(true, true, true, true);
        emit OperationsAdmin__RouteRegistered(SECOND_LENDING_INDEX, true);
        vm.prank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        assertTrue(operationsAdmin.isLendingRoute(SECOND_LENDING_INDEX));

        vm.expectEmit(true, true, true, true);
        emit OperationsAdmin__RouteRegistered(SECOND_IDLE_INDEX, false);
        vm.prank(OWNER);
        operationsAdmin.registerRoute(SECOND_IDLE_INDEX, false);
        assertFalse(operationsAdmin.isLendingRoute(SECOND_IDLE_INDEX));
        assertEq(
            uint256(operationsAdmin.getRouteClass(SECOND_IDLE_INDEX)), uint256(IOperationsAdmin.RouteClass.Idle)
        );
    }

    function testMistakenClassificationRecoveredAtNewIndex() external {
        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, false);
        assertFalse(operationsAdmin.isLendingRoute(SECOND_LENDING_INDEX));

        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__RouteAlreadyRegistered.selector, SECOND_LENDING_INDEX
            )
        );
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);

        operationsAdmin.registerRoute(SECOND_LENDING_INDEX + 1, true);
        vm.stopPrank();
        assertTrue(operationsAdmin.isLendingRoute(SECOND_LENDING_INDEX + 1));
        assertFalse(operationsAdmin.isLendingRoute(SECOND_LENDING_INDEX));
    }

    function testMistakenHandlerAssignmentRecoveredAtNewIndex() external {
        address oldHandler = operationsAdmin.getTokenHandler(address(stablecoin), s_lendingProtocolIndex);
        DummyLendingHandler unusedHandler = new DummyLendingHandler();

        vm.startPrank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__HandlerAlreadyAssigned.selector,
                address(stablecoin),
                s_lendingProtocolIndex
            )
        );
        operationsAdmin.assignTokenHandler(address(stablecoin), s_lendingProtocolIndex, address(unusedHandler));

        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        operationsAdmin.assignTokenHandler(address(stablecoin), SECOND_LENDING_INDEX, address(unusedHandler));
        vm.stopPrank();

        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), s_lendingProtocolIndex), oldHandler);
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), SECOND_LENDING_INDEX), address(unusedHandler));
    }

    function testIdleHandlerAtNonZeroIndexLeavesOriginalIdleResolvable() external {
        DummyTokenHandler idleAtZero = new DummyTokenHandler();
        DummyTokenHandler idleAtTen = new DummyTokenHandler();

        vm.startPrank(OWNER);
        operationsAdmin.assignTokenHandler(address(stablecoin), IDLE_INDEX, address(idleAtZero));
        operationsAdmin.registerRoute(SECOND_IDLE_INDEX, false);
        operationsAdmin.assignTokenHandler(address(stablecoin), SECOND_IDLE_INDEX, address(idleAtTen));

        DummyTokenHandler extra = new DummyTokenHandler();
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__HandlerAlreadyAssigned.selector,
                address(stablecoin),
                SECOND_IDLE_INDEX
            )
        );
        operationsAdmin.assignTokenHandler(address(stablecoin), SECOND_IDLE_INDEX, address(extra));
        vm.stopPrank();

        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), IDLE_INDEX), address(idleAtZero));
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), SECOND_IDLE_INDEX), address(idleAtTen));
        assertFalse(operationsAdmin.isLendingRoute(IDLE_INDEX));
        assertFalse(operationsAdmin.isLendingRoute(SECOND_IDLE_INDEX));
    }

    function testOldRouteStillPaysUserAfterNewHandlerRegistered() external {
        address oldHandler = operationsAdmin.getTokenHandler(address(stablecoin), s_lendingProtocolIndex);
        DummyLendingHandler newHandler = new DummyLendingHandler();

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        vm.expectEmit(true, true, true, true);
        emit OperationsAdmin__TokenHandlerAssigned(
            address(stablecoin), SECOND_LENDING_INDEX, address(newHandler)
        );
        operationsAdmin.assignTokenHandler(address(stablecoin), SECOND_LENDING_INDEX, address(newHandler));
        vm.stopPrank();

        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), s_lendingProtocolIndex), oldHandler);
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), SECOND_LENDING_INDEX), address(newHandler));

        bytes32 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).scheduleId;
        uint256 remaining = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).tokenBalance;
        uint256 userBalanceBefore = stablecoin.balanceOf(USER);

        vm.prank(USER);
        dcaManager.withdrawToken(address(stablecoin), 0, scheduleId, remaining);

        assertGt(stablecoin.balanceOf(USER), userBalanceBefore);
        assertEq(dcaManager.getDcaSchedule(USER, address(stablecoin), 0).tokenBalance, 0);
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), s_lendingProtocolIndex), oldHandler);
    }

    function testOwnerCannotMoveAnotherUsersTokens() external {
        bytes32 userScheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).scheduleId;
        uint256 userRemaining = dcaManager.getDcaSchedule(USER, address(stablecoin), 0).tokenBalance;
        uint256 userWalletBefore = stablecoin.balanceOf(USER);

        deal(address(stablecoin), OWNER, AMOUNT_TO_DEPOSIT);
        vm.startPrank(OWNER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_lendingProtocolIndex
        );
        vm.stopPrank();

        bytes32 ownerScheduleId = dcaManager.getDcaSchedule(OWNER, address(stablecoin), 0).scheduleId;
        uint256 ownerRemaining = dcaManager.getDcaSchedule(OWNER, address(stablecoin), 0).tokenBalance;
        uint256 ownerWalletBefore = stablecoin.balanceOf(OWNER);

        vm.prank(OWNER);
        vm.expectRevert(IDcaManager.DcaManager__ScheduleIdAndIndexMismatch.selector);
        dcaManager.withdrawToken(address(stablecoin), 0, userScheduleId, userRemaining);

        vm.prank(OWNER);
        vm.expectRevert(IDcaManagerAccessControl.DcaManagerAccessControl__OnlyDcaManagerCanCall.selector);
        ITokenHandler(address(stablecoinHandler)).withdrawToken(USER, userRemaining);

        vm.prank(OWNER);
        dcaManager.withdrawToken(address(stablecoin), 0, ownerScheduleId, ownerRemaining);

        assertGt(stablecoin.balanceOf(OWNER), ownerWalletBefore);
        assertEq(dcaManager.getDcaSchedule(OWNER, address(stablecoin), 0).tokenBalance, 0);
        assertEq(dcaManager.getDcaSchedule(USER, address(stablecoin), 0).tokenBalance, userRemaining);
        assertEq(stablecoin.balanceOf(USER), userWalletBefore);

        DummyLendingHandler dummy = new DummyLendingHandler();
        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        operationsAdmin.assignTokenHandler(address(stablecoin), SECOND_LENDING_INDEX, address(dummy));
        operationsAdmin.addSwapper(address(0xBEEF));
        vm.stopPrank();

        assertEq(dcaManager.getDcaSchedule(USER, address(stablecoin), 0).tokenBalance, userRemaining);
        assertEq(stablecoin.balanceOf(USER), userWalletBefore);
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), s_lendingProtocolIndex), address(stablecoinHandler));
    }

    function testLendingHandlerRejectedAtIdleIndexZero() external {
        DummyLendingHandler lendingStub = new DummyLendingHandler();
        address otherToken = makeAddr("r31IdleZeroToken");
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__LendingHandlerOnIdleRoute.selector, address(lendingStub)
            )
        );
        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(otherToken, IDLE_INDEX, address(lendingStub));
    }

    function testLendingHandlerRejectedAtRegisteredIdleIndex() external {
        DummyLendingHandler lendingStub = new DummyLendingHandler();
        address otherToken = makeAddr("r31IdleIndexToken");
        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(SECOND_IDLE_INDEX, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__LendingHandlerOnIdleRoute.selector, address(lendingStub)
            )
        );
        operationsAdmin.assignTokenHandler(otherToken, SECOND_IDLE_INDEX, address(lendingStub));
        vm.stopPrank();
    }

    function testIdleHandlerRejectedAtLendingIndex() external {
        DummyTokenHandler idleStub = new DummyTokenHandler();
        address otherToken = makeAddr("r31LendingToken");
        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__ContractIsNotTokenLending.selector, address(idleStub)
            )
        );
        operationsAdmin.assignTokenHandler(otherToken, SECOND_LENDING_INDEX, address(idleStub));
        vm.stopPrank();
    }

    function testMatchingClassAssignmentsSucceed() external {
        DummyTokenHandler idleStub = new DummyTokenHandler();
        DummyLendingHandler lendingStub = new DummyLendingHandler();
        address otherToken = makeAddr("r31OtherToken");

        vm.startPrank(OWNER);
        operationsAdmin.assignTokenHandler(otherToken, IDLE_INDEX, address(idleStub));
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        operationsAdmin.assignTokenHandler(otherToken, SECOND_LENDING_INDEX, address(lendingStub));
        vm.stopPrank();

        assertEq(operationsAdmin.getTokenHandler(otherToken, IDLE_INDEX), address(idleStub));
        assertEq(operationsAdmin.getTokenHandler(otherToken, SECOND_LENDING_INDEX), address(lendingStub));
    }
}
