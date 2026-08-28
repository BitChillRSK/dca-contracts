// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title ISwapperBatcher
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice One transaction, several `DcaManager.batchBuyRbtc` calls (one group per token×route).
 * @dev Holds no user funds. Callers and this contract itself are both authenticated against the
 *      same OperationsAdmin swapper allowlist `DcaManager` uses. A revert in any group rolls
 *      back every group in the same transaction.
 */
interface ISwapperBatcher {
    /**
     * @notice One `DcaManager.batchBuyRbtc` argument group. Every row in a group must share
     *         `token` and `routeIndex`; mixing those is rejected by `DcaManager`.
     */
    struct Batch {
        address[] buyers;
        address token;
        uint256[] scheduleIndexes;
        uint64[] scheduleIds;
        uint256[] purchaseAmounts;
        uint256 routeIndex;
    }

    //////////////////////
    // Errors ////////////
    //////////////////////
    /// @notice `batches` must contain at least one group.
    error SwapperBatcher__EmptyBatches();
    /// @notice Constructor `dcaManager` has no code.
    error SwapperBatcher__DcaManagerIsNotAContract(address dcaManager);
    /// @notice Caller is not on the OperationsAdmin swapper allowlist.
    error SwapperBatcher__UnauthorizedSwapper(address sender);

    /**
     * @notice Forward each group to `DcaManager.batchBuyRbtc`. Empty input reverts; per-group
     *         empty and length checks stay on `DcaManager`.
     * @param batches One group per token×route handler that is due this tick.
     * @dev Caller must be on the OperationsAdmin swapper allowlist. No `try/catch`: one revert
     *      rolls back every venue in the bundle. A paused schedule reverts its own
     *      `batchBuyRbtc`, which therefore also rolls back every other group in this call. The
     *      swapper must filter paused rows before composing. The bot EOA stays on the allowlist
     *      so a failed bundle can be retried one handler at a time.
     */
    function batchBuyRbtcGroups(Batch[] calldata batches) external;

    /**
     * @notice The `DcaManager` this batcher is permanently pinned to.
     */
    function i_dcaManager() external view returns (address);

    /**
     * @notice The OperationsAdmin whose swapper allowlist this batcher reads.
     * @dev Taken from the pinned `DcaManager` at construction, so it cannot drift from the
     *      manager's own list.
     */
    function i_operationsAdmin() external view returns (address);
}
