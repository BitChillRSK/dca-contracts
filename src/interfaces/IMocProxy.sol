// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IMocProxy
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Money on Chain proxy surface BitChill uses to redeem DOC for rBTC.
 * @dev Third-party ABI. BitChill measures native balance deltas around these calls.
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
