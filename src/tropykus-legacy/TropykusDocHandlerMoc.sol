// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {TropykusHandler} from "./TropykusHandler.sol";
import {PurchaseMoc} from "../PurchaseMoc.sol";

/**
 * @title TropykusDocHandlerMoc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Test-only Tropykus-lent DOC + MoC handler; excluded from production deployment.
 * @dev Constructor-only leaf. Only its immutable DcaManager moves principal, buys, or withdraws rBTC;
 *      the owner controls fee settings and collection. MoC redeems at its protocol price, so this
 *      route has no pool-slippage floor.
 *      Holds a standing max DOC approval to the kToken, restorable by anyone.
 */
contract TropykusDocHandlerMoc is TropykusHandler, PurchaseMoc {
    /**
     * @param dcaManager The DcaManager allowed to call this handler.
     * @param docToken Dollar On Chain token.
     * @param kToken Tropykus kDOC token.
     * @param feeCollector Address that receives purchase fees.
     * @param mocProxy Money on Chain proxy.
     * @param feeSettings Purchase fee parameters.
     * @param initialOwner Address that owns fee configuration immediately after deploy.
     */
    constructor(
        address dcaManager,
        address docToken,
        address kToken,
        address feeCollector,
        address mocProxy,
        FeeSettings memory feeSettings,
        address initialOwner
    )
        TropykusHandler(dcaManager, docToken, kToken)
        PurchaseMoc(mocProxy, FeeConfig({feeCollector: feeCollector, feeSettings: feeSettings}), initialOwner)
    {}
}
