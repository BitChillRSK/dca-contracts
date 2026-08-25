// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {TokenHandler} from "src/TokenHandler.sol";
import {TokenLending} from "src/TokenLending.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title LendingErc20Handler
 * @notice Shared per-user share accounting, withdraw clamp, interest, and batch pro-rata
 *         redeem for lending handlers. Protocol adapters implement the exchange-rate and
 *         mint/redeem hooks; Idle is not a sibling of this type.
 */
abstract contract LendingErc20Handler is TokenHandler, TokenLending {
    using SafeERC20 for IERC20;

    mapping(address user => uint256 balance) internal s_shares;

    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param stableTokenAddress the address of the ERC20 stablecoin token
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     * @param exchangeRateDecimals the scale of the protocol exchange rate
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 exchangeRateDecimals
    ) TokenHandler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings) TokenLending(exchangeRateDecimals) {}

    /**
     * @notice deposit the full token amount for DCA on the contract
     * @param user: the address of the user making the deposit
     * @param depositAmount: the amount requested from the user
     * @return depositedAmount the stablecoin amount actually received before minting shares
     */
    function depositToken(address user, uint256 depositAmount)
        public
        override(TokenHandler, ITokenHandler)
        onlyDcaManager
        returns (uint256 depositedAmount)
    {
        depositedAmount = super.depositToken(user, depositAmount);
        address spender = _lendingSpender();
        if (i_stableToken.allowance(address(this), spender) < depositedAmount) {
            i_stableToken.safeApprove(spender, depositedAmount);
        }
        uint256 mintedAmount = _protocolDeposit(depositedAmount);
        if (mintedAmount == 0) revert TokenLending__LendingProtocolDepositFailed();
        s_shares[user] += mintedAmount;
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
     * @notice retrieve the user's stablecoin by redeeming shares
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @return the amount of stablecoin this contract actually received
     */
    function _retrieveStablecoin(address user, uint256 stablecoinAmount) internal virtual returns (uint256) {
        return _redeemShares(user, stablecoinAmount, _exchangeRate());
    }

    /**
     * @notice Shared redeem clamp-and-measure before the protocol call
     * @dev Every redemption is sized by the share count this contract debits, never by the underlying
     *      amount. The number booked out of `s_shares` is the number handed to the protocol to burn,
     *      so the books cannot drift above the shares actually held even if a protocol's internal rate
     *      disagrees with the one read here. What comes back is protocol-chosen and always measured.
     *
     *      The `sharesToRedeem > usersShares` clamp is a per-user solvency boundary, not a rounding
     *      workaround. `_retrieveStablecoin` (single purchase) has no `withdrawToken` outer clamp, and
     *      `DcaManager.tokenBalance` can legitimately sit ahead of share-backed underlying (R21
     *      fee-on-transfer second hop). Clamp to this user's book only; never to the handler's pooled
     *      protocol balance. Batch purchases keep the named `InsufficientShares` revert instead.
     *
     *      A zero-share result after that clamp is a no-op: return 0 without touching storage or the
     *      protocol (R15 dust stays deferred — this is not a sweep). Any positive share redemption
     *      that pays nothing reverts and rolls the debit back.
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
        // @notice nothing to burn: do not debit, do not call the protocol, do not emit SharesRedeemed
        if (sharesToRedeem == 0) {
            return 0;
        }
        s_shares[user] -= sharesToRedeem;
        stablecoinReceived = _measuredProtocolRedeem(sharesToRedeem, exchangeRate);
        // @notice a protocol call that reports success but pays nothing still burnt the user's shares,
        // so revert instead of paying out zero. The revert rolls back the virtual debit and any
        // protocol-side burn. A positive dust balance (underlying floors below 1 wei) is not an
        // exception — R15 deferred that sweep.
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
    ) internal virtual returns (uint256) {
        uint256 exchangeRate = _exchangeRate();
        uint256 totalSharesToRedeem = _stablecoinToShares(totalStablecoinAmount, exchangeRate);

        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            // @notice the amount of shares each user redeems is proportional to the ratio of
            // that user's stablecoin being retrieved over the total being retrieved
            // @notice Rounds up the shares amount to avoid underestimating the amount to subtract from each user's balance
            uint256 usersSharesToRedeem =
                Math.mulDiv(totalSharesToRedeem, purchaseAmounts[i], totalStablecoinAmount, Math.Rounding.Up);
            uint256 usersShares = s_shares[users[i]];
            if (usersSharesToRedeem > usersShares) {
                revert TokenLending__InsufficientShares(users[i], usersSharesToRedeem, usersShares);
            }
            s_shares[users[i]] = usersShares - usersSharesToRedeem;
            emit TokenLending__SharesRedeemed(users[i], purchaseAmounts[i], usersSharesToRedeem);
        }
        uint256 stablecoinReceived = _measuredProtocolRedeem(totalSharesToRedeem, exchangeRate);
        if (stablecoinReceived > 0) emit TokenLending__SharesRedeemedBatch(stablecoinReceived, totalSharesToRedeem);
        else revert TokenLending__ZeroStablecoinReceived(totalStablecoinAmount);
        return stablecoinReceived;
    }

    /**
     * @notice mutating-ok exchange rate used on write paths
     */
    function _exchangeRate() internal virtual returns (uint256);

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
     * @notice the one place a redemption's cash is measured
     * @dev `AGENTS.md` invariant 1 lives here and nowhere else: adapters move the funds, this measures
     *      what arrived. An adapter that reported its own figure could return an integrator's claim
     *      instead of a balance delta, which is the mistake the invariant exists to prevent.
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
     * @notice burn `sharesAmount` at the lending protocol, crediting this contract
     * @dev Move the funds and nothing else. Do not measure, do not decide what a zero payout means —
     *      the base does both. Adapters only raise failures their own protocol reports (a Compound
     *      return code) or skip a call their own protocol rejects (a zero-amount Aave withdraw).
     * @param sharesAmount the share count to burn (after any clamp)
     * @param exchangeRate the rate already read by the caller; do not re-query the protocol
     */
    function _protocolRedeem(uint256 sharesAmount, uint256 exchangeRate) internal virtual;
}
