// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TokenHandler} from "src/TokenHandler.sol";
import {StablecoinSource} from "src/StablecoinSource.sol";
import {IIdleErc20Handler} from "./IIdleErc20Handler.sol";

/**
 * @title IdleErc20Handler
 * @notice Holds deposited stablecoin on the handler instead of minting shares.
 * @dev Per-user idle balances clamp withdrawals and single purchases so a DcaManager
 * accounting bug cannot spend another user's pooled DOC. Batch purchases revert instead
 * of clamping, because PurchaseMoc splits rBTC by the original planned weights.
 */
abstract contract IdleErc20Handler is TokenHandler, IIdleErc20Handler, StablecoinSource {
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
     * @param depositAmount: the amount requested from the user
     * @return depositedAmount the amount actually credited to the user's idle balance
     * @dev TokenHandler owns the balance-delta measurement and the zero-received revert,
     * so a fee-on-transfer token that delivers nothing never reaches the idle balance.
     */
    function depositToken(address user, uint256 depositAmount)
        public
        override
        onlyDcaManager
        returns (uint256 depositedAmount)
    {
        depositedAmount = super.depositToken(user, depositAmount);
        s_idleBalances[user] += depositedAmount;
    }

    /**
     * @notice withdraw the token amount sending it back to the user's address
     * @param user: the address of the user making the withdrawal
     * @param withdrawalAmount: the amount to withdraw
     * @return withdrawnAmount the amount that left this contract after debiting the idle mapping
     */
    function withdrawToken(address user, uint256 withdrawalAmount)
        public
        override
        onlyDcaManager
        returns (uint256)
    {
        uint256 requested = withdrawalAmount;
        withdrawalAmount = _debitIdleBalance(user, withdrawalAmount);
        if (requested > 0 && withdrawalAmount == 0) revert IdleErc20Handler__ZeroStablecoinPaid(requested);
        return super.withdrawToken(user, withdrawalAmount);
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
     * @notice retrieve `amount` of the user's idle DOC for the purchase path
     * @dev Lending handlers redeem their shares to pull DOC onto the handler; idle DOC is
     * already here, so this only debits the mapping.
     * @param user: the address of the user
     * @param amount: the amount of stablecoin to debit
     * @return the amount actually debited
     */
    function _retrieveStablecoin(address user, uint256 amount) internal virtual override returns (uint256) {
        return _debitIdleBalance(user, amount);
    }

    /**
     * @notice debit each buyer's idle DOC for a batch purchase
     * @dev Reverts if any buyer cannot cover their purchase amount. Clamping here would
     * return a short total that PurchaseMoc still splits by the original planned weights,
     * so one underfunded buyer would dilute every other buyer in the batch.
     * @param users: the addresses of the users
     * @param purchaseAmounts: the amounts of stablecoin to debit
     * @return totalWithdrawn the total amount debited
     */
    function _batchRetrieveStablecoin(address[] memory users, uint256[] memory purchaseAmounts, uint256)
        internal
        virtual
        override
        returns (uint256 totalWithdrawn)
    {
        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            uint256 amount = purchaseAmounts[i];
            uint256 idleBalance = s_idleBalances[users[i]];
            if (amount > idleBalance) {
                revert IdleErc20Handler__InsufficientIdleBalance(users[i], amount, idleBalance);
            }
            s_idleBalances[users[i]] = idleBalance - amount;
            totalWithdrawn += amount;
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
