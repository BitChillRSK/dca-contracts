// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title StablecoinSource
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Shared declaration of the purchase-path funding hooks.
 * @dev PurchaseRbtc consumes these; LendingErc20Handler and IdleErc20Handler implement them.
 *      Declaring the seam once lets the six leaves drop forwarding resolvers, and keeps the
 *      token the purchase reports as spent tied to the token the handler actually holds.
 *      It is also the only base both the lending side and the purchase side inherit, so the
 *      standing-allowance repair they share is declared here.
 */
abstract contract StablecoinSource {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Restores a standing allowance that no longer covers `amount`, and is a no-op otherwise.
     *      Both spenders are granted `type(uint256).max` at construction, so this never fires in the
     *      ordinary course — reaching it by spending alone would take ~2**256 wei of cumulative flow.
     *      It fires when something outside this contract clears the allowance, which two of the three
     *      shipped stablecoins can do: they sit behind upgradeable proxies. Without it the affected
     *      path is bricked for good, because the grant happens only in the constructor.
     *
     *      Re-grants `max` rather than `amount`, so the path returns to the zero-write steady state the
     *      standing approval exists for instead of paying a write on every later call. That widens
     *      nothing: it restores the same allowance to the same immutable spender the constructor
     *      already granted, and cannot name a different one.
     */
    function _ensureStandingAllowance(IERC20 token, address spender, uint256 amount) internal {
        if (token.allowance(address(this), spender) < amount) {
            token.forceApprove(spender, type(uint256).max);
        }
    }

    /**
     * @dev The stablecoin this handler holds or lends out, spent by the purchase and reported in
     *      fees, errors, and events. Implemented against the handler's own stablecoin so the
     *      purchase route cannot name a different token.
     */
    function _purchaseToken() internal view virtual returns (IERC20);

    /**
     * @dev Retrieve several buyers' stablecoin for a batch purchase.
     * @param buyers Buyers whose positions are debited.
     * @param purchaseAmounts Amount charged to each buyer.
     * @return The total amount actually available to spend.
     */
    function _batchRetrieveStablecoin(
        address[] memory buyers,
        uint256[] memory purchaseAmounts
    ) internal virtual returns (uint256);
}
