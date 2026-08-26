// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IdleErc20Handler} from "./IdleErc20Handler.sol";
import {PurchaseMoc} from "src/PurchaseMoc.sol";

/**
 * @title IdleDocHandlerMoc
 * @notice DOC stays on the handler (lending index 0). Redeems DOC for rBTC at the MoC contract.
 */
contract IdleDocHandlerMoc is IdleErc20Handler, PurchaseMoc {
    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param docTokenAddress the address of the Dollar On Chain token on the blockchain of deployment
     * @param feeCollector the address to which fees will be sent on every purchase
     * @param mocProxyAddress the address of the MoC proxy contract on the blockchain of deployment
     * @param feeSettings the settings to calculate the fees charged by the protocol
     */
    constructor(
        address dcaManagerAddress,
        address docTokenAddress,
        address feeCollector,
        address mocProxyAddress,
        FeeSettings memory feeSettings
    ) IdleErc20Handler(dcaManagerAddress, docTokenAddress, feeCollector, feeSettings) PurchaseMoc(mocProxyAddress) {}
}
