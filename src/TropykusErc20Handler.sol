// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenHandler} from "./interfaces/ITokenHandler.sol";
import {TokenHandler} from "./TokenHandler.sol";
import {ITropykusErc20Lending} from "./interfaces/ITropykusErc20Lending.sol";
import {IkToken} from "./interfaces/IkToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenLending} from "src/TokenLending.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TropykusErc20Handler
 * @notice This abstract contract contains the functions that are common regardless of the method used to swap ERC20 stablecoin for rBTC
 */
abstract contract TropykusErc20Handler is TokenHandler, TokenLending, ITropykusErc20Lending {
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
     * @param depositAmount: the amount to deposit
     */
    function depositToken(address user, uint256 depositAmount)
        public
        override(TokenHandler, ITokenHandler)
        onlyDcaManager
    {
        super.depositToken(user, depositAmount);
        if (i_stableToken.allowance(address(this), address(i_kToken)) < depositAmount) {
            i_stableToken.safeApprove(address(i_kToken), depositAmount);
        }
        uint256 prevKtokenBalance = i_kToken.balanceOf(address(this));
        if(i_kToken.mint(depositAmount) != 0) revert TokenLending__LendingProtocolDepositFailed();
        uint256 postKtokenBalance = i_kToken.balanceOf(address(this));
        s_kTokenBalances[user] += postKtokenBalance - prevKtokenBalance;
    }

    /**
     * @notice withdraw the token amount sending it back to the user's address
     * @param user: the address of the user making the withdrawal
     * @param withdrawalAmount: the amount to withdraw
     * @return the amount of stablecoin actually paid to the user
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
        withdrawalAmount = _redeemStablecoin(user, withdrawalAmount, exchangeRate);
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
        uint256 stablecoinRedeemed = _burnKtoken(user, stablecoinInterestAmount, exchangeRate);
        
        i_stableToken.safeTransfer(user, stablecoinRedeemed);
        emit TokenLending__InterestWithdrawn(user, address(i_stableToken), stablecoinRedeemed);
    }

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
     * @notice redeem stablecoin
     * @param user: the address of the user
     * @param stablecoinToRedeem: the amount of stablecoin to redeem
     * @return stablecoinRedeemed: the amount of stablecoin redeemed
     */
    function _redeemStablecoin(address user, uint256 stablecoinToRedeem) internal virtual returns (uint256) {
        return _redeemStablecoin(user, stablecoinToRedeem, i_kToken.exchangeRateCurrent());
    }

    /**
     * @notice redeem stablecoin
     * @param user: the address of the user
     * @param stablecoinToRedeem: the amount of stablecoin to redeem
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @return stablecoinRedeemed: the amount of stablecoin redeemed
     */
    function _redeemStablecoin(address user, uint256 stablecoinToRedeem, uint256 exchangeRate) internal virtual returns (uint256) {
        return _redeemInternal(user, stablecoinToRedeem, exchangeRate, true);
    }

    /**
     * @notice burn kToken
     * @param user: the address of the user
     * @param stablecoinToRedeem: the amount of stablecoin to redeem
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @return stablecoinRedeemed the amount of stablecoin redeemed
     */
    function _burnKtoken(address user, uint256 stablecoinToRedeem, uint256 exchangeRate)
        internal
        returns (uint256 stablecoinRedeemed)
    {
        return _redeemInternal(user, stablecoinToRedeem, exchangeRate, false);
    }

    /**
     * @notice Internal redemption function that handles both underlying and kToken redemptions
     * @param user: the address of the user
     * @param stablecoinToRedeem: the amount of stablecoin to redeem
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @param redeemUnderlying: true to call redeemUnderlying, false to call redeem
     * @return stablecoinRedeemed the amount of stablecoin redeemed
     */
    function _redeemInternal(address user, uint256 stablecoinToRedeem, uint256 exchangeRate, bool redeemUnderlying) 
        internal 
        returns (uint256 stablecoinRedeemed) 
    {
        uint256 usersKtokenBalance = s_kTokenBalances[user];
        uint256 kTokenToRepay = _stablecoinToLendingToken(stablecoinToRedeem, exchangeRate);
        if (kTokenToRepay > usersKtokenBalance) {
            uint256 oldKtokenToRepay = kTokenToRepay;
            uint256 oldStablecoinToRedeem = stablecoinToRedeem;
            kTokenToRepay = usersKtokenBalance;
            stablecoinToRedeem = _lendingTokenToStablecoin(kTokenToRepay, exchangeRate);
            emit TokenLending__AmountToRepayAdjusted(user, oldKtokenToRepay, kTokenToRepay, oldStablecoinToRedeem, stablecoinToRedeem);
        }
        s_kTokenBalances[user] -= kTokenToRepay;
        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));
        
        uint256 result;
        if (redeemUnderlying) {
            result = i_kToken.redeemUnderlying(stablecoinToRedeem);
        } else {
            result = i_kToken.redeem(kTokenToRepay);
        }
        
        if (result == 0) {
            uint256 stablecoinBalanceAfter = i_stableToken.balanceOf(address(this));
            stablecoinRedeemed = stablecoinBalanceAfter - stablecoinBalanceBefore;
            // @notice a success code with no stablecoin received still burnt the user's kToken, so revert
            // instead of paying out zero
            if (stablecoinToRedeem > 0 && stablecoinRedeemed == 0) {
                revert TropykusErc20Lending__ZeroStablecoinRedeemed(stablecoinToRedeem);
            }
            emit TokenLending__UnderlyingRedeemed(user, stablecoinRedeemed, kTokenToRepay);
        } else {
            revert TropykusErc20Lending__RedeemUnderlyingFailed(result);
        }
    }

    /**
     * @notice batch redeem stablecoin
     * @param users: the addresses of the users
     * @param purchaseAmounts: the amounts of stablecoin to redeem
     * @param totalStablecoinToRedeem: the total amount of stablecoin to redeem
     * @return stablecoinRedeemed: the amount of stablecoin redeemed
     */
    function _batchRedeemStablecoin(address[] memory users, uint256[] memory purchaseAmounts, uint256 totalStablecoinToRedeem)
        internal
        virtual
        returns (uint256)
    {
        uint256 totalKtokenToRepay = _stablecoinToLendingToken(totalStablecoinToRedeem, i_kToken.exchangeRateCurrent());
        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            // @notice the amount of kToken each user repays is proportional to the ratio of 
            // that user's stablecoin getting redeemed over the total stablecoin getting redeemed
            // @notice Rounds up the lending token amount to avoid underestimating the amount to subtract from each user's balance
            uint256 usersRepaidKtoken = Math.mulDiv(totalKtokenToRepay, purchaseAmounts[i], totalStablecoinToRedeem, Math.Rounding.Up);
            s_kTokenBalances[users[i]] -= usersRepaidKtoken;
            emit TokenLending__UnderlyingRedeemed(users[i], purchaseAmounts[i], usersRepaidKtoken);
        }
        
        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));
        uint256 result = i_kToken.redeemUnderlying(totalStablecoinToRedeem);
        if (result == 0) {
            uint256 stablecoinBalanceAfter = i_stableToken.balanceOf(address(this));
            uint256 stablecoinRedeemed = stablecoinBalanceAfter - stablecoinBalanceBefore;
            
            emit TokenLending__UnderlyingRedeemedBatch(stablecoinRedeemed, totalKtokenToRepay);
            return stablecoinRedeemed;
        }
        else revert TokenLending__BatchRedeemUnderlyingFailed();
    }
}
