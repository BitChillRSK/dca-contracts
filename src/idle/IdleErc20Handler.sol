// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {TokenHandler} from "../TokenHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IdleErc20Handler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Base for the handlers that hold their stablecoin instead of lending it; each leaf adds a
 *         purchase route.
 * @dev Deposits stay on this contract as the stablecoin itself. There is no per-user handler ledger:
 *      schedule `tokenBalance` in DcaManager is the liability, and handler cash is the pooled cover.
 *      Withdrawals and batch funding take the amounts DcaManager supplies; an overstatement against
 *      another user's pooled cash is refused only by schedule ownership and the manager's balance
 *      checks, not by a shadow book here.
 */
abstract contract IdleErc20Handler is TokenHandler {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param dcaManagerAddress The DcaManager allowed to call deposit and withdraw.
     * @param stableTokenAddress The ERC20 stablecoin this handler holds idle.
     */
    constructor(address dcaManagerAddress, address stableTokenAddress)
        TokenHandler(dcaManagerAddress, stableTokenAddress)
    {}

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Pay `withdrawalAmount` from this contract's pooled cash and return the measured balance delta.
    function _withdrawToken(address user, uint256 withdrawalAmount)
        internal
        virtual
        override
        returns (uint256 withdrawnAmount)
    {
        uint256 balanceBefore = i_stableToken.balanceOf(address(this));
        i_stableToken.safeTransfer(user, withdrawalAmount);
        withdrawnAmount = balanceBefore - i_stableToken.balanceOf(address(this));
        emit TokenHandler__TokenWithdrawn(address(i_stableToken), user, withdrawnAmount);
    }

    /**
     * @dev Sum the batch's purchase amounts. Cash already sits on this handler; DcaManager debits
     *      each schedule before the call, so a second per-user book here would only re-store the
     *      same figures.
     */
    function _batchRetrieveStablecoin(address[] calldata, uint256[] calldata purchaseAmounts)
        internal
        virtual
        override
        returns (uint256 totalWithdrawn)
    {
        uint256 numOfPurchases = purchaseAmounts.length;
        for (uint256 i; i < numOfPurchases; ++i) {
            // Each amount is a uint96, so the sum cannot overflow.
            unchecked {
                totalWithdrawn += purchaseAmounts[i];
            }
        }
    }
}
