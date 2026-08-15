// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IDcaManagerAccessControl} from "src/interfaces/IDcaManagerAccessControl.sol";

/**
 * @title DcaManagerAccessControl
 * @dev Base contract for handling DCA Manager access control
 */
abstract contract DcaManagerAccessControl is IDcaManagerAccessControl {
    address public immutable i_dcaManager; // The DCA manager contract

    modifier onlyDcaManager() {
        if (msg.sender != i_dcaManager) revert DcaManagerAccessControl__OnlyDcaManagerCanCall();
        _;
    }

    /**
     * @notice constructor for the DcaManagerAccessControl contract
     * @param dcaManagerAddress: the address of the DCA manager contract
     */
    constructor(address dcaManagerAddress) {
        i_dcaManager = dcaManagerAddress;
    }
}
