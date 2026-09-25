// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PurchaseUniswap} from "src/PurchaseUniswap.sol";
import {TropykusErc20Handler} from "./TropykusErc20Handler.sol";

/**
 * @title TropykusErc20HandlerDex
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Test-only Tropykus lending + Uniswap V3 handler; excluded from production deployment.
 * @dev Constructor-only leaf. Only its immutable DcaManager moves principal, buys, or withdraws rBTC;
 *      the owner controls fees, oracle, path allowlist, and floor. The funding base is listed first so
 *      `i_stableToken` is set before `PurchaseUniswap` builds the path.
 *      Holds standing max approvals to SwapRouter02 and the lending spender, restorable by anyone.
 */
contract TropykusErc20HandlerDex is TropykusErc20Handler, PurchaseUniswap {
    /**
     * @param dcaManagerAddress The DcaManager allowed to call this handler.
     * @param stablecoinAddress The stablecoin this handler lends.
     * @param kTokenAddress Tropykus kToken for that stablecoin.
     * @param uniswapSettings Router, WRBTC, path, and MoC oracle.
     * @param feeCollector Address that receives purchase fees.
     * @param feeSettings Linear fee parameters.
     * @param amountOutMinimumPercent Swap-time oracle floor, 1e18-scaled.
     * @param amountOutMinimumSafetyCheck Lowest floor the owner may configure, 1e18-scaled.
     * @param initialOwner Address that owns fee/oracle configuration immediately after deploy.
     */
    constructor(
        address dcaManagerAddress,
        address stablecoinAddress,
        address kTokenAddress,
        UniswapSettings memory uniswapSettings,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck,
        address initialOwner
    )
        TropykusErc20Handler(
            dcaManagerAddress, stablecoinAddress, kTokenAddress, feeCollector, feeSettings, initialOwner
        )
        PurchaseUniswap(uniswapSettings, amountOutMinimumPercent, amountOutMinimumSafetyCheck)
    {}
}
