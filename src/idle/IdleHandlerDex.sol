// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PurchaseUniswap} from "../PurchaseUniswap.sol";
import {IdleHandler} from "./IdleHandler.sol";

/**
 * @title IdleHandlerDex
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Token-agnostic idle stablecoin + Uniswap V3 purchase handler.
 * @dev Constructor-only leaf. Only its immutable DcaManager moves principal, buys, or withdraws rBTC;
 *      the owner controls fees, oracle, path allowlist, and floor. Holds a standing max stablecoin
 *      approval to SwapRouter02, restorable by anyone.
 */
contract IdleHandlerDex is IdleHandler, PurchaseUniswap {
    /**
     * @param dcaManager The DcaManager allowed to call this handler.
     * @param stablecoin The stablecoin this handler holds idle.
     * @param uniswapSettings Router, WRBTC, path, and MoC oracle.
     * @param feeCollector Address that receives purchase fees.
     * @param feeSettings Linear fee parameters.
     * @param amountOutMinimumPercent Swap-time oracle floor, 1e18-scaled.
     * @param amountOutMinimumSafetyCheck Lowest floor the owner may configure, 1e18-scaled.
     * @param initialOwner Address that owns fee/oracle configuration immediately after deploy.
     */
    constructor(
        address dcaManager,
        address stablecoin,
        UniswapSettings memory uniswapSettings,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck,
        address initialOwner
    )
        IdleHandler(dcaManager, stablecoin)
        PurchaseUniswap(
            uniswapSettings,
            FeeConfig({feeCollector: feeCollector, feeSettings: feeSettings}),
            amountOutMinimumPercent,
            amountOutMinimumSafetyCheck,
            initialOwner
        )
    {}
}
