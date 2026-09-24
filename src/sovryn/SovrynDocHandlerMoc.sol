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
 *      Holds a standing, unbounded DOC approval to iSUSD, granted at construction. That rests on a
 *      precondition, not on an enforced property: iSUSD's mint and burn entry points pull from their
 *      caller, and the one bZx entry point that would let a caller name both a target and its calldata,
 *      `flashBorrowToken`, is not implemented by the shipped loan-token logic. Were it reinstated, no
 *      shape this handler declares would defend the allowance, because such a call needs no answer from
 *      the approver — the defence there is Sovryn governance, not BitChill. iSUSD is upgradeable behind
 *      Sovryn's timelocks, and already custodies the lending position; what the standing approval adds is
 *      the DOC transiently held during a deposit or redeem, plus dust.
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
