// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LayerBankErc20Handler} from "./LayerBankErc20Handler.sol";
import {PurchaseMoc} from "src/PurchaseMoc.sol";

/**
 * @title LayerBankDocHandlerMoc
 * @notice This contract handles swaps of DOC for rBTC, redeeming the DOC at the MoC contract
 */
contract LayerBankDocHandlerMoc is LayerBankErc20Handler, PurchaseMoc {
    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param docTokenAddress the address of the Dollar On Chain token on the blockchain of deployment
     * @param aTokenAddress the address of LayerBank's aToken for DOC
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param mocProxyAddress the address of the MoC proxy contract on the blockchain of deployment
     * @param feeSettings the settings to calculate the fees charged by the protocol
     */
    constructor(
        address dcaManagerAddress,
        address docTokenAddress,
        address aTokenAddress,
        address feeCollector,
        address mocProxyAddress,
        FeeSettings memory feeSettings
    )
        LayerBankErc20Handler(
            dcaManagerAddress,
            docTokenAddress,
            aTokenAddress,
            feeCollector,
            feeSettings
        )
        PurchaseMoc(docTokenAddress, mocProxyAddress)
    {}
}
