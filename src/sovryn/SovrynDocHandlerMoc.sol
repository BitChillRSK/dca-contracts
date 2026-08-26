// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseMoc} from "src/PurchaseMoc.sol";
import {SovrynErc20Handler} from "./SovrynErc20Handler.sol";

/**
 * @title SovrynDocHandlerMoc
 * @notice This contract handles swaps of DOC for rBTC, redeeming the DOC at the MoC contract
 */
contract SovrynDocHandlerMoc is SovrynErc20Handler, PurchaseMoc {
    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param docTokenAddress the address of the Dollar On Chain token on the blockchain of deployment
     * @param iSusdTokenAddress the address of Sovryn's iSUSD token contract
     * @param mocProxyAddress the address of the MoC proxy contract on the blockchain of deployment
     * @param feeSettings the settings to calculate the fees charged by the protocol
     */
    constructor(
        address dcaManagerAddress,
        address docTokenAddress,
        address iSusdTokenAddress,
        address feeCollector,
        address mocProxyAddress,
        FeeSettings memory feeSettings
    )
        SovrynErc20Handler(dcaManagerAddress, docTokenAddress, iSusdTokenAddress, feeCollector, feeSettings)
        PurchaseMoc(mocProxyAddress)
    {}
}
