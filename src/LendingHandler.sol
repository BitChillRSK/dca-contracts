// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ILendingHandler} from "./interfaces/ILendingHandler.sol";
import {TokenHandler} from "./TokenHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title LendingHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Shared per-user share accounting, share ↔ stablecoin conversion, withdraw clamp,
 *         interest, and exact-sum batch redeem for lending handlers. Protocol adapters implement
 *         the exchange-rate and mint/redeem hooks.
 */
abstract contract LendingHandler is TokenHandler, ILendingHandler {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev Scale of the protocol exchange rate; each adapter passes its own constant.
    uint256 internal immutable i_exchangeRateDecimals;

    mapping(address user => uint256 balance) internal s_shares;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param dcaManagerAddress The DcaManager allowed to call deposit, withdraw, and interest.
     * @param stableTokenAddress The ERC20 stablecoin this handler lends.
     * @param exchangeRateDecimals Scale of the protocol exchange rate (adapter constant).
     */
    constructor(address dcaManagerAddress, address stableTokenAddress, uint256 exchangeRateDecimals)
        TokenHandler(dcaManagerAddress, stableTokenAddress)
    {
        i_exchangeRateDecimals = exchangeRateDecimals;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendingHandler
    function withdrawInterest(address user, uint256 stablecoinLockedInDcaSchedules) external override onlyDcaManager {
        uint256 exchangeRate = _exchangeRate();
        uint256 usersShares = s_shares[user];
        uint256 totalStablecoinInLending = _sharesToStablecoin(usersShares, exchangeRate);
        if (totalStablecoinInLending <= stablecoinLockedInDcaSchedules) {
            return; // No interest to withdraw
        }
        uint256 stablecoinInterestAmount;
        unchecked {
            stablecoinInterestAmount = totalStablecoinInLending - stablecoinLockedInDcaSchedules;
        }
        uint256 stablecoinReceived = _redeemShares(user, usersShares, stablecoinInterestAmount, exchangeRate);
        emit LendingHandler__InterestWithdrawn(user, address(i_stableToken), stablecoinReceived);
    }

    /// @inheritdoc ILendingHandler
    function getAccruedInterest(address user, uint256 stablecoinLockedInDcaSchedules)
        external
        override
        onlyDcaManager
        returns (uint256)
    {
        return _accruedInterest(user, stablecoinLockedInDcaSchedules, _exchangeRate());
    }

    /// @inheritdoc ILendingHandler
    function restoreLendingApproval() external override {
        _approveLendingSpender();
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILendingHandler
    function getUserShares(address user) external view override returns (uint256) {
        return s_shares[user];
    }

    /// @inheritdoc ILendingHandler
    function quoteAccruedInterest(address user, uint256 stablecoinLockedInDcaSchedules)
        external
        view
        override
        onlyDcaManager
        returns (uint256)
    {
        return _accruedInterest(user, stablecoinLockedInDcaSchedules, _viewExchangeRate());
    }

    /// @dev Advertise `ITokenHandler` (via TokenHandler) and `ILendingHandler`.
    function supportsInterface(bytes4 interfaceID) public view virtual override returns (bool) {
        return interfaceID == type(ILendingHandler).interfaceId || super.supportsInterface(interfaceID);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Never add a `fallback` or `executeOperation` here: an Aave-style flash loan naming this
     *      handler as receiver would repay itself from this allowance.
     */
    function _approveLendingSpender() internal {
        i_stableToken.forceApprove(_lendingSpender(), type(uint256).max);
    }

    /// @dev TokenHandler reverts unless the pull matches `depositAmount`, so the mint always uses the full request.
    function _depositToken(address user, uint256 depositAmount) internal virtual override {
        super._depositToken(user, depositAmount);
        uint256 mintedAmount = _protocolDeposit(depositAmount);
        if (mintedAmount == 0) revert LendingHandler__LendingProtocolDepositFailed();
        uint256 previousShares = s_shares[user];
        _setUserShares(user, previousShares, previousShares + mintedAmount);
    }

    /**
     * @dev Redeems straight to `user` and reports what the redemption actually paid them. Cash may be
     *      less than requested when the complete share claim was consumed (fee / realized loss); a
     *      partial share burn reverts.
     */
    function _withdrawToken(address user, uint256 withdrawalAmount)
        internal
        virtual
        override
        returns (uint256 withdrawnAmount)
    {
        uint256 exchangeRate = _exchangeRate();
        uint256 usersShares = s_shares[user];
        uint256 totalStablecoinInLending = _sharesToStablecoin(usersShares, exchangeRate);

        if (totalStablecoinInLending < withdrawalAmount) {
            emit LendingHandler__WithdrawalAmountAdjusted(user, withdrawalAmount, totalStablecoinInLending);
            withdrawalAmount = totalStablecoinInLending;
        }

        withdrawnAmount = _redeemShares(user, usersShares, withdrawalAmount, exchangeRate);
        emit TokenHandler__TokenWithdrawn(address(i_stableToken), user, withdrawnAmount);
    }

    /**
     * @dev Redeem shares for stablecoin, sized by the share count this contract debits, and pay the
     *      cash straight to `user`: this contract never holds an exit's stablecoin.
     *      Clamp to this user's book, never the handler's pooled balance: schedule accounting can
     *      sit ahead of share-backed underlying, and purchases have no outer withdraw clamp.
     *      Zero shares is a no-op. A positive burn that pays nothing reverts and rolls back.
     *      Callers pass the `usersShares` they already loaded to avoid a second SLOAD.
     */
    function _redeemShares(address user, uint256 usersShares, uint256 stablecoinAmount, uint256 exchangeRate)
        internal
        returns (uint256 stablecoinReceived)
    {
        uint256 sharesToRedeem = _stablecoinToShares(stablecoinAmount, exchangeRate);
        if (sharesToRedeem > usersShares) {
            uint256 oldSharesToRedeem = sharesToRedeem;
            uint256 oldStablecoinAmount = stablecoinAmount;
            sharesToRedeem = usersShares;
            stablecoinAmount = _sharesToStablecoin(sharesToRedeem, exchangeRate);
            emit LendingHandler__AmountToRedeemAdjusted(
                user, oldSharesToRedeem, sharesToRedeem, oldStablecoinAmount, stablecoinAmount
            );
        }
        if (sharesToRedeem == 0) {
            return 0;
        }
        unchecked {
            _setUserShares(user, usersShares, usersShares - sharesToRedeem);
        }
        stablecoinReceived = _measuredProtocolRedeem(sharesToRedeem, exchangeRate, user);
        if (stablecoinReceived == 0) {
            revert LendingHandler__ZeroStablecoinReceived(sharesToRedeem);
        }
        emit LendingHandler__SharesRedeemed(user, stablecoinReceived, sharesToRedeem);
    }

    /**
     * @dev Retrieve several users' stablecoin in one protocol redemption.
     *      Each row uses the same ceil(stablecoin → shares) as a single redeem; the protocol
     *      burn is exactly the sum of those debits so virtual books and the lending position
     *      stay aligned (an aggregate-then-pro-rata ceil can debit more shares than it burns).
     *      Shortfalls revert rather than clamp: PurchaseRbtc still allocates by the planned
     *      weights, so clamping one row would dilute every other buyer in the batch.
     */
    function _batchRetrieveStablecoin(address[] calldata users, uint256[] calldata purchaseAmounts)
        internal
        virtual
        override
        returns (uint256)
    {
        uint256 exchangeRate = _exchangeRate();
        uint256 totalSharesToRedeem;

        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            uint256 usersSharesToRedeem = _stablecoinToShares(purchaseAmounts[i], exchangeRate);
            uint256 usersShares = s_shares[users[i]];
            if (usersSharesToRedeem > usersShares) {
                revert LendingHandler__InsufficientShares(users[i], usersSharesToRedeem, usersShares);
            }
            unchecked {
                _setUserShares(users[i], usersShares, usersShares - usersSharesToRedeem);
            }
            totalSharesToRedeem += usersSharesToRedeem;
            // Per-user facts on this path are `UserSharesUpdated` (exact virtual debit) and, after
            // the protocol call, one measured `SharesRedeemedBatch`. Do not emit `SharesRedeemed`
            // here: that event's `underlyingAmount` is measured cash on single redeems, and the
            // planned gross is not measured cash.
        }
        uint256 stablecoinReceived = _measuredProtocolRedeem(totalSharesToRedeem, exchangeRate, address(this));
        if (stablecoinReceived > 0) {
            emit LendingHandler__SharesRedeemedBatch(stablecoinReceived, totalSharesToRedeem);
            return stablecoinReceived;
        }
        revert LendingHandler__ZeroStablecoinReceived(totalSharesToRedeem);
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

    /// @dev Address that must be approved to pull stablecoin on deposit.
    function _lendingSpender() internal view virtual returns (address);

    /**
     * @dev Mint shares against `stablecoinAmount` already held by this contract.
     * @return mintedShares The share balance this contract actually gained.
     */
    function _protocolDeposit(uint256 stablecoinAmount) internal virtual returns (uint256 mintedShares);

    /**
     * @dev Burn `sharesAmount` at the lending protocol and pay the stablecoin to `receiver`: the user
     *      on an exit, this contract when a batch funds a purchase. Adapters move funds only. Cash and
     *      receipt-share measurement live in the base.
     */
    function _protocolRedeem(uint256 sharesAmount, uint256 exchangeRate, address receiver) internal virtual;

    /**
     * @dev This handler's external receipt-share balance: iToken/kToken `balanceOf`, or aToken
     *      `scaledBalanceOf`. Never a protocol return value. Not `view`: the iToken/kToken ABIs
     *      declare `balanceOf` without that mutability.
     */
    function _receiptSharesBalance() internal virtual returns (uint256);

    /**
     * @dev Convert stablecoin to shares. Rounds up so the virtual share debit is never below
     *      what the lending protocol may burn for the same stablecoin amount (keeps sum of
     *      per-user shares <= shares the handler actually holds). Round-down would allow the
     *      books to drift above reality. The product `stablecoinAmount * i_exchangeRateDecimals`
     *      is checked: callers pass a `uint96` purchase amount or an amount already bounded by
     *      `_sharesToStablecoin`, so it fits, and an overflow would revert rather than wrap.
     * @param stablecoinAmount Amount of stablecoin to convert.
     * @param exchangeRate Stablecoin per share, scaled by `i_exchangeRateDecimals`.
     * @return sharesAmount Corresponding shares, rounded up.
     */
    function _stablecoinToShares(uint256 stablecoinAmount, uint256 exchangeRate)
        internal
        view
        returns (uint256 sharesAmount)
    {
        sharesAmount = Math.ceilDiv(stablecoinAmount * i_exchangeRateDecimals, exchangeRate);
    }

    /**
     * @dev Convert shares to stablecoin (round down).
     * @param sharesAmount Amount of shares to convert.
     * @param exchangeRate Stablecoin per share, scaled by `i_exchangeRateDecimals`.
     * @return stablecoinAmount Corresponding stablecoin.
     */
    function _sharesToStablecoin(uint256 sharesAmount, uint256 exchangeRate)
        internal
        view
        returns (uint256 stablecoinAmount)
    {
        stablecoinAmount = sharesAmount * exchangeRate / i_exchangeRateDecimals;
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Share-backed stablecoin above locked principal at `exchangeRate`, or zero. The two public
     *      readers differ only in which rate they pass: the quote uses the market's plain read, the
     *      spendable figure the rate a write path would get.
     */
    function _accruedInterest(address user, uint256 stablecoinLockedInDcaSchedules, uint256 exchangeRate)
        private
        view
        returns (uint256)
    {
        uint256 totalStablecoinInLending = _sharesToStablecoin(s_shares[user], exchangeRate);
        unchecked {
            return totalStablecoinInLending > stablecoinLockedInDcaSchedules
                ? totalStablecoinInLending - stablecoinLockedInDcaSchedules
                : 0;
        }
    }

    /**
     * @dev Write the user's virtual share balance and emit the canonical transition.
     *      No log when the balance is unchanged, so a zero-share debit is silent.
     *      Callers pass the already-loaded `previousShares` to avoid a second SLOAD.
     */
    function _setUserShares(address user, uint256 previousShares, uint256 newShares) private {
        s_shares[user] = newShares;
        if (previousShares != newShares) {
            emit LendingHandler__UserSharesUpdated(user, previousShares, newShares);
        }
    }

    /**
     * @dev Measure the cash `receiver` gained and require this contract's external receipt-share
     *      balance to fall by exactly `sharesAmount`. Cash and shares are independent facts: a fee
     *      haircut with a full burn succeeds; positive cash with a partial burn reverts. Compare
     *      before/after without subtracting when the balance did not decrease, so a flat or rising
     *      balance cannot panic.
     */
    function _measuredProtocolRedeem(uint256 sharesAmount, uint256 exchangeRate, address receiver)
        private
        returns (uint256 received)
    {
        uint256 sharesBefore = _receiptSharesBalance();
        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(receiver);
        _protocolRedeem(sharesAmount, exchangeRate, receiver);
        uint256 sharesAfter = _receiptSharesBalance();
        if (sharesAfter >= sharesBefore || sharesBefore - sharesAfter != sharesAmount) {
            revert LendingHandler__ShareConsumptionMismatch(sharesAmount, sharesBefore, sharesAfter);
        }
        received = i_stableToken.balanceOf(receiver) - stablecoinBalanceBefore;
    }
}
