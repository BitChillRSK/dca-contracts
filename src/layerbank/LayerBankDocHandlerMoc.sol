// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {LayerBankHandler} from "./LayerBankHandler.sol";
import {PurchaseMoc} from "../PurchaseMoc.sol";

/**
 * @title LayerBankDocHandlerMoc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice LayerBank-lent DOC + MoC: deposits supply aTokens; buys redeem DOC for rBTC at Money on Chain.
 * @dev Constructor-only leaf. Only its immutable DcaManager moves principal, buys, or withdraws rBTC;
 *      the owner controls fee settings and collection. MoC redeems at its protocol price, so this
 *      route has no pool-slippage floor.
 *      Holds a standing max DOC approval to the LayerBank Pool, restorable by anyone.
 */
contract LayerBankDocHandlerMoc is LayerBankHandler, PurchaseMoc {
    /**
     * @param dcaManager The DcaManager allowed to call this handler.
     * @param docToken Dollar On Chain token.
     * @param aToken LayerBank aToken for DOC.
     * @param feeCollector Address that receives purchase fees.
     * @param mocProxy Money on Chain proxy.
     * @param feeSettings Linear fee parameters.
     * @param initialOwner Address that owns fee configuration immediately after deploy.
     */
    constructor(
        address dcaManager,
        address docToken,
        address aToken,
        address feeCollector,
        address mocProxy,
        FeeSettings memory feeSettings,
        address initialOwner
    )
        LayerBankHandler(dcaManager, docToken, aToken)
        PurchaseMoc(mocProxy, FeeConfig({feeCollector: feeCollector, feeSettings: feeSettings}), initialOwner)
    {}
}
