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
    mapping(address account => uint256 encodedAmount) private s_accumulatedRbtc;

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
     *      amount. Net weights and the total fee allocate measured output over `purchaseAmountsSum`:
     *      buyer credits and the protocol fee are floored shares of measured output. Reported spend
     *      is each row's share of retrieved gross. The collector's share is credited to the same
     *      accumulated-rBTC books last; it withdraws like any other account.
     */
    function batchBuyRbtc(
        address[] calldata buyers,
        uint64[] calldata scheduleIds,
        uint256[] calldata purchaseAmounts,
        uint256 minRbtcOut
    ) external override onlyDcaManager {
        uint256[] memory netWeights;
        uint256 purchaseAmountsSum;
        uint256 totalFee;
        uint256 totalStablecoinRetrieved;

        {
            (totalFee, netWeights, purchaseAmountsSum) = _calculateFeeAndNetWeights(purchaseAmounts);

            // Retrieve against `purchaseAmounts`. What comes back is what the retrieval delivered,
            // which a lending handler can leave short of the request. The venue spends that amount in
            // full.
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

        // Can't overflow: the rBTC total is under the native supply (< 2^85 wei) and the total fee is a
        // fraction of purchaseAmountsSum (capped at 5% of uint96 purchase amounts).
        uint256 feeRbtc;
        unchecked {
            feeRbtc = totalPurchasedRbtc * totalFee / purchaseAmountsSum;
        }

        _creditPurchases(
            buyers,
            scheduleIds,
            purchaseAmounts,
            netWeights,
            totalPurchasedRbtc,
            purchaseAmountsSum,
            totalStablecoinRetrieved
        );
        emit PurchaseRbtc__SuccessfulRbtcBatchPurchase(
            address(i_stablecoin), totalPurchasedRbtc, totalStablecoinRetrieved
        );
        // Fee last: buyer credits and the batch event are already in the frame. The collector is
        // credited on the same books and withdraws through `withdrawAccumulatedRbtc`.
        _payFee(feeRbtc, totalFee, purchaseAmountsSum, totalStablecoinRetrieved);
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
     * @dev `netWeights` are allocation weights over `purchaseAmountsSum`: each row takes its share of
     *      measured output even if the redemption paid less than requested. Both the fee and each row
     *      floor, which can leave under one wei of rBTC per term uncredited; see IPurchaseRbtc.
     *      Split out of `batchBuyRbtc` so the purchase path compiles under legacy codegen.
     */
    function _creditPurchases(
        address[] calldata buyers,
        uint64[] calldata scheduleIds,
        uint256[] calldata purchaseAmounts,
        uint256[] memory netWeights,
        uint256 totalPurchasedRbtc,
        uint256 purchaseAmountsSum,
        uint256 totalStablecoinRetrieved
    ) private {
        uint256 purchaseCount = buyers.length;
        for (uint256 i; i < purchaseCount; ++i) {
            uint256 userRbtc;
            unchecked {
                userRbtc = totalPurchasedRbtc * netWeights[i] / purchaseAmountsSum;
            }
            // Gross share of what the venue actually spent (all-in average price).
            uint256 userStablecoinSpent = totalStablecoinRetrieved * purchaseAmounts[i] / purchaseAmountsSum;
            // Skip zero floor allocations so a never-credited user is not marked live.
            if (userRbtc != 0) _creditRbtc(buyers[i], userRbtc);
            emit PurchaseRbtc__RbtcBought(
                buyers[i], address(i_stablecoin), userRbtc, scheduleIds[i], userStablecoinSpent
            );
        }
    }

    /**
     * @dev Credit `feeRbtc` to `s_feeCollector` on the same accumulated-rBTC books as buyers.
     *      `stablecoinAmount` is the fee's share of retrieved venue input so off-chain can compute
     *      BitChill's all-in price. No-op when the floored rBTC fee is zero.
     */
    function _payFee(uint256 feeRbtc, uint256 totalFee, uint256 purchaseAmountsSum, uint256 totalStablecoinRetrieved)
        private
    {
        if (feeRbtc == 0) return;
        uint256 feeStablecoin;
        unchecked {
            feeStablecoin = totalStablecoinRetrieved * totalFee / purchaseAmountsSum;
        }
        address collector = s_feeCollector;
        _creditRbtc(collector, feeRbtc);
        emit PurchaseFees__FeeCredited(collector, feeRbtc, feeStablecoin);
    }

    /**
     * @dev Encode and store a positive rBTC credit. Live slots hold `claimable + 1`.
     *      The add is unchecked: credits are shares of rBTC this handler measured receiving,
     *      which are tiny compared to `type(uint256).max`.
     */
    function _creditRbtc(address account, uint256 amount) private {
        uint256 stored = s_accumulatedRbtc[account];
        unchecked {
            s_accumulatedRbtc[account] = (stored == 0 ? 1 : stored) + amount;
        }
    }

    /// @dev Decode claimable rBTC, revert if none, and leave the post-withdraw sentinel. Caller then pays.
    function _withdrawRbtcChecksEffects(address user) private returns (uint256 rbtcBalance) {
        uint256 stored = s_accumulatedRbtc[user];
        // `0` = never credited; `1` = fully withdrawn sentinel. Both mean nothing to pay.
        if (stored <= 1) revert PurchaseRbtc__NoAccumulatedRbtcToWithdraw();

        unchecked {
            rbtcBalance = stored - 1;
        }
        s_accumulatedRbtc[user] = 1;
    }

    /**
     * @dev Claimable rBTC for `user`. Decodes the `claimable + 1` encoding; `0` / sentinel `1` both
     *      return 0 so callers never see dust.
     */
    function _claimableRbtc(address user) private view returns (uint256) {
        uint256 stored = s_accumulatedRbtc[user];
        unchecked {
            return stored == 0 ? 0 : stored - 1;
        }
    }
}
