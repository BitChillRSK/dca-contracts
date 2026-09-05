// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseMoc} from "src/PurchaseMoc.sol";
import {SovrynErc20Handler} from "./SovrynErc20Handler.sol";

/**
 * @title SovrynDocHandlerMoc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Sovryn-lent DOC + MoC: deposits mint iSUSD; buys redeem DOC for rBTC at Money on Chain.
 * @dev Constructor-only leaf: the funding base supplies the deposit and share accounting, and
 *      `PurchaseMoc` the purchase route. DOC is redeemed at Money on Chain's own price rather
 *      than swapped against a pool, so no oracle floor or slippage bound applies here — the
 *      redemption price itself is the whole of the execution guarantee.
 */
contract SovrynDocHandlerMoc is SovrynErc20Handler, PurchaseMoc {
    /**
     * @param dcaManagerAddress The DcaManager allowed to call this handler.
     * @param docTokenAddress Dollar On Chain token.
     * @param iSusdTokenAddress Sovryn iSUSD token.
     * @param feeCollector Address that receives purchase fees.
     * @param mocProxyAddress Money on Chain proxy.
     * @param feeSettings Linear fee parameters.
     * @param initialOwner Address that owns fee configuration immediately after deploy.
     */
    constructor(
        address dcaManagerAddress,
        address docTokenAddress,
        address iSusdTokenAddress,
        address feeCollector,
        address mocProxyAddress,
        FeeSettings memory feeSettings,
        address initialOwner
    )
        SovrynErc20Handler(
            dcaManagerAddress, docTokenAddress, iSusdTokenAddress, feeCollector, feeSettings, initialOwner
        )
        PurchaseMoc(mocProxyAddress)
    {}
}
