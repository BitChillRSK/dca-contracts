// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "../../script/Constants.sol";
import {MockWrbtcToken} from "./MockWrbtcToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Minimal mock interface for Uniswap V3 SwapRouter
interface IV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

// Mock implementation of SwapRouter02 (V3 Router)
contract MockSwapRouter02 is IV3SwapRouter {
    MockWrbtcToken s_mockWrbtcToken;
    uint256 private s_outputTokenPrice;

    constructor(MockWrbtcToken mockWrbtcToken, uint256 _outputTokenPrice) {
        s_mockWrbtcToken = mockWrbtcToken;
        s_outputTokenPrice = _outputTokenPrice;
    }

    // Mock function to simulate exactInput swap
    function exactInput(ExactInputParams calldata params) external payable override returns (uint256 amountOut) {
        require(params.amountIn > 0, "AmountIn must be greater than zero");
        require(params.path.length >= 20, "Path too short");

        amountOut = (params.amountIn * 997) / (1000 * s_outputTokenPrice);

        require(params.amountOutMinimum <= amountOut, "Insufficient output amount");

        // Pull the input token like a real router (path starts with tokenIn)
        address tokenIn = address(uint160(bytes20(params.path[:20])));
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "transferFrom failed");

        // To simulate the handler receiving WRBTC when exactInput is called, deposit rBTC in the WRBTC contract
        // msg.sender is the handler
        s_mockWrbtcToken.deposit{value: amountOut}(msg.sender);

        return amountOut;
    }

    // Allow changing the price of the output token for testing purposes
    function setFixedAmountOut(uint256 _newPrice) external {
        s_outputTokenPrice = _newPrice;
    }
}
