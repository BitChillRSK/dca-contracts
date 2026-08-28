// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {DcaManager} from "src/DcaManager.sol";
import {LayerBankErc20HandlerDex} from "src/layerbank/LayerBankErc20HandlerDex.sol";
import {DeployUsdrifHandler} from "script/DeployUsdrifHandler.s.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";
import {MockStablecoinWithDecimals} from "test/mocks/MockStablecoinWithDecimals.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "test/mocks/MockLayerBank.sol";
import {MockWrbtcToken} from "test/mocks/MockWrbtcToken.sol";
import {MockSwapRouter02} from "test/mocks/MockSwapRouter02.sol";
import {MockMocOracle} from "test/mocks/MockMocOracle.sol";
import "script/Constants.sol";

/**
 * @title Usdt0DexDeploymentTest
 * @notice USDT0 live/mainnet config is 6-decimal. Anvil mocks may stay 18-decimal; this suite is
 *         the coverage that the USDT0 handler is not constructed with DOC/USDRIF `Constants.sol` units.
 */
contract Usdt0DexDeploymentTest is Test {
    address internal constant OWNER = address(0x5678);

    function test_usdt0ConstantsAreNotEighteenDecimalDocUnits() public {
        assertEq(USDT0_MIN_PURCHASE_AMOUNT, 25e6);
        assertEq(USDT0_FEE_PURCHASE_LOWER_BOUND, 1000e6);
        assertEq(USDT0_FEE_PURCHASE_UPPER_BOUND, 100_000e6);
        assertTrue(USDT0_MIN_PURCHASE_AMOUNT != MIN_PURCHASE_AMOUNT);
        assertTrue(USDT0_FEE_PURCHASE_LOWER_BOUND != FEE_PURCHASE_LOWER_BOUND);
        assertTrue(USDT0_FEE_PURCHASE_UPPER_BOUND != FEE_PURCHASE_UPPER_BOUND);
    }

    function test_feeSettingsForToken_liveUsdt0UsesSixDecimalBounds() public {
        DeployUsdrifHandler deployer = new DeployUsdrifHandler();
        IFeeHandler.FeeSettings memory live = deployer.feeSettingsForToken(true);
        IFeeHandler.FeeSettings memory local = deployer.feeSettingsForToken(false);

        assertEq(live.feePurchaseLowerBound, USDT0_FEE_PURCHASE_LOWER_BOUND);
        assertEq(live.feePurchaseUpperBound, USDT0_FEE_PURCHASE_UPPER_BOUND);
        assertEq(local.feePurchaseLowerBound, FEE_PURCHASE_LOWER_BOUND);
        assertEq(local.feePurchaseUpperBound, FEE_PURCHASE_UPPER_BOUND);
    }

    function test_usdt0Handler_sixDecimalBoundsAndMinPurchase() public {
        vm.prank(OWNER);
        OperationsAdmin operationsAdmin = new OperationsAdmin(OWNER);
        vm.prank(OWNER);
        DcaManager dcaManager = new DcaManager(
            address(operationsAdmin), MIN_PURCHASE_PERIOD, MAX_SCHEDULES_PER_TOKEN, MIN_PURCHASE_AMOUNT, OWNER
        );

        (address handler, address usdt0) = _deploySixDecimalHandler(address(dcaManager));

        IFeeHandler.FeeSettings memory stored = IFeeHandler(handler).getFeeSettings();
        assertEq(stored.feePurchaseLowerBound, 1000e6);
        assertEq(stored.feePurchaseUpperBound, 100_000e6);
        assertTrue(stored.feePurchaseLowerBound != 1000 ether);
        assertTrue(stored.feePurchaseUpperBound != 100_000 ether);

        vm.prank(OWNER);
        dcaManager.setTokenMinPurchaseAmount(usdt0, USDT0_MIN_PURCHASE_AMOUNT);
        (uint256 minPurchase, bool custom) = dcaManager.getTokenMinPurchaseAmount(usdt0);
        assertTrue(custom);
        assertEq(minPurchase, 25e6);
        assertTrue(minPurchase != 25 ether);

        assertEq(LayerBankErc20HandlerDex(payable(handler)).i_aToken().UNDERLYING_ASSET_ADDRESS(), usdt0);
    }

    function _deploySixDecimalHandler(address dcaManager) internal returns (address handler, address usdt0) {
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
        handler = deployer.deployLayerBankErc20HandlerDex(
            DeployUsdrifHandler.DeployParams({
                dcaManagerAddress: dcaManager,
                tokenAddress: usdt0,
                aTokenAddress: address(aToken),
                uniswapSettings: IPurchaseUniswap.UniswapSettings({
                    wrBtcToken: IWRBTC(address(wrbtc)),
                    swapRouter02: ISwapRouter02(address(new MockSwapRouter02(wrbtc, BTC_PRICE))),
                    swapIntermediateTokens: intermediates,
                    swapPoolFeeRates: fees,
                    mocOracle: ICoinPairPrice(address(new MockMocOracle()))
                }),
                feeCollector: address(this),
                feeSettings: deployer.feeSettingsForToken(true),
                amountOutMinimumPercent: DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
                amountOutMinimumSafetyCheck: DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK,
                initialOwner: OWNER
            })
        );
    }
}
