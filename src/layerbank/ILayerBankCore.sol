// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title ILayerBankCore
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Slim LayerBank Core surface. lToken supply/redeem are `onlyCore`, so the handler
 *         enters the market through these functions. Returns are amounts, not Compound error
 *         codes; treat them as untrusted and measure token balance deltas instead.
 */
interface ILayerBankCore {
    function supply(address lToken, uint256 underlyingAmount) external payable returns (uint256);

    function redeemToken(address lToken, uint256 lTokenAmount) external returns (uint256);

    function redeemUnderlying(address lToken, uint256 underlyingAmount) external returns (uint256);
}
