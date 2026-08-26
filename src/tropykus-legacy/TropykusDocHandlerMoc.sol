// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TropykusErc20Handler} from "./TropykusErc20Handler.sol";
import {PurchaseMoc} from "src/PurchaseMoc.sol";

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
}
