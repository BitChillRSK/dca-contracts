// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {PurchaseUniswap} from "../../src/PurchaseUniswap.sol";
import {FeeHandler} from "../../src/FeeHandler.sol";
import {DcaManagerAccessControl} from "../../src/DcaManagerAccessControl.sol";
import {StablecoinSource} from "../../src/StablecoinSource.sol";
import {IPurchaseUniswap} from "../../src/interfaces/IPurchaseUniswap.sol";
import {IFeeHandler} from "../../src/interfaces/IFeeHandler.sol";
import {ICoinPairPrice} from "../../src/interfaces/ICoinPairPrice.sol";
import {IWRBTC} from "../../src/interfaces/IWRBTC.sol";
import {IUniswapV3SwapRouter} from "../../src/interfaces/IUniswapV3SwapRouter.sol";

/**
 * @notice Proves `PurchaseUniswap` rejects a zero `i_stableToken` at path construction.
 * @dev Split out of PurchaseUniswapSettingsTest.sol (R60) because this contract's constructor is
 *      deliberately, provably always-reverting — `StablecoinSource(address(0))` leaves the immutable
 *      unset — which trips a known solc/via_ir compiler limitation
 *      (https://github.com/ethereum/solidity/issues/11642): the optimizer proves the constructor
 *      always reverts, dead-code-eliminates everything after the revert including the immutable
 *      `setimmutable` for `i_stablecoinToUsdScale`, and a later checker then reports error 1284
 *      ("immutables read but never assigned"). That is a compiler analysis-ordering artifact on this
 *      always-reverting constructor, not a defect in `PurchaseUniswap`'s real constructor, and no
 *      reordering within `src/PurchaseUniswap.sol` changes that this specific derived test contract
 *      always reverts by design. This file alone is restricted to legacy codegen under
 *      `[profile.deploy]` (see foundry.toml and docs/relaunch/R60-src-only-via-ir.md); every other
 *      test file, and all of `src/`, compiles under `via_ir=true`.
 *
 *      This is not a reversed-inheritance proof: with `i_stableToken` on shared `StablecoinSource`,
 *      leaf `is` order no longer gates the token. See `ReversedDexInheritanceTest` for that.
 */
contract ZeroTokenPurchaseUniswap is PurchaseUniswap {
    constructor(
        address dcaManagerAddress,
        address feeCollector,
        IFeeHandler.FeeSettings memory feeSettings,
        UniswapSettings memory uniswapSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck
    )
        FeeHandler(feeCollector, feeSettings, msg.sender)
        DcaManagerAccessControl(dcaManagerAddress)
        StablecoinSource(address(0))
        PurchaseUniswap(uniswapSettings, amountOutMinimumPercent, amountOutMinimumSafetyCheck)
    {}

    function _batchRetrieveStablecoin(address[] calldata, uint256[] calldata)
        internal
        pure
        override
        returns (uint256)
    {
        return 0;
    }
}

contract PurchaseUniswapZeroTokenTest is Test {
    function testConstructorRevertsWhenPurchaseTokenIsZero() public {
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: 100,
            maxFeeRate: 100,
            feePurchaseLowerBound: 1000 ether,
            feePurchaseUpperBound: 100_000 ether
        });
        address[] memory intermediateTokens = new address[](0);
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;
        IPurchaseUniswap.UniswapSettings memory uniswapSettings = IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(address(0x1)),
            swapRouter02: IUniswapV3SwapRouter(address(0x2)),
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracle: ICoinPairPrice(address(0x3))
        });

        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__ZeroPurchaseToken.selector);
        new ZeroTokenPurchaseUniswap(
            address(this), address(0xFEE), feeSettings, uniswapSettings, 0.997 ether, 0.99 ether
        );
    }
}
