// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ISwapperBatcher} from "./interfaces/ISwapperBatcher.sol";
import {IDcaManager} from "./interfaces/IDcaManager.sol";

/**
 * @title SwapperBatcher
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Thin forwarder so one cron tick can drive every due token×route in a single transaction.
 * @dev Does not hold tokens or native rBTC: there is no `receive`, no token custody, and no
 *      withdrawal. Replacing it is `addSwapper` on a new instance and `revokeSwapper` on this one.
 *      Access control is `DcaManager.onlySwapper` on the inner calls; this contract is `msg.sender`
 *      for those, so it must be allowlisted. There is no second allowlist here.
 */
contract SwapperBatcher is ISwapperBatcher {
    address public immutable i_dcaManager;

    /**
     * @param dcaManagerAddress the DcaManager this batcher forwards to for the life of the contract
     */
    constructor(address dcaManagerAddress) {
        if (dcaManagerAddress.code.length == 0) {
            revert SwapperBatcher__DcaManagerIsNotAContract(dcaManagerAddress);
        }
        i_dcaManager = dcaManagerAddress;
    }

    /**
     * @inheritdoc ISwapperBatcher
     */
    function batchBuyRbtc(Batch[] calldata batches) external {
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
