// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IdleDocHandlerMoc} from "src/idle/IdleDocHandlerMoc.sol";
import {IdleErc20HandlerDex} from "src/idle/IdleErc20HandlerDex.sol";
import {SovrynDocHandlerMoc} from "src/sovryn/SovrynDocHandlerMoc.sol";
import {SovrynErc20HandlerDex} from "src/sovryn/SovrynErc20HandlerDex.sol";
import {LayerBankDocHandlerMoc} from "src/layerbank/LayerBankDocHandlerMoc.sol";
import {LayerBankErc20HandlerDex} from "src/layerbank/LayerBankErc20HandlerDex.sol";
import {IStablecoinSource} from "src/interfaces/IStablecoinSource.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {IUniswapV3SwapRouter} from "src/interfaces/IUniswapV3SwapRouter.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockIsusdToken} from "test/mocks/MockIsusdToken.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "test/mocks/MockLayerBank.sol";
import {MockMocOracle} from "test/mocks/MockMocOracle.sol";
import {MockWrbtcToken} from "test/mocks/MockWrbtcToken.sol";
import "test/Constants.sol";

/**
 * @notice Every production handler leaf refuses a zero stablecoin at construction.
 * @dev Each market mock is real and wraps a real stablecoin, so the stablecoin argument is the only bad
 *      one. `StablecoinSource` is a base of every leaf, so its constructor runs before any lending or
 *      purchase constructor calls the token or its market.
 */
contract ZeroStablecoinTest is Test {
    address private constant FEE_COLLECTOR = address(0xFEE);
    address private constant MOC_PROXY = address(0x70C);
    address private constant SWAP_ROUTER = address(0x5A9);

    address private s_iSusd;
    address private s_aToken;
    MockMocOracle private s_oracle;
    MockWrbtcToken private s_wrBtc;

    function setUp() public {
        MockStablecoin stablecoin = new MockStablecoin(address(this));
        s_iSusd = address(new MockIsusdToken(address(stablecoin)));
        MockLayerBankAToken aToken = new MockLayerBankAToken(address(stablecoin));
        aToken.setPool(address(new MockLayerBankPool(aToken)));
        s_aToken = address(aToken);
        s_oracle = new MockMocOracle();
        s_wrBtc = new MockWrbtcToken();
    }

    function testIdleMocRejectsZeroStablecoin() public {
        vm.expectRevert(IStablecoinSource.StablecoinSource__ZeroStablecoin.selector);
        new IdleDocHandlerMoc(address(this), address(0), FEE_COLLECTOR, MOC_PROXY, _feeSettings(), address(this));
    }

    function testIdleDexRejectsZeroStablecoin() public {
        vm.expectRevert(IStablecoinSource.StablecoinSource__ZeroStablecoin.selector);
        new IdleErc20HandlerDex(
            address(this),
            address(0),
            _uniswapSettings(),
            FEE_COLLECTOR,
            _feeSettings(),
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            address(this)
        );
    }

    function testSovrynMocRejectsZeroStablecoin() public {
        vm.expectRevert(IStablecoinSource.StablecoinSource__ZeroStablecoin.selector);
        new SovrynDocHandlerMoc(
            address(this), address(0), s_iSusd, FEE_COLLECTOR, MOC_PROXY, _feeSettings(), address(this)
        );
    }

    function testSovrynDexRejectsZeroStablecoin() public {
        vm.expectRevert(IStablecoinSource.StablecoinSource__ZeroStablecoin.selector);
        new SovrynErc20HandlerDex(
            address(this),
            address(0),
            s_iSusd,
            _uniswapSettings(),
            FEE_COLLECTOR,
            _feeSettings(),
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            address(this)
        );
    }

    function testLayerBankMocRejectsZeroStablecoin() public {
        vm.expectRevert(IStablecoinSource.StablecoinSource__ZeroStablecoin.selector);
        new LayerBankDocHandlerMoc(
            address(this), address(0), s_aToken, FEE_COLLECTOR, MOC_PROXY, _feeSettings(), address(this)
        );
    }

    function testLayerBankDexRejectsZeroStablecoin() public {
        vm.expectRevert(IStablecoinSource.StablecoinSource__ZeroStablecoin.selector);
        new LayerBankErc20HandlerDex(
            address(this),
            address(0),
            s_aToken,
            _uniswapSettings(),
            FEE_COLLECTOR,
            _feeSettings(),
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
            address(this)
        );
    }

    function _feeSettings() private pure returns (IFeeHandler.FeeSettings memory) {
        return IFeeHandler.FeeSettings({
            minFeeRate: MIN_FEE_RATE,
            maxFeeRate: MAX_FEE_RATE_TEST,
            feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
            feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
        });
    }

    function _uniswapSettings() private view returns (IPurchaseUniswap.UniswapSettings memory) {
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;
        return IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(address(s_wrBtc)),
            swapRouter02: IUniswapV3SwapRouter(SWAP_ROUTER),
            swapIntermediateTokens: new address[](0),
            swapPoolFeeRates: poolFeeRates,
            mocOracle: ICoinPairPrice(address(s_oracle))
        });
    }
}
