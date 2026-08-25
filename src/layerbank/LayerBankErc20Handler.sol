// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {TokenHandler} from "src/TokenHandler.sol";
import {ILayerBankAToken} from "./ILayerBankAToken.sol";
import {ILayerBankErc20Handler} from "./ILayerBankErc20Handler.sol";
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
abstract contract LayerBankErc20Handler is TokenHandler, TokenLending, ILayerBankErc20Handler {
    using SafeERC20 for IERC20;

    /// @notice Aave liquidity-index scale. Fixed for this protocol; not a constructor arg
    ///         (passing Tropykus/Sovryn's 1e18 would size withdrawals 1e9× too large).
    uint256 public constant RAY = 1e27;

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
        FeeSettings memory feeSettings
    )
        TokenHandler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings)
        TokenLending(RAY)
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
        withdrawalAmount = _redeemByUnderlying(user, withdrawalAmount, exchangeRate);
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
        return _redeemByUnderlying(user, stablecoinAmount, _normalizedIncome());
    }

    /**
     * @notice redeem the user's scaled aToken sized by underlying: withdraw `stablecoinAmount` from the Pool
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @return the amount of stablecoin this contract actually received
     */
    function _redeemByUnderlying(address user, uint256 stablecoinAmount, uint256 exchangeRate)
        internal
        virtual
        returns (uint256)
    {
        return _redeemInternal(user, stablecoinAmount, exchangeRate, true);
    }

    /**
     * @notice redeem the user's scaled aToken sized by shares: debit the share count `stablecoinAmount`
     *         converts to, then withdraw that debit's underlying equivalent
     * @dev Aave has no share-sized withdraw, so this helper still calls `Pool.withdraw`; only the
     *      sizing differs from `_redeemByUnderlying`.
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @return stablecoinReceived the amount of stablecoin this contract actually received
     */
    function _redeemByShares(address user, uint256 stablecoinAmount, uint256 exchangeRate)
        internal
        returns (uint256 stablecoinReceived)
    {
        return _redeemInternal(user, stablecoinAmount, exchangeRate, false);
    }

    /**
     * @notice Internal aToken redemption, sized either by underlying amount or by share count
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @param sizeByUnderlying: true to withdraw `stablecoinAmount`; false to withdraw the
     *        underlying equivalent of the (clamped) scaled-share debit
     * @return stablecoinReceived the amount of stablecoin this contract actually received
     */
    function _redeemInternal(
        address user,
        uint256 stablecoinAmount,
        uint256 exchangeRate,
        bool sizeByUnderlying
    ) internal returns (uint256 stablecoinReceived) {
        uint256 usersAtokenBalance = s_aTokenBalances[user];
        uint256 aTokenToRedeem = _stablecoinToLendingToken(stablecoinAmount, exchangeRate);
        if (aTokenToRedeem > usersAtokenBalance) {
            uint256 oldAtokenToRedeem = aTokenToRedeem;
            uint256 oldStablecoinAmount = stablecoinAmount;
            aTokenToRedeem = usersAtokenBalance;
            stablecoinAmount = _lendingTokenToStablecoin(aTokenToRedeem, exchangeRate);
            emit TokenLending__AmountToRedeemAdjusted(
                user, oldAtokenToRedeem, aTokenToRedeem, oldStablecoinAmount, stablecoinAmount
            );
        }
        s_aTokenBalances[user] -= aTokenToRedeem;
        uint256 amountOut =
            sizeByUnderlying ? stablecoinAmount : _lendingTokenToStablecoin(aTokenToRedeem, exchangeRate);
        // Live Aave `withdraw` reverts on a zero amount (`InvalidAmount`).
        if (amountOut == 0) {
            emit TokenLending__LendingTokenRedeemed(user, 0, aTokenToRedeem);
            return 0;
        }

        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));
        i_pool.withdraw(address(i_stableToken), amountOut, address(this));
        stablecoinReceived = i_stableToken.balanceOf(address(this)) - stablecoinBalanceBefore;
        // @notice a success with no stablecoin received still burnt the user's shares, so revert
        // instead of paying out zero
        if (stablecoinReceived == 0) {
            revert TokenLending__ZeroStablecoinReceived(stablecoinAmount);
        }
        emit TokenLending__LendingTokenRedeemed(user, stablecoinReceived, aTokenToRedeem);
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
        uint256 totalAtokenToRedeem = _stablecoinToLendingToken(totalStablecoinAmount, _normalizedIncome());
        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            // @notice the amount of scaled aToken each user redeems is proportional to the ratio of
            // that user's stablecoin being retrieved over the total being retrieved
            // @notice Rounds up the lending token amount to avoid underestimating the amount to subtract from each user's balance
            uint256 usersAtokenToRedeem =
                Math.mulDiv(totalAtokenToRedeem, purchaseAmounts[i], totalStablecoinAmount, Math.Rounding.Up);
            uint256 usersAtokenBalance = s_aTokenBalances[users[i]];
            if (usersAtokenToRedeem > usersAtokenBalance) {
                revert TokenLending__InsufficientLendingTokenBalance(users[i], usersAtokenToRedeem, usersAtokenBalance);
            }
            s_aTokenBalances[users[i]] = usersAtokenBalance - usersAtokenToRedeem;
            emit TokenLending__LendingTokenRedeemed(users[i], purchaseAmounts[i], usersAtokenToRedeem);
        }

        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));
        i_pool.withdraw(address(i_stableToken), totalStablecoinAmount, address(this));
        uint256 stablecoinReceived = i_stableToken.balanceOf(address(this)) - stablecoinBalanceBefore;
        if (stablecoinReceived > 0) emit TokenLending__LendingTokenRedeemedBatch(stablecoinReceived, totalAtokenToRedeem);
        else revert TokenLending__ZeroStablecoinReceived(totalStablecoinAmount);
        return stablecoinReceived;
    }
}
