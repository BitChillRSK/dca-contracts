// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

interface IMocStateV1 {
    function getBtcPriceProvider() external view returns (address);
    function setBtcPriceProvider(address _btcPriceProvider) external;
    function getMoCPriceProvider() external view returns (address);
    function setMoCPriceProvider(address _mocPriceProvider) external;
    function getBitcoinPrice() external view returns(uint256);
}

interface IChangeContract {
    function execute() external;
}


