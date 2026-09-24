// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {LayerBankErc20Handler} from "./LayerBankErc20Handler.sol";
import {PurchaseMoc} from "src/PurchaseMoc.sol";

/**
 * @title LayerBankDocHandlerMoc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice LayerBank-lent DOC + MoC: deposits supply aTokens; buys redeem DOC for rBTC at Money on Chain.
 * @dev Constructor-only leaf. Only its immutable DcaManager moves principal, buys, or withdraws rBTC;
 *      the owner controls fee settings and collection. MoC redeems at its protocol price, so this
 *      route has no pool-slippage floor.
 *      Holds a standing, unbounded stablecoin approval to the lending spender, granted at construction.
 *      That rests on a precondition, not on an enforced property: this handler answers no protocol
 *      callback, so a pool entry point that repays from a caller-named address cannot reach it. Adding a
 *      `fallback` or an `executeOperation` here would break that. The spender's own code is governed by
 *      its protocol's admin, not by BitChill.
 */
contract LayerBankDocHandlerMoc is LayerBankErc20Handler, PurchaseMoc {
    /**
     * @param dcaManagerAddress The DcaManager allowed to call this handler.
     * @param docTokenAddress Dollar On Chain token.
     * @param aTokenAddress LayerBank aToken for DOC.
     * @param feeCollector Address that receives purchase fees.
     * @param mocProxyAddress Money on Chain proxy.
     * @param feeSettings Linear fee parameters.
     * @param initialOwner Address that owns fee configuration immediately after deploy.
     */
    constructor(
        address dcaManagerAddress,
        address docTokenAddress,
        address aTokenAddress,
        address feeCollector,
        address mocProxyAddress,
        FeeSettings memory feeSettings,
        address initialOwner
    )
        LayerBankErc20Handler(
            dcaManagerAddress,
            docTokenAddress,
            aTokenAddress,
            feeCollector,
            feeSettings,
            initialOwner
        )
        PurchaseMoc(mocProxyAddress)
    {}
}
