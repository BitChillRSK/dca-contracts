// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PurchaseMoc} from "../PurchaseMoc.sol";
import {SovrynHandler} from "./SovrynHandler.sol";

/**
 * @title SovrynDocHandlerMoc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Sovryn-lent DOC + MoC: deposits mint iDOC; buys redeem DOC for rBTC at Money on Chain.
 * @dev Constructor-only leaf. Only its immutable DcaManager moves principal, buys, or withdraws rBTC;
 *      the owner controls fee settings and collection. MoC redeems at its protocol price, so this
 *      route has no pool-slippage floor.
 *      Holds a standing max DOC approval to iDOC, restorable by anyone.
 */
contract SovrynDocHandlerMoc is SovrynHandler, PurchaseMoc {
    /**
     * @param dcaManager The DcaManager allowed to call this handler.
     * @param docToken Dollar On Chain token.
     * @param iToken Sovryn iDOC (on-chain ERC-20 symbol is still `iSUSD`).
     * @param feeCollector Address that receives purchase fees.
     * @param mocProxy Money on Chain proxy.
     * @param feeSettings Purchase fee parameters.
     * @param initialOwner Address that owns fee configuration immediately after deploy.
     */
    constructor(
        address dcaManager,
        address docToken,
        address iToken,
        address feeCollector,
        address mocProxy,
        FeeSettings memory feeSettings,
        address initialOwner
    )
        SovrynHandler(dcaManager, docToken, iToken)
        PurchaseMoc(mocProxy, FeeConfig({feeCollector: feeCollector, feeSettings: feeSettings}), initialOwner)
    {}
}
