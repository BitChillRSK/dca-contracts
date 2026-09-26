// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IdleErc20Handler} from "src/idle/IdleErc20Handler.sol";
import {PurchaseUniswap} from "src/PurchaseUniswap.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {IUniswapV3SwapRouter} from "src/interfaces/IUniswapV3SwapRouter.sol";
import {MockMocOracle} from "test/mocks/MockMocOracle.sol";
import {MockWrbtcToken} from "test/mocks/MockWrbtcToken.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import "test/Constants.sol";

/**
 * @notice Production Dex leaves list funding then purchase (`IdleErc20Handler, PurchaseUniswap`).
 *         This harness reverses that `is` order so the test can prove path construction no longer
 *         depends on funding-first inheritance once `i_stableToken` lives on shared `StablecoinSource`.
 */
contract ReversedIdleErc20HandlerDex is PurchaseUniswap, IdleErc20Handler {
    constructor(
        address dcaManagerAddress,
        address stableTokenAddress,
        UniswapSettings memory uniswapSettings,
        address feeCollector,
        FeeSettings memory feeSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck,
        address initialOwner
    )
        IdleErc20Handler(dcaManagerAddress, stableTokenAddress, feeCollector, feeSettings, initialOwner)
        PurchaseUniswap(uniswapSettings, amountOutMinimumPercent, amountOutMinimumSafetyCheck)
    {}
}

contract ReversedDexInheritanceTest is Test {
    function testReversedIsOrderStillSetsPurchasePathFromStablecoin() public {
        MockStablecoin stablecoin = new MockStablecoin(address(this));
        MockWrbtcToken wrBtc = new MockWrbtcToken();
        MockMocOracle oracle = new MockMocOracle();
        address router = makeAddr("reversedDexRouter");

        address[] memory intermediateTokens = new address[](0);
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;

        IPurchaseUniswap.UniswapSettings memory uniswapSettings = IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(address(wrBtc)),
            swapRouter02: IUniswapV3SwapRouter(router),
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracle: ICoinPairPrice(address(oracle))
        });

        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });

        ReversedIdleErc20HandlerDex handler = new ReversedIdleErc20HandlerDex(
            address(this),
            address(stablecoin),
            uniswapSettings,
            address(0xFEE),
            feeSettings,
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            address(this)
        );

        assertEq(address(handler.i_stableToken()), address(stablecoin), "stablecoin immutable");
        bytes memory path = handler.getSwapPath();
        assertEq(_firstTokenInPath(path), address(stablecoin), "path hop 0 must be i_stableToken");
    }

    function _firstTokenInPath(bytes memory path) private pure returns (address token) {
        require(path.length >= 20, "path too short");
        uint256 packed;
        for (uint256 i; i < 20; ++i) {
            packed = (packed << 8) | uint8(path[i]);
        }
        token = address(uint160(packed));
    }
}
