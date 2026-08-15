// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

contract MockMocPriceProvider {
    bytes32 public mocPrice;
    bool public has;
    bool public useLastPublicationBlock = false;
    uint256 public lastPublicationBlock = 0;

    /**
     * @notice constructor
     * @param price_ MoC price for mock contract
     */
    constructor(uint256 price_) {
        mocPrice = bytes32(price_);
        has = true;
    }

    function peek() external view returns (bytes32, bool) {
        return (mocPrice, has);
    }

    function poke(uint256 price_) external {
        mocPrice = bytes32(price_);
        lastPublicationBlock = block.number;
    }

    function deprecatePriceProvider() external {
        has = false;
    }

    function getLastPublicationBlock() external view returns (uint256) {
        if (useLastPublicationBlock) return lastPublicationBlock;
        else return block.number;
    }

    function setLastPublicationBlock(uint256 lastPublicationBlock_) external returns (uint256) {
        useLastPublicationBlock = true;
        lastPublicationBlock = lastPublicationBlock_;
        return lastPublicationBlock;
    }

    function removeLastPublicationBlock() external {
        useLastPublicationBlock = false;
    }

    // Return the current price.
    function getPrice() external view returns (uint256) {
        return uint256(mocPrice);
    }

    // Return the result of getPrice, getIsValid and getLastPublicationBlock at once.
    function getPriceInfo()
        external
        view
        returns (uint256 price, bool isValid, uint256 lastPubBlock)
    {
        return (uint256(mocPrice), true, lastPublicationBlock);
    }
}