// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenLending} from "src/interfaces/ITokenLending.sol";

/**
 * @title ITropykusErc20Lending
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the TropykusErc20Handler contract.
 */
interface ITropykusErc20Lending is ITokenLending {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error TropykusErc20Lending__RedeemUnderlyingFailed(uint256 errorCode);
    /// @notice the redemption reported success but paid nothing, so the burnt kToken bought no stablecoin
    error TropykusErc20Lending__ZeroStablecoinRedeemed(uint256 stablecoinRequested);
}
