// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IdleErc20Handler} from "./IdleErc20Handler.sol";
import {PurchaseMoc} from "src/PurchaseMoc.sol";

/**
 * @title IdleDocHandlerMoc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Idle DOC + MoC: deposits stay on the handler; buys redeem DOC for rBTC at Money on Chain.
 * @dev Constructor-only leaf. Only its immutable DcaManager moves principal, buys, or withdraws rBTC;
 *      the owner controls fee settings and collection. It has no pause or owner rescue path.
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
