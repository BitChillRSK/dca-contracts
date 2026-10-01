// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {DcaManager} from "src/DcaManager.sol";
import {LayerBankHandlerDex} from "src/layerbank/LayerBankHandlerDex.sol";
import {DeployUsdrifHandler} from "script/DeployUsdrifHandler.s.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {IUniswapV3SwapRouter} from "../../../src/interfaces/IUniswapV3SwapRouter.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";
import {MockStablecoinWithDecimals} from "test/mocks/MockStablecoinWithDecimals.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "test/mocks/MockLayerBank.sol";
import {MockWrbtcToken} from "test/mocks/MockWrbtcToken.sol";
import {MockSwapRouter02} from "test/mocks/MockSwapRouter02.sol";
import {MockMocOracle} from "test/mocks/MockMocOracle.sol";
import "test/Constants.sol";

contract DeployUsdrifHandlerHarness is DeployUsdrifHandler {
    function maybeAssign(
        OperationsAdmin operationsAdmin,
        DcaManager dcaManager,
        address stablecoin,
        address handler,
        bool isUsdt0Live
    ) external {
        _maybeAssign(operationsAdmin, dcaManager, stablecoin, handler, isUsdt0Live);
    }
}

/**
 * @title Usdt0DexDeploymentTest
 * @notice USDT0 live/mainnet config is 6-decimal. Anvil mocks may stay 18-decimal; this suite is
 *         the coverage that the USDT0 handler is not constructed with DOC/USDRIF `Constants.sol` units.
 */
contract Usdt0DexDeploymentTest is Test {
    function test_usdt0ConstantsAreNotEighteenDecimalDocUnits() public {
        assertEq(USDT0_MIN_PURCHASE_AMOUNT, 25e6);
        assertEq(USDT0_FEE_PURCHASE_LOWER_BOUND, 1000e6);
        assertTrue(USDT0_MIN_PURCHASE_AMOUNT != MIN_PURCHASE_AMOUNT);
        assertTrue(USDT0_FEE_PURCHASE_LOWER_BOUND != FEE_PURCHASE_LOWER_BOUND);
    }

    function test_feeSettingsForToken_liveUsdt0UsesSixDecimalBounds() public {
        DeployUsdrifHandler deployer = new DeployUsdrifHandler();
        IPurchaseFees.FeeSettings memory live = deployer.feeSettingsForToken(true);
        IPurchaseFees.FeeSettings memory local = deployer.feeSettingsForToken(false);

        assertEq(live.feePurchaseLowerBound, USDT0_FEE_PURCHASE_LOWER_BOUND);
        assertEq(local.feePurchaseLowerBound, FEE_PURCHASE_LOWER_BOUND);
    }

    function test_usdt0Handler_sixDecimalBoundsAndMinPurchase() public {
        DeployUsdrifHandlerHarness deployer = new DeployUsdrifHandlerHarness();
        (OperationsAdmin operationsAdmin, DcaManager dcaManager, address handler, address usdt0) =
            _deploySixDecimalStack(address(deployer));

        IPurchaseFees.FeeSettings memory stored = IPurchaseFees(handler).getFeeSettings();
        assertEq(stored.feePurchaseLowerBound, 1000e6);
        assertTrue(stored.feePurchaseLowerBound != 1000 ether);

        // Nested admin/manager calls come from the harness; own the stack as the harness so
        // `_maybeAssign`'s `msg.sender == owner` check matches production broadcast.
        vm.prank(address(deployer));
        deployer.maybeAssign(operationsAdmin, dcaManager, usdt0, handler, true);

        assertEq(dcaManager.getTokenMinPurchaseAmount(usdt0), 25e6);
        assertTrue(dcaManager.getTokenMinPurchaseAmount(usdt0) != 25 ether);
        assertEq(operationsAdmin.getHandler(usdt0, LAYERBANK_INDEX), handler);
        assertTrue(IPurchaseUniswap(handler).isPurchasePathAllowed(keccak256(IPurchaseUniswap(handler).getSwapPath())));
        assertEq(LayerBankHandlerDex(payable(handler)).i_aToken().UNDERLYING_ASSET_ADDRESS(), usdt0);
    }

    function test_maybeAssign_nonOwnerLeavesUsdt0MinUnset() public {
        DeployUsdrifHandlerHarness deployer = new DeployUsdrifHandlerHarness();
        (OperationsAdmin operationsAdmin, DcaManager dcaManager, address handler, address usdt0) =
            _deploySixDecimalStack(address(deployer));

        deployer.maybeAssign(operationsAdmin, dcaManager, usdt0, handler, true);

        assertEq(
            dcaManager.getTokenMinPurchaseAmount(usdt0), 0, "non-owner add-on must not set the min; Safe runbook has to"
        );
        assertEq(operationsAdmin.getHandler(usdt0, LAYERBANK_INDEX), address(0));
    }

    function _deploySixDecimalStack(address owner)
        internal
        returns (OperationsAdmin operationsAdmin, DcaManager dcaManager, address handler, address usdt0)
    {
        operationsAdmin = new OperationsAdmin(owner);
        dcaManager = new DcaManager(address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, owner);
        (handler, usdt0) = _deploySixDecimalHandler(address(dcaManager), owner);
    }

    function _deploySixDecimalHandler(address dcaManager, address owner)
        internal
        returns (address handler, address usdt0)
    {
        MockStablecoinWithDecimals token = new MockStablecoinWithDecimals(address(this), 6);
        assertEq(token.decimals(), 6);
        usdt0 = address(token);

        MockLayerBankAToken aToken = new MockLayerBankAToken(usdt0);
        MockLayerBankPool pool = new MockLayerBankPool(aToken);
        aToken.setPool(address(pool));

        MockWrbtcToken wrbtc = new MockWrbtcToken();
        address[] memory intermediates = new address[](0);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;

        DeployUsdrifHandler deployer = new DeployUsdrifHandler();
        handler = deployer.deployLayerBankHandlerDex(
            DeployUsdrifHandler.DeployParams({
                dcaManager: dcaManager,
                stablecoin: usdt0,
                aToken: address(aToken),
                uniswapSettings: IPurchaseUniswap.UniswapSettings({
                    wrbtc: IWRBTC(address(wrbtc)),
                    swapRouter: IUniswapV3SwapRouter(address(new MockSwapRouter02(wrbtc, BTC_PRICE))),
                    swapIntermediateTokens: intermediates,
                    swapPoolFeeRates: fees,
                    mocOracle: ICoinPairPrice(address(new MockMocOracle()))
                }),
                feeCollector: address(this),
                feeSettings: deployer.feeSettingsForToken(true),
                amountOutMinimumPercent: DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
                amountOutMinimumSafetyCheck: DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
                initialOwner: owner
            })
        );
    }
}
