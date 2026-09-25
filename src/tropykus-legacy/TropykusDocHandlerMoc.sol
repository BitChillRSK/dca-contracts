// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {TropykusErc20Handler} from "./TropykusErc20Handler.sol";
import {PurchaseMoc} from "src/PurchaseMoc.sol";

/**
 * @title TropykusDocHandlerMoc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Test-only Tropykus-lent DOC + MoC handler; excluded from production deployment.
 * @dev Constructor-only leaf. Only its immutable DcaManager moves principal, buys, or withdraws rBTC;
 *      the owner controls fee settings and collection. MoC redeems at its protocol price, so this
 *      route has no pool-slippage floor.
 *      Holds a standing max DOC approval to the kToken, restorable by anyone.
 */
contract TropykusDocHandlerMoc is TropykusErc20Handler, PurchaseMoc {
    /**
     * @param dcaManagerAddress The DcaManager allowed to call this handler.
     * @param docTokenAddress Dollar On Chain token.
     * @param kDocTokenAddress Tropykus kDOC token.
     * @param feeCollector Address that receives purchase fees.
     * @param mocProxyAddress Money on Chain proxy.
     * @param feeSettings Linear fee parameters.
     * @param initialOwner Address that owns fee configuration immediately after deploy.
     */
    constructor(
        address dcaManagerAddress,
        address docTokenAddress,
        address kDocTokenAddress,
        address feeCollector,
        address mocProxyAddress,
        FeeSettings memory feeSettings,
        address initialOwner
    )
        TropykusErc20Handler(
            dcaManagerAddress, docTokenAddress, kDocTokenAddress, feeCollector, feeSettings, initialOwner
        )
        PurchaseMoc(mocProxyAddress)
    {}
}
