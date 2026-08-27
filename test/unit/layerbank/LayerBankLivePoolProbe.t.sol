// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {LayerBankDocHandlerMoc} from "src/layerbank/LayerBankDocHandlerMoc.sol";
import {ILayerBankAToken} from "src/layerbank/ILayerBankAToken.sol";
import {ILayerBankPool} from "src/layerbank/ILayerBankPool.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import "script/Constants.sol";

/**
 * @title LayerBankLivePoolProbe
 * @notice View + construct probe against the live Rootstock LayerBank Aave Pool / lRooDOC aToken.
 * @dev Lives under `test/unit/` so `make fork-sovryn` (chain tip) runs it. Skips when the aToken
 *      has no code (Anvil, or a Tropykus pin from before this market existed). Does not add
 *      `LENDING_PROTOCOL=layerbank`.
 */
contract LayerBankLivePoolProbe is Test {
    address internal constant ATOKEN = 0x3F04280C66314b78E9712A41BF8C1A214460cAa2;
    address internal constant POOL = 0x526D06c65777eA6D56d7a1Dd47cD79230dDf72E9;
    address internal constant DOC = 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db;
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
            IFeeHandler.FeeSettings({
                minFeeRate: MIN_FEE_RATE,
                maxFeeRate: MAX_FEE_RATE_TEST,
                feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
                feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
            }),
            address(this)
        );
        assertEq(address(handler.i_aToken()), ATOKEN);
        assertEq(address(handler.i_pool()), POOL);
        assertEq(handler.i_aToken().UNDERLYING_ASSET_ADDRESS(), DOC);
    }
}
