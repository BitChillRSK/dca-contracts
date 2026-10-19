// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {DcaManagerHandler} from "./DcaManagerHandler.sol";
import {OperationsAdminHandler} from "./OperationsAdminHandler.sol";
import {LayerBankHandlerDexHandler} from "./LayerBankHandlerDexHandler.sol";
import {EnvironmentHandler} from "./EnvironmentHandler.sol";
import {RoundTripHandler} from "./RoundTripHandler.sol";
import {AdversarialHandler} from "./AdversarialHandler.sol";

/// @notice Inherits from all the handlers to expose all entry points in a single contract.
///         Manages environment changes (e.g. current actor, current token, mocks setup, etc.).
abstract contract Handlers is
    DcaManagerHandler,
    OperationsAdminHandler,
    LayerBankHandlerDexHandler,
    EnvironmentHandler,
    RoundTripHandler,
    AdversarialHandler
{
    function setCurrentActor(uint256 entropy) public {
        actor = actors[entropy % actors.length];
    }

    function setCurrentSwapper(uint256 entropy) public {
        swapper = swappers[entropy % swappers.length];
    }
}
