// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenLending} from "./interfaces/ITokenLending.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TokenLending
 * @notice Defines functions to convert stablecoin balances to shares and vice versa
 */
abstract contract TokenLending is ITokenLending {
    uint256 immutable i_exchangeRateDecimals;

    constructor(uint256 exchangeRateDecimals) {
        i_exchangeRateDecimals = exchangeRateDecimals;
    }

    /**
     * @notice convert stablecoin to shares
     * @dev Rounds up so the virtual share debit is never below what the lending protocol may burn for
     *      the same stablecoin amount (keeps sum of per-user shares <= shares the handler actually holds).
     *      Round-down would allow the books to drift above reality.
     * @param stablecoinAmount: the amount of stablecoin to convert
     * @param exchangeRate: the exchange rate of shares to stablecoin (stablecoin per share)
     * @return sharesAmount the amount of shares
     */
    function _stablecoinToShares(uint256 stablecoinAmount, uint256 exchangeRate)
        internal
        view
        returns (uint256 sharesAmount)
    {
        sharesAmount = Math.mulDiv(stablecoinAmount, i_exchangeRateDecimals, exchangeRate, Math.Rounding.Ceil);
    }

    /**
     * @notice convert shares to stablecoin
     * @param sharesAmount: the amount of shares to convert
     * @param exchangeRate: the exchange rate of shares to stablecoin (stablecoin per share)
     * @return stablecoinAmount the amount of stablecoin
     */
    function _sharesToStablecoin(uint256 sharesAmount, uint256 exchangeRate)
        internal
        view
        returns (uint256 stablecoinAmount)
    {
        stablecoinAmount = sharesAmount * exchangeRate / i_exchangeRateDecimals;
    }
}
