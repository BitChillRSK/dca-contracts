// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DcaManager} from "src/DcaManager.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {BitChillOwnable} from "src/BitChillOwnable.sol";
import {IdleDocHandlerMoc} from "src/idle/IdleDocHandlerMoc.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import {ownableUnauthorized, ownableInvalidOwner} from "test/utils/OzRevert.sol";
import "test/Constants.sol";

/**
 * @title TwoStepOwnershipTest
 * @notice R45: pending-owner / accept / reject / replace / zero-owner / renounce on manager, admin, and a handler.
 */
contract TwoStepOwnershipTest is Test {
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    address internal constant OWNER = address(0xA11CE);
    address internal constant NEW_OWNER = address(0xB0B);
    address internal constant OTHER = address(0xD1E);
    address internal constant FEE_COLLECTOR = address(0xFEE);

    OperationsAdmin internal operationsAdmin;
    DcaManager internal dcaManager;
    IdleDocHandlerMoc internal handler;

    function setUp() public {
        operationsAdmin = new OperationsAdmin(OWNER);
        dcaManager = new DcaManager(
            address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, OWNER
        );

        MockStablecoin docToken = new MockStablecoin(address(this));
        MockMocProxy mocProxy = new MockMocProxy(address(docToken));
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
            }),
            OWNER
        );
    }

    function test_constructor_setsOwnerAndZeroPending() public {
        _assertDirectOwnership(operationsAdmin);
        _assertDirectOwnership(dcaManager);
        _assertDirectOwnership(handler);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(ownableInvalidOwner(address(0)));
        new OperationsAdmin(address(0));

        vm.expectRevert(ownableInvalidOwner(address(0)));
        new DcaManager(
            address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, address(0)
        );

        MockStablecoin docToken = new MockStablecoin(address(this));
        MockMocProxy mocProxy = new MockMocProxy(address(docToken));
        vm.expectRevert(ownableInvalidOwner(address(0)));
        new IdleDocHandlerMoc(
            address(dcaManager),
            address(docToken),
            FEE_COLLECTOR,
            address(mocProxy),
            IFeeHandler.FeeSettings({
                minFeeRate: MIN_FEE_RATE,
                maxFeeRate: MAX_FEE_RATE_TEST,
                feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
                feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
            }),
            address(0)
        );
    }

    function test_transferOwnership_setsPendingWithoutChangingOwner() public {
        _propose(operationsAdmin);
        _propose(dcaManager);
        _propose(handler);
    }

    function test_acceptOwnership_completesTransfer() public {
        _accept(operationsAdmin);
        _accept(dcaManager);
        _accept(handler);
    }

    function test_acceptOwnership_revertsForWrongCaller() public {
        vm.prank(OWNER);
        operationsAdmin.transferOwnership(NEW_OWNER);

        vm.expectRevert(ownableUnauthorized(OTHER));
        vm.prank(OTHER);
        operationsAdmin.acceptOwnership();

        vm.expectRevert(ownableUnauthorized(OWNER));
        vm.prank(OWNER);
        operationsAdmin.acceptOwnership();

        assertEq(operationsAdmin.owner(), OWNER);
        assertEq(operationsAdmin.pendingOwner(), NEW_OWNER);
    }

    function test_transferOwnership_replacesPendingOwner() public {
        vm.startPrank(OWNER);
        operationsAdmin.transferOwnership(NEW_OWNER);
        operationsAdmin.transferOwnership(OTHER);
        vm.stopPrank();

        assertEq(operationsAdmin.owner(), OWNER);
        assertEq(operationsAdmin.pendingOwner(), OTHER);

        vm.expectRevert(ownableUnauthorized(NEW_OWNER));
        vm.prank(NEW_OWNER);
        operationsAdmin.acceptOwnership();

        vm.expectEmit(true, true, true, true, address(operationsAdmin));
        emit OwnershipTransferred(OWNER, OTHER);
        vm.prank(OTHER);
        operationsAdmin.acceptOwnership();

        assertEq(operationsAdmin.owner(), OTHER);
        assertEq(operationsAdmin.pendingOwner(), address(0));
    }

    function test_renounceOwnership_alwaysReverts() public {
        _assertRenounceReverts(operationsAdmin);
        _assertRenounceReverts(dcaManager);
        _assertRenounceReverts(handler);
    }

    function _assertDirectOwnership(BitChillOwnable governed) internal {
        assertEq(governed.owner(), OWNER);
        assertEq(governed.pendingOwner(), address(0));
    }

    function _propose(BitChillOwnable governed) internal {
        vm.expectEmit(true, true, true, true, address(governed));
        emit OwnershipTransferStarted(OWNER, NEW_OWNER);
        vm.prank(OWNER);
        governed.transferOwnership(NEW_OWNER);
        assertEq(governed.owner(), OWNER);
        assertEq(governed.pendingOwner(), NEW_OWNER);
    }

    function _accept(BitChillOwnable governed) internal {
        vm.prank(OWNER);
        governed.transferOwnership(NEW_OWNER);

        vm.expectEmit(true, true, true, true, address(governed));
        emit OwnershipTransferred(OWNER, NEW_OWNER);
        vm.prank(NEW_OWNER);
        governed.acceptOwnership();

        assertEq(governed.owner(), NEW_OWNER);
        assertEq(governed.pendingOwner(), address(0));
    }

    function _assertRenounceReverts(BitChillOwnable governed) internal {
        bytes memory encoded =
            abi.encodeWithSelector(BitChillOwnable.BitChillOwnable__OwnershipCannotBeRenounced.selector);
        vm.expectRevert(encoded);
        vm.prank(OWNER);
        governed.renounceOwnership();

        vm.expectRevert(encoded);
        vm.prank(OTHER);
        governed.renounceOwnership();

        assertEq(governed.owner(), OWNER);
    }
}
