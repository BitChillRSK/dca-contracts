// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {DcaManagerAccessControl} from "./DcaManagerAccessControl.sol";
import {FeeHandler} from "./FeeHandler.sol";
import {StablecoinSource} from "./StablecoinSource.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    /**
     * @dev Allow the contract to receive native rBTC from MoC or from unwrapping WRBTC.
     */
    receive() external payable {}

    /**
     * @inheritdoc IPurchaseRbtc
     * @dev Spends the stablecoin actually received, never the gross amount asked of the lending
     *      protocol. Planned net amounts are only allocation weights: both the rBTC credited and
     *      the stablecoin reported as spent are shares of what actually moved.
     */
    function batchBuyRbtc(
        address[] memory buyers,
        uint64[] memory scheduleIds,
        uint256[] memory purchaseAmounts,
        uint256 minRbtcOut
    ) external override onlyDcaManager {
        uint256[] memory netStablecoinAmountsToSpend;
        uint256 totalNetStablecoinPlanned;
        uint256 totalStablecoinAmountToSpend;
        IERC20 purchaseToken;

        // `aggregatedFee` is scoped to this block: it is dead once the fee is paid, and releasing its
        // stack slot here keeps the credit loop below within stack limits.
        {
            uint256 aggregatedFee;
            // Calculate net amounts
            (aggregatedFee, netStablecoinAmountsToSpend, totalNetStablecoinPlanned) =
                _calculateFeeAndNetAmounts(purchaseAmounts);

            // Retrieve the stablecoin to spend: the net amount destined for rBTC plus the fee BitChill
            // charges. What comes back is what the lending protocol actually paid, never the gross request.
            totalStablecoinAmountToSpend =
                _batchRetrieveStablecoin(buyers, purchaseAmounts, totalNetStablecoinPlanned + aggregatedFee);
            if (totalStablecoinAmountToSpend <= aggregatedFee) {
                revert PurchaseRbtc__StablecoinRetrievedBelowFee(totalStablecoinAmountToSpend, aggregatedFee);
            }
            totalStablecoinAmountToSpend -= aggregatedFee;

            purchaseToken = _purchaseToken();
            _transferFee(purchaseToken, aggregatedFee);
        }

        uint256 totalPurchasedRbtc = _purchaseRbtc(totalStablecoinAmountToSpend, minRbtcOut);
        if (totalPurchasedRbtc == 0) revert PurchaseRbtc__RbtcBatchPurchaseFailed(address(purchaseToken));
        // Checked against the rBTC we measured ourselves receiving, so the bound holds on every purchase
        // venue and never trusts an integrator return value. Equality passes, and the venue's own floor is
        // independent of this one: the stricter of the two wins.
        if (totalPurchasedRbtc < minRbtcOut) {
            revert PurchaseRbtc__BelowSwapperMinimum(totalPurchasedRbtc, minRbtcOut);
        }

        uint256 numOfPurchases = buyers.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            // The planned net amounts are only allocation weights: they sum to totalNetStablecoinPlanned,
            // so the shares below sum to exactly 1 even if the redemption paid less than expected. Both the
            // rBTC credited and the stablecoin reported as spent are shares of what actually moved.
            uint256 plannedNet = netStablecoinAmountsToSpend[i];
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
     */
    function _purchaseRbtc(uint256 stablecoinAmount, uint256 minRbtcOut) internal virtual returns (uint256 rbtcReceived);
}
