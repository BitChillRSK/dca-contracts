// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IDcaManagerAccessControl
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the DcaManagerAccessControl contract.
 */
interface IDcaManagerAccessControl {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error DcaManagerAccessControl__OnlyDcaManagerCanCall();
}
