// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IPurchaseRbtc} from "./interfaces/IPurchaseRbtc.sol";
import {DcaManagerAccessControl} from "./DcaManagerAccessControl.sol";
import {PurchaseFees} from "./PurchaseFees.sol";
import {StablecoinSource} from "./StablecoinSource.sol";

/**
 * @title PurchaseRbtc
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Shared rBTC purchase pipeline, accumulated-balance accounting, and signer withdrawals.
 */
abstract contract PurchaseRbtc is IPurchaseRbtc, PurchaseFees, DcaManagerAccessControl, StablecoinSource {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Encoded claimable rBTC. `0` means never credited; a live value is `claimable + 1`
     *      (including post-withdraw sentinel `1`). Keeps the slot nonzero so the next credit after a
     *      full withdrawal is a cheaper nonzero-to-nonzero SSTORE. Getters and withdrawals decode.
     *      Private so leaves cannot bypass `_creditRbtc` / `_claimableRbtc` / `_withdrawRbtcChecksEffects`.
     */
    mapping(address user => uint256 encodedAmount) private s_usersAccumulatedRbtc;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param feeConfig Collector and interpolated fee settings.
     * @param initialOwner Address that owns this handler immediately after deploy.
     */
    constructor(FeeConfig memory feeConfig, address initialOwner)
        PurchaseFees(feeConfig.feeCollector, feeConfig.feeSettings, initialOwner)
    {}

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Allow the contract to receive native rBTC from MoC or from unwrapping WRBTC.
    receive() external payable {}

    /**
     * @inheritdoc IPurchaseRbtc
     * @dev Spends the stablecoin the retrieval actually delivered, never the gross amount it was asked
     *      for: a lending handler can come back short when it redeems its shares. Idle retrieval only sums
     *      the request, because the cash already sits on the handler; if it is not all there, the venue's
     *      pull or the exact-consumption check reverts the batch. The venue spends that full retrieved
     *      amount. Planned net weights and the aggregated fee allocate measured output over planned gross: buyer
     *      credits and the protocol fee are floored shares of measured output. Reported spend is each
     *      row's share of retrieved gross. The fee (native rBTC or WRBTC) is paid last.
     */
    function batchBuyRbtc(
        address[] calldata buyers,
        uint64[] calldata scheduleIds,
        uint256[] calldata purchaseAmounts,
        uint256 minRbtcOut
    ) external override onlyDcaManager {
        uint256[] memory netWeights;
        uint256 plannedGross;
        uint256 aggregatedFee;
        uint256 totalStablecoinRetrieved;

        {
            uint256 totalNetWeight;
            (aggregatedFee, netWeights, totalNetWeight) = _calculateFeeAndNetAmounts(purchaseAmounts);
            // Fee + net weights reconstruct the planned gross: each row's fee was peeled from its
            // purchase amount.
            unchecked {
                plannedGross = totalNetWeight + aggregatedFee;
            }

            // Retrieve the full planned gross. What comes back is what the retrieval delivered, which a
            // lending handler can leave short of the request. The venue spends that amount in full.
            totalStablecoinRetrieved = _batchRetrieveStablecoin(buyers, purchaseAmounts);
        }

        uint256 totalPurchasedRbtc;
        {
            uint256 inputBalanceBefore = i_stablecoin.balanceOf(address(this));
            totalPurchasedRbtc = _purchaseRbtc(totalStablecoinRetrieved, minRbtcOut);
            uint256 inputBalanceAfter = i_stablecoin.balanceOf(address(this));
            if (
                inputBalanceAfter > inputBalanceBefore
                    || inputBalanceBefore - inputBalanceAfter != totalStablecoinRetrieved
            ) {
                revert PurchaseRbtc__InputAmountNotFullySpent(
                    totalStablecoinRetrieved, inputBalanceBefore, inputBalanceAfter
                );
            }
        }
        if (totalPurchasedRbtc == 0) revert PurchaseRbtc__RbtcBatchPurchaseFailed(address(i_stablecoin));
        // Checked against the rBTC we measured ourselves receiving, so the bound holds on every purchase
        // venue and never trusts an integrator return value. Equality passes. Where the venue applies a
        // floor of its own, it is enforced there and the stricter of the two decides. The bound is on
        // gross measured output; buyer credits are the residual after the protocol fee and floor dust.
        if (totalPurchasedRbtc < minRbtcOut) {
            revert PurchaseRbtc__BelowSwapperMinimum(totalPurchasedRbtc, minRbtcOut);
        }

        // Can't overflow: the rBTC total is under the native supply (< 2^85 wei) and the fee weight is a
        // fraction of plannedGross (capped at 5% of uint96 purchase amounts).
        uint256 feeRbtc;
        unchecked {
            feeRbtc = totalPurchasedRbtc * aggregatedFee / plannedGross;
        }

        _creditPurchases(
            buyers, scheduleIds, purchaseAmounts, netWeights, totalPurchasedRbtc, plannedGross, totalStablecoinRetrieved
        );
        emit PurchaseRbtc__SuccessfulRbtcBatchPurchase(
            address(i_stablecoin), totalPurchasedRbtc, totalStablecoinRetrieved
        );
        // Fee last: buyer credits and events are already in the frame. A failing collector payment
        // reverts the whole batch rather than leaving partial accounting.
        _transferFee(feeRbtc);
    }

    /// @inheritdoc IPurchaseRbtc
    function withdrawAccumulatedRbtc(address user) external override onlyDcaManager {
        uint256 rbtcBalance = _withdrawRbtcChecksEffects(user);
        _withdrawRbtc(user, rbtcBalance);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPurchaseRbtc
    function getAccumulatedRbtcBalance(address user) external view override returns (uint256) {
        return _claimableRbtc(user);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Pay `rbtcBalance` native rBTC to `user`. Reverts if the call fails. A route whose purchases
     *      accumulate wrapped rBTC overrides this to unwrap first.
     */
    function _withdrawRbtc(address user, uint256 rbtcBalance) internal virtual {
        (bool sent,) = user.call{value: rbtcBalance}("");
        if (!sent) revert PurchaseRbtc__rBtcWithdrawalFailed();
        emit PurchaseRbtc__rBtcWithdrawn(user, rbtcBalance);
    }

    /**
     * @dev Spend `stablecoinAmount` of stablecoin and return only measured rBTC or WRBTC received.
     *      The caller proves exact purchase-token consumption around this call. The amount is the full
     *      retrieved gross — the protocol fee is taken from the measured output afterward.
     */
    function _purchaseRbtc(uint256 stablecoinAmount, uint256 minRbtcOut) internal virtual returns (uint256 rbtcReceived);

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev `netWeights` are allocation weights over planned gross: each row takes its share of
     *      measured output even if the redemption paid less than planned. Both the fee and each row
     *      floor, which can leave under one wei of rBTC per term uncredited; see IPurchaseRbtc.
     *      Split out of `batchBuyRbtc` so the purchase path compiles under legacy codegen.
     */
    function _creditPurchases(
        address[] calldata buyers,
        uint64[] calldata scheduleIds,
        uint256[] calldata purchaseAmounts,
        uint256[] memory netWeights,
        uint256 totalPurchasedRbtc,
        uint256 plannedGross,
        uint256 totalStablecoinRetrieved
    ) private {
        uint256 purchaseCount = buyers.length;
        for (uint256 i; i < purchaseCount; ++i) {
            uint256 userRbtc;
            unchecked {
                userRbtc = totalPurchasedRbtc * netWeights[i] / plannedGross;
            }
            // Gross share of what the venue actually spent (all-in average price).
            uint256 userStablecoinSpent = totalStablecoinRetrieved * purchaseAmounts[i] / plannedGross;
            // Skip zero floor allocations so a never-credited user is not marked live.
            if (userRbtc != 0) _creditRbtc(buyers[i], userRbtc);
            emit PurchaseRbtc__RbtcBought(
                buyers[i], address(i_stablecoin), userRbtc, scheduleIds[i], userStablecoinSpent
            );
        }
    }

    /**
     * @dev Encode and store a positive rBTC credit. Live slots hold `claimable + 1`.
     *      The add is unchecked: credits are shares of rBTC this handler measured receiving,
     *      which are tiny compared to `type(uint256).max`.
     */
    function _creditRbtc(address buyer, uint256 amount) private {
        uint256 stored = s_usersAccumulatedRbtc[buyer];
        unchecked {
            s_usersAccumulatedRbtc[buyer] = (stored == 0 ? 1 : stored) + amount;
        }
    }

    /// @dev Decode claimable rBTC, revert if none, and leave the post-withdraw sentinel. Caller then pays.
    function _withdrawRbtcChecksEffects(address user) private returns (uint256 rbtcBalance) {
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
    function _claimableRbtc(address user) private view returns (uint256) {
        uint256 stored = s_usersAccumulatedRbtc[user];
        unchecked {
            return stored == 0 ? 0 : stored - 1;
        }
    }
}
