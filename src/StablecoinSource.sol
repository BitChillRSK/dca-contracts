// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenHandler} from "./interfaces/ITokenHandler.sol";

/**
 * @title StablecoinSource
 * @notice Shared declaration of the purchase-path funding hooks.
 * @dev PurchaseRbtc consumes these; LendingErc20Handler and IdleErc20Handler implement them.
 *      Declaring the seam once lets the six leaves drop forwarding resolvers, and keeps the
 *      token the purchase reports as spent tied to the token the handler actually holds.
 */
abstract contract StablecoinSource {
    /**
     * @notice Per-user funded balance and accumulated rBTC, packed into one slot.
     * @dev Declared here because this is the one contract both sides of a handler inherit: the funding
     *      base (LendingErc20Handler / IdleErc20Handler) owns `fundedBalance`, and PurchaseRbtc owns
     *      `accumulatedRbtc`. Neither is narrowed below uint128, which holds 3.4e20 whole tokens at 18
     *      decimals — far above any share or rBTC balance a handler can hold.
     */
    mapping(address user => ITokenHandler.UserPosition position) internal s_userPositions;

    /**
     * @notice the stablecoin handled (held or lent out), spent by the purchase and reported in fees, errors, and events
     * @dev Implemented against the handler's own stablecoin so the purchase route cannot name a different token.
     * @return the stablecoin token
     */
    function _purchaseToken() internal view virtual returns (IERC20);

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
