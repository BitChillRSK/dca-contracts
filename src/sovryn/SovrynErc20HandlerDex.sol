// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {PurchaseUniswap} from "src/PurchaseUniswap.sol";
import {SovrynErc20Handler} from "./SovrynErc20Handler.sol";

/**
 * @title SovrynErc20HandlerDex
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Sovryn lending + Uniswap V3 purchases.
 * @dev Constructor-only leaf. Only its immutable DcaManager moves principal, buys, or withdraws rBTC;
 *      the owner controls fees, oracle, path allowlist, and floor. Funding base is listed first as house
 *      style; `i_stableToken` lives on shared `StablecoinSource`, so path construction does not depend
 *      on that order. Holds standing max stablecoin approvals to SwapRouter02 and the iSUSD token,
 *      restorable by anyone.
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
