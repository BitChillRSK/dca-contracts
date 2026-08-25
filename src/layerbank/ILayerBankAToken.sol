// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title ILayerBankAToken
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Slim live LayerBank aToken surface (Aave-v3 `ATokenInstance`). Supply and withdraw
 *         go through `ILayerBankPool`; this token has no `core()`, `accruedExchangeRate()`,
 *         or `underlying()`.
 */
interface ILayerBankAToken {
    function POOL() external view returns (address);

    function UNDERLYING_ASSET_ADDRESS() external view returns (address);

    /// @notice Non-rebasing scaled balance. Store this, not `balanceOf`.
    function scaledBalanceOf(address account) external view returns (uint256);
}
