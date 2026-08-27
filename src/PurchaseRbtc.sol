// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {DcaManagerAccessControl} from "./DcaManagerAccessControl.sol";
import {FeeHandler} from "./FeeHandler.sol";
import {StablecoinSource} from "./StablecoinSource.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PurchaseRbtc
 * @notice Shared rBTC purchase pipeline, accumulated-balance accounting, and signer withdrawals
 */
abstract contract PurchaseRbtc is IPurchaseRbtc, FeeHandler, DcaManagerAccessControl, StablecoinSource {
    //////////////////////
    // State variables ///
    //////////////////////
    mapping(address user => uint256 amount) internal s_usersAccumulatedRbtc;

    /**
     * @notice Allow the contract to receive rBTC
     */
    receive() external payable {}

    /**
     * @notice batch buy rBTC
     * @param buyers: the users on behalf of which the contract is making the rBTC purchase
     * @param scheduleIds: the schedule ids
     * @param purchaseAmounts: the amounts to spend on rBTC
     */
    function batchBuyRbtc(address[] memory buyers, bytes32[] memory scheduleIds, uint256[] memory purchaseAmounts)
        external
        override
        onlyDcaManager
    {
        uint256 numOfPurchases = buyers.length;

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

        for (uint256 i; i < numOfPurchases; ++i) {
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
     * @notice the user can at any time withdraw the rBTC that has been accumulated through periodical purchases
     * @param user: the user to withdraw the rBTC to
     */
    function withdrawAccumulatedRbtc(address user) external virtual override onlyDcaManager {
        uint256 rbtcBalance = _withdrawRbtcChecksEffects(user);
        _withdrawRbtc(user, rbtcBalance);
    }

    /**
     * @notice get the accumulated rBTC balance for a specific user
     * @param user the address of the user to check the accumulated rBTC balance for
     * @return the accumulated rBTC balance
     */
    function getAccumulatedRbtcBalance(address user) external view override returns (uint256) {
        return s_usersAccumulatedRbtc[user];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice checks and effects for the withdrawal of rBTC from the contract
     * @param user: the user to withdraw the rBTC to
     * @return the amount of rBTC to withdraw
     */
    function _withdrawRbtcChecksEffects(address user) internal returns (uint256) {
        uint256 rbtcBalance = s_usersAccumulatedRbtc[user];
        if (rbtcBalance == 0) revert PurchaseRbtc__NoAccumulatedRbtcToWithdraw();

        s_usersAccumulatedRbtc[user] = 0;
        return rbtcBalance;
    }

    /**
     * @notice withdraw rBTC from the contract
     * @param user: the user to withdraw the rBTC to
     * @param rbtcBalance: the amount of rBTC to withdraw
     */
    function _withdrawRbtc(address user, uint256 rbtcBalance) internal {
        (bool sent,) = user.call{value: rbtcBalance}("");
        if (!sent) revert PurchaseRbtc__rBtcWithdrawalFailed();
        emit PurchaseRbtc__rBtcWithdrawn(user, rbtcBalance);
    }

    /**
     * @notice spend `stablecoinAmount` of net stablecoin and return only measured rBTC or WRBTC received
     * @param stablecoinAmount the net stablecoin amount to spend after fees
     * @return rbtcReceived the measured native rBTC or WRBTC this contract actually received
     */
    function _purchaseRbtc(uint256 stablecoinAmount) internal virtual returns (uint256 rbtcReceived);
}
