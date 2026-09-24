// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SovrynDocHandlerMoc} from "src/sovryn/SovrynDocHandlerMoc.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {MockDecrementingStablecoin} from "test/mocks/MockDecrementingStablecoin.sol";
import {MockIsusdToken} from "test/mocks/MockIsusdToken.sol";
import {MockMocProxy} from "test/mocks/MockMocProxy.sol";
import "test/Constants.sol";

/**
 * @title StandingApprovalFallbackTest
 * @notice The deposit path's allowance top-up on a decrementing stablecoin, and the callback shape that
 *         keeps a standing lending allowance out of reach.
 * @dev The standing approval granted at construction is what every deposit normally spends, so the
 *      top-up in `LendingErc20Handler._depositToken` only fires for a token that decrements far enough
 *      to fall short. Runs on every lane: it builds its own handler and never reads the lane env.
 *      `dcaManager` is this test contract so the `onlyDcaManager` entry points are callable directly.
 */
contract StandingApprovalFallbackTest is Test {
    address internal constant USER = address(0xD0C0);
    address internal constant FEE_COLLECTOR = address(0xFEE);
    uint256 internal constant DEPOSIT_AMOUNT = 500 ether;

    MockDecrementingStablecoin internal docToken;
    MockIsusdToken internal iSusdToken;
    MockMocProxy internal mocProxy;
    SovrynDocHandlerMoc internal handler;

    function setUp() public {
        docToken = new MockDecrementingStablecoin(address(this));
        iSusdToken = new MockIsusdToken(address(docToken));
        mocProxy = new MockMocProxy(address(docToken));

        handler = new SovrynDocHandlerMoc(
            address(this),
            address(docToken),
            address(iSusdToken),
            FEE_COLLECTOR,
            address(mocProxy),
            IFeeHandler.FeeSettings({
                minFeeRate: MIN_FEE_RATE,
                maxFeeRate: MAX_FEE_RATE_TEST,
                feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND,
                feePurchaseUpperBound: FEE_PURCHASE_UPPER_BOUND
            }),
            address(this)
        );

        docToken.mint(USER, 10 * DEPOSIT_AMOUNT);
        vm.prank(USER);
        docToken.approve(address(handler), type(uint256).max);
    }

    /// @notice A decrementing token still deposits against the standing approval, which just shrinks.
    function test_decrementingToken_spendsTheStandingApproval() public {
        assertEq(docToken.allowance(address(handler), address(iSusdToken)), type(uint256).max);

        handler.depositToken(USER, DEPOSIT_AMOUNT);

        assertEq(
            docToken.allowance(address(handler), address(iSusdToken)),
            type(uint256).max - DEPOSIT_AMOUNT,
            "the standing allowance should have been spent, not rewritten"
        );
        assertGt(handler.getUserShares(USER), 0);
    }

    /// @notice Once the allowance no longer covers the deposit, the top-up restores it and the deposit lands.
    function test_exhaustedAllowance_isToppedUpByTheDeposit() public {
        vm.prank(address(handler));
        docToken.approve(address(iSusdToken), DEPOSIT_AMOUNT - 1); // one wei short of the next deposit

        handler.depositToken(USER, DEPOSIT_AMOUNT);

        assertGt(handler.getUserShares(USER), 0, "the top-up should have let the deposit through");
        assertEq(
            docToken.allowance(address(handler), address(iSusdToken)),
            0,
            "the top-up approves exactly the deposit, which the mint then spends in full"
        );
    }

    /**
     * @notice A lending handler answers no flash-loan callback, which is what bounds its standing
     *         allowance to its own deposits.
     * @dev Aave-style pools repay a flash loan from the `receiverAddress` the caller names rather than
     *      from the caller, so an address that holds a standing allowance **and** answers
     *      `executeOperation` can be made to pay a stranger's premium. LayerBank has flash loans
     *      disabled on all three shipped reserves today, but that is their switch, not ours. Ours is
     *      this: the handler declares no `executeOperation` and no `fallback`, so the callback reverts
     *      and unwinds the loan. Adding either to a lending handler would hand that vector a live
     *      target, which is why the leaf headers carry it as a precondition.
     */
    function test_handlerAnswersNoFlashLoanCallback() public {
        (bool answered,) = address(handler).call(
            abi.encodeWithSignature(
                "executeOperation(address,uint256,uint256,address,bytes)",
                address(docToken),
                DEPOSIT_AMOUNT,
                0,
                address(this),
                ""
            )
        );
        assertFalse(answered, "the handler answered a flash-loan callback");

        // Nor does it accept unknown calldata through a fallback, which would decode as a false return.
        (bool fellThrough,) = address(handler).call(abi.encodeWithSignature("someUnknownHook()"));
        assertFalse(fellThrough, "the handler has a fallback");

        // Native rBTC still arrives, so the refusal above is the missing hook and not a dead contract.
        vm.deal(address(this), 1 ether);
        (bool received,) = address(handler).call{value: 1 ether}("");
        assertTrue(received, "the handler should still accept native rBTC");
    }
}
