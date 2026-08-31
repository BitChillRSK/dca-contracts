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
    //////////////////////
    // State variables ///
    //////////////////////
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
        // Calculate net amounts
        (uint256 aggregatedFee, uint256[] memory netStablecoinAmountsToSpend, uint256 totalNetStablecoinPlanned) =
            _calculateFeeAndNetAmounts(purchaseAmounts);

        // Retrieve the stablecoin to spend
        // @notice we spend the stablecoin we actually received, never the gross amount we asked the lending protocol for
        uint256 totalStablecoinAmountToSpend =
            _batchRetrieveStablecoin(buyers, purchaseAmounts, totalNetStablecoinPlanned + aggregatedFee); // totalNetStablecoinPlanned (to spend on rBTC) + aggregatedFee (charged by BitChill)
        if (totalStablecoinAmountToSpend <= aggregatedFee) {
            revert PurchaseRbtc__StablecoinRetrievedBelowFee(totalStablecoinAmountToSpend, aggregatedFee);
        }
        totalStablecoinAmountToSpend -= aggregatedFee;

        IERC20 purchaseToken = _purchaseToken();
        _transferFee(purchaseToken, aggregatedFee);

        uint256 totalPurchasedRbtc = _purchaseRbtc(totalStablecoinAmountToSpend);
        if (totalPurchasedRbtc == 0) revert PurchaseRbtc__RbtcBatchPurchaseFailed(address(purchaseToken));
        // @notice the caller's bound is checked against the rBTC we measured ourselves receiving, so it holds
        // on every purchase venue and never trusts an integrator return value. Equality passes. The venue may
        // already have reverted on its own floor; the two bounds are independent and the stricter one wins.
        if (totalPurchasedRbtc < minRbtcOut) {
            revert PurchaseRbtc__BelowSwapperMinimum(totalPurchasedRbtc, minRbtcOut);
        }

        // @notice `buyers.length` is read per iteration rather than cached in a local on purpose: this
        // function sits one slot under the limit the non-IR pipeline can address, and the cached length was
        // the slot that put it over. Re-adding it fails the build with "Stack too deep", it does not save
        // gas here (measured slightly cheaper without), and the fix is not to split the loop into a helper.
        for (uint256 i; i < buyers.length; ++i) {
            // @notice the planned net amounts are only allocation weights: they sum to totalNetStablecoinPlanned,
            // so the shares below sum to exactly 1 even if the redemption paid less than expected. Both the rBTC credited
            // and the stablecoin reported as spent are shares of what actually moved.
            uint256 usersPurchasedRbtc =
                totalPurchasedRbtc * netStablecoinAmountsToSpend[i] / totalNetStablecoinPlanned;
            uint256 usersStablecoinSpent =
                totalStablecoinAmountToSpend * netStablecoinAmountsToSpend[i] / totalNetStablecoinPlanned;
            s_usersAccumulatedRbtc[buyers[i]] += usersPurchasedRbtc;
            emit PurchaseRbtc__RbtcBought(
                buyers[i], address(purchaseToken), usersPurchasedRbtc, scheduleIds[i], usersStablecoinSpent
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
    function _purchaseRbtc(uint256 stablecoinAmount) internal virtual returns (uint256 rbtcReceived);
}
