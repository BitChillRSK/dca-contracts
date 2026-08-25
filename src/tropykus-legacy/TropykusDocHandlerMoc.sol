// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TropykusErc20Handler} from "./TropykusErc20Handler.sol";
import {LendingErc20Handler} from "src/LendingErc20Handler.sol";
import {PurchaseMoc} from "src/PurchaseMoc.sol";
import {PurchaseRbtc} from "src/PurchaseRbtc.sol";

/**
 * @title TropykusDocHandlerMoc
 * @notice This contract handles swaps of DOC for rBTC, redeeming the DOC at the MoC contract
 */
contract TropykusDocHandlerMoc is TropykusErc20Handler, PurchaseMoc {
    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param docTokenAddress the address of the Dollar On Chain token on the blockchain of deployment
     * @param kDocTokenAddress the address of Tropykus' kDOC token contract
     * @param mocProxyAddress the address of the MoC proxy contract on the blockchain of deployment
     * @param feeSettings the settings to calculate the fees charged by the protocol
     */
    constructor(
        address dcaManagerAddress,
        address docTokenAddress,
        address kDocTokenAddress,
        address feeCollector,
        address mocProxyAddress,
        FeeSettings memory feeSettings
    )
        TropykusErc20Handler(dcaManagerAddress, docTokenAddress, kDocTokenAddress, feeCollector, feeSettings)
        PurchaseMoc(docTokenAddress, mocProxyAddress)
    {}

    /**
     * @notice Override the _retrieveStablecoin hook to resolve ambiguity between parent contracts
     * @param user The address of the user whose DOC is being retrieved
     * @param amount The amount of DOC wanted
     */
    function _retrieveStablecoin(address user, uint256 amount)
        internal
        override(LendingErc20Handler, PurchaseRbtc)
        returns (uint256)
    {
        return LendingErc20Handler._retrieveStablecoin(user, amount);
    }

    /**
     * @notice Override the _batchRetrieveStablecoin hook to resolve ambiguity between parent contracts
     * @param users The array of user addresses whose DOC is being retrieved
     * @param purchaseAmounts The array of amounts of DOC charged to each user
     * @param totalDocAmountToSpend The total amount of DOC wanted
     */
    function _batchRetrieveStablecoin(address[] memory users, uint256[] memory purchaseAmounts, uint256 totalDocAmountToSpend)
        internal
        override(LendingErc20Handler, PurchaseRbtc)
        returns (uint256)
    {
        return LendingErc20Handler._batchRetrieveStablecoin(users, purchaseAmounts, totalDocAmountToSpend);
    }
}
