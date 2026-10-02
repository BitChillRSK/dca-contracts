// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/**
 * @title ITropykusHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Tropykus-specific errors. Share events and errors stay on `ILendingHandler`.
 */
interface ITropykusHandler {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The kToken's `redeem` reported failure with a non-zero Compound error code.
    error TropykusHandler__LendingProtocolRedeemFailed(uint256 errorCode);
    /// @notice The kToken's underlying is not the stablecoin this handler was constructed with.
    error TropykusHandler__UnderlyingMismatch();
}
