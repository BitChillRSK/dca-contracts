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
     * @param feeConfig Collector and purchase fee settings.
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

    /// @inheritdoc IPurchaseRbtc
    function batchBuyRbtc(
        address[] calldata buyers,
        uint64[] calldata scheduleIds,
        uint256[] calldata purchaseAmounts,
        uint256 minRbtcOut
    ) external override onlyDcaManager {
        uint256[] memory netWeights;
        uint256 purchaseAmountsSum;
        uint256 totalFee;
        uint256[] memory fundedAmounts = purchaseAmounts;
        // The funding hook may reduce a row's weight in place.
        uint256 totalStablecoinRetrieved = _batchRetrieveStablecoin(buyers, fundedAmounts);
        (totalFee, netWeights, purchaseAmountsSum) = _calculateFeeAndNetWeights(fundedAmounts);

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
        // Gross measured Q — never trusts an integrator return. Equality passes.
        if (totalPurchasedRbtc < minRbtcOut) {
            revert PurchaseRbtc__BelowSwapperMinimum(totalPurchasedRbtc, minRbtcOut);
        }

        // Can't overflow: rBTC < 2^85 wei; totalFee ≤ 5% of uint96 purchase amounts.
        uint256 feeRbtc;
        unchecked {
            feeRbtc = totalPurchasedRbtc * totalFee / purchaseAmountsSum;
        }

        _creditPurchases(
            buyers,
            scheduleIds,
            fundedAmounts,
            netWeights,
            totalPurchasedRbtc,
            purchaseAmountsSum,
            totalStablecoinRetrieved
        );
        emit PurchaseRbtc__SuccessfulRbtcBatchPurchase(
            address(i_stablecoin), totalPurchasedRbtc, totalStablecoinRetrieved
        );
        _creditFee(feeRbtc, totalFee, purchaseAmountsSum, totalStablecoinRetrieved);
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
     * @dev Spend `stablecoinAmount` of stablecoin; return only measured rBTC/WRBTC.
     *      Caller proves exact purchase-token consumption. Amount is retrieved gross; the fee is
     *      taken from measured output afterward.
     */
    function _purchaseRbtc(uint256 stablecoinAmount, uint256 minRbtcOut) internal virtual returns (uint256 rbtcReceived);

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Allocate floored shares of measured output. Split out of `batchBuyRbtc` for legacy codegen.
     *      Fee and each row floor; under one wei per term can stay uncredited — see IPurchaseRbtc.
     * @param purchaseAmounts Per-row funded weights.
     */
    function _creditPurchases(
        address[] calldata buyers,
        uint64[] calldata scheduleIds,
        uint256[] memory purchaseAmounts,
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
            uint256 userStablecoinSpent = totalStablecoinRetrieved * purchaseAmounts[i] / purchaseAmountsSum;
            // Skip zero floors so a never-credited user is not marked live.
            if (userRbtc != 0) _creditRbtc(buyers[i], userRbtc);
            emit PurchaseRbtc__RbtcBought(
                buyers[i], address(i_stablecoin), userRbtc, scheduleIds[i], userStablecoinSpent
            );
        }
    }

    /**
     * @dev Credit `floor(Q × F / G)` rBTC; emit `floor(retrieved × F / G)` stablecoin. No-op at zero.
     */
    function _creditFee(uint256 feeRbtc, uint256 totalFee, uint256 purchaseAmountsSum, uint256 totalStablecoinRetrieved)
        private
    {
        if (feeRbtc == 0) return;
        uint256 feeStablecoin = totalStablecoinRetrieved * totalFee / purchaseAmountsSum;
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
