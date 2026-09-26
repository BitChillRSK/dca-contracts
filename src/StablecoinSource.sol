// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title StablecoinSource
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Shared stablecoin immutable and batch-funding hook for handlers and purchase routes.
 * @dev Owns `i_stableToken` so deposit/withdraw and the purchase pipeline name the same token.
 *      Lending and idle bases implement `_batchRetrieveStablecoin`.
 */
abstract contract StablecoinSource {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The stablecoin this handler deposits, withdraws, and spends on purchases.
     * @return The constructor-supplied ERC20.
     */
    IERC20 public immutable i_stableToken;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param tokenAddress The stablecoin this handler holds or lends out.
     */
    constructor(address tokenAddress) {
        i_stableToken = IERC20(tokenAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Retrieve several buyers' stablecoin for a batch purchase.
     * @param buyers Buyers whose positions are debited.
     * @param purchaseAmounts Amount charged to each buyer.
     * @return The total amount actually available to spend.
     */
    function _batchRetrieveStablecoin(
        address[] calldata buyers,
        uint256[] calldata purchaseAmounts
    ) internal virtual returns (uint256);
}
