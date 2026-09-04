//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {OperationsAdmin} from "../../src/OperationsAdmin.sol";
import {BitChillOwnable} from "../../src/BitChillOwnable.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IDcaManagerAccessControl} from "../../src/interfaces/IDcaManagerAccessControl.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {IOperationsAdmin} from "../../src/interfaces/IOperationsAdmin.sol";
import "./TestsHelper.t.sol";
import {ownableUnauthorized} from "../utils/OzRevert.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {scheduleAt, scheduleIdAt} from "test/utils/ScheduleAt.sol";

contract OperationsAdminTest is DcaDappTest {
    event OperationsAdmin__SwapperAdded(address indexed swapper);
    event OperationsAdmin__SwapperRevoked(address indexed swapper);
    event OperationsAdmin__RouteRegistered(uint256 index, bool lends);
    event OperationsAdmin__DepositsPauseSet(address indexed token, uint256 routeIndex, bool paused);

    uint256 private constant TOKEN_ROUTE_MAPPING_SLOT = 2;
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
        operationsAdmin.assignTokenHandler(address(stablecoin), s_routeIndex, dummyAddress);
    }

    function testAssignTokenHandlerFailsIfRouteUnregistered() external {
        bytes memory encodedRevert =
            abi.encodeWithSelector(IOperationsAdmin.OperationsAdmin__RouteNotRegistered.selector, 3);
        vm.expectRevert(encodedRevert);
        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(address(stablecoin), 3, address(stablecoinHandler));
    }

    /// @dev Both the pair check and R47's address check would fire here; the pair check runs first,
    ///      so this error is unchanged by R47.
    function testDuplicateHandlerAssignmentReverts() external {
        bytes memory encodedRevert = abi.encodeWithSelector(
            IOperationsAdmin.OperationsAdmin__HandlerAlreadyAssigned.selector,
            address(stablecoin),
            s_routeIndex
        );
        vm.expectRevert(encodedRevert);
        vm.prank(OWNER);
        operationsAdmin.assignTokenHandler(address(stablecoin), s_routeIndex, address(stablecoinHandler));
    }

    function testOnlyOwnerCanRegisterRoutesAndSwappers() external {
        vm.prank(ADMIN);
        vm.expectRevert(ownableUnauthorized(ADMIN));
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);

        vm.prank(SWAPPER);
        vm.expectRevert(ownableUnauthorized(SWAPPER));
        operationsAdmin.addSwapper(address(2));

        vm.prank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        assertTrue(operationsAdmin.isLendingRoute(SECOND_LENDING_INDEX));
    }

    function testOwnerCannotRenounceOwnership() external {
        vm.expectRevert(BitChillOwnable.BitChillOwnable__OwnershipCannotBeRenounced.selector);
        vm.prank(OWNER);
        operationsAdmin.renounceOwnership();

        vm.expectRevert(BitChillOwnable.BitChillOwnable__OwnershipCannotBeRenounced.selector);
        vm.prank(USER);
        operationsAdmin.renounceOwnership();

        assertEq(operationsAdmin.owner(), OWNER);
    }

    function testConstructorEmitsIdleRouteRegistered() external {
        vm.expectEmit(false, false, false, true);
        emit OperationsAdmin__RouteRegistered(0, false);
        OperationsAdmin freshAdmin = new OperationsAdmin(OWNER);
        assertEq(uint256(freshAdmin.getRouteClass(0)), uint256(IOperationsAdmin.RouteClass.Idle));
        assertFalse(freshAdmin.isLendingRoute(0));
        assertEq(freshAdmin.owner(), OWNER);
        assertEq(freshAdmin.pendingOwner(), address(0));
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
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(ownableUnauthorized(notOwner));
        operationsAdmin.revokeSwapper(SWAPPER);
    }

    function testRevokedSwapperCannotPurchase() external {
        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        vm.prank(OWNER);
        operationsAdmin.revokeSwapper(SWAPPER);

        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__UnauthorizedSwapper.selector, SWAPPER));
        buyRbtcOne(USER, scheduleId);
    }

    function testReregisteringAnyIndexReverts() external {
        vm.startPrank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IOperationsAdmin.OperationsAdmin__RouteAlreadyRegistered.selector, 0)
        );
        operationsAdmin.registerRoute(0, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__RouteAlreadyRegistered.selector, s_routeIndex
            )
        );
        operationsAdmin.registerRoute(s_routeIndex, true);
        vm.stopPrank();
    }

    function testIsLendingRouteReadsRecordedClass() external {
        assertFalse(operationsAdmin.isLendingRoute(0));
        assertEq(
            uint256(operationsAdmin.getRouteClass(0)), uint256(IOperationsAdmin.RouteClass.Idle)
        );
        assertTrue(operationsAdmin.isLendingRoute(TROPYKUS_INDEX));
        assertTrue(operationsAdmin.isLendingRoute(SOVRYN_INDEX));
        assertTrue(operationsAdmin.isLendingRoute(LAYERBANK_INDEX));
        assertFalse(operationsAdmin.isLendingRoute(999));
        assertEq(
            uint256(operationsAdmin.getRouteClass(999)), uint256(IOperationsAdmin.RouteClass.Unregistered)
        );
    }

    function testRegisterRouteEmitsAndClassifies() external {
        vm.expectEmit(false, false, false, true);
        emit OperationsAdmin__RouteRegistered(SECOND_LENDING_INDEX, true);
        vm.prank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        assertTrue(operationsAdmin.isLendingRoute(SECOND_LENDING_INDEX));

        vm.expectEmit(false, false, false, true);
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
        address oldHandler = operationsAdmin.getTokenHandler(address(stablecoin), s_routeIndex);
        DummyLendingHandler unusedHandler = new DummyLendingHandler();

        vm.startPrank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__HandlerAlreadyAssigned.selector,
                address(stablecoin),
                s_routeIndex
            )
        );
        operationsAdmin.assignTokenHandler(address(stablecoin), s_routeIndex, address(unusedHandler));

        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        operationsAdmin.assignTokenHandler(address(stablecoin), SECOND_LENDING_INDEX, address(unusedHandler));
        vm.stopPrank();

        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), s_routeIndex), oldHandler);
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), SECOND_LENDING_INDEX), address(unusedHandler));
    }

    function testIdleHandlerAtNonZeroIndexLeavesOriginalIdleResolvable() external {
        DummyTokenHandler idleAtZero = new DummyTokenHandler();
        DummyTokenHandler idleAtTen = new DummyTokenHandler();

        vm.startPrank(OWNER);
        if (operationsAdmin.getTokenHandler(address(stablecoin), IDLE_INDEX) == address(0)) {
            operationsAdmin.assignTokenHandler(address(stablecoin), IDLE_INDEX, address(idleAtZero));
        }
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

        assertTrue(operationsAdmin.getTokenHandler(address(stablecoin), IDLE_INDEX) != address(0));
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), SECOND_IDLE_INDEX), address(idleAtTen));
        assertFalse(operationsAdmin.isLendingRoute(IDLE_INDEX));
        assertFalse(operationsAdmin.isLendingRoute(SECOND_IDLE_INDEX));
    }

    function testOldRouteStillPaysUserAfterNewHandlerRegistered() external {
        address oldHandler = operationsAdmin.getTokenHandler(address(stablecoin), s_routeIndex);
        DummyLendingHandler newHandler = new DummyLendingHandler();

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        vm.expectEmit(true, true, true, true);
        emit OperationsAdmin__TokenHandlerAssigned(
            address(stablecoin), SECOND_LENDING_INDEX, address(newHandler)
        );
        operationsAdmin.assignTokenHandler(address(stablecoin), SECOND_LENDING_INDEX, address(newHandler));
        vm.stopPrank();

        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), s_routeIndex), oldHandler);
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), SECOND_LENDING_INDEX), address(newHandler));

        uint64 scheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        uint256 remaining = scheduleAt(dcaManager, USER, address(stablecoin), 0).tokenBalance;
        uint256 userBalanceBefore = stablecoin.balanceOf(USER);

        vm.prank(USER);
        dcaManager.withdrawToken(scheduleId, remaining);

        assertGt(stablecoin.balanceOf(USER), userBalanceBefore);
        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), 0).tokenBalance, 0);
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), s_routeIndex), oldHandler);
    }

    function testOwnerCannotMoveAnotherUsersTokens() external {
        uint64 userScheduleId = scheduleIdAt(dcaManager, USER, address(stablecoin), 0);
        uint256 userRemaining = scheduleAt(dcaManager, USER, address(stablecoin), 0).tokenBalance;
        uint256 userWalletBefore = stablecoin.balanceOf(USER);

        deal(address(stablecoin), OWNER, AMOUNT_TO_DEPOSIT);
        vm.startPrank(OWNER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        dcaManager.createDcaSchedule(
            address(stablecoin), AMOUNT_TO_DEPOSIT, AMOUNT_TO_SPEND, MIN_PURCHASE_PERIOD, s_routeIndex
        );
        vm.stopPrank();

        uint64 ownerScheduleId = scheduleIdAt(dcaManager, OWNER, address(stablecoin), 0);
        uint256 ownerRemaining = scheduleAt(dcaManager, OWNER, address(stablecoin), 0).tokenBalance;
        uint256 ownerWalletBefore = stablecoin.balanceOf(OWNER);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IDcaManager.DcaManager__InexistentSchedule.selector, OWNER, userScheduleId));
        dcaManager.withdrawToken(userScheduleId, userRemaining);

        vm.prank(OWNER);
        vm.expectRevert(IDcaManagerAccessControl.DcaManagerAccessControl__OnlyDcaManagerCanCall.selector);
        ITokenHandler(address(stablecoinHandler)).withdrawToken(USER, userRemaining);

        vm.prank(OWNER);
        dcaManager.withdrawToken(ownerScheduleId, ownerRemaining);

        assertGt(stablecoin.balanceOf(OWNER), ownerWalletBefore);
        assertEq(scheduleAt(dcaManager, OWNER, address(stablecoin), 0).tokenBalance, 0);
        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), 0).tokenBalance, userRemaining);
        assertEq(stablecoin.balanceOf(USER), userWalletBefore);

        DummyLendingHandler dummy = new DummyLendingHandler();
        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        operationsAdmin.assignTokenHandler(address(stablecoin), SECOND_LENDING_INDEX, address(dummy));
        operationsAdmin.addSwapper(address(0xBEEF));
        vm.stopPrank();

        assertEq(scheduleAt(dcaManager, USER, address(stablecoin), 0).tokenBalance, userRemaining);
        assertEq(stablecoin.balanceOf(USER), userWalletBefore);
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), s_routeIndex), address(stablecoinHandler));
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

    /*//////////////////////////////////////////////////////////////
                    R47 HANDLER-ADDRESS UNIQUENESS
    //////////////////////////////////////////////////////////////*/

    /// @dev Same token, two lending indexes: DcaManager locks principal per route while the
    ///      handler keys shares by user alone, so the second route would read the first's principal as yield.
    function testHandlerAddressCannotBackTwoLendingRoutes() external {
        DummyLendingHandler lendingStub = new DummyLendingHandler();
        address token = makeAddr("r47SameTokenLending");

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX + 1, true);
        operationsAdmin.assignTokenHandler(token, SECOND_LENDING_INDEX, address(lendingStub));

        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__HandlerAddressAlreadyInUse.selector, address(lendingStub)
            )
        );
        operationsAdmin.assignTokenHandler(token, SECOND_LENDING_INDEX + 1, address(lendingStub));
        vm.stopPrank();

        assertEq(operationsAdmin.getTokenHandler(token, SECOND_LENDING_INDEX), address(lendingStub));
        assertEq(operationsAdmin.getTokenHandler(token, SECOND_LENDING_INDEX + 1), address(0));
    }

    /// @dev Idle handlers hold balances keyed by user only, so the rule is not lending-specific.
    function testHandlerAddressCannotBackTwoIdleRoutes() external {
        DummyTokenHandler idleStub = new DummyTokenHandler();
        address token = makeAddr("r47SameTokenIdle");

        vm.startPrank(OWNER);
        operationsAdmin.assignTokenHandler(token, IDLE_INDEX, address(idleStub));
        operationsAdmin.registerRoute(SECOND_IDLE_INDEX, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__HandlerAddressAlreadyInUse.selector, address(idleStub)
            )
        );
        operationsAdmin.assignTokenHandler(token, SECOND_IDLE_INDEX, address(idleStub));
        vm.stopPrank();

        assertEq(operationsAdmin.getTokenHandler(token, IDLE_INDEX), address(idleStub));
        assertEq(operationsAdmin.getTokenHandler(token, SECOND_IDLE_INDEX), address(0));
    }

    /// @dev A handler is constructed for one stablecoin, so a second token is never a legitimate reuse.
    function testHandlerAddressCannotBeReusedForASecondToken() external {
        DummyLendingHandler lendingStub = new DummyLendingHandler();
        address firstToken = makeAddr("r47FirstToken");
        address secondToken = makeAddr("r47SecondToken");

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        operationsAdmin.assignTokenHandler(firstToken, SECOND_LENDING_INDEX, address(lendingStub));

        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__HandlerAddressAlreadyInUse.selector, address(lendingStub)
            )
        );
        operationsAdmin.assignTokenHandler(secondToken, SECOND_LENDING_INDEX, address(lendingStub));
        vm.stopPrank();

        assertEq(operationsAdmin.getTokenHandler(secondToken, SECOND_LENDING_INDEX), address(0));
    }

    /// @dev Uniqueness is checked before the class checks, so crossing lending → idle with a second
    ///      token reports the reuse rather than the class mismatch. Neither path lets the address through.
    function testHandlerAddressCannotBeReusedAcrossRouteClasses() external {
        DummyLendingHandler lendingStub = new DummyLendingHandler();
        address firstToken = makeAddr("r47ClassFirstToken");
        address secondToken = makeAddr("r47ClassSecondToken");

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        operationsAdmin.assignTokenHandler(firstToken, SECOND_LENDING_INDEX, address(lendingStub));

        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__HandlerAddressAlreadyInUse.selector, address(lendingStub)
            )
        );
        operationsAdmin.assignTokenHandler(secondToken, IDLE_INDEX, address(lendingStub));
        vm.stopPrank();

        assertEq(operationsAdmin.getTokenHandler(secondToken, IDLE_INDEX), address(0));
    }

    /// @dev Versioned routes stay usable: distinct instances are what ops must deploy per pair.
    function testDistinctHandlerInstancesRemainAssignable() external {
        DummyLendingHandler firstStub = new DummyLendingHandler();
        DummyLendingHandler secondStub = new DummyLendingHandler();
        address token = makeAddr("r47DistinctInstances");

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX + 1, true);
        operationsAdmin.assignTokenHandler(token, SECOND_LENDING_INDEX, address(firstStub));
        operationsAdmin.assignTokenHandler(token, SECOND_LENDING_INDEX + 1, address(secondStub));
        vm.stopPrank();

        assertEq(operationsAdmin.getTokenHandler(token, SECOND_LENDING_INDEX), address(firstStub));
        assertEq(operationsAdmin.getTokenHandler(token, SECOND_LENDING_INDEX + 1), address(secondStub));
    }

    /// @dev Only a successful assignment consumes the address: a class-rejected handler is still assignable.
    function testRevertedAssignmentDoesNotConsumeHandlerAddress() external {
        DummyTokenHandler idleStub = new DummyTokenHandler();
        address token = makeAddr("r47RevertedAssignment");

        vm.startPrank(OWNER);
        operationsAdmin.registerRoute(SECOND_LENDING_INDEX, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__ContractIsNotTokenLending.selector, address(idleStub)
            )
        );
        operationsAdmin.assignTokenHandler(token, SECOND_LENDING_INDEX, address(idleStub));

        operationsAdmin.assignTokenHandler(token, IDLE_INDEX, address(idleStub));
        vm.stopPrank();

        assertEq(operationsAdmin.getTokenHandler(token, IDLE_INDEX), address(idleStub));
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

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function testRoutesStartWithDepositsUnpaused() external {
        assertFalse(operationsAdmin.areDepositsPaused(address(stablecoin), s_routeIndex));
    }

    function testOwnerPausesAndUnpausesDeposits() external {
        vm.expectEmit(true, false, false, true);
        emit OperationsAdmin__DepositsPauseSet(address(stablecoin), s_routeIndex, true);
        vm.prank(OWNER);
        operationsAdmin.setDepositsPaused(address(stablecoin), s_routeIndex, true);
        assertTrue(operationsAdmin.areDepositsPaused(address(stablecoin), s_routeIndex));

        vm.expectEmit(true, false, false, true);
        emit OperationsAdmin__DepositsPauseSet(address(stablecoin), s_routeIndex, false);
        vm.prank(OWNER);
        operationsAdmin.setDepositsPaused(address(stablecoin), s_routeIndex, false);
        assertFalse(operationsAdmin.areDepositsPaused(address(stablecoin), s_routeIndex));
    }

    function testOnlyOwnerCanPauseDeposits() external {
        address stranger = makeAddr("r48Stranger");
        vm.expectRevert(ownableUnauthorized(stranger));
        vm.prank(stranger);
        operationsAdmin.setDepositsPaused(address(stablecoin), s_routeIndex, true);
        assertFalse(operationsAdmin.areDepositsPaused(address(stablecoin), s_routeIndex));
    }

    /// @dev Pausing deposits on a pair nobody can deposit into would only mislead an operator.
    function testPausingAnUnassignedPairReverts() external {
        address unassignedToken = makeAddr("r48UnassignedToken");
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__HandlerNotAssigned.selector, unassignedToken, s_routeIndex
            )
        );
        vm.prank(OWNER);
        operationsAdmin.setDepositsPaused(unassignedToken, s_routeIndex, true);
    }

    function testPausingAnUnregisteredRouteReverts() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__HandlerNotAssigned.selector,
                address(stablecoin),
                SECOND_LENDING_INDEX
            )
        );
        vm.prank(OWNER);
        operationsAdmin.setDepositsPaused(address(stablecoin), SECOND_LENDING_INDEX, true);
    }

    /// @dev Every emitted event is a real transition, so an indexer never sees a repeated state.
    function testRepeatingTheCurrentPauseStateReverts() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__DepositsPauseUnchanged.selector,
                address(stablecoin),
                s_routeIndex,
                false
            )
        );
        vm.prank(OWNER);
        operationsAdmin.setDepositsPaused(address(stablecoin), s_routeIndex, false);

        vm.prank(OWNER);
        operationsAdmin.setDepositsPaused(address(stablecoin), s_routeIndex, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__DepositsPauseUnchanged.selector,
                address(stablecoin),
                s_routeIndex,
                true
            )
        );
        vm.prank(OWNER);
        operationsAdmin.setDepositsPaused(address(stablecoin), s_routeIndex, true);
    }

    /// @dev The flag is keyed per pair: a second token and a second route stay open.
    function testPauseIsScopedToOnePair() external {
        DummyTokenHandler otherTokenStub = new DummyTokenHandler();
        DummyTokenHandler otherRouteStub = new DummyTokenHandler();
        address otherToken = makeAddr("r48OtherToken");

        vm.startPrank(OWNER);
        operationsAdmin.assignTokenHandler(otherToken, IDLE_INDEX, address(otherTokenStub));
        operationsAdmin.registerRoute(SECOND_IDLE_INDEX, false);
        operationsAdmin.assignTokenHandler(address(stablecoin), SECOND_IDLE_INDEX, address(otherRouteStub));
        operationsAdmin.setDepositsPaused(address(stablecoin), s_routeIndex, true);
        vm.stopPrank();

        assertTrue(operationsAdmin.areDepositsPaused(address(stablecoin), s_routeIndex));
        assertFalse(operationsAdmin.areDepositsPaused(otherToken, IDLE_INDEX));
        assertFalse(operationsAdmin.areDepositsPaused(address(stablecoin), SECOND_IDLE_INDEX));
    }

    function testRegisterRouteAcceptsUint32Max() external {
        uint256 maxRoute = type(uint32).max;
        vm.prank(OWNER);
        operationsAdmin.registerRoute(maxRoute, false);
        assertEq(uint256(operationsAdmin.getRouteClass(maxRoute)), uint256(IOperationsAdmin.RouteClass.Idle));
    }

    function testRegisterRouteRevertsUint32MaxPlusOne() external {
        uint256 overflowing = uint256(type(uint32).max) + 1;
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, overflowing)
        );
        operationsAdmin.registerRoute(overflowing, true);
    }

    function testAssignTokenHandlerRevertsUint32MaxPlusOne() external {
        uint256 overflowing = uint256(type(uint32).max) + 1;
        DummyTokenHandler stub = new DummyTokenHandler();
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, overflowing)
        );
        operationsAdmin.assignTokenHandler(address(stablecoin), overflowing, address(stub));
    }

    function testSetDepositsPausedRevertsUint32MaxPlusOne() external {
        uint256 overflowing = uint256(type(uint32).max) + 1;
        vm.prank(OWNER);
        vm.expectRevert(_routeIndexOverflow(overflowing));
        operationsAdmin.setDepositsPaused(address(stablecoin), overflowing, true);
    }

    function testRouteIndexGettersRevertUint32MaxPlusOne() external {
        uint256 overflowing = uint256(type(uint32).max) + 1;

        vm.expectRevert(_routeIndexOverflow(overflowing));
        operationsAdmin.areDepositsPaused(address(stablecoin), overflowing);

        vm.expectRevert(_routeIndexOverflow(overflowing));
        operationsAdmin.getTokenHandler(address(stablecoin), overflowing);

        vm.expectRevert(_routeIndexOverflow(overflowing));
        operationsAdmin.isLendingRoute(overflowing);

        vm.expectRevert(_routeIndexOverflow(overflowing));
        operationsAdmin.getRouteClass(overflowing);
    }

    function testInRangeRouteIndexGettersAreUnchanged() external {
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), s_routeIndex), address(stablecoinHandler));
        assertFalse(operationsAdmin.areDepositsPaused(address(stablecoin), s_routeIndex));
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), SECOND_IDLE_INDEX), address(0));
        assertFalse(operationsAdmin.areDepositsPaused(address(stablecoin), SECOND_IDLE_INDEX));
    }

    /*//////////////////////////////////////////////////////////////
                        HANDLER + PAUSE PACKING
    //////////////////////////////////////////////////////////////*/

    function testHandlerAndPauseShareOneMappingValue() external {
        bytes32 valueSlot = _tokenRouteSlot(address(stablecoin), s_routeIndex);
        uint256 packed = uint256(vm.load(address(operationsAdmin), valueSlot));

        assertEq(address(uint160(packed)), address(stablecoinHandler), "the handler is not the low 20 bytes");
        assertEq(packed >> 160, 0, "deposits read as paused before any pause");

        vm.prank(OWNER);
        operationsAdmin.setDepositsPaused(address(stablecoin), s_routeIndex, true);

        packed = uint256(vm.load(address(operationsAdmin), valueSlot));
        assertEq(address(uint160(packed)), address(stablecoinHandler), "pausing moved the handler");
        assertEq(packed >> 160, 1, "the pause flag is not the byte above the handler");
    }

    function testUnassignedPairReadsAsZeroAndUnpaused() external {
        bytes32 valueSlot = _tokenRouteSlot(address(stablecoin), SECOND_LENDING_INDEX);
        assertEq(uint256(vm.load(address(operationsAdmin), valueSlot)), 0);
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), SECOND_LENDING_INDEX), address(0));
        assertFalse(operationsAdmin.areDepositsPaused(address(stablecoin), SECOND_LENDING_INDEX));
    }

    function _routeIndexOverflow(uint256 value) private pure returns (bytes memory) {
        return abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, value);
    }

    /// @dev `s_tokenRoute` is the first BitChill variable, at slot 2 (Ownable2Step takes 0 and 1).
    function _tokenRouteSlot(address token, uint256 routeIndex) private pure returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(token, uint256(TOKEN_ROUTE_MAPPING_SLOT)));
        return keccak256(abi.encode(routeIndex, inner));
    }
}
