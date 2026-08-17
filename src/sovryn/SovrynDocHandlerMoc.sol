// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseMoc} from "src/PurchaseMoc.sol";
import {PurchaseRbtc} from "src/PurchaseRbtc.sol";
import {SovrynErc20Handler} from "./SovrynErc20Handler.sol";

/**
 * @title SovrynDocHandlerMoc
 * @notice This contract handles swaps of DOC for rBTC, redeeming the DOC at the MoC contract
 */
contract SovrynDocHandlerMoc is SovrynErc20Handler, PurchaseMoc {
    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param docTokenAddress the address of the Dollar On Chain token on the blockchain of deployment
     * @param iSusdTokenAddress the address of Tropykus' iSUSD token contract
     * @param minPurchaseAmount  the minimum amount of DOC for periodic purchases
     * @param mocProxyAddress the address of the MoC proxy contract on the blockchain of deployment
     * @param feeSettings the settings to calculate the fees charged by the protocol
     */
    constructor(
        address dcaManagerAddress,
        address docTokenAddress,
        address iSusdTokenAddress,
        uint256 minPurchaseAmount,
        address feeCollector,
        address mocProxyAddress,
        FeeSettings memory feeSettings,
        uint256 exchangeRateDecimals
    )
        SovrynErc20Handler(
            dcaManagerAddress,
            docTokenAddress,
            iSusdTokenAddress,
            feeCollector,
            feeSettings,
            exchangeRateDecimals
        )
        PurchaseMoc(docTokenAddress, mocProxyAddress)
    {}

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Override the _retrieveStablecoin hook to resolve ambiguity between parent contracts
     * @param user The address of the user whose DOC is being retrieved
     * @param amount The amount of DOC wanted
     */
    function _retrieveStablecoin(address user, uint256 amount)
        internal
        override(SovrynErc20Handler, PurchaseRbtc)
        returns (uint256)
    {
        // Call SovrynErc20Handler's version of _retrieveStablecoin
        return SovrynErc20Handler._retrieveStablecoin(user, amount);
    }

    /**
     * @notice Override the _batchRetrieveStablecoin hook to resolve ambiguity between parent contracts
     * @param users The array of user addresses whose DOC is being retrieved
     * @param purchaseAmounts The array of amounts of DOC charged to each user
     * @param totalDocAmountToSpend The total amount of DOC wanted
     */
    function _batchRetrieveStablecoin(address[] memory users, uint256[] memory purchaseAmounts, uint256 totalDocAmountToSpend)
        internal
        override(SovrynErc20Handler, PurchaseRbtc)
        returns (uint256)
    {
        // Call SovrynErc20Handler's version of _batchRetrieveStablecoin
        return SovrynErc20Handler._batchRetrieveStablecoin(users, purchaseAmounts, totalDocAmountToSpend);
    }
}
