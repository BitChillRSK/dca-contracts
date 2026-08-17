// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TropykusErc20Handler} from "./TropykusErc20Handler.sol";
import {PurchaseMoc} from "src/PurchaseMoc.sol";
import {PurchaseRbtc} from "src/PurchaseRbtc.sol";

/**
 * @title TropykusDocHandlerMoc
 * @notice This contract handles swaps of DOC for rBTC directly redeeming the latter from the MoC contract
 */
contract TropykusDocHandlerMoc is TropykusErc20Handler, PurchaseMoc {
    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param docTokenAddress the address of the Dollar On Chain token on the blockchain of deployment
     * @param kDocTokenAddress the address of Tropykus' kDOC token contract
     * @param minPurchaseAmount  the minimum amount of DOC for periodic purchases
     * @param mocProxyAddress the address of the MoC proxy contract on the blockchain of deployment
     * @param feeSettings the settings to calculate the fees charged by the protocol
     */
    constructor(
        address dcaManagerAddress,
        address docTokenAddress,
        address kDocTokenAddress,
        uint256 minPurchaseAmount,
        address feeCollector,
        address mocProxyAddress,
        FeeSettings memory feeSettings,
        uint256 exchangeRateDecimals
    )
        TropykusErc20Handler(
            dcaManagerAddress,
            docTokenAddress,
            kDocTokenAddress,
            feeCollector,
            feeSettings,
            exchangeRateDecimals
        )
        PurchaseMoc(docTokenAddress, mocProxyAddress)
    {}

    /**
     * @notice Override the _redeemStablecoin function to resolve ambiguity between parent contracts
     * @param user The address of the user for whom DOC is being redeemed
     * @param amount The amount of DOC to redeem
     */
    function _redeemStablecoin(address user, uint256 amount)
        internal
        override(TropykusErc20Handler, PurchaseRbtc)
        returns (uint256)
    {
        // Call TropykusErc20Handler's version of _redeemStablecoin
        return TropykusErc20Handler._redeemStablecoin(user, amount);
    }

    /**
     * @notice Override the _batchRedeemStablecoin function to resolve ambiguity between parent contracts
     * @param users The array of user addresses for whom DOC is being redeemed
     * @param purchaseAmounts The array of amounts of DOC to redeem for each user
     * @param totalDocAmountToSpend The total amount of DOC to redeem
     */
    function _batchRedeemStablecoin(address[] memory users, uint256[] memory purchaseAmounts, uint256 totalDocAmountToSpend)
        internal
        override(TropykusErc20Handler, PurchaseRbtc)
        returns (uint256)
    {
        // Call TropykusErc20Handler's version of _batchRedeemStablecoin
        return TropykusErc20Handler._batchRedeemStablecoin(users, purchaseAmounts, totalDocAmountToSpend);
    }
}
