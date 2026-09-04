// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title StablecoinSource
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Shared declaration of the purchase-path funding hooks.
 * @dev PurchaseRbtc consumes these; LendingErc20Handler and IdleErc20Handler implement them.
 *      Declaring the seam once lets the six leaves drop forwarding resolvers, and keeps the
 *      token the purchase reports as spent tied to the token the handler actually holds.
 */
abstract contract StablecoinSource {
    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The stablecoin this handler holds or lends out, spent by the purchase and reported in
     *      fees, errors, and events. Implemented against the handler's own stablecoin so the
     *      purchase route cannot name a different token.
     */
    function _purchaseToken() internal view virtual returns (IERC20);

    /**
     * @dev Retrieve the buyer's stablecoin onto the handler so the purchase can spend it.
     *      Lending handlers redeem their shares here; the idle handler only debits its mapping.
     * @param buyer Buyer whose position is debited.
     * @param amount Stablecoin wanted.
     * @return The amount actually available to spend.
     */
    function _retrieveStablecoin(address buyer, uint256 amount) internal virtual returns (uint256);

    /**
     * @dev Retrieve several buyers' stablecoin for a batch purchase.
     * @param buyers Buyers whose positions are debited.
     * @param purchaseAmounts Amount charged to each buyer.
     * @param totalStablecoinToRetrieve Total stablecoin wanted.
     * @return The total amount actually available to spend.
     */
    function _batchRetrieveStablecoin(
        address[] memory buyers,
        uint256[] memory purchaseAmounts,
        uint256 totalStablecoinToRetrieve
    ) internal virtual returns (uint256);
}
