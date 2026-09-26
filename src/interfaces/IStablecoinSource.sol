// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IStablecoinSource
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice The stablecoin a handler is built for.
 * @dev `ITokenHandler` and `IPurchaseRbtc` both extend this, so one public immutable answers both.
 */
interface IStablecoinSource {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The handler was constructed with a zero stablecoin address.
    error StablecoinSource__ZeroStablecoin();

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The stablecoin this handler deposits, withdraws, and spends on purchases.
     * @return The constructor-supplied ERC20.
     */
    function i_stableToken() external view returns (IERC20);
}
