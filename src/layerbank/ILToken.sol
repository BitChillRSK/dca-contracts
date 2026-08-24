// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title ILToken
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Slim LayerBank lToken surface used by the handler. Supply and redeem are `onlyCore`
 *         on the live token; the handler must call them through `ILayerBankCore`.
 */
interface ILToken {
    function core() external view returns (address);

    function underlying() external view returns (address);

    function balanceOf(address account) external view returns (uint256);

    /// @notice View exchange rate (1e18 scale). LayerBank already folds pending interest into this
    ///         view (`pendingAccrueSnapshot`); it is not Compound's stale `exchangeRateStored`.
    function exchangeRate() external view returns (uint256);

    /// @notice Accrue interest to storage and return the current exchange rate (1e18 scale).
    ///         Same number as `exchangeRate()` after the write.
    function accruedExchangeRate() external returns (uint256);
}
