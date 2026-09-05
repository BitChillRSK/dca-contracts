// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IDcaManagerAccessControl
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice The revert a handler raises when a caller other than its pinned DcaManager reaches an
 *         `onlyDcaManager` entry point.
 */
interface IDcaManagerAccessControl {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice Caller is not the DcaManager this handler was constructed with.
    error DcaManagerAccessControl__OnlyDcaManagerCanCall();
}
