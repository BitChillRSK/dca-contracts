// SPDX-License-Identifier: BUSL-1.1
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

    /// @dev Encoded claimable rBTC. `0` means never credited; a live value is `claimable + 1`
    ///      (including post-withdraw sentinel `1`). Keeps the slot nonzero so the next credit after a
    ///      full withdrawal is a cheaper nonzero-to-nonzero SSTORE. Getters and withdrawals decode.
    ///      Private so leaves cannot bypass `_creditRbtc` / `_claimableRbtc` / `_withdrawRbtcChecksEffects`.
    mapping(address user => uint256 encodedAmount) private s_usersAccumulatedRbtc;

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Allow the contract to receive native rBTC from MoC or from unwrapping WRBTC.
     */
    receive() external payable {}

    /**
     * @inheritdoc IPurchaseRbtc
     * @dev Spends the stablecoin the retrieval actually delivered, never the gross amount it was asked
     *      for: a lending handler can come back short when it redeems its shares, while the idle handler
     *      reverts rather than under-deliver. Planned net amounts are only allocation weights: both the
     *      rBTC credited and the stablecoin reported as spent are shares of what actually moved.
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

        // `aggregatedFee` is scoped to this block because it is dead once the fee is paid.
        {
            uint256 aggregatedFee;
            // Calculate net amounts
            (aggregatedFee, netStablecoinAmountsToSpend, totalNetStablecoinPlanned) =
                _calculateFeeAndNetAmounts(purchaseAmounts);

            // Retrieve the stablecoin to spend: the net amount destined for rBTC plus the fee BitChill
            // charges. What comes back is what the retrieval delivered, which a lending handler can leave
            // short of the request.
            totalStablecoinAmountToSpend =
                _batchRetrieveStablecoin(buyers, purchaseAmounts);
            if (totalStablecoinAmountToSpend <= aggregatedFee) {
                revert PurchaseRbtc__StablecoinRetrievedBelowFee(totalStablecoinAmountToSpend, aggregatedFee);
            }
            unchecked {
                totalStablecoinAmountToSpend -= aggregatedFee;
            }

            purchaseToken = _purchaseToken();
            _transferFee(purchaseToken, aggregatedFee);
        }

        uint256 inputBalanceBefore = purchaseToken.balanceOf(address(this));
        uint256 totalPurchasedRbtc = _purchaseRbtc(totalStablecoinAmountToSpend, minRbtcOut);
        uint256 inputBalanceAfter = purchaseToken.balanceOf(address(this));
        if (
            inputBalanceAfter > inputBalanceBefore
                || inputBalanceBefore - inputBalanceAfter != totalStablecoinAmountToSpend
        ) {
            revert PurchaseRbtc__InputAmountNotFullySpent(
                totalStablecoinAmountToSpend, inputBalanceBefore, inputBalanceAfter
            );
        }
        if (totalPurchasedRbtc == 0) revert PurchaseRbtc__RbtcBatchPurchaseFailed(address(purchaseToken));
        // Checked against the rBTC we measured ourselves receiving, so the bound holds on every purchase
        // venue and never trusts an integrator return value. Equality passes. Where the venue applies a
        // floor of its own, it is enforced there and the stricter of the two decides.
        if (totalPurchasedRbtc < minRbtcOut) {
            revert PurchaseRbtc__BelowSwapperMinimum(totalPurchasedRbtc, minRbtcOut);
        }

        uint256 numOfPurchases = buyers.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            // Planned nets are allocation weights only: they sum to totalNetStablecoinPlanned, so each row
            // takes its share of what actually moved even if the redemption paid less than planned. Both
            // shares floor, which can leave under one wei of rBTC per row uncredited; see IPurchaseRbtc.
            uint256 plannedNet = netStablecoinAmountsToSpend[i];
            address buyer = buyers[i];
            uint256 usersPurchasedRbtc = totalPurchasedRbtc * plannedNet / totalNetStablecoinPlanned;
            uint256 usersStablecoinSpent = totalStablecoinAmountToSpend * plannedNet / totalNetStablecoinPlanned;
            // Skip zero floor allocations so a never-credited user is not marked live.
            if (usersPurchasedRbtc != 0) _creditRbtc(buyer, usersPurchasedRbtc);
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
        return _claimableRbtc(user);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Decode claimable rBTC, revert if none, and leave the post-withdraw sentinel. Caller then pays.
     */
    function _withdrawRbtcChecksEffects(address user) internal returns (uint256 rbtcBalance) {
        uint256 stored = s_usersAccumulatedRbtc[user];
        // `0` = never credited; `1` = fully withdrawn sentinel. Both mean nothing to pay.
        if (stored <= 1) revert PurchaseRbtc__NoAccumulatedRbtcToWithdraw();

        unchecked {
            rbtcBalance = stored - 1;
        }
        s_usersAccumulatedRbtc[user] = 1;
    }

    /**
     * @dev Claimable rBTC for `user`. Decodes the `claimable + 1` encoding; `0` / sentinel `1` both
     *      return 0 so callers never see dust.
     */
    function _claimableRbtc(address user) internal view returns (uint256) {
        uint256 stored = s_usersAccumulatedRbtc[user];
        unchecked {
            return stored == 0 ? 0 : stored - 1;
        }
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
     *      The caller proves exact purchase-token consumption around this call.
     */
    function _purchaseRbtc(uint256 stablecoinAmount, uint256 minRbtcOut) internal virtual returns (uint256 rbtcReceived);

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Encode and store a positive rBTC credit. Live slots hold `claimable + 1`.
     */
    function _creditRbtc(address buyer, uint256 amount) private {
        uint256 stored = s_usersAccumulatedRbtc[buyer];
        s_usersAccumulatedRbtc[buyer] = (stored == 0 ? 1 : stored) + amount;
    }
}
