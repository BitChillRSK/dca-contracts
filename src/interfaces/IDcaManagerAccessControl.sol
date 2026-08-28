// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IDcaManagerAccessControl
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Restricts handler entry points to the pinned DcaManager.
 */
interface IDcaManagerAccessControl {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice Caller is not the DcaManager this handler was constructed with.
    error DcaManagerAccessControl__OnlyDcaManagerCanCall();
}
