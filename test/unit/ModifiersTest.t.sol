//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {DcaManager} from "../../src/DcaManager.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {ownableUnauthorized} from "../utils/OzRevert.sol";
import "../../script/Constants.sol";

contract ModifiersTest is DcaDappTest {
    // Events
    event DcaManager__MinPurchasePeriodModified(uint256 indexed newMinPurchasePeriod);

    /// @dev Pre-R46 `setOperationsAdmin(address)` selector. Kept as a literal so the test
    ///      still compiles after the function is deleted.
    bytes4 private constant SET_OPERATIONS_ADMIN_SELECTOR = 0x32742d59;

    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                            ONLYOWNER TESTS
    //////////////////////////////////////////////////////////////*/
    function testSetOperationsAdminSelectorIsAbsent() external {
        assertEq(SET_OPERATIONS_ADMIN_SELECTOR, bytes4(keccak256("setOperationsAdmin(address)")));

        (bool callSucceeded, bytes memory returnData) = address(dcaManager).call(
            abi.encodeWithSelector(SET_OPERATIONS_ADMIN_SELECTOR, address(dcaManager))
        );
        assertFalse(callSucceeded);
        assertEq(returnData.length, 0);

        vm.prank(OWNER);
        (bool ownerCallSucceeded, bytes memory ownerReturnData) = address(dcaManager).call(
            abi.encodeWithSelector(SET_OPERATIONS_ADMIN_SELECTOR, address(dcaManager))
        );
        assertFalse(ownerCallSucceeded);
        assertEq(ownerReturnData.length, 0);

        assertEq(dcaManager.getOperationsAdminAddress(), address(operationsAdmin));
    }

    function testOperationsAdminPinnedAtConstruction() external {
        assertEq(dcaManager.getOperationsAdminAddress(), address(operationsAdmin));
        assertTrue(address(operationsAdmin).code.length > 0);
    }

    function testConstructorRevertsIfOperationsAdminIsZero() external {
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__OperationsAdminIsNotAContract.selector, address(0))
        );
        new DcaManager(address(0), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, OWNER);
    }

    function testConstructorRevertsIfOperationsAdminIsEoa() external {
        address eoa = makeAddr("notAContract");
        vm.expectRevert(
            abi.encodeWithSelector(IDcaManager.DcaManager__OperationsAdminIsNotAContract.selector, eoa)
        );
        new DcaManager(eoa, MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, OWNER);
    }

    function testOperationsAdminNotInStorage() external {
        // R45 stored the admin at slot 2. After pinning it is immutable bytecode, and slot 2
        // is the s_dcaSchedules mapping root (empty → 0), not the admin address.
        bytes32 slot2 = vm.load(address(dcaManager), bytes32(uint256(2)));
        assertEq(uint256(slot2), 0);
        assertTrue(uint160(dcaManager.getOperationsAdminAddress()) != 0);
        assertEq(dcaManager.getOperationsAdminAddress(), address(operationsAdmin));
    }

    function testonlyOwnerCanModifyMinPurchasePeriod() external {
        uint256 newMinPurchasePeriod = 2 days;
        uint256 minPurchasePeriodBefore = dcaManager.getMinPurchasePeriod();
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER); // User can't
        dcaManager.modifyMinPurchasePeriod(newMinPurchasePeriod); // dummy address, e.g. that of DcaManager
        uint256 minPurchasePeriodAfter = dcaManager.getMinPurchasePeriod();
        assertEq(minPurchasePeriodBefore, minPurchasePeriodAfter);
        vm.prank(OWNER); // Owner can
        vm.expectEmit(true, true, true, true);
        emit DcaManager__MinPurchasePeriodModified(newMinPurchasePeriod);
        dcaManager.modifyMinPurchasePeriod(newMinPurchasePeriod);
        minPurchasePeriodAfter = dcaManager.getMinPurchasePeriod();
        assertEq(minPurchasePeriodAfter, newMinPurchasePeriod);
    }

    function testModifyMinPurchasePeriodRevertsBelowOneDay() external {
        vm.prank(OWNER);
        vm.expectRevert(IDcaManager.DcaManager__MinPurchasePeriodMustBeAtLeastOneDay.selector);
        dcaManager.modifyMinPurchasePeriod(1 days - 1);
        assertEq(dcaManager.getMinPurchasePeriod(), MIN_PURCHASE_PERIOD);
    }

    function testModifyMinPurchasePeriodAllowsOneDay() external {
        vm.prank(OWNER);
        dcaManager.modifyMinPurchasePeriod(2 days);
        vm.prank(OWNER);
        dcaManager.modifyMinPurchasePeriod(1 days);
        assertEq(dcaManager.getMinPurchasePeriod(), 1 days);
    }

    function testConstructorRevertsIfMinPurchasePeriodBelowOneDay() external {
        vm.expectRevert(IDcaManager.DcaManager__MinPurchasePeriodMustBeAtLeastOneDay.selector);
        new DcaManager(address(operationsAdmin), 1 days - 1, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, OWNER);
    }
}
