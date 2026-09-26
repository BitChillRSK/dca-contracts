// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IStablecoinSource
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice The stablecoin a handler is built for.
 * @dev Declared once, here, for both halves of a handler: `ITokenHandler` (deposit and withdraw) and
 *      `IPurchaseRbtc` (purchases) extend it, and `StablecoinSource` answers it with one public immutable.
 *      A public state variable can override only a single declaration, so neither half declares the
 *      getter itself.
 */
interface IStablecoinSource {
    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The stablecoin this handler deposits, withdraws, and spends on purchases.
     * @return The constructor-supplied ERC20.
     */
    function i_stableToken() external view returns (IERC20);
}
