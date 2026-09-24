// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PurchaseUniswap} from "src/PurchaseUniswap.sol";
import {SovrynErc20Handler} from "./SovrynErc20Handler.sol";

/**
 * @title SovrynErc20HandlerDex
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Sovryn lending + Uniswap V3 purchases.
 * @dev Constructor-only leaf. Only its immutable DcaManager moves principal, buys, or withdraws rBTC;
 *      the owner controls fees, oracle, path allowlist, and floor. The funding base is listed first so
 *      `i_stableToken` is set before `PurchaseUniswap` builds the path.
 *      Holds standing, unbounded stablecoin approvals to the Uniswap router and to iSUSD, both granted at
 *      construction. SwapRouter02 pulls only from the caller of the swap it is executing and is not
 *      upgradeable. The iSUSD allowance rests on a precondition instead: iSUSD's mint and burn entry
 *      points pull from their caller, and the one bZx entry point that would let a caller name both a
 *      target and its calldata, `flashBorrowToken`, is not implemented by the shipped loan-token logic.
 *      Were it reinstated, no shape this handler declares would defend the allowance, because such a call
 *      needs no answer from the approver — the defence there is Sovryn governance, not BitChill. iSUSD is
 *      upgradeable behind Sovryn's timelocks, and already custodies the lending position; what the
 *      standing approval adds is the stablecoin transiently held during a deposit or redeem, plus dust.
 */
contract SovrynErc20HandlerDex is SovrynErc20Handler, PurchaseUniswap {
    /**
     * @param dcaManagerAddress The DcaManager allowed to call this handler.
     * @param stableTokenAddress The stablecoin this handler lends.
     * @param iSusdTokenAddress Sovryn iToken for that stablecoin.
     * @param uniswapSettings Router, WRBTC, path, and MoC oracle.
     * @param feeCollector Address that receives purchase fees.
     * @param feeSettings Linear fee parameters.
     * @param amountOutMinimumPercent Swap-time oracle floor, 1e18-scaled.
     * @param amountOutMinimumSafetyCheck Lowest floor the owner may configure, 1e18-scaled.
     * @param initialOwner Address that owns fee/oracle configuration immediately after deploy.
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address iSusdTokenAddress,
        UniswapSettings memory uniswapSettings,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck,
        address initialOwner
    )
        SovrynErc20Handler(
            dcaManagerAddress, stableTokenAddress, iSusdTokenAddress, feeCollector, feeSettings, initialOwner
        )
        PurchaseUniswap(uniswapSettings, amountOutMinimumPercent, amountOutMinimumSafetyCheck)
    {}
}
