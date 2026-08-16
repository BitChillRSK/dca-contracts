// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {DcaManagerAccessControl} from "./DcaManagerAccessControl.sol";

/**
 * @title PurchaseRbtc
 * @notice Base contract for purchasing and handling rBTC
 */
abstract contract PurchaseRbtc is IPurchaseRbtc, DcaManagerAccessControl {
    //////////////////////
    // State variables ///
    //////////////////////
    mapping(address user => uint256 amount) internal s_usersAccumulatedRbtc;

    /**
     * @notice Allow the contract to receive rBTC
     */
    receive() external payable {}

    /**
     * @notice the user can at any time withdraw the rBTC that has been accumulated through periodical purchases
     * @param user: the user to withdraw the rBTC to
     */
    function withdrawAccumulatedRbtc(address user) external virtual override onlyDcaManager {
        uint256 rbtcBalance = _withdrawRbtcChecksEffects(user);
        _withdrawRbtc(user, rbtcBalance);
    }

    /**
     * @notice get the accumulated rBTC balance for a specific user
     * @param user the address of the user to check the accumulated rBTC balance for
     * @return the accumulated rBTC balance
     */
    function getAccumulatedRbtcBalance(address user) external view override returns (uint256) {
        return s_usersAccumulatedRbtc[user];
    }

    /**
     * @notice get the accumulated rBTC balance for the caller
     * @return the accumulated rBTC balance
     */
    function getAccumulatedRbtcBalance() external view override returns (uint256) {
        return s_usersAccumulatedRbtc[msg.sender];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice checks and effects for the withdrawal of rBTC from the contract
     * @param user: the user to withdraw the rBTC to
     * @return the amount of rBTC to withdraw
     */
    function _withdrawRbtcChecksEffects(address user) internal returns (uint256) {
        uint256 rbtcBalance = s_usersAccumulatedRbtc[user];
        if (rbtcBalance == 0) revert PurchaseRbtc__NoAccumulatedRbtcToWithdraw();

        s_usersAccumulatedRbtc[user] = 0;
        return rbtcBalance;
    }

    /**
     * @notice withdraw rBTC from the contract
     * @param user: the user to withdraw the rBTC to
     * @param rbtcBalance: the amount of rBTC to withdraw
     */
    function _withdrawRbtc(address user, uint256 rbtcBalance) internal {
        (bool sent,) = user.call{value: rbtcBalance}("");
        if (!sent) revert PurchaseRbtc__rBtcWithdrawalFailed();
        emit PurchaseRbtc__rBtcWithdrawn(user, rbtcBalance);
    }

    /**
     * @notice redeem stablecoin for rBTC
     * @notice define abstract functions to be implemented by child contracts
     * @dev these functions semantically belong to the TokenLending contract,
     * however, putting them there and changing the inheritance graph made it 
     * impossible to linearize and finding another solution  would have required a major refactor.
     * @param buyer: the address of the buyer
     * @param amount: the amount of stablecoin to redeem
     * @return the amount of stablecoin redeemed
     */
    function _redeemStablecoin(address buyer, uint256 amount) internal virtual returns (uint256);

    /**
     * @notice redeem stablecoin for rBTC in batch
     * @param buyers: the addresses of the buyers
     * @param purchaseAmounts: the amounts of stablecoin to redeem for each buyer
     * @param totalStablecoinAmountToRedeem: the total amount of stablecoin to redeem
     * @return the total amount of stablecoin redeemed
     */
    function _batchRedeemStablecoin(address[] memory buyers, uint256[] memory purchaseAmounts, uint256 totalStablecoinAmountToRedeem)
        internal
        virtual
        returns (uint256);
} 