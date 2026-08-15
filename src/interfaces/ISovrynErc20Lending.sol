// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenLending} from "./ITokenLending.sol";

/**
 * @title ISovrynErc20Lending
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the SovrynErc20Handler contract.
 */
interface ISovrynErc20Lending is ITokenLending {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error SovrynErc20Lending__RedeemUnderlyingFailed();
}
