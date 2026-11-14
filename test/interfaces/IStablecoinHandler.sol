// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ITokenHandler} from "../../src/interfaces/ITokenHandler.sol";
import {ILendingHandler} from "../../src/interfaces/ILendingHandler.sol";

/**
 * @title IStablecoinHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 */
interface IStablecoinHandler is ITokenHandler, ILendingHandler {}
