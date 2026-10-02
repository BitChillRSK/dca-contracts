// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SovrynDocHandlerMoc} from "src/sovryn/SovrynDocHandlerMoc.sol";
import {ILendingHandler} from "src/interfaces/ILendingHandler.sol";
import {IiToken} from "src/sovryn/IiToken.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
import "test/Constants.sol";

/**
 * @title SovrynLiveITokenProbe
 * @notice View + construct probe against the live Rootstock Sovryn iSUSD loan token.
 * @dev Runs in the chain-tip fork lanes; skips when iSUSD has no code (Anvil). Pins the getter
 *      `SovrynHandler` checks at construction: `loanTokenAddress()`.
 */
contract SovrynLiveITokenProbe is Test {
    address internal constant I_TOKEN = 0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1;
    address internal constant DOC = 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db;
    address internal constant USDRIF = 0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37;

    function setUp() public {
        if (I_TOKEN.code.length == 0) vm.skip(true);
    }

    function test_liveIToken_underlyingGetterIsLoanTokenAddress() public {
        assertEq(IiToken(I_TOKEN).loanTokenAddress(), DOC, "loanTokenAddress()");

        (bool okUnderlying,) = I_TOKEN.staticcall(abi.encodeWithSignature("underlying()"));
        assertFalse(okUnderlying, "live iSUSD must not expose underlying()");
        (bool okAsset,) = I_TOKEN.staticcall(abi.encodeWithSignature("asset()"));
        assertFalse(okAsset, "live iSUSD must not expose asset()");
    }

    function test_liveIToken_constructsHandlerForItsUnderlying() public {
        SovrynDocHandlerMoc handler = _construct(DOC);
        assertEq(address(handler.i_iToken()), I_TOKEN);
        assertEq(handler.i_iToken().loanTokenAddress(), address(handler.i_stablecoin()));
    }

    function test_liveIToken_refusesAnotherStablecoin() public {
        vm.expectRevert(ILendingHandler.LendingHandler__UnderlyingMismatch.selector);
        _construct(USDRIF);
    }

    function _construct(address stablecoin) private returns (SovrynDocHandlerMoc) {
        return new SovrynDocHandlerMoc(
            address(this),
            stablecoin,
            I_TOKEN,
            address(this),
            address(this),
            IPurchaseFees.FeeSettings({
                minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE_TEST, feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND
            }),
            address(this)
        );
    }
}
