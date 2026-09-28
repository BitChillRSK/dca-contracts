//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {IPurchaseFees} from "../../src/interfaces/IPurchaseFees.sol";
import "../Constants.sol";

contract StablecoinHandlerTest is DcaDappTest {
    // Events
    event TokenHandler__MinPurchaseAmountModified(uint256 indexed newMinPurchaseAmount);
    event PurchaseFees__FeeCollectorAddressSet(address indexed feeCollector);

    function setUp() public override {
        super.setUp();
    }

    ////////////////////////////
    ///// Settings tests ///////
    ////////////////////////////

    function testStablecoinHandlerSupportsInterface() external {
        assertEq(IERC165(address(stablecoinHandler)).supportsInterface(type(ITokenHandler).interfaceId), true);
    }

    function testStablecoinHandlerSetFeeRateParams() external {
        vm.prank(OWNER);
        IPurchaseFees(address(stablecoinHandler)).setFeeRateParams(100, 200, 1000 ether, 100000 ether);
        IPurchaseFees.FeeSettings memory settings = IPurchaseFees(address(stablecoinHandler)).getFeeSettings();
        assertEq(settings.minFeeRate, 100);
        assertEq(settings.maxFeeRate, 200);
        assertEq(settings.feePurchaseLowerBound, 1000 ether);
        assertEq(settings.feePurchaseUpperBound, 100000 ether);
    }

    function testStablecoinHandlerSetFeeCollectorAddress() external {
        address newFeeCollector = makeAddr("newFeeCollector");
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true);
        emit PurchaseFees__FeeCollectorAddressSet(newFeeCollector);
        IPurchaseFees(address(stablecoinHandler)).setFeeCollector(newFeeCollector);
        assertEq(IPurchaseFees(address(stablecoinHandler)).getFeeCollector(), newFeeCollector);
    }
}
