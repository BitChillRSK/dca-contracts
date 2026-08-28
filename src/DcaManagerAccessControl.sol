// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDcaManagerAccessControl} from "src/interfaces/IDcaManagerAccessControl.sol";

/**
 * @title DcaManagerAccessControl
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Restricts handler entry points to the DcaManager passed at construction.
 */
abstract contract DcaManagerAccessControl is IDcaManagerAccessControl {
    /// @notice The DcaManager allowed to call this handler's entry points.
    /// @return The constructor-supplied DcaManager address.
    address public immutable i_dcaManager;

    modifier onlyDcaManager() {
        if (msg.sender != i_dcaManager) revert DcaManagerAccessControl__OnlyDcaManagerCanCall();
        _;
    }

    /**
     * @param dcaManagerAddress The DcaManager allowed to call handler entry points.
     */
    constructor(address dcaManagerAddress) {
        i_dcaManager = dcaManagerAddress;
    }
}
