// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {IkToken} from "../../src/tropykus-legacy/IkToken.sol";
import {IiToken} from "../../src/sovryn/IiToken.sol";

/**
 * @title IShareToken
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Generic interface for lending share tokens (kToken / iToken).
 */
interface IShareToken is IkToken, IiToken {
    /**
     * @dev Returns the balance of the specified address.
     * @param owner The address to query the balance of.
     * @return The balance of the specified address.
     */
    function balanceOf(address owner) external override(IiToken, IkToken) returns (uint256);
}
