// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {MockStablecoin} from "../mocks/MockStablecoin.sol";
import {Test, console} from "forge-std/Test.sol";
import "../../script/Constants.sol";

contract MockMocProxy {
    MockStablecoin mockDocToken;

    event MockMocProxy__DocRedeemed(address indexed user, uint256 docAmount, uint256 btcAmount);

    constructor(address docTokenAddress) {
        mockDocToken = MockStablecoin(docTokenAddress);
    }

    function redeemDocRequest(uint256 docAmount) external {}

    function redeemFreeDoc(uint256 docAmount) external {
        // Priced off the requested amount on purpose: production DOC is not fee-on-transfer, so
        // received == docAmount. The burn below uses the measured delta only so this mock stays
        // solvent when a FOT stablecoin mock is swapped in; it is not modelling a MoC payout rule.
        uint256 redeemedRbtc = docAmount / BTC_PRICE;
        uint256 balanceBefore = mockDocToken.balanceOf(address(this));
        mockDocToken.transferFrom(msg.sender, address(this), docAmount);
        uint256 received = mockDocToken.balanceOf(address(this)) - balanceBefore;
        mockDocToken.burn(received);
        (bool success,) = msg.sender.call{value: redeemedRbtc}("");
        if (success) {
            emit MockMocProxy__DocRedeemed(msg.sender, docAmount, redeemedRbtc);
        }
    }

    function mintDoc(uint256 rbtcToDeposit) external payable {}
    function mintDocVendors(uint256 rbtcToDeposit, address payable vendorAccount) external payable {}
}
