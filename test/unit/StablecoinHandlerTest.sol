//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {IERC165} from "lib/forge-std/src/interfaces/IERC165.sol";
import {IFeeHandler} from "../../src/interfaces/IFeeHandler.sol";
import "../../script/Constants.sol";

contract StablecoinHandlerTest is DcaDappTest {
    // Events
    event TokenHandler__MinPurchaseAmountModified(uint256 indexed newMinPurchaseAmount);
    event FeeHandler__FeeCollectorAddressSet(address indexed feeCollector);
    
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
        IFeeHandler(address(stablecoinHandler)).setFeeRateParams(100, 200, 1000 ether, 100000 ether);
        assertEq(IFeeHandler(address(stablecoinHandler)).getMinFeeRate(), 100);
        assertEq(IFeeHandler(address(stablecoinHandler)).getMaxFeeRate(), 200);
        assertEq(IFeeHandler(address(stablecoinHandler)).getFeePurchaseLowerBound(), 1000 ether);
        assertEq(IFeeHandler(address(stablecoinHandler)).getFeePurchaseUpperBound(), 100000 ether);
    }

    function testStablecoinHandlerSetFeeCollectorAddress() external {
        address newFeeCollector = makeAddr("newFeeCollector");
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true);
        emit FeeHandler__FeeCollectorAddressSet(newFeeCollector);
        IFeeHandler(address(stablecoinHandler)).setFeeCollectorAddress(newFeeCollector);
        assertEq(IFeeHandler(address(stablecoinHandler)).getFeeCollectorAddress(), newFeeCollector);
    }
} 