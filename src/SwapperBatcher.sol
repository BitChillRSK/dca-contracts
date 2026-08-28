// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ISwapperBatcher} from "./interfaces/ISwapperBatcher.sol";
import {IDcaManager} from "./interfaces/IDcaManager.sol";
import {IOperationsAdmin} from "./interfaces/IOperationsAdmin.sol";

/**
 * @title SwapperBatcher
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Thin forwarder so one cron tick can drive every due token×route in a single transaction.
 * @dev Does not hold tokens or native rBTC: there is no `receive`, no token custody, and no
 *      withdrawal. Replacing it is `addSwapper` on a new instance and `revokeSwapper` on this one.
 *      The outer caller and this contract are both checked against the same OperationsAdmin
 *      swapper allowlist `DcaManager` uses. This contract is `msg.sender` on the inner calls, so
 *      it must be allowlisted; without the outer check a random EOA could consume one due
 *      schedule and revert the bot's atomic bundle.
 */
contract SwapperBatcher is ISwapperBatcher {
    address public immutable i_dcaManager;
    address public immutable i_operationsAdmin;

    /**
     * @notice only allow addresses on the OperationsAdmin swapper allowlist
     */
    modifier onlySwapper() {
        if (!IOperationsAdmin(i_operationsAdmin).isSwapper(msg.sender)) {
            revert SwapperBatcher__UnauthorizedSwapper(msg.sender);
        }
        _;
    }

    /**
     * @param dcaManagerAddress the DcaManager this batcher forwards to for the life of the contract
     */
    constructor(address dcaManagerAddress) {
        if (dcaManagerAddress.code.length == 0) {
            revert SwapperBatcher__DcaManagerIsNotAContract(dcaManagerAddress);
        }
        i_dcaManager = dcaManagerAddress;
        i_operationsAdmin = IDcaManager(dcaManagerAddress).getOperationsAdminAddress();
    }

    /**
     * @inheritdoc ISwapperBatcher
     */
    function batchBuyRbtcGroups(Batch[] calldata batches) external onlySwapper {
        uint256 numBatches = batches.length;
        if (numBatches == 0) revert SwapperBatcher__EmptyBatches();
        IDcaManager dcaManager = IDcaManager(i_dcaManager);
        for (uint256 i; i < numBatches; ++i) {
            Batch calldata batch = batches[i];
            dcaManager.batchBuyRbtc(
                batch.buyers,
                batch.token,
                batch.scheduleIndexes,
                batch.scheduleIds,
                batch.purchaseAmounts,
                batch.routeIndex
            );
        }
    }
}
