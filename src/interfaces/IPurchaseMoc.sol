// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IPurchaseMoc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Money on Chain specific purchase errors. The redeem wrappers live on `PurchaseMoc`.
 */
interface IPurchaseMoc {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice MoC `redeemDocRequest` reverted.
    error PurchaseMoc__RedeemDocRequestFailed();
    /// @notice MoC `redeemFreeDoc` reverted.
    error PurchaseMoc__RedeemFreeDocFailed();
}
