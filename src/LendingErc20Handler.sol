// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {ITokenLending} from "src/interfaces/ITokenLending.sol";
import {TokenHandler} from "src/TokenHandler.sol";
import {TokenLending} from "src/TokenLending.sol";
import {StablecoinSource} from "src/StablecoinSource.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title LendingErc20Handler
 * @notice Shared per-user share accounting, withdraw clamp, interest, and batch pro-rata
 *         redeem for lending handlers. Protocol adapters implement the exchange-rate and
 *         mint/redeem hooks.
 */
abstract contract LendingErc20Handler is TokenHandler, TokenLending, StablecoinSource {
    using SafeERC20 for IERC20;

    mapping(address user => uint256 balance) internal s_shares;

    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param stableTokenAddress the address of the ERC20 stablecoin token
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     * @param exchangeRateDecimals the scale of the protocol exchange rate
     * @param initialOwner the address that owns fee configuration immediately after deploy
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 exchangeRateDecimals,
        address initialOwner
    )
        TokenHandler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, initialOwner)
        TokenLending(exchangeRateDecimals)
    {}

    /**
     * @notice deposit the full token amount for DCA on the contract
     * @param user: the address of the user making the deposit
     * @param depositAmount: the amount requested from the user
     * @dev TokenHandler reverts unless the pull matches `depositAmount`, so the mint always uses the full request
     */
    function depositToken(address user, uint256 depositAmount)
        public
        override(TokenHandler, ITokenHandler)
        onlyDcaManager
    {
        super.depositToken(user, depositAmount);
        address spender = _lendingSpender();
        if (i_stableToken.allowance(address(this), spender) < depositAmount) {
            i_stableToken.forceApprove(spender, depositAmount);
        }
        uint256 mintedAmount = _protocolDeposit(depositAmount);
        if (mintedAmount == 0) revert TokenLending__LendingProtocolDepositFailed();
        _setUserShares(user, s_shares[user] + mintedAmount);
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
        uint256 exchangeRate = _exchangeRate();
        uint256 totalStablecoinInLending = _sharesToStablecoin(s_shares[user], exchangeRate);

        if (totalStablecoinInLending < withdrawalAmount) {
            emit TokenLending__WithdrawalAmountAdjusted(user, withdrawalAmount, totalStablecoinInLending);
            withdrawalAmount = totalStablecoinInLending;
        }

        // @notice we pay out what the redemption actually produced, which may be less than requested
        withdrawalAmount = _redeemShares(user, withdrawalAmount, exchangeRate);
        return super.withdrawToken(user, withdrawalAmount);
    }

    /**
     * @notice get the users shares balance
     * @param user: the address of the user
     * @return the users shares balance
     */
    function getUserShares(address user) external view override returns (uint256) {
        return s_shares[user];
    }

    /**
     * @notice advertise ITokenHandler (via TokenHandler) and ITokenLending
     */
    function supportsInterface(bytes4 interfaceID) public view virtual override returns (bool) {
        return interfaceID == type(ITokenLending).interfaceId || super.supportsInterface(interfaceID);
    }

    /**
     * @notice withdraw the interest
     * @param user: the address of the user
     * @param stablecoinLockedInDcaSchedules: the amount of stablecoin locked in DCA schedules
     */
    function withdrawInterest(address user, uint256 stablecoinLockedInDcaSchedules) external override onlyDcaManager {
        uint256 exchangeRate = _exchangeRate();
        uint256 totalStablecoinInLending = _sharesToStablecoin(s_shares[user], exchangeRate);
        if (totalStablecoinInLending <= stablecoinLockedInDcaSchedules) {
            return; // No interest to withdraw
        }
        uint256 stablecoinInterestAmount = totalStablecoinInLending - stablecoinLockedInDcaSchedules;
        uint256 stablecoinReceived = _redeemShares(user, stablecoinInterestAmount, exchangeRate);
        if (stablecoinReceived > 0) {
            i_stableToken.safeTransfer(user, stablecoinReceived);
        }
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
        uint256 totalStablecoinInLending = _sharesToStablecoin(s_shares[user], _viewExchangeRate());
        stablecoinInterestAmount =
            totalStablecoinInLending > stablecoinLockedInDcaSchedules
                ? totalStablecoinInLending - stablecoinLockedInDcaSchedules
                : 0;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice the stablecoin this handler lends out
     */
    function _purchaseToken() internal view override returns (IERC20) {
        return i_stableToken;
    }

    /**
     * @notice retrieve the user's stablecoin by redeeming shares
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @return the amount of stablecoin this contract actually received
     */
    function _retrieveStablecoin(address user, uint256 stablecoinAmount) internal virtual override returns (uint256) {
        return _redeemShares(user, stablecoinAmount, _exchangeRate());
    }

    /**
     * @notice Redeem shares for stablecoin, sized by the share count this contract debits
     * @dev Clamp to this user's book, never the handler's pooled balance: schedule accounting can
     *      sit ahead of share-backed underlying, and purchases have no outer withdraw clamp.
     *      Zero shares is a no-op. A positive burn that pays nothing reverts and rolls back.
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of shares to stablecoin (stablecoin per share)
     * @return stablecoinReceived the amount of stablecoin this contract actually received
     */
    function _redeemShares(address user, uint256 stablecoinAmount, uint256 exchangeRate)
        internal
        returns (uint256 stablecoinReceived)
    {
        uint256 usersShares = s_shares[user];
        uint256 sharesToRedeem = _stablecoinToShares(stablecoinAmount, exchangeRate);
        if (sharesToRedeem > usersShares) {
            uint256 oldSharesToRedeem = sharesToRedeem;
            uint256 oldStablecoinAmount = stablecoinAmount;
            sharesToRedeem = usersShares;
            stablecoinAmount = _sharesToStablecoin(sharesToRedeem, exchangeRate);
            emit TokenLending__AmountToRedeemAdjusted(
                user, oldSharesToRedeem, sharesToRedeem, oldStablecoinAmount, stablecoinAmount
            );
        }
        if (sharesToRedeem == 0) {
            return 0;
        }
        _setUserShares(user, usersShares - sharesToRedeem);
        stablecoinReceived = _measuredProtocolRedeem(sharesToRedeem, exchangeRate);
        if (stablecoinReceived == 0) {
            revert TokenLending__ZeroStablecoinReceived(stablecoinAmount);
        }
        emit TokenLending__SharesRedeemed(user, stablecoinReceived, sharesToRedeem);
    }

    /**
     * @notice retrieve several users' stablecoin in one protocol redemption
     * @param users: the addresses of the users
     * @param purchaseAmounts: the amounts of stablecoin charged to each user
     * @param totalStablecoinAmount: the total amount of stablecoin wanted
     * @return the amount of stablecoin this contract actually received
     */
    function _batchRetrieveStablecoin(
        address[] memory users,
        uint256[] memory purchaseAmounts,
        uint256 totalStablecoinAmount
    ) internal virtual override returns (uint256) {
        uint256 exchangeRate = _exchangeRate();
        uint256 totalSharesToRedeem = _stablecoinToShares(totalStablecoinAmount, exchangeRate);

        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            // round up so we never underestimate the debit against this user
            uint256 usersSharesToRedeem =
                Math.mulDiv(totalSharesToRedeem, purchaseAmounts[i], totalStablecoinAmount, Math.Rounding.Ceil);
            uint256 usersShares = s_shares[users[i]];
            if (usersSharesToRedeem > usersShares) {
                revert TokenLending__InsufficientShares(users[i], usersSharesToRedeem, usersShares);
            }
            _setUserShares(users[i], usersShares - usersSharesToRedeem);
            emit TokenLending__SharesRedeemed(users[i], purchaseAmounts[i], usersSharesToRedeem);
        }
        uint256 stablecoinReceived = _measuredProtocolRedeem(totalSharesToRedeem, exchangeRate);
        if (stablecoinReceived > 0) emit TokenLending__SharesRedeemedBatch(stablecoinReceived, totalSharesToRedeem);
        else revert TokenLending__ZeroStablecoinReceived(totalStablecoinAmount);
        return stablecoinReceived;
    }

    /**
     * @notice Write the user's virtual share balance and emit the canonical transition.
     * @dev No log when the balance is unchanged, so a zero-share debit is silent.
     */
    function _setUserShares(address user, uint256 newShares) private {
        uint256 previousShares = s_shares[user];
        s_shares[user] = newShares;
        if (previousShares != newShares) {
            emit TokenLending__UserSharesUpdated(user, previousShares, newShares);
        }
    }

    /**
     * @notice mutating-ok exchange rate used on write paths
     * @dev Defaults to the view rate. Override when the live call mutates
     *      (like in Compound's `exchangeRateCurrent()` vs `exchangeRateStored()`). A new
     *      adapter that needs an accrual poke compiles against this default
     *      and uses a stale view rate until it overrides.
     */
    function _exchangeRate() internal virtual returns (uint256) {
        return _viewExchangeRate();
    }

    /**
     * @notice view exchange rate used by `getAccruedInterest`
     */
    function _viewExchangeRate() internal view virtual returns (uint256);

    /**
     * @notice address that must be approved to pull stablecoin on deposit
     */
    function _lendingSpender() internal view virtual returns (address);

    /**
     * @notice mint shares against `stablecoinAmount` already held by this contract
     * @return mintedShares the share balance this contract actually gained
     */
    function _protocolDeposit(uint256 stablecoinAmount) internal virtual returns (uint256 mintedShares);

    /**
     * @notice Measure the stablecoin this contract gained from a protocol redeem
     * @param sharesAmount the share count to burn (after any clamp)
     * @param exchangeRate the rate already read by the caller; do not re-query the protocol
     * @return received the stablecoin amount this contract actually gained
     */
    function _measuredProtocolRedeem(uint256 sharesAmount, uint256 exchangeRate)
        private
        returns (uint256 received)
    {
        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));
        _protocolRedeem(sharesAmount, exchangeRate);
        received = i_stableToken.balanceOf(address(this)) - stablecoinBalanceBefore;
    }

    /**
     * @notice Burn `sharesAmount` at the lending protocol onto this contract
     * @dev Adapters move funds only. Measurement and the zero-payout revert live in the base.
     * @param sharesAmount the share count to burn (after any clamp)
     * @param exchangeRate the rate already read by the caller; do not re-query the protocol
     */
    function _protocolRedeem(uint256 sharesAmount, uint256 exchangeRate) internal virtual;
}
