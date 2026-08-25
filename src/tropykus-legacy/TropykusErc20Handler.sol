// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {TokenHandler} from "src/TokenHandler.sol";
import {IkToken} from "./IkToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenLending} from "src/TokenLending.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TropykusErc20Handler
 * @notice This abstract contract contains the functions that are common regardless of the method used to swap ERC20 stablecoin for rBTC
 */
abstract contract TropykusErc20Handler is TokenHandler, TokenLending {
    using SafeERC20 for IERC20;

    //////////////////////
    // State variables ///
    //////////////////////
    IkToken public immutable i_kToken;
    mapping(address user => uint256 balance) internal s_kTokenBalances;

    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param stableTokenAddress the address of the ERC20 stablecoin token on the blockchain of deployment
     * @param kTokenAddress the address of Tropykus'  kToken token contract
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address kTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 exchangeRateDecimals
    )
        TokenHandler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings)
        TokenLending(exchangeRateDecimals)
    {
        i_kToken = IkToken(kTokenAddress);
    }

    /**
     * @notice deposit the full token amount for DCA on the contract
     * @param user: the address of the user making the deposit
     * @param depositAmount: the amount requested from the user
     * @return depositedAmount the stablecoin amount actually received before minting kTokens
     */
    function depositToken(address user, uint256 depositAmount)
        public
        override(TokenHandler, ITokenHandler)
        onlyDcaManager
        returns (uint256 depositedAmount)
    {
        depositedAmount = super.depositToken(user, depositAmount);
        if (i_stableToken.allowance(address(this), address(i_kToken)) < depositedAmount) {
            i_stableToken.safeApprove(address(i_kToken), depositedAmount);
        }
        uint256 prevKtokenBalance = i_kToken.balanceOf(address(this));
        if(i_kToken.mint(depositedAmount) != 0) revert TokenLending__LendingProtocolDepositFailed();
        uint256 postKtokenBalance = i_kToken.balanceOf(address(this));
        s_kTokenBalances[user] += postKtokenBalance - prevKtokenBalance;
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
        uint256 exchangeRate = i_kToken.exchangeRateCurrent();
        uint256 stablecoinInTropykus = _lendingTokenToStablecoin(s_kTokenBalances[user], exchangeRate);
        if (stablecoinInTropykus < withdrawalAmount) {
            emit TokenLending__WithdrawalAmountAdjusted(user, withdrawalAmount, stablecoinInTropykus);
            withdrawalAmount = stablecoinInTropykus;
        }
        // @notice we pay out what the redemption actually produced, which may be less than requested
        withdrawalAmount = _redeemByUnderlying(user, withdrawalAmount, exchangeRate);
        return super.withdrawToken(user, withdrawalAmount);
    }

    /**
     * @notice get the users lending token balance
     * @param user: the address of the user
     * @return the users lending token balance
     */
    function getUsersLendingTokenBalance(address user) external view override returns (uint256) {
        return s_kTokenBalances[user];
    }

    /**
     * @notice withdraw the interest
     * @param user: the address of the user
     * @param stablecoinLockedInDcaSchedules: the amount of stablecoin locked in DCA schedules
     */
    function withdrawInterest(address user, uint256 stablecoinLockedInDcaSchedules) external override onlyDcaManager {
        uint256 exchangeRate = i_kToken.exchangeRateCurrent();
        uint256 totalStablecoinInLending = _lendingTokenToStablecoin(s_kTokenBalances[user], exchangeRate);
        if (totalStablecoinInLending <= stablecoinLockedInDcaSchedules) {
            return; // No interest to withdraw
        }
        uint256 stablecoinInterestAmount = totalStablecoinInLending - stablecoinLockedInDcaSchedules;
        uint256 stablecoinReceived = _redeemByShares(user, stablecoinInterestAmount, exchangeRate);
        
        i_stableToken.safeTransfer(user, stablecoinReceived);
        emit TokenLending__InterestWithdrawn(user, address(i_stableToken), stablecoinReceived);
    }

    /**
     * @notice get the accrued interest
     * @param user: the address of the user
     * @param stablecoinLockedInDcaSchedules: the amount of stablecoin locked in DCA schedules
     * @return stablecoinInterestAmount the amount of accrued interest
     */
    function getAccruedInterest(address user, uint256 stablecoinLockedInDcaSchedules)
        external
        view
        override
        onlyDcaManager
        returns (uint256 stablecoinInterestAmount)
    {
        uint256 totalStablecoinInLending = _lendingTokenToStablecoin(s_kTokenBalances[user], i_kToken.exchangeRateStored());
        stablecoinInterestAmount = totalStablecoinInLending > stablecoinLockedInDcaSchedules ? totalStablecoinInLending - stablecoinLockedInDcaSchedules : 0;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice retrieve the user's stablecoin by redeeming kToken
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @return the amount of stablecoin this contract actually received
     */
    function _retrieveStablecoin(address user, uint256 stablecoinAmount) internal virtual returns (uint256) {
        return _redeemByUnderlying(user, stablecoinAmount, i_kToken.exchangeRateCurrent());
    }

    /**
     * @notice redeem the user's kToken sized by underlying: ask Tropykus for `stablecoinAmount` of stablecoin
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @return the amount of stablecoin this contract actually received
     */
    function _redeemByUnderlying(address user, uint256 stablecoinAmount, uint256 exchangeRate) internal virtual returns (uint256) {
        return _redeemLendingTokenInternal(user, stablecoinAmount, exchangeRate, true);
    }

    /**
     * @notice redeem the user's kToken sized by shares: burn the share count `stablecoinAmount` converts to
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @return stablecoinReceived the amount of stablecoin this contract actually received
     */
    function _redeemByShares(address user, uint256 stablecoinAmount, uint256 exchangeRate)
        internal
        returns (uint256 stablecoinReceived)
    {
        return _redeemLendingTokenInternal(user, stablecoinAmount, exchangeRate, false);
    }

    /**
     * @notice Internal kToken redemption, sized either by underlying amount or by share count
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @param sizeByUnderlying: true to call kToken's redeemUnderlying, false to call its redeem
     * @return stablecoinReceived the amount of stablecoin this contract actually received
     */
    function _redeemLendingTokenInternal(address user, uint256 stablecoinAmount, uint256 exchangeRate, bool sizeByUnderlying) 
        internal 
        returns (uint256 stablecoinReceived) 
    {
        uint256 usersKtokenBalance = s_kTokenBalances[user];
        uint256 kTokenToRedeem = _stablecoinToLendingToken(stablecoinAmount, exchangeRate);
        if (kTokenToRedeem > usersKtokenBalance) {
            uint256 oldKtokenToRedeem = kTokenToRedeem;
            uint256 oldStablecoinAmount = stablecoinAmount;
            kTokenToRedeem = usersKtokenBalance;
            stablecoinAmount = _lendingTokenToStablecoin(kTokenToRedeem, exchangeRate);
            emit TokenLending__AmountToRedeemAdjusted(user, oldKtokenToRedeem, kTokenToRedeem, oldStablecoinAmount, stablecoinAmount);
        }
        s_kTokenBalances[user] -= kTokenToRedeem;
        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));
        
        uint256 result;
        if (sizeByUnderlying) {
            result = i_kToken.redeemUnderlying(stablecoinAmount);
        } else {
            result = i_kToken.redeem(kTokenToRedeem);
        }
        
        if (result == 0) {
            uint256 stablecoinBalanceAfter = i_stableToken.balanceOf(address(this));
            stablecoinReceived = stablecoinBalanceAfter - stablecoinBalanceBefore;
            // @notice a success code with no stablecoin received still burnt the user's kToken, so revert
            // instead of paying out zero
            if (stablecoinAmount > 0 && stablecoinReceived == 0) {
                revert TokenLending__ZeroStablecoinReceived(stablecoinAmount);
            }
            emit TokenLending__LendingTokenRedeemed(user, stablecoinReceived, kTokenToRedeem);
        } else {
            revert TokenLending__LendingProtocolRedeemFailed(result);
        }
    }

    /**
     * @notice retrieve several users' stablecoin in one kToken redemption
     * @param users: the addresses of the users
     * @param purchaseAmounts: the amounts of stablecoin charged to each user
     * @param totalStablecoinAmount: the total amount of stablecoin wanted
     * @return the amount of stablecoin this contract actually received
     */
    function _batchRetrieveStablecoin(address[] memory users, uint256[] memory purchaseAmounts, uint256 totalStablecoinAmount)
        internal
        virtual
        returns (uint256)
    {
        uint256 totalKtokenToRedeem = _stablecoinToLendingToken(totalStablecoinAmount, i_kToken.exchangeRateCurrent());
        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            // @notice the amount of kToken each user redeems is proportional to the ratio of
            // that user's stablecoin being retrieved over the total being retrieved
            // @notice Rounds up the lending token amount to avoid underestimating the amount to subtract from each user's balance
            uint256 usersKtokenToRedeem = Math.mulDiv(totalKtokenToRedeem, purchaseAmounts[i], totalStablecoinAmount, Math.Rounding.Up);
            uint256 usersKtokenBalance = s_kTokenBalances[users[i]];
            if (usersKtokenToRedeem > usersKtokenBalance) {
                revert TokenLending__InsufficientLendingTokenBalance(users[i], usersKtokenToRedeem, usersKtokenBalance);
            }
            s_kTokenBalances[users[i]] = usersKtokenBalance - usersKtokenToRedeem;
            emit TokenLending__LendingTokenRedeemed(users[i], purchaseAmounts[i], usersKtokenToRedeem);
        }
        
        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));
        uint256 result = i_kToken.redeemUnderlying(totalStablecoinAmount);
        if (result == 0) {
            uint256 stablecoinBalanceAfter = i_stableToken.balanceOf(address(this));
            uint256 stablecoinReceived = stablecoinBalanceAfter - stablecoinBalanceBefore;
            
            emit TokenLending__LendingTokenRedeemedBatch(stablecoinReceived, totalKtokenToRedeem);
            return stablecoinReceived;
        }
        else revert TokenLending__LendingProtocolRedeemFailed(result);
    }
}
