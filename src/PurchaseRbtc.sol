// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {DcaManagerAccessControl} from "./DcaManagerAccessControl.sol";
import {FeeHandler} from "./FeeHandler.sol";
import {StablecoinSource} from "./StablecoinSource.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title PurchaseRbtc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Shared rBTC purchase pipeline, accumulated-balance accounting, and signer withdrawals.
 */
abstract contract PurchaseRbtc is IPurchaseRbtc, FeeHandler, DcaManagerAccessControl, StablecoinSource {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    mapping(address user => uint256 amount) internal s_usersAccumulatedRbtc;

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Allow the contract to receive native rBTC from MoC or from unwrapping WRBTC.
     */
    receive() external payable {}

    /**
     * @inheritdoc IPurchaseRbtc
     * @dev Retrieval comes first and decides which rows this batch is actually buying for. A buyer's
     *      funds here are their own — pooled across their schedules on this route, and independent of
     *      the principal the manager's ledger says each schedule holds — so a row can pass every check
     *      the manager makes and still have nothing behind it. `_batchRetrieveStablecoin` zeroes those
     *      rows in `purchaseAmounts` instead of reverting, and every step after it reads the filtered
     *      array: no fee is charged for a dropped row, and it gets no weight in the allocation. Their
     *      indexes are what this returns, so the manager knows not to debit their schedules.
     *
     *      What is spent is then the stablecoin the retrieval actually delivered, never the gross that
     *      was asked for. Planned net amounts are only allocation weights: both the rBTC credited and
     *      the stablecoin reported as spent are shares of what actually moved.
     */
    function batchBuyRbtc(
        address[] memory buyers,
        uint64[] memory scheduleIds,
        uint256[] memory purchaseAmounts,
        uint256 minRbtcOutRate
    ) external override onlyDcaManager returns (uint256[] memory unfundedRows) {
        uint256[] memory netStablecoinAmountsToSpend;
        uint256 totalNetStablecoinPlanned;
        // Retrieve first, so the fee and the weights below are calculated on the rows that funded.
        uint256 totalStablecoinAmountToSpend;
        (totalStablecoinAmountToSpend, unfundedRows) = _batchRetrieveStablecoin(buyers, purchaseAmounts);
        IERC20 purchaseToken;

        // `aggregatedFee` is scoped to this block because it is dead once the fee is paid.
        {
            uint256 aggregatedFee;
            // Calculate net amounts. A dropped row is zero here, so it pays no fee and carries no
            // weight; the fee each surviving row pays is still the fee on the gross it asked for.
            (aggregatedFee, netStablecoinAmountsToSpend, totalNetStablecoinPlanned) =
                _calculateFeeAndNetAmounts(purchaseAmounts);
            // Nothing funded: no fee to transfer and nothing to swap. The manager debits no schedule.
            if (totalNetStablecoinPlanned == 0) return unfundedRows;

            if (totalStablecoinAmountToSpend <= aggregatedFee) {
                revert PurchaseRbtc__StablecoinRetrievedBelowFee(totalStablecoinAmountToSpend, aggregatedFee);
            }
            totalStablecoinAmountToSpend -= aggregatedFee;

            purchaseToken = _purchaseToken();
            _transferFee(purchaseToken, aggregatedFee);
        }

        uint256 totalPurchasedRbtc = _purchaseRbtc(totalStablecoinAmountToSpend, minRbtcOutRate);
        if (totalPurchasedRbtc == 0) revert PurchaseRbtc__RbtcBatchPurchaseFailed(address(purchaseToken));
        // The rate is applied to the stablecoin actually spent on this tick, measured just above, never
        // to a pre-computed or planned amount: that is what keeps the bound meaningful when a schedule's
        // purchaseAmount changed since the swapper quoted minRbtcOutRate. Checked against the rBTC we
        // measured ourselves receiving, so the bound holds on every purchase venue — MoC included — and
        // never trusts an integrator return value. Rounding the requirement up means the floor is never
        // accidentally weaker than configured. Equality passes. Where the venue applies a floor of its
        // own, it is enforced there and the stricter of the two decides.
        uint256 requiredMinimum =
            Math.mulDiv(minRbtcOutRate, totalStablecoinAmountToSpend, 1 ether, Math.Rounding.Ceil);
        if (totalPurchasedRbtc < requiredMinimum) {
            revert PurchaseRbtc__BelowSwapperMinimum(totalPurchasedRbtc, requiredMinimum);
        }

        uint256 numOfPurchases = buyers.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            // The planned net amounts are only allocation weights: they sum to totalNetStablecoinPlanned,
            // so the shares below sum to exactly 1 even if the redemption paid less than expected. Both the
            // rBTC credited and the stablecoin reported as spent are shares of what actually moved.
            uint256 plannedNet = netStablecoinAmountsToSpend[i];
            if (plannedNet == 0) continue; // a row this handler could not fund: no credit, no event
            address buyer = buyers[i];
            uint256 usersPurchasedRbtc = totalPurchasedRbtc * plannedNet / totalNetStablecoinPlanned;
            uint256 usersStablecoinSpent = totalStablecoinAmountToSpend * plannedNet / totalNetStablecoinPlanned;
            s_usersAccumulatedRbtc[buyer] += usersPurchasedRbtc;
            emit PurchaseRbtc__RbtcBought(
                buyer, address(purchaseToken), usersPurchasedRbtc, scheduleIds[i], usersStablecoinSpent
            );
        }
        emit PurchaseRbtc__SuccessfulRbtcBatchPurchase(
            address(purchaseToken), totalPurchasedRbtc, totalStablecoinAmountToSpend
        );
    }

    /**
     * @inheritdoc IPurchaseRbtc
     */
    function withdrawAccumulatedRbtc(address user) external virtual override onlyDcaManager {
        uint256 rbtcBalance = _withdrawRbtcChecksEffects(user);
        _withdrawRbtc(user, rbtcBalance);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IPurchaseRbtc
     */
    function getAccumulatedRbtcBalance(address user) external view override returns (uint256) {
        return s_usersAccumulatedRbtc[user];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Zero the user's accumulated balance after checking it is nonzero. Caller then pays.
     */
    function _withdrawRbtcChecksEffects(address user) internal returns (uint256) {
        uint256 rbtcBalance = s_usersAccumulatedRbtc[user];
        if (rbtcBalance == 0) revert PurchaseRbtc__NoAccumulatedRbtcToWithdraw();

        s_usersAccumulatedRbtc[user] = 0;
        return rbtcBalance;
    }

    /**
     * @dev Pay `rbtcBalance` native rBTC to `user`. Reverts if the call fails.
     */
    function _withdrawRbtc(address user, uint256 rbtcBalance) internal {
        (bool sent,) = user.call{value: rbtcBalance}("");
        if (!sent) revert PurchaseRbtc__rBtcWithdrawalFailed();
        emit PurchaseRbtc__rBtcWithdrawn(user, rbtcBalance);
    }

    /**
     * @dev Spend `stablecoinAmount` of net stablecoin and return only measured rBTC or WRBTC received.
     * @param minRbtcOutRate rBTC/WRBTC wei per raw stablecoin wei, 1e18-scaled. A route with a swap-time
     *        floor of its own (Uniswap) derives an absolute minimum from this rate against
     *        `stablecoinAmount` and enforces it during the swap; a route with no such floor (MoC) simply
     *        ignores it here, since the shared post-purchase check in `batchBuyRbtc` above still applies
     *        the same rate against the same measured spend.
     */
    function _purchaseRbtc(uint256 stablecoinAmount, uint256 minRbtcOutRate)
        internal
        virtual
        returns (uint256 rbtcReceived);
}
