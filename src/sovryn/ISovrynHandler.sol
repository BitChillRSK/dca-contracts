// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/**
 * @title ISovrynHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Sovryn-specific constructor errors. Share events and errors stay on `ILendingHandler`.
 */
interface ISovrynHandler {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The iToken's underlying is not the stablecoin this handler was constructed with.
    error SovrynHandler__UnderlyingMismatch();
}
