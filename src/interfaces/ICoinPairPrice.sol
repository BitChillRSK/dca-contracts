// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/**
 * @title ICoinPairPrice
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice MoC BTC/USD oracle surface. BitChill calls `getPriceInfo` to build Uniswap `amountOutMinimum`.
 * @dev Third-party ABI, reduced to the one read BitChill makes. Money on Chain's own `CoinPairPrice`
 *      exposes more price reads, oracle subscription, price publication, round management, and staking;
 *      BitChill neither calls nor implements any of it, so declaring it here would put surface on the
 *      verified source that no BitChill contract can reach. The comments below are the vendor's.
 */
interface ICoinPairPrice {
    /// @notice Return the current price with validity information
    /// @return price The current price
    /// @return isValid Whether the price is valid and up-to-date
    /// @return lastPubBlock The block number when the price was last updated
    function getPriceInfo() external view returns (uint256 price, bool isValid, uint256 lastPubBlock);
}
