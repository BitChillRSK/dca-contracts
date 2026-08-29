// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IdleErc20Handler} from "./IdleErc20Handler.sol";
import {PurchaseMoc} from "src/PurchaseMoc.sol";

/**
 * @title IdleDocHandlerMoc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Idle DOC + MoC: deposits stay on the handler; buys redeem DOC for rBTC at Money on Chain.
 * @dev Default OperationsAdmin route index 0 is pre-registered as idle, not as a lending protocol.
 */
contract IdleDocHandlerMoc is IdleErc20Handler, PurchaseMoc {
    /**
     * @param dcaManagerAddress The DcaManager allowed to call this handler.
     * @param docTokenAddress Dollar On Chain token.
     * @param feeCollector Address that receives purchase fees.
     * @param mocProxyAddress Money on Chain proxy.
     * @param feeSettings Linear fee parameters.
     * @param initialOwner Address that owns fee configuration immediately after deploy.
     */
    constructor(
        address dcaManagerAddress,
        address docTokenAddress,
        address feeCollector,
        address mocProxyAddress,
        FeeSettings memory feeSettings,
        address initialOwner
    )
        IdleErc20Handler(dcaManagerAddress, docTokenAddress, feeCollector, feeSettings, initialOwner)
        PurchaseMoc(mocProxyAddress)
    {}
}
