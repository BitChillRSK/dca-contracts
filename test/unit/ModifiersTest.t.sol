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
    event DcaManager__OperationsAdminUpdated(address indexed newOperationsAdmin);
    event DcaManager__MinPurchasePeriodModified(uint256 indexed newMinPurchasePeriod);
    
    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                            ONLYOWNER TESTS
    //////////////////////////////////////////////////////////////*/
    function testonlyOwnerCanSetOperationsAdmin() external {
        address operationsAdminBefore = dcaManager.getOperationsAdminAddress();
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER); // User can't
        dcaManager.setOperationsAdmin(address(dcaManager)); // dummy address, e.g. that of DcaManager
        address operationsAdminAfter = dcaManager.getOperationsAdminAddress();
        assertEq(operationsAdminBefore, operationsAdminAfter);
        vm.prank(OWNER); // Owner can
        vm.expectEmit(true, true, true, true);
        emit DcaManager__OperationsAdminUpdated(address(dcaManager));
        dcaManager.setOperationsAdmin(address(dcaManager));
        operationsAdminAfter = dcaManager.getOperationsAdminAddress();
        assertEq(operationsAdminAfter, address(dcaManager));
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
