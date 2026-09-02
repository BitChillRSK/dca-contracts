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
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Shared per-user share accounting, withdraw clamp, interest, and batch pro-rata
 *         redeem for lending handlers. Protocol adapters implement the exchange-rate and
 *         mint/redeem hooks.
 */
abstract contract LendingErc20Handler is TokenHandler, TokenLending, StablecoinSource {
    using SafeERC20 for IERC20;

    mapping(address user => uint256 balance) internal s_shares;

    /**
     * @param dcaManagerAddress The DcaManager allowed to call deposit, withdraw, and interest.
     * @param stableTokenAddress The ERC20 stablecoin this handler lends.
     * @param feeCollector Address that receives purchase fees.
     * @param feeSettings Linear fee parameters.
     * @param exchangeRateDecimals Scale of the protocol exchange rate (adapter constant).
     * @param initialOwner Address that owns fee configuration immediately after deploy.
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
     * @inheritdoc ITokenHandler
     * @dev TokenHandler reverts unless the pull matches `depositAmount`, so the mint always uses the full request.
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
     * @inheritdoc ITokenHandler
     * @dev Pays out what the redemption actually produced, which may be less than requested.
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
     * @inheritdoc ITokenLending
     */
    function getUserShares(address user) external view override returns (uint256) {
        return s_shares[user];
    }

    /**
     * @dev Advertise `ITokenHandler` (via TokenHandler) and `ITokenLending`.
     */
    function supportsInterface(bytes4 interfaceID) public view virtual override returns (bool) {
        return interfaceID == type(ITokenLending).interfaceId || super.supportsInterface(interfaceID);
    }

    /**
     * @inheritdoc ITokenLending
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
     * @inheritdoc ITokenLending
     */
    function getAccruedInterest(address user, uint256 stablecoinLockedInDcaSchedules)
        external
        override
        onlyDcaManager
        returns (uint256 stablecoinInterestAmount)
    {
        uint256 totalStablecoinInLending = _sharesToStablecoin(s_shares[user], _exchangeRate());
        stablecoinInterestAmount =
            totalStablecoinInLending > stablecoinLockedInDcaSchedules
                ? totalStablecoinInLending - stablecoinLockedInDcaSchedules
                : 0;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The stablecoin this handler lends out.
     */
    function _purchaseToken() internal view override returns (IERC20) {
        return i_stableToken;
    }

    /**
     * @dev Retrieve the user's stablecoin by redeeming shares.
     */
    function _retrieveStablecoin(address user, uint256 stablecoinAmount) internal virtual override returns (uint256) {
        return _redeemShares(user, stablecoinAmount, _exchangeRate());
    }

    /**
     * @dev Redeem shares for stablecoin, sized by the share count this contract debits.
     *      Clamp to this user's book, never the handler's pooled balance: schedule accounting can
     *      sit ahead of share-backed underlying, and purchases have no outer withdraw clamp.
     *      Zero shares is a no-op. A positive burn that pays nothing reverts and rolls back.
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
     * @dev Retrieve several users' stablecoin in one protocol redemption.
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
     * @dev Write the user's virtual share balance and emit the canonical transition.
     *      No log when the balance is unchanged, so a zero-share debit is silent.
     */
    function _setUserShares(address user, uint256 newShares) private {
        uint256 previousShares = s_shares[user];
        s_shares[user] = newShares;
        if (previousShares != newShares) {
            emit TokenLending__UserSharesUpdated(user, previousShares, newShares);
        }
    }

    /**
     * @dev Mutating-ok exchange rate used on write paths and by `getAccruedInterest`, which reports
     *      a figure a caller may then spend against. Defaults to the view rate.
     *      Override when the live call mutates (Compound `exchangeRateCurrent()` vs
     *      `exchangeRateStored()`). A new adapter that needs an accrual poke compiles
     *      against this default and uses a stale view rate until it overrides.
     */
    function _exchangeRate() internal virtual returns (uint256) {
        return _viewExchangeRate();
    }

    /**
     * @dev The market's exchange rate as a plain read. Adapters implement this one; callers use
     *      `_exchangeRate`, which equals it unless the market must be poked to accrue first.
     */
    function _viewExchangeRate() internal view virtual returns (uint256);

    /**
     * @dev Address that must be approved to pull stablecoin on deposit.
     */
    function _lendingSpender() internal view virtual returns (address);

    /**
     * @dev Mint shares against `stablecoinAmount` already held by this contract.
     * @return mintedShares The share balance this contract actually gained.
     */
    function _protocolDeposit(uint256 stablecoinAmount) internal virtual returns (uint256 mintedShares);

    /**
     * @dev Measure the stablecoin this contract gained from a protocol redeem.
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
     * @dev Burn `sharesAmount` at the lending protocol onto this contract.
     *      Adapters move funds only. Measurement and the zero-payout revert live in the base.
     */
    function _protocolRedeem(uint256 sharesAmount, uint256 exchangeRate) internal virtual;
}
