//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {IFeeHandler} from "../../src/interfaces/IFeeHandler.sol";
import {TropykusDocHandlerMoc} from "../../src/tropykus-legacy/TropykusDocHandlerMoc.sol";
import {IOperationsAdmin} from "../../src/interfaces/IOperationsAdmin.sol";
import "./TestsHelper.t.sol";

contract OperationsAdminTest is DcaDappTest {
    // Events
    event OperationsAdmin__AdminRoleGranted(address indexed admin);
    event OperationsAdmin__SwapperRoleGranted(address indexed swapper);
    event OperationsAdmin__AdminRoleRevoked(address indexed admin);
    event OperationsAdmin__SwapperRoleRevoked(address indexed swapper);
    
    function setUp() public override {
        super.setUp();
    }

    event OperationsAdmin__LendingProtocolAdded(uint256 indexed index, string indexed name);

    /*//////////////////////////////////////////////////////////////
                         ADMIN OPERATIONS TESTS
    //////////////////////////////////////////////////////////////*/
    function testUpdateTokenHandlerMustSupportInterface() external {
        vm.startBroadcast();
        DummyERC165Contract dummyERC165Contract = new DummyERC165Contract();
        vm.stopBroadcast();
        bytes memory encodedRevert = abi.encodeWithSelector(
            IOperationsAdmin.OperationsAdmin__ContractIsNotTokenHandler.selector, address(dummyERC165Contract)
        );

        vm.expectRevert(encodedRevert);
        vm.prank(ADMIN);
        operationsAdmin.assignOrUpdateTokenHandler(
            address(stablecoin), s_lendingProtocolIndex, address(dummyERC165Contract)
        );

        vm.expectRevert();
        vm.prank(ADMIN);
        operationsAdmin.assignOrUpdateTokenHandler(address(stablecoin), s_lendingProtocolIndex, address(dcaManager));
    }

    function testUpdateTokenHandlerFailsIfAddressIsEoa() external {
        address dummyAddress = makeAddr("dummyAddress");
        bytes memory encodedRevert =
            abi.encodeWithSelector(IOperationsAdmin.OperationsAdmin__EoaCannotBeHandler.selector, dummyAddress);
        vm.expectRevert(encodedRevert);
        vm.prank(ADMIN);
        operationsAdmin.assignOrUpdateTokenHandler(address(stablecoin), s_lendingProtocolIndex, dummyAddress);
    }

    function testTokenHandlerUpdated() external {
        address prevTropykusDocHandlerMoc = operationsAdmin.getTokenHandler(address(stablecoin), s_lendingProtocolIndex);
        vm.startBroadcast();
        TropykusDocHandlerMoc newTropykusDocHandlerMoc = new TropykusDocHandlerMoc(
            address(dcaManager),
            address(stablecoin),
            address(shareToken),
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
        vm.stopBroadcast();
        assert(prevTropykusDocHandlerMoc != address(newTropykusDocHandlerMoc));
        vm.prank(ADMIN);
        operationsAdmin.assignOrUpdateTokenHandler(
            address(stablecoin), s_lendingProtocolIndex, address(newTropykusDocHandlerMoc)
        );
        assertEq(
            operationsAdmin.getTokenHandler(address(stablecoin), s_lendingProtocolIndex),
            address(newTropykusDocHandlerMoc)
        );
    }

    function testSetRoles() external {
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true);
        emit OperationsAdmin__AdminRoleGranted(address(1));
        operationsAdmin.setAdminRole(address(1));
        assert(operationsAdmin.hasRole(operationsAdmin.ADMIN_ROLE(), address(1)));
        vm.prank(ADMIN);
        vm.expectEmit(true, true, true, true);
        emit OperationsAdmin__SwapperRoleGranted(address(2));
        operationsAdmin.setSwapperRole(address(2));
        assert(operationsAdmin.hasRole(operationsAdmin.SWAPPER_ROLE(), address(2)));
    }

    function testRevokeAdminRole() external {
        vm.expectEmit(true, true, true, true);
        emit OperationsAdmin__AdminRoleRevoked(ADMIN);
        vm.prank(OWNER);
        operationsAdmin.revokeAdminRole(ADMIN);
        assertFalse(operationsAdmin.hasRole(operationsAdmin.ADMIN_ROLE(), ADMIN));
    }

    function testRevokeSwapperRole() external {
        vm.expectEmit(true, true, true, true);
        emit OperationsAdmin__SwapperRoleRevoked(SWAPPER);
        vm.prank(ADMIN);
        operationsAdmin.revokeSwapperRole(SWAPPER);
        assertFalse(operationsAdmin.hasRole(operationsAdmin.SWAPPER_ROLE(), address(2)));
    }

    function testRevokeAdminRoleFailsIfNotOwner() external {
        vm.prank(ADMIN);
        vm.expectRevert("Ownable: caller is not the owner");
        operationsAdmin.revokeAdminRole(ADMIN);
    }

    function testRevokeSwapperRoleFailsIfNotAdmin() external {
        vm.prank(makeAddr("notAdmin"));
        vm.expectRevert();
        operationsAdmin.revokeSwapperRole(address(2));
    }

    function testAssignTokenHandlerFailsIfLendingProtocolNotAdded() external {
        bytes memory encodedRevert =
            abi.encodeWithSelector(IOperationsAdmin.OperationsAdmin__LendingProtocolNotAllowed.selector, 3);
        vm.expectRevert(encodedRevert);
        vm.prank(ADMIN);
        operationsAdmin.assignOrUpdateTokenHandler(address(stablecoin), 3, address(stablecoinHandler));
    }

    function testAddOrUpdateLendingProtocol() external {
        vm.expectEmit(true, true, true, false);
        emit OperationsAdmin__LendingProtocolAdded(3, "dummyProtocol");
        vm.prank(ADMIN);
        operationsAdmin.addOrUpdateLendingProtocol("dummyProtocol", 3);
        assertEq(operationsAdmin.getLendingProtocolIndex("dummyProtocol"), 3);
        assertEq(operationsAdmin.getLendingProtocolName(3), "dummyProtocol");
    }

    function testLendingProtocolIndexCannotBeZero() external {
        vm.expectRevert(IOperationsAdmin.OperationsAdmin__LendingProtocolIndexCannotBeZero.selector);
        vm.prank(ADMIN);
        operationsAdmin.addOrUpdateLendingProtocol("dummyProtocol", 0);
    }

    function testLendingProtocolStringNonEmpty() external {
        vm.expectRevert(IOperationsAdmin.OperationsAdmin__LendingProtocolNameNotSet.selector);
        vm.prank(ADMIN);
        operationsAdmin.addOrUpdateLendingProtocol("", 3);
    }
}
