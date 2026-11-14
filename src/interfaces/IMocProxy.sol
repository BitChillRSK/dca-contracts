// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/**
 * @title IMocProxy
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Money on Chain proxy surface BitChill uses to redeem DOC for rBTC.
 * @dev Third-party ABI. Purchases call `redeemFreeDoc` only and measure the handler's native
 *      balance delta around that call. `redeemDocRequest` is MoC's settlement-queue entry and is
 *      kept on this interface for documentation; BitChill never calls it.
 */
interface IMocProxy {
    /**
     * @dev Enqueue DOC for redemption at the next MoC settlement. Not used by BitChill purchases.
     * @param docAmount the amount of DOC requested for redemption on settlement
     */
    function redeemDocRequest(uint256 docAmount) external;

    /**
     * @dev Immediately redeem free DOC for rBTC. This is the only MoC call BitChill purchases make.
     * @param docAmount the amount of DOC to redeem
     */
    function redeemFreeDoc(uint256 docAmount) external;
}
