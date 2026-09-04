// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseRbtc} from "./PurchaseRbtc.sol";
import {IMocProxy} from "./interfaces/IMocProxy.sol";
import {IPurchaseMoc} from "./interfaces/IPurchaseMoc.sol";

/**
 * @title PurchaseMoc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice MoC purchase route: redeem DOC for native rBTC and measure the handler's balance delta.
 */
abstract contract PurchaseMoc is PurchaseRbtc, IPurchaseMoc {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @notice Money on Chain proxy used to redeem DOC for rBTC.
    /// @return The constructor-supplied MoC proxy.
    IMocProxy public immutable i_mocProxy;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param mocProxyAddress Money on Chain proxy that exposes `redeemDocRequest` / `redeemFreeDoc`.
     */
    constructor(address mocProxyAddress) {
        i_mocProxy = IMocProxy(mocProxyAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Redeem DOC for rBTC and return the handler's native-balance delta.
     */
    function _purchaseRbtc(uint256 stablecoinAmount, uint256 /* minRbtcOut */)
        internal
        override
        returns (uint256 rbtcReceived)
    {
        (uint256 balancePrev, uint256 balancePost) = _redeemDoc(stablecoinAmount);
        if (balancePost > balancePrev) rbtcReceived = balancePost - balancePrev;
    }

    /**
     * @dev Redeem DOC for rBTC at Money on Chain. Returns the handler's native balance before and after.
     */
    function _redeemDoc(uint256 docAmountToSpend) internal returns (uint256, uint256) {
        try i_mocProxy.redeemDocRequest(docAmountToSpend) {}
        catch {
            revert PurchaseMoc__RedeemDocRequestFailed();
        }
        uint256 balancePrev = address(this).balance;
        try i_mocProxy.redeemFreeDoc(docAmountToSpend) {}
        catch {
            revert PurchaseMoc__RedeemFreeDocFailed();
        }
        uint256 balancePost = address(this).balance;
        return (balancePrev, balancePost);
    }

}
