// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {MockStablecoin} from "../mocks/MockStablecoin.sol";
import {Test, console} from "forge-std/Test.sol";
import "../../script/Constants.sol";

contract MockMocProxy {
    MockStablecoin mockDocToken;

    event MockMocProxy__DocRedeemed(address indexed user, uint256 docAmount, uint256 btcAmount);

    uint256 public docRequestCalls;
    uint256 public freeDocCalls;
    string private s_revertFreeDoc;
    uint256 private s_freeDoc = type(uint256).max;

    constructor(address docTokenAddress) {
        mockDocToken = MockStablecoin(docTokenAddress);
    }

    function setRevertFreeDoc(string calldata reason) external {
        s_revertFreeDoc = reason;
    }

    function setFreeDoc(uint256 freeDoc) external {
        s_freeDoc = freeDoc;
    }

    function redeemDocRequest(uint256) external {
        ++docRequestCalls;
    }

    function redeemFreeDoc(uint256 docAmount) external {
        ++freeDocCalls;
        if (bytes(s_revertFreeDoc).length != 0) {
            revert(s_revertFreeDoc);
        }
        // Live MoC caps the redeemed DOC at the available free-DOC amount and can therefore return a
        // positive rBTC payout after consuming less than requested. The configurable cap reproduces
        // that behavior; its default preserves a complete redemption.
        uint256 finalDocAmount = docAmount < s_freeDoc ? docAmount : s_freeDoc;
        uint256 redeemedRbtc = finalDocAmount / BTC_PRICE;
        uint256 balanceBefore = mockDocToken.balanceOf(address(this));
        mockDocToken.transferFrom(msg.sender, address(this), finalDocAmount);
        uint256 received = mockDocToken.balanceOf(address(this)) - balanceBefore;
        mockDocToken.burn(received);
        (bool success,) = msg.sender.call{value: redeemedRbtc}("");
        if (success) {
            emit MockMocProxy__DocRedeemed(msg.sender, finalDocAmount, redeemedRbtc);
        }
    }

    function mintDoc(uint256 rbtcToDeposit) external payable {}
    function mintDocVendors(uint256 rbtcToDeposit, address payable vendorAccount) external payable {}
}
