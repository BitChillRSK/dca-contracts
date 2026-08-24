// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {TokenHandler} from "src/TokenHandler.sol";
import {ILToken} from "./ILToken.sol";
import {ILayerBankCore} from "./ILayerBankCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenLending} from "src/TokenLending.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title LayerBankErc20Handler
 * @notice Stablecoin functions that are common regardless of the method used to swap stablecoin for rBTC.
 * @dev LayerBank lTokens are `onlyCore`. Supply and redeem go through Core; the lToken pulls DOC
 *      from this handler. Per-user virtual lToken balances are exact and owned here.
 */
abstract contract LayerBankErc20Handler is TokenHandler, TokenLending {
    using SafeERC20 for IERC20;

    error LayerBankErc20Handler__CoreNotSet();
    error LayerBankErc20Handler__UnderlyingMismatch();

    //////////////////////
    // State variables ///
    //////////////////////
    ILToken public immutable i_lToken;
    ILayerBankCore public immutable i_core;
    mapping(address user => uint256 balance) internal s_lTokenBalances;

    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param stableTokenAddress the address of the ERC20 stablecoin token on the blockchain of deployment
     * @param lTokenAddress the address of LayerBank's lToken for this stablecoin
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address lTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 exchangeRateDecimals
    )
        TokenHandler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings)
        TokenLending(exchangeRateDecimals)
    {
        i_lToken = ILToken(lTokenAddress);
        if (i_lToken.underlying() != stableTokenAddress) revert LayerBankErc20Handler__UnderlyingMismatch();
        // LayerBank `setCore` is one-shot; snapshotting matches that immutability.
        address core = i_lToken.core();
        if (core == address(0)) revert LayerBankErc20Handler__CoreNotSet();
        i_core = ILayerBankCore(core);
    }

    /**
     * @notice deposit the full token amount for DCA on the contract
     * @param user: the address of the user making the deposit
     * @param depositAmount: the amount requested from the user
     * @return depositedAmount the stablecoin amount actually received before minting lTokens
     */
    function depositToken(address user, uint256 depositAmount)
        public
        override(TokenHandler, ITokenHandler)
        onlyDcaManager
        returns (uint256 depositedAmount)
    {
        depositedAmount = super.depositToken(user, depositAmount);
        if (i_stableToken.allowance(address(this), address(i_lToken)) < depositedAmount) {
            i_stableToken.safeApprove(address(i_lToken), depositedAmount);
        }
        // @notice the lToken we credit is the balance we actually gained, never Core.supply()'s return
        uint256 prevLtokenBalance = i_lToken.balanceOf(address(this));
        i_core.supply(address(i_lToken), depositedAmount);
        uint256 mintedAmount = i_lToken.balanceOf(address(this)) - prevLtokenBalance;
        if (mintedAmount == 0) revert TokenLending__LendingProtocolDepositFailed();
        s_lTokenBalances[user] += mintedAmount;
    }

    /**
     * @notice withdraw the token amount sending it back to the user's address
     * @param user: the address of the user making the withdrawal
     * @param withdrawalAmount: the amount to withdraw
     * @return withdrawnAmount the amount that left this contract after redeeming
     */
    function withdrawToken(address user, uint256 withdrawalAmount)
        public
        override(TokenHandler, ITokenHandler)
        onlyDcaManager
        returns (uint256)
    {
        uint256 exchangeRate = i_lToken.accruedExchangeRate();
        uint256 stablecoinInLayerBank = _lendingTokenToStablecoin(s_lTokenBalances[user], exchangeRate);
        if (stablecoinInLayerBank < withdrawalAmount) {
            emit TokenLending__WithdrawalAmountAdjusted(user, withdrawalAmount, stablecoinInLayerBank);
            withdrawalAmount = stablecoinInLayerBank;
        }
        // @notice we pay out what the redemption actually produced, which may be less than requested
        withdrawalAmount = _redeemLendingToken(user, withdrawalAmount, exchangeRate);
        return super.withdrawToken(user, withdrawalAmount);
    }

    /**
     * @notice get the users lending token balance
     * @param user: the address of the user
     * @return the users lending token balance
     */
    function getUsersLendingTokenBalance(address user) external view override returns (uint256) {
        return s_lTokenBalances[user];
    }

    /**
     * @notice withdraw the interest
     * @param user: the address of the user
     * @param stablecoinLockedInDcaSchedules: the amount of stablecoin locked in DCA schedules
     */
    function withdrawInterest(address user, uint256 stablecoinLockedInDcaSchedules) external override onlyDcaManager {
        uint256 exchangeRate = i_lToken.accruedExchangeRate();
        uint256 totalStablecoinInLending = _lendingTokenToStablecoin(s_lTokenBalances[user], exchangeRate);
        if (totalStablecoinInLending <= stablecoinLockedInDcaSchedules) {
            return; // No interest to withdraw
        }
        uint256 stablecoinInterestAmount = totalStablecoinInLending - stablecoinLockedInDcaSchedules;
        uint256 stablecoinReceived = _burnLtoken(user, stablecoinInterestAmount, exchangeRate);

        i_stableToken.safeTransfer(user, stablecoinReceived);
        emit TokenLending__InterestWithdrawn(user, address(i_stableToken), stablecoinReceived);
    }

    function getAccruedInterest(address user, uint256 stablecoinLockedInDcaSchedules)
        external
        view
        override
        onlyDcaManager
        returns (uint256 stablecoinInterestAmount)
    {
        uint256 totalStablecoinInLending = _lendingTokenToStablecoin(s_lTokenBalances[user], i_lToken.exchangeRate());
        stablecoinInterestAmount = totalStablecoinInLending > stablecoinLockedInDcaSchedules
            ? totalStablecoinInLending - stablecoinLockedInDcaSchedules
            : 0;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice retrieve the user's stablecoin by redeeming lToken
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @return the amount of stablecoin this contract actually received
     */
    function _retrieveStablecoin(address user, uint256 stablecoinAmount) internal virtual returns (uint256) {
        return _redeemLendingToken(user, stablecoinAmount, i_lToken.accruedExchangeRate());
    }

    /**
     * @notice redeem enough lToken to get `stablecoinAmount` of stablecoin onto this contract
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @return the amount of stablecoin this contract actually received
     */
    function _redeemLendingToken(address user, uint256 stablecoinAmount, uint256 exchangeRate)
        internal
        virtual
        returns (uint256)
    {
        return _redeemLendingTokenInternal(user, stablecoinAmount, exchangeRate, true);
    }

    /**
     * @notice redeem the user's lToken by share count instead of by underlying amount
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @return stablecoinReceived the amount of stablecoin this contract actually received
     */
    function _burnLtoken(address user, uint256 stablecoinAmount, uint256 exchangeRate)
        internal
        returns (uint256 stablecoinReceived)
    {
        return _redeemLendingTokenInternal(user, stablecoinAmount, exchangeRate, false);
    }

    /**
     * @notice Internal lToken redemption, sized either by underlying amount or by share count
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @param redeemUnderlying: true to call Core.redeemUnderlying, false to call Core.redeemToken
     * @return stablecoinReceived the amount of stablecoin this contract actually received
     */
    function _redeemLendingTokenInternal(
        address user,
        uint256 stablecoinAmount,
        uint256 exchangeRate,
        bool redeemUnderlying
    ) internal returns (uint256 stablecoinReceived) {
        uint256 usersLtokenBalance = s_lTokenBalances[user];
        uint256 lTokenToRepay = _stablecoinToLendingToken(stablecoinAmount, exchangeRate);
        if (lTokenToRepay > usersLtokenBalance) {
            uint256 oldLtokenToRepay = lTokenToRepay;
            uint256 oldStablecoinAmount = stablecoinAmount;
            lTokenToRepay = usersLtokenBalance;
            stablecoinAmount = _lendingTokenToStablecoin(lTokenToRepay, exchangeRate);
            emit TokenLending__AmountToRepayAdjusted(
                user, oldLtokenToRepay, lTokenToRepay, oldStablecoinAmount, stablecoinAmount
            );
        }
        // @notice Solvency: LayerBank Market._redeem burns
        // `uAmountIn.mul(1e18).div(exchangeRate())` (round down). We debit
        // `_stablecoinToLendingToken` (Math.Rounding.Up). Debiting >= the
        // shares LayerBank burns keeps `sum(s_lTokenBalances)` <= the handler's
        // real lToken balance. Flipping either side to round down breaks this;
        // no existing test would catch it.
        s_lTokenBalances[user] -= lTokenToRepay;
        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));

        if (redeemUnderlying) {
            i_core.redeemUnderlying(address(i_lToken), stablecoinAmount);
        } else {
            i_core.redeemToken(address(i_lToken), lTokenToRepay);
        }

        stablecoinReceived = i_stableToken.balanceOf(address(this)) - stablecoinBalanceBefore;
        // @notice a success with no stablecoin received still burnt the user's lToken, so revert
        // instead of paying out zero
        if (stablecoinAmount > 0 && stablecoinReceived == 0) {
            revert TokenLending__ZeroStablecoinReceived(stablecoinAmount);
        }
        emit TokenLending__LendingTokenRedeemed(user, stablecoinReceived, lTokenToRepay);
    }

    /**
     * @notice retrieve several users' stablecoin in one lToken redemption
     * @param users: the addresses of the users
     * @param purchaseAmounts: the amounts of stablecoin charged to each user
     * @param totalStablecoinAmount: the total amount of stablecoin wanted
     * @return the amount of stablecoin this contract actually received
     */
    function _batchRetrieveStablecoin(
        address[] memory users,
        uint256[] memory purchaseAmounts,
        uint256 totalStablecoinAmount
    ) internal virtual returns (uint256) {
        uint256 totalLtokenToRepay = _stablecoinToLendingToken(totalStablecoinAmount, i_lToken.accruedExchangeRate());
        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            // @notice the amount of lToken each user repays is proportional to the ratio of
            // that user's stablecoin being retrieved over the total being retrieved
            // @notice Rounds up the lending token amount to avoid underestimating the amount to subtract from each user's balance
            // @notice Same solvency pairing as the single-redeem debit: LayerBank `_redeem` rounds the share burn down; we round the virtual debit up. Flipping either side breaks `sum(s_lTokenBalances)` <= real lToken balance, and no test would catch it.
            uint256 usersRepaidLtoken =
                Math.mulDiv(totalLtokenToRepay, purchaseAmounts[i], totalStablecoinAmount, Math.Rounding.Up);
            uint256 usersLtokenBalance = s_lTokenBalances[users[i]];
            if (usersRepaidLtoken > usersLtokenBalance) {
                revert TokenLending__InsufficientLendingTokenBalance(users[i], usersRepaidLtoken, usersLtokenBalance);
            }
            s_lTokenBalances[users[i]] = usersLtokenBalance - usersRepaidLtoken;
            emit TokenLending__LendingTokenRedeemed(users[i], purchaseAmounts[i], usersRepaidLtoken);
        }

        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));
        i_core.redeemUnderlying(address(i_lToken), totalStablecoinAmount);
        uint256 stablecoinReceived = i_stableToken.balanceOf(address(this)) - stablecoinBalanceBefore;
        if (stablecoinReceived > 0) emit TokenLending__LendingTokenRedeemedBatch(stablecoinReceived, totalLtokenToRepay);
        else revert TokenLending__ZeroStablecoinReceived(totalStablecoinAmount);
        return stablecoinReceived;
    }
}
