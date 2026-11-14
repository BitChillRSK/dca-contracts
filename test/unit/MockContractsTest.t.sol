//SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IDcaManager} from "../../src/interfaces/IDcaManager.sol";
import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import "../Constants.sol";

contract MockContractsTest is DcaDappTest {
    function setUp() public override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                          MOCK MOC PROXY TESTS
    //////////////////////////////////////////////////////////////*/
    function testMockMocProxyRedeemFreeDoc() external onlyMocSwaps {
        if (block.chainid == ANVIL_CHAIN_ID) {
            uint256 redeemAmount = 50_000 ether; // redeem 50,000 DOC
            stablecoin.mint(USER, redeemAmount);
            uint256 rBtcBalancePrev = USER.balance;
            uint256 docBalancePrev = stablecoin.balanceOf(USER);
            vm.startPrank(USER);
            stablecoin.approve(address(mocProxy), redeemAmount);
            vm.expectEmit(true, true, true, false);
            emit MockMocProxy__DocRedeemed(USER, redeemAmount, 1 ether);
            mocProxy.redeemFreeDoc(redeemAmount);
            vm.stopPrank();
            uint256 rBtcBalancePost = USER.balance;
            uint256 docBalancePost = stablecoin.balanceOf(USER);
            assertEq(rBtcBalancePost - rBtcBalancePrev, 1 ether);
            assertEq(docBalancePrev - docBalancePost, redeemAmount);
        }
    }
}
