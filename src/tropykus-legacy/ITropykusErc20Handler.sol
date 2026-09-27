// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/**
 * @title ITropykusErc20Handler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Tropykus-specific errors. Share events and errors stay on `ILendingHandler`.
 */
interface ITropykusErc20Handler {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The kToken's `redeem` reported failure with a non-zero Compound error code.
    error TropykusErc20Handler__LendingProtocolRedeemFailed(uint256 errorCode);
}
