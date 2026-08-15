// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IMocProxy
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the MOC proxy contract.
 */
interface IMocProxy {
    /**
     * @dev This function requests that an amount of DOC be allowed to get redeemed for rBTC
     * @param docAmount the amount of DOC requested for redemption
     */
    function redeemDocRequest(uint256 docAmount) external;

    /**
     * @dev This function requests that an amount of DOC be redeemed for rBTC
     * @param docAmount the amount of DOC redeemed
     */
    function redeemFreeDoc(uint256 docAmount) external;
}
