// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IPurchaseMoc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the Money On Chain specific purchase related errors
 */
interface IPurchaseMoc {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PurchaseMoc__RedeemDocRequestFailed();
    error PurchaseMoc__RedeemFreeDocFailed();
} 