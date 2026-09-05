// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PurchaseUniswap} from "src/PurchaseUniswap.sol";
import {LayerBankErc20Handler} from "./LayerBankErc20Handler.sol";

/**
 * @title LayerBankErc20HandlerDex
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice LayerBank lending + Uniswap V3 purchases. One bytecode, deployed once per listed stablecoin.
 * @dev Constructor-only leaf. The funding base is listed first so `i_stableToken` is set before
 *      `PurchaseUniswap` builds the swap path.
 */
contract LayerBankErc20HandlerDex is LayerBankErc20Handler, PurchaseUniswap {
    /**
     * @param dcaManagerAddress The DcaManager allowed to call this handler.
     * @param stableTokenAddress The stablecoin this handler lends.
     * @param aTokenAddress LayerBank aToken for that stablecoin.
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
        address aTokenAddress,
        UniswapSettings memory uniswapSettings,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck,
        address initialOwner
    )
        LayerBankErc20Handler(
            dcaManagerAddress, stableTokenAddress, aTokenAddress, feeCollector, feeSettings, initialOwner
        )
        PurchaseUniswap(uniswapSettings, amountOutMinimumPercent, amountOutMinimumSafetyCheck)
    {}
}
