// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseRbtc} from "./PurchaseRbtc.sol";
import {IMocProxy} from "./interfaces/IMocProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPurchaseMoc} from "./interfaces/IPurchaseMoc.sol";

/**
 * @title PurchaseMoc
 * @notice This contract handles swaps of DOC for rBTC, redeeming the DOC at the MoC contract
 */
abstract contract PurchaseMoc is PurchaseRbtc, IPurchaseMoc {
    //////////////////////
    // State variables ///
    //////////////////////
    IERC20 public immutable i_docToken;
    IMocProxy public immutable i_mocProxy;

    /**
     * @param docTokenAddress the address of the Dollar On Chain token on the blockchain of deployment
     * @param mocProxyAddress the address of the MoC proxy contract on the blockchain of deployment
     */
    constructor(
        address docTokenAddress,
        address mocProxyAddress
    )
    {
        i_mocProxy = IMocProxy(mocProxyAddress);
        i_docToken = IERC20(docTokenAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice redeem DOC for rBTC and return the handler's native-balance delta
     * @param stablecoinAmount the net DOC amount to redeem
     * @return rbtcReceived the measured rBTC this contract actually received
     */
    function _purchaseRbtc(uint256 stablecoinAmount) internal override returns (uint256 rbtcReceived) {
        (uint256 balancePrev, uint256 balancePost) = _redeemDoc(stablecoinAmount);
        if (balancePost > balancePrev) rbtcReceived = balancePost - balancePrev;
    }

    /**
     * @notice redeem DOC for rBTC at Money on Chain
     * @param docAmountToSpend the amount of DOC to redeem
     * @return the contract's rBTC balance before the redemption
     * @return the contract's rBTC balance after the redemption
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
