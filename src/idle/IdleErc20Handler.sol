// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TokenHandler} from "src/TokenHandler.sol";
import {IIdleErc20Handler} from "./IIdleErc20Handler.sol";

/**
 * @title IdleErc20Handler
 * @notice Holds deposited stablecoin on the handler instead of minting a lending token.
 * @dev Per-user idle balances clamp withdrawals and purchases so a DcaManager accounting
 * bug cannot spend another user's pooled DOC.
 */
abstract contract IdleErc20Handler is TokenHandler, IIdleErc20Handler {
    //////////////////////
    // State variables ///
    //////////////////////
    mapping(address user => uint256 balance) internal s_idleBalances;

    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param stableTokenAddress the address of the ERC20 stablecoin token on the blockchain of deployment
     * @param feeCollector the address to which fees will be sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings
    ) TokenHandler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings) {}

    /**
     * @notice deposit the full token amount for DCA on the contract
     * @param user: the address of the user making the deposit
     * @param depositAmount: the amount to deposit
     */
    function depositToken(address user, uint256 depositAmount)
        public
        override
        onlyDcaManager
    {
        uint256 balanceBefore = i_stableToken.balanceOf(address(this));
        super.depositToken(user, depositAmount);
        uint256 received = i_stableToken.balanceOf(address(this)) - balanceBefore;
        if (depositAmount > 0 && received == 0) revert IdleErc20Handler__ZeroStablecoinReceived();
        s_idleBalances[user] += received;
    }

    /**
     * @notice withdraw the token amount sending it back to the user's address
     * @param user: the address of the user making the withdrawal
     * @param withdrawalAmount: the amount to withdraw
     * @return the amount of stablecoin actually paid to the user
     */
    function withdrawToken(address user, uint256 withdrawalAmount)
        public
        override
        onlyDcaManager
        returns (uint256)
    {
        withdrawalAmount = _debitIdleBalance(user, withdrawalAmount);
        uint256 userBalanceBefore = i_stableToken.balanceOf(user);
        super.withdrawToken(user, withdrawalAmount);
        return i_stableToken.balanceOf(user) - userBalanceBefore;
    }

    /**
     * @notice get the users idle token balance
     * @param user: the address of the user
     * @return the users idle token balance
     */
    function getUsersIdleTokenBalance(address user) external view override returns (uint256) {
        return s_idleBalances[user];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice debit idle DOC for a purchase; the tokens are already on this contract
     * @param user: the address of the user
     * @param amount: the amount of stablecoin to debit
     * @return the amount actually debited
     */
    function _redeemStablecoin(address user, uint256 amount) internal virtual returns (uint256) {
        return _debitIdleBalance(user, amount);
    }

    /**
     * @notice debit idle DOC for a batch of purchases; the tokens are already on this contract
     * @param users: the addresses of the users
     * @param purchaseAmounts: the amounts of stablecoin to debit
     * @return totalRedeemed the total amount actually debited
     */
    function _batchRedeemStablecoin(address[] memory users, uint256[] memory purchaseAmounts, uint256)
        internal
        virtual
        returns (uint256 totalRedeemed)
    {
        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            totalRedeemed += _debitIdleBalance(users[i], purchaseAmounts[i]);
        }
    }

    /**
     * @notice clamp `amount` to the user's idle balance and debit it
     * @param user: the address of the user
     * @param amount: the amount requested
     * @return the amount actually debited
     */
    function _debitIdleBalance(address user, uint256 amount) internal returns (uint256) {
        uint256 idleBalance = s_idleBalances[user];
        if (idleBalance < amount) {
            emit IdleErc20Handler__AmountAdjusted(user, amount, idleBalance);
            amount = idleBalance;
        }
        s_idleBalances[user] = idleBalance - amount;
        return amount;
    }
}
