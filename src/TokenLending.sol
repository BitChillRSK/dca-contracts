// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenLending} from "./interfaces/ITokenLending.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TokenLending
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Share ↔ stablecoin conversion math. No TokenHandler inherit; adapters pass the scale.
 */
abstract contract TokenLending is ITokenLending {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 immutable i_exchangeRateDecimals;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(uint256 exchangeRateDecimals) {
        i_exchangeRateDecimals = exchangeRateDecimals;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Convert stablecoin to shares. Rounds up so the virtual share debit is never below
     *      what the lending protocol may burn for the same stablecoin amount (keeps sum of
     *      per-user shares <= shares the handler actually holds). Round-down would allow the
     *      books to drift above reality.
     * @param stablecoinAmount Amount of stablecoin to convert.
     * @param exchangeRate Stablecoin per share, scaled by `i_exchangeRateDecimals`.
     * @return sharesAmount Corresponding shares, rounded up.
     */
    function _stablecoinToShares(uint256 stablecoinAmount, uint256 exchangeRate)
        internal
        view
        returns (uint256 sharesAmount)
    {
        sharesAmount = Math.mulDiv(stablecoinAmount, i_exchangeRateDecimals, exchangeRate, Math.Rounding.Ceil);
    }

    /**
     * @dev Convert shares to stablecoin (round down).
     * @param sharesAmount Amount of shares to convert.
     * @param exchangeRate Stablecoin per share, scaled by `i_exchangeRateDecimals`.
     * @return stablecoinAmount Corresponding stablecoin.
     */
    function _sharesToStablecoin(uint256 sharesAmount, uint256 exchangeRate)
        internal
        view
        returns (uint256 stablecoinAmount)
    {
        stablecoinAmount = sharesAmount * exchangeRate / i_exchangeRateDecimals;
    }
}
