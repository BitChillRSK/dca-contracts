// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title ILayerBankPool
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Slim live LayerBank Pool surface (Aave-v3). `supply` has no return; `withdraw`
 *         returns an amount — treat it as untrusted and measure token balance deltas instead.
 */
interface ILayerBankPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Current liquidity index including pending interest, RAY (1e27) scale.
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}
