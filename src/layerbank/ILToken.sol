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

    /// @notice View exchange rate (1e18 scale), including pending interest.
    function exchangeRate() external view returns (uint256);

    /// @notice Accrue interest and return the current exchange rate (1e18 scale).
    function accruedExchangeRate() external returns (uint256);
}
