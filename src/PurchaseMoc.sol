// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FeeHandler} from "./FeeHandler.sol";
import {PurchaseRbtc} from "./PurchaseRbtc.sol";
import {IMocProxy} from "./interfaces/IMocProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPurchaseMoc} from "./interfaces/IPurchaseMoc.sol";

/**
 * @title PurchaseMoc
 * @notice This contract handles swaps of DOC for rBTC directly redeeming the latter from the MoC contract
 */
abstract contract PurchaseMoc is FeeHandler, PurchaseRbtc, IPurchaseMoc {
    using SafeERC20 for IERC20;

    //////////////////////
    // State variables ///
    //////////////////////
    IERC20 public immutable i_docToken;
    IMocProxy public immutable i_mocProxy;

    /**
     * @param docTokenAddress the address of the Dollar On Chain token on the blockchain of deployment
     * @param mocProxyAddress the address of the MoC proxy contract on the blockchain of deployment
     */
    constructor(
        address docTokenAddress,
        address mocProxyAddress
    )
    {
        i_mocProxy = IMocProxy(mocProxyAddress);
        i_docToken = IERC20(docTokenAddress);
    }

    /**
     * @param buyer: the user on behalf of which the contract is making the rBTC purchase
     * @param scheduleId: the schedule id
     * @param purchaseAmount: the amount to spend on rBTC
     * @notice this function will be called periodically through a CRON job running on a web server
     */
    function buyRbtc(address buyer, bytes32 scheduleId, uint256 purchaseAmount)
        external
        override
        onlyDcaManager
    {
        // Redeem DOC (repaying kDOC)
        purchaseAmount = _redeemStablecoin(buyer, purchaseAmount); 

        // Charge fee
        uint256 fee = _calculateFee(purchaseAmount);
        uint256 netPurchaseAmount = purchaseAmount - fee;
        _transferFee(i_docToken, fee);

        // Redeem rBTC repaying DOC
        (uint256 balancePrev, uint256 balancePost) = _redeemRbtc(netPurchaseAmount);

        if (balancePost > balancePrev) {
            s_usersAccumulatedRbtc[buyer] += (balancePost - balancePrev);
            emit PurchaseRbtc__RbtcBought(
                buyer, address(i_docToken), balancePost - balancePrev, scheduleId, netPurchaseAmount
            );
        } else {
            revert PurchaseRbtc__RbtcPurchaseFailed(buyer, address(i_docToken));
        }
    }

    /**
     * @notice batch buy rBTC
     * @param buyers: the users on behalf of which the contract is making the rBTC purchase
     * @param scheduleIds: the schedule ids
     * @param purchaseAmounts: the amounts to spend on rBTC
     */
    function batchBuyRbtc(
        address[] memory buyers,
        bytes32[] memory scheduleIds,
        uint256[] memory purchaseAmounts
    ) external override onlyDcaManager {
        uint256 numOfPurchases = buyers.length;

        // Calculate net amounts
        (uint256 aggregatedFee, uint256[] memory netDocAmountsToSpend, uint256 totalNetDocPlanned) =
            _calculateFeeAndNetAmounts(purchaseAmounts);

        // Redeem DOC (and repay kDOC)
        // @notice we spend the DOC we actually received, which might not match totalNetDocPlanned, the full amount we asked the lending protocol for
        uint256 totalDocAmountToSpend = _batchRedeemStablecoin(buyers, purchaseAmounts, totalNetDocPlanned + aggregatedFee); // total DOC to redeem by repaying kDOC in order to spend it to redeem rBTC is totalNetDocPlanned + aggregatedFee
        if (totalDocAmountToSpend <= aggregatedFee) {
            revert PurchaseRbtc__RedeemedAmountBelowFee(totalDocAmountToSpend, aggregatedFee);
        }
        totalDocAmountToSpend -= aggregatedFee;

        // Charge fees
        _transferFee(i_docToken, aggregatedFee);

        // Redeem DOC for rBTC
        uint256 totalPurchasedRbtc;
        {
            (uint256 balancePrev, uint256 balancePost) = _redeemRbtc(totalDocAmountToSpend);
            if (balancePost <= balancePrev) revert PurchaseRbtc__RbtcBatchPurchaseFailed(address(i_docToken));
            totalPurchasedRbtc = balancePost - balancePrev;
        }

        for (uint256 i; i < numOfPurchases; ++i) {
            // @notice the weights are shares of the planned net total, so they sum to exactly 1 even when the
            // redemption paid less than planned. Dividing by the smaller actual spend instead would credit
            // more rBTC than this contract received.
            uint256 usersPurchasedRbtc = totalPurchasedRbtc * netDocAmountsToSpend[i] / totalNetDocPlanned;
            s_usersAccumulatedRbtc[buyers[i]] += usersPurchasedRbtc;
            emit PurchaseRbtc__RbtcBought(
                buyers[i], address(i_docToken), usersPurchasedRbtc, scheduleIds[i], netDocAmountsToSpend[i]
            );
        }
        emit PurchaseRbtc__SuccessfulRbtcBatchPurchase(address(i_docToken), totalPurchasedRbtc, totalDocAmountToSpend);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice the guys at Money on Chain mistakenly named their functions as "redeem DOC", when it is rBTC that gets redeemed (by repaying DOC)
     * @param docAmountToSpend the amount of DOC to repay to redeem rBTC
     */
    function _redeemRbtc(uint256 docAmountToSpend) internal returns (uint256, uint256) {
        try i_mocProxy.redeemDocRequest(docAmountToSpend) {}
        catch {
            revert PurchaseMoc__RedeemDocRequestFailed();
        }
        uint256 balancePrev = address(this).balance;
        try i_mocProxy.redeemFreeDoc(docAmountToSpend) {}
        catch {
            revert PurchaseMoc__RedeemFreeDocFailed();
        }
        uint256 balancePost = address(this).balance;
        return (balancePrev, balancePost);
    }

}
