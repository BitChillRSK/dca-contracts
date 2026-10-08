// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStablecoinSource} from "./interfaces/IStablecoinSource.sol";

/**
 * @title StablecoinSource
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Shared stablecoin immutable and batch-funding hook for handlers and purchase routes.
 * @dev Owns `i_stablecoin` so deposit/withdraw and the purchase pipeline name the same token.
 *      Lending and idle bases implement `_batchRetrieveStablecoin`.
 */
abstract contract StablecoinSource is IStablecoinSource {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStablecoinSource
    IERC20 public immutable override i_stablecoin;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param stablecoin The stablecoin this handler holds or lends out.
     */
    constructor(address stablecoin) {
        if (stablecoin == address(0)) revert StablecoinSource__ZeroStablecoin();
        i_stablecoin = IERC20(stablecoin);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Retrieve several buyers' stablecoin for a batch purchase.
     * @param buyers Buyers whose positions are debited.
     * @param purchaseAmounts Per-row funding weights. May get clamped; the caller
     *        uses the resulting weights for fees and output allocation.
     * @return The total amount actually available to spend.
     */
    function _batchRetrieveStablecoin(address[] calldata buyers, uint256[] memory purchaseAmounts)
        internal
        virtual
        returns (uint256);
}
