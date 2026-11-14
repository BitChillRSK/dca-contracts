// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/**
 * @title IDcaManagerAccessControl
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice The DcaManager a handler is pinned to, and the revert it raises when any other caller
 *         reaches an `onlyDcaManager` entry point.
 */
interface IDcaManagerAccessControl {
    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The DcaManager allowed to call this handler's entry points.
    function i_dcaManager() external view returns (address);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice Caller is not the DcaManager this handler was constructed with.
    error DcaManagerAccessControl__OnlyDcaManagerCanCall();
}
