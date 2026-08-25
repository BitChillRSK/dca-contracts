// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title StablecoinSource
 * @notice Shared declaration of the purchase-path funding hooks.
 * @dev PurchaseRbtc consumes these; LendingErc20Handler and IdleErc20Handler implement them.
 *      Declaring the seam once lets the six leaves drop forwarding resolvers.
 */
abstract contract StablecoinSource {
    /**
     * @notice retrieve the buyer's stablecoin onto the handler so the purchase can spend it
     * @dev Lending handlers redeem their shares here; the idle handler only debits its mapping.
     * @param buyer the address of the buyer
     * @param amount the amount of stablecoin wanted
     * @return the amount of stablecoin actually available to spend
     */
    function _retrieveStablecoin(address buyer, uint256 amount) internal virtual returns (uint256);

    /**
     * @notice retrieve several buyers' stablecoin for a batch purchase
     * @param buyers the addresses of the buyers
     * @param purchaseAmounts the amounts of stablecoin charged to each buyer
     * @param totalStablecoinToRetrieve the total amount of stablecoin wanted
     * @return the total amount of stablecoin actually available to spend
     */
    function _batchRetrieveStablecoin(
        address[] memory buyers,
        uint256[] memory purchaseAmounts,
        uint256 totalStablecoinToRetrieve
    ) internal virtual returns (uint256);
}
