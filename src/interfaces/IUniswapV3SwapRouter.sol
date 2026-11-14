// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/**
 * @title IUniswapV3SwapRouter
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Minimal first-party surface of Uniswap's SwapRouter02, covering only the entry point
 *         BitChill's Dex purchase route calls.
 * @dev Third-party ABI. `@uniswap/swap-router-contracts`'s `ISwapRouter02` / `IV3SwapRouter` are
 *      `GPL-2.0-or-later`; `PurchaseUniswap` only ever calls `exactInput`, so this file declares
 *      that one function under BitChill's own license instead of importing the GPL interface into
 *      a BUSL-1.1 contract. The deployed SwapRouter02 is unchanged; this is a narrower view of its
 *      existing ABI (identical selector), not a new or different contract.
 */
interface IUniswapV3SwapRouter {
    /// @notice Parameters for a (possibly multi-hop) exact-input swap along an encoded V3 path.
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /**
     * @notice Swap `amountIn` of the first token in `path` for at least `amountOutMinimum` of the last.
     * @param params Path, recipient, input amount, and minimum output.
     * @return amountOut The amount of the output token received.
     */
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}
