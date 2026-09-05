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
     * @dev Retrieve several buyers' stablecoin for a batch purchase, and say which rows it could fund.
     *      A buyer's position here is pooled across their schedules on this route, so whether a row can
     *      be funded is decided in row order against what that buyer has left, and a row that cannot be
     *      funded in full is dropped rather than clamped: a short row would still carry its original
     *      weight through the allocation and so would be paid for out of the other buyers' stablecoin.
     * @param buyers Buyers whose positions are debited.
     * @param purchaseAmounts Amount charged to each buyer, edited in place: a row this handler could
     *        not fund is set to zero, and a row that is already zero is passed over untouched.
     * @return totalRetrieved The total amount actually available to spend.
     * @return unfundedRows Indexes of the rows this handler could not fund, ascending. Empty — and
     *         never allocated — when it funded every row it was given, which is the usual case.
     */
    function _batchRetrieveStablecoin(address[] memory buyers, uint256[] memory purchaseAmounts)
        internal
        virtual
        returns (uint256 totalRetrieved, uint256[] memory unfundedRows);

    /**
     * @dev Copy the first `length` entries of a row-index list into a right-sized array. Reached only
     *      by a batch that actually had a row it could not fund.
     */
    function _trimRowIndexes(uint256[] memory rowIndexes, uint256 length)
        internal
        pure
        returns (uint256[] memory trimmed)
    {
        trimmed = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            trimmed[i] = rowIndexes[i];
        }
    }
}
