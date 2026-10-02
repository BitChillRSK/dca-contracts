// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LayerBankDocHandlerMoc} from "src/layerbank/LayerBankDocHandlerMoc.sol";
import {ILayerBankAToken} from "src/layerbank/ILayerBankAToken.sol";
import {ILayerBankPool} from "src/layerbank/ILayerBankPool.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
import "test/Constants.sol";

/**
 * @title LayerBankLivePoolProbe
 * @notice View + construct probe against the live Rootstock LayerBank Aave Pool / lRooDOC aToken.
 * @dev Lives under `test/unit/` so `make fork-sovryn` (chain tip) runs it. Skips when the aToken
 *      has no code (Anvil, or a Tropykus pin from before this market existed). Does not add
 *      `LENDING_PROTOCOL=layerbank`.
 */
contract LayerBankLivePoolProbe is Test {
    address internal constant ATOKEN = 0x3F04280C66314b78E9712A41BF8C1A214460cAa2;
    address internal constant ATOKEN_USDRIF = 0xc96fBD12bE56Dd565b258d243344bCf792A51128;
    address internal constant ATOKEN_USDT0 = 0x6bE7d4cfCe825b106aa88F6916A412c5af230Ec0;
    address internal constant POOL = 0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9;
    address internal constant DOC = 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db;
    address internal constant USDRIF = 0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address internal constant RUSDT_HOP = 0xAf368c91793CB22739386DFCbBb2F1A9e4bCBeBf;
    address internal constant ADDRESSES_PROVIDER = 0x0c32000a7d7d4454a3CC3B700a8b12678ade7052;

    function setUp() public {
        if (ATOKEN.code.length == 0) vm.skip(true);
    }

    function test_liveAToken_isAavePoolNotV2Core() public {
        ILayerBankAToken aToken = ILayerBankAToken(ATOKEN);
        assertEq(aToken.POOL(), POOL, "POOL()");
        assertEq(aToken.UNDERLYING_ASSET_ADDRESS(), DOC, "UNDERLYING_ASSET_ADDRESS()");

        (bool okCore,) = ATOKEN.staticcall(abi.encodeWithSignature("core()"));
        assertFalse(okCore, "live aToken must not expose core()");
        (bool okRate,) = ATOKEN.staticcall(abi.encodeWithSignature("accruedExchangeRate()"));
        assertFalse(okRate, "live aToken must not expose accruedExchangeRate()");
        (bool okUnderlying,) = ATOKEN.staticcall(abi.encodeWithSignature("underlying()"));
        assertFalse(okUnderlying, "live aToken must not expose underlying()");

        ILayerBankPool pool = ILayerBankPool(POOL);
        uint256 income = pool.getReserveNormalizedIncome(DOC);
        assertGe(income, 1e27, "normalized income is RAY-scale");

        (bool okProvider, bytes memory data) = POOL.staticcall(abi.encodeWithSignature("ADDRESSES_PROVIDER()"));
        assertTrue(okProvider, "ADDRESSES_PROVIDER()");
        assertEq(abi.decode(data, (address)), ADDRESSES_PROVIDER);

        aToken.scaledBalanceOf(address(this));
    }

    function test_liveAToken_constructsHandler() public {
        LayerBankDocHandlerMoc handler = new LayerBankDocHandlerMoc(
            address(this),
            DOC,
            ATOKEN,
            address(this),
            address(this),
            IPurchaseFees.FeeSettings({
                minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE_TEST, feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND
            }),
            address(this)
        );
        assertEq(address(handler.i_aToken()), ATOKEN);
        assertEq(address(handler.i_pool()), POOL);
        assertEq(handler.i_aToken().UNDERLYING_ASSET_ADDRESS(), DOC);
    }

    /**
     * @dev `LayerBankHandler` sizes each withdrawal so that Aave's half-up `rayDiv` burns exactly the
     *      booked scaled shares. Current upstream Aave v3 burns with a ceiling instead (`rayDivCeil`
     *      in `TokenMath.getATokenBurnScaledAmount`); if LayerBank adopts it, the handler's
     *      floor + 1 candidate burns one share too many and those redeems revert on the shared
     *      exact-consumption check. No single amount is exact under both rules while the index is
     *      below 2 RAY, so the handler keeps the half-up sizing and this probe fails the fork gate
     *      the day the live Pool stops burning half-up.
     */
    function test_livePool_withdrawBurnsHalfUpScaledShares() public {
        uint256 supplied = 1000 ether;
        vm.prank(DOC_HOLDER);
        IERC20(DOC).transfer(address(this), supplied);
        IERC20(DOC).approve(POOL, supplied);

        ILayerBankPool pool = ILayerBankPool(POOL);
        ILayerBankAToken aToken = ILayerBankAToken(ATOKEN);
        pool.supply(DOC, supplied, address(this), 0);
        // One block, so the index every withdrawal below burns at.
        uint256 index = pool.getReserveNormalizedIncome(DOC);

        uint256 separatingSamples;
        for (uint256 i; i < 16; ++i) {
            uint256 amount = 1 ether + i * 7;
            uint256 halfUp = (amount * 1e27 + index / 2) / index;
            uint256 roundUp = (amount * 1e27 + index - 1) / index;

            uint256 scaledBefore = aToken.scaledBalanceOf(address(this));
            pool.withdraw(DOC, amount, address(this));
            uint256 burned = scaledBefore - aToken.scaledBalanceOf(address(this));

            assertEq(burned, halfUp, "live Pool no longer burns half-up: re-derive LayerBankHandler redeem sizing");
            if (halfUp != roundUp) ++separatingSamples;
        }
        assertGt(separatingSamples, 0, "no sample separated half-up from round-up");
    }

    function test_liveUsdrifAToken_underlyingIsUsdrifNotRusdt() public {
        if (ATOKEN_USDRIF.code.length == 0) vm.skip(true);
        ILayerBankAToken aToken = ILayerBankAToken(ATOKEN_USDRIF);
        assertEq(aToken.POOL(), POOL);
        assertEq(aToken.UNDERLYING_ASSET_ADDRESS(), USDRIF);
        assertTrue(aToken.UNDERLYING_ASSET_ADDRESS() != RUSDT_HOP);
    }

    function test_liveUsdt0AToken_underlyingIsUsdt0NotRusdt() public {
        if (ATOKEN_USDT0.code.length == 0) vm.skip(true);
        ILayerBankAToken aToken = ILayerBankAToken(ATOKEN_USDT0);
        assertEq(aToken.POOL(), POOL);
        assertEq(aToken.UNDERLYING_ASSET_ADDRESS(), USDT0);
        assertTrue(aToken.UNDERLYING_ASSET_ADDRESS() != RUSDT_HOP);
        uint256 income = ILayerBankPool(POOL).getReserveNormalizedIncome(USDT0);
        assertGe(income, 1e27, "USDT0 normalized income is RAY-scale");
    }
}
