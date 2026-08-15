// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "../../test/Constants.sol";

// Mock Oracle Contract
contract MockMocOracle {
    uint256 private s_price;
    bool private s_isValid;
    uint256 private s_timestamp;

    constructor() {
        s_price = BTC_PRICE * 1e18;
        s_isValid = true;
        s_timestamp = block.timestamp;
    }

    // Mock function to simulate MocOracle.getPrice()
    function getPrice() external view returns (uint256) {
        return s_price;
    }

    // Mock function for the ICoinPairPrice.getPriceInfo() interface
    function getPriceInfo() external view returns (uint256, bool, uint256) {
        return (s_price, s_isValid, block.number);
    }

    // Function to update the price for testing purposes
    function setPrice(uint256 _newPrice) external {
        s_price = _newPrice;
        s_timestamp = block.timestamp;
    }

    // Function to set the price as invalid for testing the validation check
    function setInvalidPrice() external {
        s_isValid = false;
    }

    // Function to set the price as valid
    function setValidPrice() external {
        s_isValid = true;
        s_timestamp = block.timestamp;
    }
}
