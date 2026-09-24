// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PurchaseRbtc} from "./PurchaseRbtc.sol";
import {IMocProxy} from "./interfaces/IMocProxy.sol";

/**
 * @title PurchaseMoc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice MoC purchase route: redeem DOC for native rBTC and measure the handler's balance delta.
 * @dev Immediate free-DOC redemption via `redeemFreeDoc`.
 */
abstract contract PurchaseMoc is PurchaseRbtc {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @notice Money on Chain proxy used to redeem DOC for rBTC.
    /// @return The constructor-supplied MoC proxy.
    IMocProxy public immutable i_mocProxy;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param mocProxyAddress Money on Chain proxy that exposes `redeemFreeDoc`.
    constructor(address mocProxyAddress) {
        i_mocProxy = IMocProxy(mocProxyAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Redeem free DOC at MoC and return the handler's native-balance delta. MoC reverts bubble;
     *      PurchaseRbtc separately proves that MoC consumed the complete DOC amount supplied here.
     */
    function _purchaseRbtc(uint256 stablecoinAmount, uint256 /* minRbtcOut */)
        internal
        override
        returns (uint256 rbtcReceived)
    {
        uint256 balancePrev = address(this).balance;
        i_mocProxy.redeemFreeDoc(stablecoinAmount);
        if (address(this).balance > balancePrev) {
            unchecked {
                rbtcReceived = address(this).balance - balancePrev;
            }
        }
    }
}
