// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PurchaseMoc} from "src/PurchaseMoc.sol";
import {SovrynErc20Handler} from "./SovrynErc20Handler.sol";

/**
 * @title SovrynDocHandlerMoc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Sovryn-lent DOC + MoC: deposits mint iSUSD; buys redeem DOC for rBTC at Money on Chain.
 * @dev Constructor-only leaf. Only its immutable DcaManager moves principal, buys, or withdraws rBTC;
 *      the owner controls fee settings and collection. MoC redeems at its protocol price, so this
 *      route has no pool-slippage floor.
 *      Holds a standing, unbounded stablecoin approval to the lending spender, granted at construction.
 *      Precondition, not enforced here: the spender pulls only from its caller, and this handler answers
 *      no protocol callback.
 *      Also relies on Sovryn not exposing bZx's `flashBorrowToken`, which no handler shape defends
 *      against.
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
