// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseUniswap} from "src/PurchaseUniswap.sol";
import {IdleErc20Handler} from "./IdleErc20Handler.sol";

/**
 * @title IdleErc20HandlerDex
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Idle stablecoin + Uniswap V3 purchases. One bytecode, two deployments (USDRIF and USDT0).
 * @dev Constructor-only leaf, same shape as `LayerBankErc20HandlerDex`. The funding base is listed
 *      first so `i_stableToken` is set before `PurchaseUniswap` builds the swap path. DOC stays on
 *      `IdleDocHandlerMoc` — it is not swapped on Uniswap.
 */
contract IdleErc20HandlerDex is IdleErc20Handler, PurchaseUniswap {
    /**
     * @param dcaManagerAddress The DcaManager allowed to call this handler.
     * @param stableTokenAddress The stablecoin this handler holds idle.
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
        UniswapSettings memory uniswapSettings,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck,
        address initialOwner
    )
        IdleErc20Handler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, initialOwner)
        PurchaseUniswap(uniswapSettings, amountOutMinimumPercent, amountOutMinimumSafetyCheck)
    {}
}
