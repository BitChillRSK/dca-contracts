// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {TokenHandler} from "src/TokenHandler.sol";
import {ILayerBankAToken} from "./ILayerBankAToken.sol";
import {ILayerBankPool} from "./ILayerBankPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenLending} from "src/TokenLending.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title LayerBankErc20Handler
 * @notice Stablecoin functions that are common regardless of the method used to swap stablecoin for rBTC.
 * @dev Live LayerBank DOC is an Aave-v3 aToken. Supply and withdraw go through the Pool; per-user
 *      virtual balances store **scaled** aToken amounts (not rebasing `balanceOf`).
 */
abstract contract LayerBankErc20Handler is TokenHandler, TokenLending {
    using SafeERC20 for IERC20;

    error LayerBankErc20Handler__PoolNotSet();
    error LayerBankErc20Handler__UnderlyingMismatch();

    //////////////////////
    // State variables ///
    //////////////////////
    ILayerBankAToken public immutable i_aToken;
    ILayerBankPool public immutable i_pool;
    mapping(address user => uint256 balance) internal s_aTokenBalances;

    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param stableTokenAddress the address of the ERC20 stablecoin token on the blockchain of deployment
     * @param aTokenAddress the address of LayerBank's aToken for this stablecoin
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address aTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 exchangeRateDecimals
    )
        TokenHandler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings)
        TokenLending(exchangeRateDecimals)
    {
        i_aToken = ILayerBankAToken(aTokenAddress);
        if (i_aToken.UNDERLYING_ASSET_ADDRESS() != stableTokenAddress) {
            revert LayerBankErc20Handler__UnderlyingMismatch();
        }
        address pool = i_aToken.POOL();
        if (pool == address(0)) revert LayerBankErc20Handler__PoolNotSet();
        i_pool = ILayerBankPool(pool);
    }

    /**
     * @notice deposit the full token amount for DCA on the contract
     * @param user: the address of the user making the deposit
     * @param depositAmount: the amount requested from the user
     * @return depositedAmount the stablecoin amount actually received before supplying to the Pool
     */
    function depositToken(address user, uint256 depositAmount)
        public
        override(TokenHandler, ITokenHandler)
        onlyDcaManager
        returns (uint256 depositedAmount)
    {
        depositedAmount = super.depositToken(user, depositAmount);
        if (i_stableToken.allowance(address(this), address(i_pool)) < depositedAmount) {
            i_stableToken.safeApprove(address(i_pool), depositedAmount);
        }
        // @notice the shares we credit are the scaled aTokens we actually gained, never a Pool return
        uint256 prevScaledBalance = i_aToken.scaledBalanceOf(address(this));
        i_pool.supply(address(i_stableToken), depositedAmount, address(this), 0);
        uint256 mintedAmount = i_aToken.scaledBalanceOf(address(this)) - prevScaledBalance;
        if (mintedAmount == 0) revert TokenLending__LendingProtocolDepositFailed();
        s_aTokenBalances[user] += mintedAmount;
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
        uint256 exchangeRate = _normalizedIncome();
        uint256 stablecoinInLayerBank = _lendingTokenToStablecoin(s_aTokenBalances[user], exchangeRate);
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
        return s_aTokenBalances[user];
    }

    /**
     * @notice withdraw the interest
     * @param user: the address of the user
     * @param stablecoinLockedInDcaSchedules: the amount of stablecoin locked in DCA schedules
     */
    function withdrawInterest(address user, uint256 stablecoinLockedInDcaSchedules) external override onlyDcaManager {
        uint256 exchangeRate = _normalizedIncome();
        uint256 totalStablecoinInLending = _lendingTokenToStablecoin(s_aTokenBalances[user], exchangeRate);
        if (totalStablecoinInLending <= stablecoinLockedInDcaSchedules) {
            return; // No interest to withdraw
        }
        uint256 stablecoinInterestAmount = totalStablecoinInLending - stablecoinLockedInDcaSchedules;
        uint256 stablecoinReceived = _burnAtoken(user, stablecoinInterestAmount, exchangeRate);

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
        uint256 totalStablecoinInLending = _lendingTokenToStablecoin(s_aTokenBalances[user], _normalizedIncome());
        stablecoinInterestAmount = totalStablecoinInLending > stablecoinLockedInDcaSchedules
            ? totalStablecoinInLending - stablecoinLockedInDcaSchedules
            : 0;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Aave liquidity index including pending interest, RAY (1e27) scale.
     */
    function _normalizedIncome() internal view returns (uint256) {
        return i_pool.getReserveNormalizedIncome(address(i_stableToken));
    }

    /**
     * @notice retrieve the user's stablecoin by withdrawing from the Pool
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @return the amount of stablecoin this contract actually received
     */
    function _retrieveStablecoin(address user, uint256 stablecoinAmount) internal virtual returns (uint256) {
        return _redeemLendingToken(user, stablecoinAmount, _normalizedIncome());
    }

    /**
     * @notice redeem enough scaled aToken to get `stablecoinAmount` of stablecoin onto this contract
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
     * @notice redeem the user's scaled aToken by share count instead of by underlying amount
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @return stablecoinReceived the amount of stablecoin this contract actually received
     */
    function _burnAtoken(address user, uint256 stablecoinAmount, uint256 exchangeRate)
        internal
        returns (uint256 stablecoinReceived)
    {
        return _redeemLendingTokenInternal(user, stablecoinAmount, exchangeRate, false);
    }

    /**
     * @notice Internal aToken redemption, sized either by underlying amount or by share count
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @param redeemUnderlying: true to withdraw `stablecoinAmount`; false to withdraw the
     *        underlying equivalent of the (clamped) scaled-share debit
     * @return stablecoinReceived the amount of stablecoin this contract actually received
     */
    function _redeemLendingTokenInternal(
        address user,
        uint256 stablecoinAmount,
        uint256 exchangeRate,
        bool redeemUnderlying
    ) internal returns (uint256 stablecoinReceived) {
        uint256 usersAtokenBalance = s_aTokenBalances[user];
        uint256 aTokenToRepay = _stablecoinToLendingToken(stablecoinAmount, exchangeRate);
        if (aTokenToRepay > usersAtokenBalance) {
            uint256 oldAtokenToRepay = aTokenToRepay;
            uint256 oldStablecoinAmount = stablecoinAmount;
            aTokenToRepay = usersAtokenBalance;
            stablecoinAmount = _lendingTokenToStablecoin(aTokenToRepay, exchangeRate);
            emit TokenLending__AmountToRepayAdjusted(
                user, oldAtokenToRepay, aTokenToRepay, oldStablecoinAmount, stablecoinAmount
            );
        }
        // @notice Solvency: Aave burns `amount.rayDiv(index)` (round nearest). We debit
        // `_stablecoinToLendingToken` (Math.Rounding.Up). Debiting >= the shares Aave
        // burns keeps `sum(s_aTokenBalances)` <= the handler's real scaled aToken
        // balance. Flipping our side to round down breaks this; no existing test
        // would catch it.
        s_aTokenBalances[user] -= aTokenToRepay;
        uint256 amountOut =
            redeemUnderlying ? stablecoinAmount : _lendingTokenToStablecoin(aTokenToRepay, exchangeRate);
        // Live Aave `withdraw` reverts on a zero amount (`InvalidAmount`).
        if (amountOut == 0) {
            emit TokenLending__LendingTokenRedeemed(user, 0, aTokenToRepay);
            return 0;
        }

        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));
        // @notice Aave `withdraw(..., to)` exists; still pull onto this handler and
        // measure the DOC delta. Do not credit the return.
        i_pool.withdraw(address(i_stableToken), amountOut, address(this));
        stablecoinReceived = i_stableToken.balanceOf(address(this)) - stablecoinBalanceBefore;
        // @notice a success with no stablecoin received still burnt the user's shares, so revert
        // instead of paying out zero
        if (stablecoinReceived == 0) {
            revert TokenLending__ZeroStablecoinReceived(stablecoinAmount);
        }
        emit TokenLending__LendingTokenRedeemed(user, stablecoinReceived, aTokenToRepay);
    }

    /**
     * @notice retrieve several users' stablecoin in one Pool withdrawal
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
        uint256 totalAtokenToRepay = _stablecoinToLendingToken(totalStablecoinAmount, _normalizedIncome());
        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            // @notice the amount of scaled aToken each user repays is proportional to the ratio of
            // that user's stablecoin being retrieved over the total being retrieved
            // @notice Rounds up the lending token amount to avoid underestimating the amount to subtract from each user's balance
            // @notice Same solvency pairing as the single-redeem debit: Aave `rayDiv` rounds nearest; we round the virtual debit up.
            uint256 usersRepaidAtoken =
                Math.mulDiv(totalAtokenToRepay, purchaseAmounts[i], totalStablecoinAmount, Math.Rounding.Up);
            uint256 usersAtokenBalance = s_aTokenBalances[users[i]];
            if (usersRepaidAtoken > usersAtokenBalance) {
                revert TokenLending__InsufficientLendingTokenBalance(users[i], usersRepaidAtoken, usersAtokenBalance);
            }
            s_aTokenBalances[users[i]] = usersAtokenBalance - usersRepaidAtoken;
            emit TokenLending__LendingTokenRedeemed(users[i], purchaseAmounts[i], usersRepaidAtoken);
        }

        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));
        i_pool.withdraw(address(i_stableToken), totalStablecoinAmount, address(this));
        uint256 stablecoinReceived = i_stableToken.balanceOf(address(this)) - stablecoinBalanceBefore;
        if (stablecoinReceived > 0) emit TokenLending__LendingTokenRedeemedBatch(stablecoinReceived, totalAtokenToRepay);
        else revert TokenLending__ZeroStablecoinReceived(totalStablecoinAmount);
        return stablecoinReceived;
    }
}
