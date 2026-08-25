// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title ILayerBankErc20Handler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev LayerBank-specific constructor errors. Share events/errors stay on `ITokenLending`.
 */
interface ILayerBankErc20Handler {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error LayerBankErc20Handler__PoolNotSet();
    error LayerBankErc20Handler__UnderlyingMismatch();
}
