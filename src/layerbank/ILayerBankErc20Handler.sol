// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title ILayerBankErc20Handler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice LayerBank-specific constructor errors. Share events and errors stay on `ITokenLending`.
 */
interface ILayerBankErc20Handler {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The aToken's `POOL()` returned the zero address.
    error LayerBankErc20Handler__PoolNotSet();
    /// @notice The aToken's underlying is not the stablecoin this handler was constructed with.
    error LayerBankErc20Handler__UnderlyingMismatch();
}
