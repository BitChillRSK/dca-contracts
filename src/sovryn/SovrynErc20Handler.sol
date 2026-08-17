// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenHandler} from "src/interfaces/ITokenHandler.sol";
import {TokenHandler} from "src/TokenHandler.sol";
import {IiSusdToken} from "./IiSusdToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenLending} from "src/TokenLending.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SovrynErc20Handler
 * @notice This abstract contract contains the stablecoin related functions that are common regardless of the method used to swap stablecoin for rBTC
 */
abstract contract SovrynErc20Handler is TokenHandler, TokenLending {
    using SafeERC20 for IERC20;

    //////////////////////
    // State variables ///
    //////////////////////
    IiSusdToken public immutable i_iSusdToken;
    mapping(address user => uint256 balance) internal s_iSusdBalances;

    /**
     * @param dcaManagerAddress the address of the DCA Manager contract
     * @param stableTokenAddress the address of the Dollar On Chain token on the blockchain of deployment
     * @param iSusdTokenAddress the address of Sovryn' iSusd token contract
     * @param feeCollector the address of to which fees will sent on every purchase
     * @param feeSettings struct with the settings for fee calculations
     */
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        address iSusdTokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 exchangeRateDecimals
    )
        TokenHandler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings)
        TokenLending(exchangeRateDecimals)
    {
        i_iSusdToken = IiSusdToken(iSusdTokenAddress);
    }

    /**
     * @notice deposit the full token amount for DCA on the contract
     * @param user: the address of the user making the deposit
     * @param depositAmount: the amount requested from the user
     * @return depositedAmount the stablecoin amount actually received before minting iTokens
     */
    function depositToken(address user, uint256 depositAmount)
        public
        override(TokenHandler, ITokenHandler)
        onlyDcaManager
        returns (uint256 depositedAmount)
    {
        depositedAmount = super.depositToken(user, depositAmount);
        if (i_stableToken.allowance(address(this), address(i_iSusdToken)) < depositedAmount) {
            i_stableToken.safeApprove(address(i_iSusdToken), depositedAmount);
        }
        // @notice the iSusd we credit is the balance we actually gained, never mint()'s return value
        uint256 prevIsusdBalance = i_iSusdToken.balanceOf(address(this));
        i_iSusdToken.mint(address(this), depositedAmount);
        uint256 mintedAmount = i_iSusdToken.balanceOf(address(this)) - prevIsusdBalance;
        if (mintedAmount == 0) revert TokenLending__LendingProtocolDepositFailed();
        s_iSusdBalances[user] += mintedAmount;
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
        uint256 exchangeRate = i_iSusdToken.tokenPrice();
        uint256 stablecoinInSovryn = _lendingTokenToStablecoin(s_iSusdBalances[user], exchangeRate);

        if (stablecoinInSovryn < withdrawalAmount) {
            emit TokenLending__WithdrawalAmountAdjusted(user, withdrawalAmount, stablecoinInSovryn);
            withdrawalAmount = stablecoinInSovryn;
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
        return s_iSusdBalances[user];
    }

    /**
     * @notice withdraw the interest
     * @param user: the address of the user
     * @param stablecoinLockedInDcaSchedules: the amount of stablecoin locked in DCA schedules
     */
    function withdrawInterest(address user, uint256 stablecoinLockedInDcaSchedules) external override onlyDcaManager {
        uint256 exchangeRate = i_iSusdToken.tokenPrice();
        uint256 totalErc20InLending = _lendingTokenToStablecoin(s_iSusdBalances[user], exchangeRate);
        if (totalErc20InLending <= stablecoinLockedInDcaSchedules) {
            return; // No interest to withdraw
        }
        uint256 stablecoinInterestAmount = totalErc20InLending - stablecoinLockedInDcaSchedules;
        stablecoinInterestAmount = _redeemLendingToken(user, stablecoinInterestAmount, exchangeRate, user);
        emit TokenLending__InterestWithdrawn(user, address(i_stableToken), stablecoinInterestAmount);
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
        uint256 totalErc20InLending = _lendingTokenToStablecoin(s_iSusdBalances[user], i_iSusdToken.tokenPrice());
        stablecoinInterestAmount = totalErc20InLending > stablecoinLockedInDcaSchedules ? totalErc20InLending - stablecoinLockedInDcaSchedules : 0;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice retrieve the user's stablecoin by redeeming iSusd
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @return the amount of stablecoin this contract actually received
     */
    function _retrieveStablecoin(address user, uint256 stablecoinAmount) internal virtual returns (uint256) {
        // For buyRbtc(), we want the stablecoin to come to the contract
        return _redeemLendingToken(user, stablecoinAmount, i_iSusdToken.tokenPrice(), address(this));
    }

    /**
     * @notice redeem enough iSusd to get `stablecoinAmount` of stablecoin onto this contract
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @return the amount of stablecoin this contract actually received
     */
    function _redeemLendingToken(address user, uint256 stablecoinAmount, uint256 exchangeRate) internal virtual returns (uint256) {
        return _redeemLendingToken(user, stablecoinAmount, exchangeRate, address(this));
    }

    /**
     * @notice redeem the user's iSusd and send the stablecoin it frees to `stablecoinRecipient`
     * @param user: the address of the user
     * @param stablecoinAmount: the amount of stablecoin wanted
     * @param exchangeRate: the exchange rate of stablecoin to lending token
     * @param stablecoinRecipient: the address of the recipient of the stablecoin
     * @return stablecoinReceived the amount of stablecoin the recipient actually received
     * @dev Sovryn's burn() returns the GROSS amount and pays the NET one once an exit fee is enabled
     * (SIP-0094), so the recipient's measured balance delta is the only trustworthy amount.
     */
    function _redeemLendingToken(address user, uint256 stablecoinAmount, uint256 exchangeRate, address stablecoinRecipient)
        internal
        virtual
        returns (uint256 stablecoinReceived)
    {
        uint256 usersIsusdBalance = s_iSusdBalances[user];
        uint256 iSusdToRepay = _stablecoinToLendingToken(stablecoinAmount, exchangeRate);
        if (iSusdToRepay > usersIsusdBalance) {
            uint256 oldiSusdToRepay = iSusdToRepay;
            uint256 oldStablecoinAmount = stablecoinAmount;
            iSusdToRepay = usersIsusdBalance;
            stablecoinAmount = _lendingTokenToStablecoin(iSusdToRepay, exchangeRate);
            emit TokenLending__AmountToRepayAdjusted(user, oldiSusdToRepay, iSusdToRepay, oldStablecoinAmount, stablecoinAmount);
        }
        s_iSusdBalances[user] -= iSusdToRepay;
        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(stablecoinRecipient);
        i_iSusdToken.burn(stablecoinRecipient, iSusdToRepay);
        stablecoinReceived = i_stableToken.balanceOf(stablecoinRecipient) - stablecoinBalanceBefore;
        if (stablecoinReceived == 0) revert TokenLending__ZeroStablecoinReceived(stablecoinAmount);
        emit TokenLending__LendingTokenRedeemed(user, stablecoinReceived, iSusdToRepay);
    }

    /**
     * @notice retrieve several users' stablecoin in one iSusd redemption
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
        uint256 totaliSusdToRepay = _stablecoinToLendingToken(totalStablecoinAmount, i_iSusdToken.tokenPrice());

        uint256 numOfPurchases = users.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            // @notice the amount of iSusd each user repays is proportional to the ratio of
            // that user's stablecoin being retrieved over the total being retrieved
            uint256 usersRepaidiSusd = Math.mulDiv(totaliSusdToRepay, purchaseAmounts[i], totalStablecoinAmount, Math.Rounding.Up);
            uint256 usersIsusdBalance = s_iSusdBalances[users[i]];
            if (usersRepaidiSusd > usersIsusdBalance) {
                revert TokenLending__InsufficientLendingTokenBalance(users[i], usersRepaidiSusd, usersIsusdBalance);
            }
            s_iSusdBalances[users[i]] = usersIsusdBalance - usersRepaidiSusd;
            emit TokenLending__LendingTokenRedeemed(users[i], purchaseAmounts[i], usersRepaidiSusd);
        }
        uint256 stablecoinBalanceBefore = i_stableToken.balanceOf(address(this));
        i_iSusdToken.burn(address(this), totaliSusdToRepay);
        uint256 stablecoinReceived = i_stableToken.balanceOf(address(this)) - stablecoinBalanceBefore;
        if (stablecoinReceived > 0) emit TokenLending__LendingTokenRedeemedBatch(stablecoinReceived, totaliSusdToRepay);
        else revert TokenLending__ZeroStablecoinReceived(totalStablecoinAmount);
        return stablecoinReceived;
    }
}
