// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/**
 * @title ILayerBankHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice LayerBank-specific constructor errors. Share events and errors stay on `ILendingHandler`.
 */
interface ILayerBankHandler {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The aToken's `POOL()` returned the zero address.
    error LayerBankHandler__PoolNotSet();
}
