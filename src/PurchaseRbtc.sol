// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IPurchaseRbtc} from "src/interfaces/IPurchaseRbtc.sol";
import {DcaManagerAccessControl} from "./DcaManagerAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PurchaseRbtc
 * @notice Base contract for purchasing and handling rBTC
 */
abstract contract PurchaseRbtc is IPurchaseRbtc, Ownable, DcaManagerAccessControl {
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
     * @notice Emergency function to withdraw rBTC stuck in contracts that cannot receive native tokens
     * @param stuckUserContract The address of the user contract where rBTC is stuck
     * @param rescueAddress The address to send the rescued rBTC to
     * @dev This function can only be called by the owner
     */
    function withdrawStuckRbtc(address stuckUserContract, address rescueAddress) external virtual onlyOwner {
        uint256 rbtcBalance = _withdrawRbtcChecksEffects(stuckUserContract);
        _withdrawStuckRbtc(stuckUserContract, rescueAddress, rbtcBalance);
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
     * @notice withdraw rBTC from stuck contract. Only necessary for users who (poorly) interacted with Bitchill from a contract
     * @param stuckUserContract: the address of the contract that interacted with Bitchill
     * @param rescueAddress: the address to send the rBTC to
     * @param rbtcBalance: the amount of rBTC to withdraw
     */
    function _withdrawStuckRbtc(address stuckUserContract, address rescueAddress, uint256 rbtcBalance) internal {
        // First try to send to the contract (might work if it has a fallback)
        (bool sentToContract,) = stuckUserContract.call{value: rbtcBalance}("");
        
        // If failed, send to the rescue address
        if (!sentToContract) {
            (bool sentToRescue,) = rescueAddress.call{value: rbtcBalance}("");
            if (!sentToRescue) revert PurchaseRbtc__rBtcWithdrawalFailed();
            emit PurchaseRbtc__rBtcRescued(stuckUserContract, rescueAddress, rbtcBalance);
        } else {
            emit PurchaseRbtc__rBtcWithdrawn(stuckUserContract, rbtcBalance);
        }
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