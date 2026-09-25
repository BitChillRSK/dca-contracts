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
 *      Holds a standing max stablecoin approval to the lending spender, set at construction and restorable
 *      by anyone through `restoreLendingApproval`; precondition: the spender pulls only from its caller and
 *      this handler answers no protocol callback.
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
